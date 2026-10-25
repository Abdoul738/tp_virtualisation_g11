#requires -Version 5.1
<#
V3 autonome - RESULTATS-BF. Un essai ab -n 2000 -c 50 par configuration.
Prerequis : bases fonctionnelles, Vagrant et ab/curl/timeout sur lb1.
Le script arrete lb2 et app3/app4, prepare 2 puis 4 applications et provisionne lb1.
Il ne modifie pas les bases. A la fin : lb2 arretee, 4 applications actives.
En cas d'erreur : pas de restauration automatique ; consulter les journaux.
Ne pas modifier le projet ou lancer un autre test pendant l'execution.
-l autorise les longueurs JSON variables (nom du serveur), sans masquer les codes HTTP.
#>
[CmdletBinding()]
param(
    [string]$DossierResultats = '',
    [string]$UrlTest = 'http://127.0.0.1/resultat?matricule=BF000001',
    [switch]$SansEchauffement
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$racine = Split-Path -Parent $PSScriptRoot
$culture = [Globalization.CultureInfo]::InvariantCulture
$dossier = $null
$ancienNb = [Environment]::GetEnvironmentVariable('NB_APP', 'Process')
$anciennesExtensions = [Environment]::GetEnvironmentVariable('EXTENSIONS', 'Process')

function Quote-Shell([string]$Valeur) {
    # Une apostrophe est fermee, echappee, puis rouverte.
    return "'" + $Valeur.Replace("'", "'\''") + "'"
}
function Executer-Vagrant {
    param([string[]]$Arguments, [string]$Journal)
    & vagrant @Arguments 2>&1 | Tee-Object -FilePath $Journal | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Vagrant a echoue (code $code). Journal : $Journal" }
}
function Capturer-SSH {
    param([string]$Commande, [string]$Journal)
    # Le fichier stdout contient les seules mesures ; stderr reste dans son propre journal.
    $sortie = @(& vagrant ssh lb1 -c $Commande 2> ($Journal + '.stderr.txt'))
    $code = $LASTEXITCODE
    $texte = $sortie -join "`n"
    $texte | Set-Content -LiteralPath $Journal -Encoding UTF8
    if ($code -ne 0) { throw "Commande sur lb1 en echec (code $code). Voir $Journal et son stderr." }
    return $texte
}
function Nombre-Ab {
    param([string]$Texte, [string]$Motif, [switch]$Optionnel)
    $m = [regex]::Match($Texte, $Motif, [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $m.Success) {
        if ($Optionnel) { return 0 }
        throw "Sortie ApacheBench incomplete : $Motif"
    }
    return [double]::Parse($m.Groups[1].Value, $culture)
}
function Lire-Ab {
    param([string]$Texte, [int]$Apps)
    $n = Nombre-Ab $Texte '^Complete requests:\s+(\d+)\s*$'
    $c = Nombre-Ab $Texte '^Concurrency Level:\s+(\d+)\s*$'
    $duree = Nombre-Ab $Texte '^Time taken for tests:\s+([0-9.]+)\s+seconds'
    $debit = Nombre-Ab $Texte '^Requests per second:\s+([0-9.]+)'
    if ($n -ne 2000 -or $c -ne 50 -or $duree -le 0 -or $debit -le 0) {
        throw 'Essai incomplet : 2000 requetes, 50 clients et des mesures positives sont requis.'
    }
    return [pscustomobject]@{
        applications = $Apps
        requetes = [int]$n
        clients = [int]$c
        duree_s = $duree
        debit_req_s = $debit
        p50_ms = Nombre-Ab $Texte '^\s*50%\s+(\d+)'
        p95_ms = Nombre-Ab $Texte '^\s*95%\s+(\d+)'
        p99_ms = Nombre-Ab $Texte '^\s*99%\s+(\d+)'
        maximum_ms = Nombre-Ab $Texte '^\s*100%\s+(\d+)'
        echecs_ab = [int](Nombre-Ab $Texte '^Failed requests:\s+(\d+)')
        non_2xx = [int](Nombre-Ab $Texte '^Non-2xx responses:\s+(\d+)' -Optionnel)
    }
}
function Empreinte-Projet {
    $lignes = foreach ($relatif in @('app/app.py', 'scripts/lb.sh', 'Vagrantfile')) {
        $chemin = Join-Path $racine $relatif
        if (-not (Test-Path -LiteralPath $chemin -PathType Leaf)) { throw "Fichier absent : $relatif" }
        $relatif + ':' + (Get-FileHash -LiteralPath $chemin -Algorithm SHA256).Hash
    }
    return ($lignes -join "`n")
}
function Verifier-HTTP {
    param([int]$Apps, [string]$Chemin)
    $vus = @{}
    # Vingt appels sequentiels a /info via le HAProxy de lb1.
    $infoUrl = $script:uri.GetLeftPart([UriPartial]::Authority) + '/info'
    for ($i = 1; $i -le 20; $i++) {
        $texte = Capturer-SSH ('curl -fsS --max-time 10 ' + (Quote-Shell $infoUrl)) `
            (Join-Path $Chemin ('info-{0:D2}.json' -f $i))
        $json = $texte | ConvertFrom-Json
        $nom = [string]$json.serveur
        if ($nom -notin @(1..$Apps | ForEach-Object { "app$_" })) {
            throw "Serveur inattendu dans /info : $nom"
        }
        $vus[$nom] = $true
    }
    if ($vus.Count -ne $Apps) { throw "Seulement $($vus.Count) applications observees sur $Apps attendues." }
    $texte = Capturer-SSH ('curl -fsS --max-time 10 ' + (Quote-Shell $UrlTest)) `
        (Join-Path $Chemin 'resultat-avant.json')
    $json = $texte | ConvertFrom-Json
    if (-not $json.PSObject.Properties['matricule']) { throw 'La consultation ne renvoie pas de matricule.' }
}

Push-Location $racine
try {
    Get-Command vagrant -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath 'config/plateforme.env')) { throw 'config/plateforme.env absent.' }
    $script:uri = [uri]$UrlTest
    if (-not $script:uri.IsAbsoluteUri -or $script:uri.Scheme -ne 'http' -or
        $script:uri.Host -notin @('127.0.0.1', 'localhost') -or $script:uri.Port -ne 80) {
        throw 'UrlTest doit viser le HAProxy local de lb1 : http://127.0.0.1/… (port 80).'
    }
    if ([string]::IsNullOrWhiteSpace($DossierResultats)) { $DossierResultats = 'tests/resultats' }
    if (-not [IO.Path]::IsPathRooted($DossierResultats)) { $DossierResultats = Join-Path $racine $DossierResultats }
    $dossier = Join-Path $DossierResultats ('v3-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $dossier -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $dossier 'v3-execute.ps1')
    $debut = (Get-Date).ToUniversalTime().ToString('o')
    $empreinte = Empreinte-Projet
    $empreinte | Set-Content (Join-Path $dossier 'empreintes.txt') -Encoding UTF8
    Write-Host 'V3 autonome : 2000 requetes / 50 clients, une fois avec 2 puis 4 applications.'
    Write-Host "Preuves : $dossier"
    $env:EXTENSIONS = 'e1,e2'
    $env:NB_APP = '4'
    Executer-Vagrant -Arguments @('halt', 'app3', 'app4') -Journal (Join-Path $dossier 'arret-vm.txt')
    $mesures = @()
    foreach ($nombre in @(2, 4)) {
        $env:NB_APP = [string]$nombre
        $chemin = Join-Path $dossier "$nombre-apps"
        New-Item -ItemType Directory -Path $chemin | Out-Null
        Write-Host "Preparation : $nombre applications."
        $machines = @('lb1') + @(1..$nombre | ForEach-Object { "app$_" })
        Executer-Vagrant -Arguments (@('up') + $machines) -Journal (Join-Path $chemin 'demarrage.txt')
        Executer-Vagrant -Arguments @('provision', 'lb1') -Journal (Join-Path $chemin 'provision-lb1.txt')
        Capturer-SSH 'command -v ab && command -v curl && command -v timeout && systemctl is-active haproxy' `
            (Join-Path $chemin 'prerequis.txt') | Out-Null
        if ((Empreinte-Projet) -ne $empreinte) { throw 'Le code du projet a change pendant le test.' }
        Verifier-HTTP $nombre $chemin
        $urlShell = Quote-Shell $UrlTest
        if (-not $SansEchauffement) {
            $chaud = Capturer-SSH ("LC_ALL=C timeout 120s ab -l -s 10 -n 200 -c 10 $urlShell") `
                (Join-Path $chemin 'echauffement.txt')
            $echecsChaud = Nombre-Ab $chaud '^Failed requests:\s+(\d+)'
            $httpChaud = Nombre-Ab $chaud '^Non-2xx responses:\s+(\d+)' -Optionnel
            $nombreChaud = Nombre-Ab $chaud '^Complete requests:\s+(\d+)'
            if ($echecsChaud -ne 0 -or $httpChaud -ne 0 -or $nombreChaud -ne 200) { throw 'Echauffement incomplet ou avec erreurs.' }
        }
        $debutEssai = (Get-Date).ToUniversalTime().ToString('o')
        $brut = Capturer-SSH ("LC_ALL=C timeout 600s ab -l -s 10 -n 2000 -c 50 $urlShell") `
            (Join-Path $chemin 'ab.txt')
        $mesure = Lire-Ab $brut $nombre
        $mesure | Add-Member -NotePropertyName debut_utc -NotePropertyValue $debutEssai
        $mesure | Add-Member -NotePropertyName fin_utc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o'))
        $mesures += $mesure
        $mesures | Export-Csv (Join-Path $dossier 'comparaison.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
        if ((Empreinte-Projet) -ne $empreinte) { throw 'Le code du projet a change pendant le test.' }
        Verifier-HTTP $nombre $chemin
    }
    $valide = @($mesures | Where-Object { $_.echecs_ab -gt 0 -or $_.non_2xx -gt 0 }).Count -eq 0
    $gain = [math]::Round(100 * ($mesures[1].debit_req_s / $mesures[0].debit_req_s - 1), 2)
    $resume = [pscustomobject]@{
        scenario = 'V3'; debut_utc = $debut; fin_utc = (Get-Date).ToUniversalTime().ToString('o')
        essais_par_configuration = 1; requetes_par_essai = 2000; clients = 50
        url_depuis_lb1 = $UrlTest; echauffement = (-not $SansEchauffement.IsPresent)
        debit_2_apps_req_s = $mesures[0].debit_req_s
        debit_4_apps_req_s = $mesures[1].debit_req_s
        gain_debit_pourcent = $gain
        comparaison_sans_erreurs = $valide
        augmentation_sans_erreurs_observee = ($valide -and $gain -gt 0)
        limite = 'Un seul essai par configuration ; generateur et HAProxy sur lb1 ; pas de collecte Prometheus.'
    }
    $resume | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dossier 'resume-v3.json') -Encoding UTF8
    $mesures | Format-Table applications, debit_req_s, p95_ms, echecs_ab, non_2xx -AutoSize | Out-Host
    Write-Host "Variation du debit : $gain %"
    if (-not $valide) { Write-Warning 'Essais avec erreurs : le gain ne valide pas une amelioration.' }
    elseif ($gain -le 0) { Write-Warning 'Aucun gain de debit observe.' }
    Write-Host 'Termine : 4 applications actives ; lb2 arretee.'
    Write-Host "Preuves : $dossier"
} catch {
    if ($null -ne $dossier) {
        $_.Exception.Message | Set-Content (Join-Path $dossier 'echec-v3.txt') -Encoding UTF8
        Write-Host "Preuves de l'echec : $dossier"
    }
    throw
} finally {
    [Environment]::SetEnvironmentVariable('NB_APP', $ancienNb, 'Process')
    [Environment]::SetEnvironmentVariable('EXTENSIONS', $anciennesExtensions, 'Process')
    Pop-Location
}