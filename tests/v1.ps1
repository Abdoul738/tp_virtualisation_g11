#requires -Version 5.1
<#
V1 - Repartition de charge RESULTATS-BF : 20 appels successifs a /info.
Prerequis : plateforme demarree et repartiteur accessible.
NB_APP est lu dans config/plateforme.env genere par Vagrant ; verifier son actualite.
Ce script ne demarre, n'arrete et ne provisionne aucune VM.
Convention du test : ecart relatif = (maximum - minimum) / moyenne par application * 100.
Critere : aucune erreur, toutes les applications attendues presentes, ecart strictement < 20 %.
#>
[CmdletBinding()]
param(
    [uri]$UrlBase = 'http://localhost:8080',
    [ValidateRange(0, 9)][int]$NombreApplications = 0,
    [ValidateRange(1, 60)][int]$DelaiMaximumSecondes = 5,
    [ValidateRange(0, 5000)][int]$PauseMillisecondes = 250,
    [string]$DossierResultats = ''
)

$ErrorActionPreference = 'Stop'
$racine = Split-Path -Parent $PSScriptRoot
$dossier = $null
Push-Location $racine
try {
    if (-not $UrlBase.IsAbsoluteUri -or $UrlBase.Scheme -notin @('http', 'https') -or
        $UrlBase.Query -ne '' -or $UrlBase.Fragment -ne '') {
        throw 'UrlBase doit etre une adresse HTTP(S) absolue sans requete ni fragment.'
    }
    $configuration = Join-Path $racine 'config/plateforme.env'
    if ($NombreApplications -eq 0) {
        if (-not (Test-Path -LiteralPath $configuration)) {
            throw 'config/plateforme.env absent : fournir -NombreApplications 2 ou 4, ou generer la configuration avec Vagrant.'
        }
        $lignes = @(Get-Content -LiteralPath $configuration |
            Where-Object { $_ -match '^\s*NB_APP=\d+\s*$' })
        if ($lignes.Count -ne 1) { throw 'Une unique ligne NB_APP est attendue dans plateforme.env.' }
        $NombreApplications = [int](($lignes[0] -split '=', 2)[1].Trim())
    }
    if ($NombreApplications -lt 2 -or $NombreApplications -gt 9) {
        throw 'Le nombre attendu doit etre compris entre 2 et 9.'
    }
    $applications = @(1..$NombreApplications | ForEach-Object { "app$_" })
    $urlInfo = $UrlBase.AbsoluteUri.TrimEnd('/') + '/info'
    if ([string]::IsNullOrWhiteSpace($DossierResultats)) { $DossierResultats = 'tests/resultats' }
    if (-not [System.IO.Path]::IsPathRooted($DossierResultats)) {
        $DossierResultats = Join-Path $racine $DossierResultats
    }
    $dossier = Join-Path $DossierResultats (
        'v1-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' +
        ([guid]::NewGuid().ToString('N').Substring(0, 6))
    )
    New-Item -ItemType Directory -Force $dossier | Out-Null
    if (Test-Path -LiteralPath $configuration) {
        Copy-Item -LiteralPath $configuration -Destination (Join-Path $dossier 'plateforme.txt')
    }
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $dossier 'v1-execute.ps1')
    $fichier = Join-Path $dossier 'requetes.csv'
    $mesures = [System.Collections.Generic.List[object]]::new()
    $debutTest = (Get-Date).ToUniversalTime()
    Write-Host "V1 : 20 appels successifs vers $urlInfo"
    Write-Host "Applications attendues : $($applications -join ', ')"
    Write-Host "Preuves : $dossier"

    foreach ($numero in 1..20) {
        $debut = (Get-Date).ToUniversalTime()
        $chrono = [System.Diagnostics.Stopwatch]::StartNew()
        $http = 0
        $serveur = ''
        $erreur = ''
        try {
            $reponse = Invoke-WebRequest -Uri $urlInfo -Method Get -UseBasicParsing `
                -DisableKeepAlive -TimeoutSec $DelaiMaximumSecondes -ErrorAction Stop
            $http = [int]$reponse.StatusCode
            $corps = $reponse.Content | ConvertFrom-Json -ErrorAction Stop
            $serveur = ([string]$corps.serveur).Trim()
            if ($http -ne 200) { throw "Code HTTP inattendu : $http" }
            if ([string]::IsNullOrWhiteSpace($serveur)) { throw 'Champ serveur absent ou vide.' }
            if ($serveur -notin $applications) { throw "Serveur inattendu : $serveur" }
        } catch {
            if ($null -ne $_.Exception.Response) {
                try { $http = [int]$_.Exception.Response.StatusCode } catch { }
            }
            $erreur = $_.Exception.Message
        } finally {
            $chrono.Stop()
        }
        $mesure = [pscustomobject]@{
            numero = $numero
            debut_utc = $debut.ToString('o')
            fin_utc = (Get-Date).ToUniversalTime().ToString('o')
            duree_ms = [math]::Round($chrono.Elapsed.TotalMilliseconds, 2)
            http = $http
            serveur = $serveur
            erreur = $erreur
        }
        $mesures.Add($mesure)
        $mesure | Export-Csv -Path $fichier -Append -Delimiter ';' -NoTypeInformation -Encoding UTF8
        Write-Host ("{0}/20 HTTP={1} serveur={2} erreur={3}" -f $numero, $http, $serveur, $erreur)
        if ($numero -lt 20 -and $PauseMillisecondes -gt 0) {
            Start-Sleep -Milliseconds $PauseMillisecondes
        }
    }

    $repartition = @(foreach ($nom in $applications) {
        $compte = @($mesures | Where-Object {
            $_.serveur -eq $nom -and $_.http -eq 200 -and $_.erreur -eq ''
        }).Count
        [pscustomobject]@{
            serveur = $nom
            reponses_valides = $compte
            part_des_20_appels_pourcent = [math]::Round(100 * $compte / 20, 2)
        }
    })
    $repartition | Export-Csv -Path (Join-Path $dossier 'repartition.csv') `
        -Delimiter ';' -NoTypeInformation -Encoding UTF8
    $statistiques = $repartition | Measure-Object -Property reponses_valides -Minimum -Maximum -Average
    $echecs = @($mesures | Where-Object { $_.http -ne 200 -or $_.erreur -ne '' }).Count
    $minimum = [int]$statistiques.Minimum
    $maximum = [int]$statistiques.Maximum
    $ecart = $null
    if ($statistiques.Average -gt 0) {
        $ecart = 100.0 * ($maximum - $minimum) / $statistiques.Average
    }
    # Comparer la valeur non arrondie au seuil ; aucun serveur absent n'est omis du calcul.
    $valide = ($echecs -eq 0 -and $minimum -gt 0 -and $null -ne $ecart -and $ecart -lt 20)
    $resume = [pscustomobject]@{
        scenario = 'V1'
        debut_utc = $debutTest.ToString('o')
        fin_utc = (Get-Date).ToUniversalTime().ToString('o')
        url = $urlInfo
        applications_attendues = $applications
        appels = 20
        reponses_valides = 20 - $echecs
        echecs = $echecs
        minimum_par_application = $minimum
        maximum_par_application = $maximum
        ecart_absolu_reponses = $maximum - $minimum
        ecart_relatif_pourcent = $(if ($null -ne $ecart) { [math]::Round($ecart, 4) } else { $null })
        formule_ecart = '(maximum - minimum) / moyenne des reponses valides par application * 100'
        seuil_strict_pourcent = 20
        test_valide = $valide
        limite = '/info verifie la repartition HTTP ; ce test ne valide pas les acces PostgreSQL.'
    }
    $resume | ConvertTo-Json -Depth 5 |
        Set-Content (Join-Path $dossier 'resume-v1.json') -Encoding UTF8
    $repartition | Format-Table -AutoSize | Out-Host
    $resume | Format-List | Out-Host
    Write-Host "Preuves : $dossier"
    if (-not $valide) { throw 'V1 non valide : consulter resume-v1.json et requetes.csv.' }
} catch {
    if ($null -ne $dossier) {
        "V1 interrompu ou non valide : $($_.Exception.Message)" |
            Set-Content (Join-Path $dossier 'echec-v1.txt') -Encoding UTF8
    }
    throw
} finally {
    Pop-Location
}