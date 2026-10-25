$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
Push-Location $racine

try {
    vagrant up app1
    if ($LASTEXITCODE -ne 0) { throw "Demarrage de app1 impossible." }

    $anciens = @(
        Get-ChildItem .\tests\resultats -Directory -Filter "v2-*" |
            Select-Object -ExpandProperty FullName
    )

    $charge = Start-Job -ArgumentList $racine -ScriptBlock {
        param($racineProjet)
        Set-Location -LiteralPath $racineProjet
        vagrant ssh lb1 -c "sudo python3 -u /vagrant/tests/v2.py"
        if ($LASTEXITCODE -ne 0) {
            throw "Le script de mesure a echoue."
        }
    }

    $limite = (Get-Date).AddSeconds(120)
    $dossier = $null

    do {
        $dossier = Get-ChildItem .\tests\resultats -Directory -Filter "v2-*" |
            Where-Object {
                $_.FullName -notin $anciens -and
                (Test-Path (Join-Path $_.FullName "charge-prete.txt"))
            } |
            Sort-Object Name -Descending |
            Select-Object -First 1

        if ($dossier) { break }

        if ($charge.State -in @("Completed", "Failed", "Stopped")) {
            Receive-Job $charge
            throw "La charge s'est terminee avant le signal."
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $limite)

    if (-not $dossier) {
        throw "Signal absent : app1 conservee en fonctionnement."
    }

    Write-Host "Charge active : arret automatique de app1."

    $debut = (Get-Date).ToUniversalTime().ToString("o")
    vagrant halt app1
    $codeArret = $LASTEXITCODE
    $fin = (Get-Date).ToUniversalTime().ToString("o")

    [pscustomobject]@{
        debut_commande_utc = $debut
        fin_commande_utc = $fin
        code_vagrant = $codeArret
    } | ConvertTo-Json |
        Set-Content (Join-Path $dossier.FullName "arret.json") -Encoding UTF8

    Write-Host "Attente de la fin des mesures..."
    Wait-Job $charge | Out-Null
    Receive-Job $charge

    Write-Host "Etat du travail de mesure : $($charge.State)"
    Write-Host "Preuves : $($dossier.FullName)"
    vagrant status app1
}
finally {
    Pop-Location
}