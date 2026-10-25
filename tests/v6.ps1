<#
Scénario V6  - RESULTATS-BF.
Panne du répartiteur (E1) vagrant halt lb1
#>
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
Push-Location $racine

try {
    $ligne = Get-Content .\config\plateforme.env |
        Where-Object { $_ -match '^GROUPE=' }

    $groupe = [int](($ligne -split '=', 2)[1])
    $url = "http://192.168.{0}.5/resultat?matricule=BF000001" -f (55 + $groupe)

    $dossier = ".\tests\resultats\v6-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Force $dossier | Out-Null
    $fichier = Join-Path $dossier "requetes.csv"

    $mesures = [System.Collections.Generic.List[object]]::new()
    $chrono = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "Surveillance active : $url"
    Write-Host "Dans le second terminal, attends 10 secondes puis arrete lb1."

    while ($chrono.Elapsed.TotalSeconds -lt 300) {
        $debut = (Get-Date).ToUniversalTime()
        $requete = [System.Diagnostics.Stopwatch]::StartNew()

        $http = & curl.exe -s -o NUL -w "%{http_code}" `
            --connect-timeout 1 --max-time 2 $url
        $codeCurl = $LASTEXITCODE

        $requete.Stop()

        $mesure = [pscustomobject]@{
            debut_utc = $debut.ToString("o")
            fin_utc   = (Get-Date).ToUniversalTime().ToString("o")
            duree_ms  = [math]::Round($requete.Elapsed.TotalMilliseconds, 1)
            http      = "$http".Trim()
            code_curl = $codeCurl
        }

        $mesures.Add($mesure)
        $mesure | Export-Csv -Path $fichier -Append `
            -Delimiter ";" -NoTypeInformation -Encoding UTF8

        Write-Host "$($mesure.debut_utc) HTTP=$http curl=$codeCurl"
        Start-Sleep -Milliseconds 500
    }

    $mesures | Group-Object http, code_curl |
        Select-Object Name, Count

    Write-Host "Preuves : $dossier"
}
finally {
    Pop-Location
}