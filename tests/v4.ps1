<#
V4  - RESULTATS-BF.
Panne de la base primaire avec vagrant halt bdd1.
Le service renvoie proprement 503 sur /sante
#>
$ErrorActionPreference = "Stop"
$racine = Split-Path -Parent $PSScriptRoot
Push-Location $racine

function Executer-Vagrant {
    param([string[]]$Arguments)
    & vagrant @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Echec Vagrant : $($Arguments -join ' ')"
    }
}

$transcription = $false

try {
    $dossier = Join-Path $racine (
        "tests\resultats\v4-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    )
    New-Item -ItemType Directory -Force $dossier | Out-Null
    Start-Transcript -Path "$dossier\transcription.txt"
    $transcription = $true

    # Controle fonctionnel avant la panne.
    $reference = Invoke-RestMethod `
        -Uri "http://localhost:8080/resultat?matricule=BF000001" `
        -TimeoutSec 10 -ErrorAction Stop

    if ($reference.matricule -ne "BF000001") {
        throw "Consultation initiale invalide."
    }

    $debutUtc = (Get-Date).ToUniversalTime().ToString("o")
    $total = [System.Diagnostics.Stopwatch]::StartNew()

    Executer-Vagrant -Arguments @("halt", "bdd1")

    $etat = @(Executer-Vagrant -Arguments @(
        "status", "bdd1", "--machine-readable"
    ))
    if (-not ($etat -match ",bdd1,state,poweroff\s*$")) {
        throw "Arret de bdd1 non confirme : promotion refusee."
    }

    Write-Host "Controle HTTP apres arret, avant promotion :"

    & curl.exe -sS -i --max-time 10 "http://localhost:8080/sante" |
        Tee-Object -FilePath "$dossier\sante-via-lb.txt"

    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de recevoir la reponse HTTP via HAProxy."
    }

    # Controle direct : distingue la reponse applicative de celle de HAProxy.
    Executer-Vagrant -Arguments @(
        "ssh", "app1", "-c",
        "curl -i --max-time 10 http://127.0.0.1:3000/sante"
    ) | Tee-Object -FilePath "$dossier\sante-directe-app1.txt"

    $promotion = [System.Diagnostics.Stopwatch]::StartNew()
    Executer-Vagrant -Arguments @(
        "ssh", "bdd2", "-c",
        "sudo timeout 60s bash /vagrant/scripts/pg.sh promote"
    )
    $promotion.Stop()

    # Verification SQL independante de l'annonce du script de promotion.
    $mode = @(Executer-Vagrant -Arguments @(
        "ssh", "bdd2", "-c",
        "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres -tAc 'SELECT pg_is_in_recovery();'"
    ))
    if (-not ($mode | Where-Object { $_.Trim() -eq "f" })) {
        throw "Le role primaire de bdd2 n'est pas confirme."
    }

    $limite = (Get-Date).AddSeconds(60)
    $retabli = $false

    do {
        try {
            $sante = Invoke-RestMethod `
                -Uri "http://localhost:8080/sante" `
                -TimeoutSec 5 -ErrorAction Stop

            $resultat = Invoke-RestMethod `
                -Uri "http://localhost:8080/resultat?matricule=BF000001" `
                -TimeoutSec 5 -ErrorAction Stop

            $retabli = (
                $sante.etat -eq "ok" -and
                $resultat.matricule -eq "BF000001"
            )
        }
        catch {
            $retabli = $false
        }

        if (-not $retabli) { Start-Sleep -Seconds 1 }
    } until ($retabli -or (Get-Date) -ge $limite)

    $total.Stop()

    $resume = [pscustomobject]@{
        debut_procedure_utc = $debutUtc
        fin_controles_utc = (Get-Date).ToUniversalTime().ToString("o")
        promotion_secondes = [math]::Round(
            $promotion.Elapsed.TotalSeconds, 3
        )
        procedure_jusqu_aux_controles_secondes = [math]::Round(
            $total.Elapsed.TotalSeconds, 3
        )
        service_retabli = $retabli
    }

    $resume | ConvertTo-Json |
        Set-Content "$dossier\resume.json" -Encoding UTF8
    $resume | Format-List

    Get-Content .\config\primary.env
    Write-Host "Preuves : $dossier"
    Write-Host "Conserver bdd1 arretee."

    if (-not $retabli) {
        throw "Le service n'est pas retabli : conserver les diagnostics."
    }
}
finally {
    if ($transcription) { Stop-Transcript }
    Pop-Location
}