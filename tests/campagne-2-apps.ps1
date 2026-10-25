#requires -Version 5.1
<#
Campagne RESULTATS-BF avec 2 applications.
Depuis le depot : .\scripts\campagne-2-apps.ps1 -DossierCampagne .\tests\resultats\campagne-partagee
Prerequis : Vagrant/VirtualBox, .env configure, bdd1/bdd2/app1/app2/lb1/obs en marche.
Le script arrete lb2 ; la version 2 applications arrete aussi app3 et app4.
Il applique le code applicatif du depot. Aucun arret des bases, aucune promotion.
Il laisse les VM dans la configuration mesuree ; ne pas lancer les deux scripts ensemble.
#>
[CmdletBinding()]
param(
    [string]$DossierCampagne = "",
    [ValidateRange(1, 10)][int]$Repetitions = 3,
    [ValidateRange(0, 300)][int]$PauseSecondes = 30
)

$ErrorActionPreference = "Stop"
$NombreApps = 2
$racine = Split-Path -Parent $PSScriptRoot
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$transcription = $false
$horaires = $null

function Executer-Vagrant {
    param([string[]]$Arguments)
    & vagrant @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Echec Vagrant : $($Arguments -join ' '). Consulter la transcription."
    }
}

function Lire-Etat {
    param([string]$Nom)
    $lignes = @(& vagrant status $Nom --machine-readable)
    if ($LASTEXITCODE -ne 0) { throw "Etat Vagrant illisible : $Nom" }
    $motif = ',' + [regex]::Escape($Nom) + ',state,([^,]+)$'
    foreach ($ligne in $lignes) {
        if ("$ligne" -match $motif) { return $Matches[1].Trim() }
    }
    throw "Etat de $Nom introuvable."
}

function Lire-Nombre {
    param([string]$Texte, [string]$Motif, [bool]$Facultatif = $false)
    $m = [regex]::Match($Texte, $Motif)
    if (-not $m.Success) {
        if ($Facultatif) { return 0.0 }
        throw "Sortie ApacheBench incomplete : champ manquant ($Motif)."
    }
    return [double]::Parse($m.Groups[1].Value, $invariant)
}

function Mesurer-Ab {
    param([string]$Nom, [int]$Requetes, [int]$Clients)
    $fichier = Join-Path $dossier "$Nom.txt"
    $ram = Get-CimInstance Win32_OperatingSystem
    $debut = (Get-Date).ToUniversalTime()
    Write-Host "=== $NombreApps applications : $Nom ($Requetes requetes, $Clients clients) ==="
    & vagrant ssh lb1 -c "ab -n $Requetes -c $Clients 'http://127.0.0.1/resultat?matricule=BF000001' 2>&1" |
        Tee-Object -FilePath $fichier | Out-Host
    $code = $LASTEXITCODE
    $fin = (Get-Date).ToUniversalTime()
    [pscustomobject]@{
        applications = $NombreApps; essai = $Nom
        debut_utc = $debut.ToString("o"); fin_utc = $fin.ToString("o")
        ram_hote_libre_go_avant = [math]::Round($ram.FreePhysicalMemory / 1MB, 2)
        code_execution = $code
    } | Export-Csv -Path $horaires -Append -Delimiter ";" -NoTypeInformation -Encoding UTF8
    if ($code -ne 0) { throw "Commande ApacheBench interrompue ($Nom, code $code)." }
    $texte = Get-Content -LiteralPath $fichier -Raw
    $completes = Lire-Nombre $texte 'Complete requests:\s+(\d+)'
    $echecs = Lire-Nombre $texte 'Failed requests:\s+(\d+)'
    $non2xx = Lire-Nombre $texte 'Non-2xx responses:\s+(\d+)' $true
    $mesure = [pscustomobject]@{
        applications = $NombreApps; essai = $Nom; clients = $Clients
        requetes = $completes; echecs_ab = $echecs; non_2xx = $non2xx
        duree_s = Lire-Nombre $texte 'Time taken for tests:\s+([0-9.]+)'
        debit_req_s = Lire-Nombre $texte 'Requests per second:\s+([0-9.]+)'
        p50_ms = Lire-Nombre $texte '(?m)^\s*50%\s+(\d+)'
        p95_ms = Lire-Nombre $texte '(?m)^\s*95%\s+(\d+)'
        p99_ms = Lire-Nombre $texte '(?m)^\s*99%\s+(\d+)'
        maximum_ms = Lire-Nombre $texte '(?m)^\s*100%\s+(\d+)'
    }
    $mesure | Export-Csv -Path (Join-Path $dossier 'resume.csv') -Append `
        -Delimiter ";" -NoTypeInformation -Encoding UTF8
    # Echecs AB et non-2xx peuvent concerner les memes requetes : ne pas les additionner.
    if ($completes -ne $Requetes -or $echecs -ne 0 -or $non2xx -ne 0) {
        throw "Erreurs HTTP/AB dans $Nom : campagne arretee, preuves conservees."
    }
}

function Verifier-Cibles {
    $cibles = Invoke-RestMethod -Uri "$urlPrometheus/api/v1/targets" -TimeoutSec 15
    if ($cibles.status -ne 'success') { throw "API des cibles Prometheus en echec." }
    $cibles | ConvertTo-Json -Depth 30 |
        Set-Content (Join-Path $dossier 'cibles-avant.json') -Encoding UTF8
    foreach ($nom in (@('bdd1', 'bdd2', 'lb1', 'obs') + $applications)) {
        $cible = @($cibles.data.activeTargets | Where-Object {
            $_.labels.job -eq 'systeme' -and $_.labels.noeud -eq $nom
        })
        if ($cible.Count -ne 1 -or $cible[0].health -ne 'up') {
            throw "Cible systeme absente ou indisponible : $nom. Reparer avant la charge."
        }
    }
    $ha = @($cibles.data.activeTargets | Where-Object {
        $_.labels.job -eq 'haproxy' -and $_.labels.noeud -eq 'lb1'
    })
    if ($ha.Count -ne 1 -or $ha[0].health -ne 'up') {
        throw "Exporteur HAProxy lb1 indisponible : reparer avant la charge."
    }
}

function Exporter-Prometheus {
    param([datetime]$Debut, [datetime]$Fin)
    $requetesProm = [ordered]@{
        disponibilite = 'up'
        cpu = '100 * (1 - avg by (noeud) (rate(node_cpu_seconds_total{job="systeme",mode="idle"}[1m])))'
        memoire_disponible = 'node_memory_MemAvailable_bytes{job="systeme"}'
        swap_entree = 'rate(node_vmstat_pswpin{job="systeme"}[1m])'
        swap_sortie = 'rate(node_vmstat_pswpout{job="systeme"}[1m])'
        applications_up = 'haproxy_server_status{job="haproxy",proxy="app_be",state="UP"}'
    }
    foreach ($nom in $requetesProm.Keys) {
        $parametres = @{
            query = $requetesProm[$nom]; start = $Debut.ToString('o')
            end = $Fin.ToString('o'); step = '5s'
        }
        $resultat = Invoke-RestMethod -Uri "$urlPrometheus/api/v1/query_range" `
            -Method Get -Body $parametres -TimeoutSec 30
        if ($resultat.status -ne 'success' -or $resultat.data.result.Count -eq 0) {
            throw "Export historique vide ou en echec : $nom."
        }
        $resultat | ConvertTo-Json -Depth 30 |
            Set-Content (Join-Path $dossier "prometheus-$nom.json") -Encoding UTF8
    }
}

Push-Location $racine
try {
    foreach ($chemin in @('Vagrantfile', '.env', 'app/app.py', 'scripts/obs.sh', 'scripts/pg.sh')) {
        if (-not (Test-Path -LiteralPath $chemin)) { throw "Fichier requis absent : $chemin" }
    }
    Get-Command vagrant, curl.exe -ErrorAction Stop | Out-Null
    if ([string]::IsNullOrWhiteSpace($DossierCampagne)) {
        $DossierCampagne = 'tests/resultats/campagne-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    }
    if (-not [System.IO.Path]::IsPathRooted($DossierCampagne)) {
        $DossierCampagne = Join-Path $racine $DossierCampagne
    }
    $dossier = Join-Path $DossierCampagne (
        "$NombreApps-apps-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    )
    New-Item -ItemType Directory -Path $dossier -Force | Out-Null
    $horaires = Join-Path $dossier 'horaires.csv'
    Start-Transcript -Path (Join-Path $dossier 'transcription.txt') | Out-Host
    $transcription = $true
    Write-Host "Configuration : $NombreApps applications ; E1/E2 ; lb2 arretee."
    Write-Host "Les bases doivent deja fonctionner. Ne pas lancer une autre campagne en parallele."
    $env:NB_APP = "$NombreApps"
    $env:EXTENSIONS = 'e1,e2'
    Executer-Vagrant -Arguments @('validate') | Out-Host
    foreach ($nom in @('bdd1', 'bdd2', 'app1', 'app2', 'lb1', 'obs')) {
        if ((Lire-Etat $nom) -ne 'running') { throw "VM requise arretee : $nom. Aucun demarrage automatique des bases." }
    }
    $roles = @{}
    foreach ($nom in @('bdd1', 'bdd2')) {
        $sortie = @(Executer-Vagrant -Arguments @('ssh', $nom, '-c', 'sudo timeout 25s bash /vagrant/scripts/pg.sh status'))
        $mode = @($sortie | Where-Object { "$_".Trim() -match '^(primaire|replique)$' })
        if ($mode.Count -ne 1) { throw "Role PostgreSQL indetermine : $nom" }
        $roles[$nom] = "$($mode[0])".Trim()
    }
    if (@($roles.Values | Where-Object { $_ -eq 'primaire' }).Count -ne 1 -or
        @($roles.Values | Where-Object { $_ -eq 'replique' }).Count -ne 1) {
        throw "Il faut exactement un primaire et une replique. Aucune promotion effectuee."
    }
    $roles | ConvertTo-Json | Set-Content (Join-Path $dossier 'roles-bdd.json') -Encoding UTF8
    Executer-Vagrant -Arguments @('halt', 'lb2') | Out-Host
    if ($NombreApps -eq 2) {
        # Declarer temporairement app3/app4 permet leur arret meme si NB_APP valait 2.
        $env:NB_APP = '4'
        try { Executer-Vagrant -Arguments @('halt', 'app3', 'app4') | Out-Host }
        finally { $env:NB_APP = '2' }
    } else {
        Executer-Vagrant -Arguments @('up', 'app3', 'app4') | Out-Host
    }
    $applications = @(1..$NombreApps | ForEach-Object { "app$_" })
    Executer-Vagrant -Arguments (@('provision') + $applications) | Out-Host
    Executer-Vagrant -Arguments @('provision', 'lb1', 'obs') | Out-Host
    Executer-Vagrant -Arguments @('ssh', 'lb1', '-c', 'command -v ab') | Out-Host
    Get-Content 'config/plateforme.env' | Set-Content (Join-Path $dossier 'plateforme.txt') -Encoding UTF8
    Copy-Item 'app/app.py' (Join-Path $dossier 'app-mesuree.py')
    Copy-Item 'scripts/lb.sh' (Join-Path $dossier 'lb-mesure.sh')
    Get-FileHash 'app/app.py', 'scripts/lb.sh' -Algorithm SHA256 |
        Export-Csv (Join-Path $dossier 'empreintes-code.csv') -NoTypeInformation -Delimiter ';' -Encoding UTF8
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git -and (Test-Path '.git')) {
        & git rev-parse HEAD | Set-Content (Join-Path $dossier 'commit.txt') -Encoding UTF8
        & git status --short | Set-Content (Join-Path $dossier 'modifications.txt') -Encoding UTF8
    }
    $ligne = Get-Content 'config/plateforme.env' | Where-Object { $_ -match '^GROUPE=' }
    $groupe = [int](($ligne -split '=', 2)[1])
    $urlPrometheus = 'http://192.168.{0}.41:9090' -f (55 + $groupe)
    # Laisser les premieres collectes suivre les rechargements de configuration.
    Start-Sleep -Seconds 15
    Verifier-Cibles
    $stats = @(Executer-Vagrant -Arguments @('ssh', 'lb1', '-c', "echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock"))
    $csvStats = @($stats | ForEach-Object { "$_" -replace '^#\s*', '' })
    $serveurs = @($csvStats | ConvertFrom-Csv | Where-Object {
        $_.pxname -eq 'app_be' -and $_.svname -match '^app[0-9]+$'
    })
    if ($serveurs.Count -ne $NombreApps) { throw "Nombre de serveurs HAProxy inattendu." }
    foreach ($nom in $applications) {
        if (@($serveurs | Where-Object { $_.svname -eq $nom -and $_.status -eq 'UP' }).Count -ne 1) {
            throw "Serveur HAProxy absent ou non UP : $nom"
        }
    }
    $resultatHttp = Invoke-RestMethod -Uri 'http://localhost:8080/resultat?matricule=BF000001' -TimeoutSec 10
    if ($resultatHttp.matricule -ne 'BF000001') { throw "Consultation HTTP incorrecte." }
    $debutMesures = (Get-Date).ToUniversalTime()
    try {
        Mesurer-Ab 'echauffement' 200 10
        foreach ($essai in 1..$Repetitions) {
            Mesurer-Ab "essai-$essai" 2000 50
            if ($essai -lt $Repetitions) { Start-Sleep -Seconds $PauseSecondes }
        }
    } finally {
        # Exporter aussi les preuves historiques si un essai HTTP echoue.
        $finMesures = (Get-Date).ToUniversalTime()
        try { Exporter-Prometheus $debutMesures $finMesures }
        catch {
            "Collecte incomplete : $($_.Exception.Message)" |
                Set-Content (Join-Path $dossier 'supervision-incomplete.txt') -Encoding UTF8
            Write-Warning "Export Prometheus incomplet : voir supervision-incomplete.txt"
        }
    }
    Write-Host "Mesures HTTP terminees sans erreur. Preuves : $dossier"
    Import-Csv (Join-Path $dossier 'resume.csv') -Delimiter ';' | Format-Table -AutoSize | Out-Host
} catch {
    if ($null -ne $horaires) {
        "ECHEC : $($_.Exception.Message)" | Set-Content (Join-Path $dossier 'echec.txt') -Encoding UTF8
    }
    throw
} finally {
    if ($transcription) { Stop-Transcript | Out-Host }
    Pop-Location
}
