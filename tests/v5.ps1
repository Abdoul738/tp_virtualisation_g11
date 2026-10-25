<#
V5  - RESULTATS-BF.
Reconstruction vagrant destroy -f puis vagrant up
#>
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
Push-Location $racine

try {
    $env:NB_APP = "2"
    $env:EXTENSIONS = "e1,e2"

    vagrant validate
    if ($LASTEXITCODE -ne 0) {
        throw "Vagrantfile invalide."
    }

    $dossier = ".\tests\resultats\v5-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Force $dossier | Out-Null

    Start-Transcript -Path "$dossier\transcription.txt"

    try {
        $debut = (Get-Date).ToUniversalTime().ToString("o")
        $total = [System.Diagnostics.Stopwatch]::StartNew()
        $destruction = [System.Diagnostics.Stopwatch]::StartNew()

        vagrant destroy -f
        $codeDestruction = $LASTEXITCODE
        $destruction.Stop()

        if ($codeDestruction -ne 0) {
            throw "Destruction incomplete : reconstruction non lancee."
        }

        $construction = [System.Diagnostics.Stopwatch]::StartNew()

        vagrant up --no-parallel
        $codeConstruction = $LASTEXITCODE

        $construction.Stop()
        $total.Stop()

        $resume = [pscustomobject]@{
            debut_utc = $debut
            fin_utc = (Get-Date).ToUniversalTime().ToString("o")
            destruction_secondes = [math]::Round(
                $destruction.Elapsed.TotalSeconds, 2
            )
            reconstruction_secondes = [math]::Round(
                $construction.Elapsed.TotalSeconds, 2
            )
            total_secondes = [math]::Round(
                $total.Elapsed.TotalSeconds, 2
            )
            code_construction = $codeConstruction
            controles_fonctionnels = "A effectuer"
        }

        $resume | ConvertTo-Json |
            Set-Content "$dossier\resume.json" -Encoding UTF8

        $resume | Format-List

        if ($codeConstruction -ne 0) {
            throw "Reconstruction en echec : conserver les preuves."
        }

        vagrant status
        Write-Host "Construction terminee. Controles fonctionnels a effectuer."
        Write-Host "Preuves : $dossier"
    }
    finally {
        Stop-Transcript
    }
}
finally {
    Pop-Location
}