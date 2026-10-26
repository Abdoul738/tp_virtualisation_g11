#requires -Version 5.1
<#
V6 RESULTATS-BF - coupure automatique de lb1 et mesure du passage MASTER de lb2.
Lancer depuis Windows : .\tests\v6.ps1
ATTENTION : coupe brutalement lb1 apres 10 secondes. lb1 reste arretee a la fin.
Mesure : evenement POWERING_OFF du journal VirtualBox -> evenement MASTER Keepalived.
La mesure reste une estimation des evenements logiciels, pas une coupure physique exacte.
Les horloges sont comparees avant et apres ; un intervalle d'incertitude est fourni.
Prerequis : lb1/lb2 en marche, VIP uniquement sur lb1, consultation fonctionnelle.
Recalcul sans action VM : .\tests\v6.ps1 -AnalyserDossier .\tests\resultats\v6-...
Aucun autre terminal n'est necessaire. Ne pas lancer une autre bascule en parallele.
#>
[CmdletBinding()]
param(
    [ValidateRange(30,1800)][int]$DureeSecondes = 300,
    [ValidateRange(5,120)][int]$ArretApresSecondes = 10,
    [ValidateRange(50,2000)][int]$PauseMs = 500,
    [string]$DossierResultats = '',
    [string]$VBoxManage = '',
    [string]$AnalyserDossier = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$racine = Split-Path -Parent $PSScriptRoot
$culture = [Globalization.CultureInfo]::InvariantCulture
$script:dossier = $null
$script:numeroCommande = 0
$script:calibrations = [Collections.Generic.List[object]]::new()
$halt = $null
$epoch = [DateTimeOffset]::Parse('1970-01-01T00:00:00Z')

function Utc { return [DateTimeOffset]::UtcNow }
function Secondes-Epoch([DateTimeOffset]$Date) { return ($Date - $script:epoch).TotalSeconds }
function Depuis-Epoch([double]$Secondes) { return $script:epoch.AddSeconds($Secondes) }
function Argument-Natif([string]$Valeur) {
    # Encodage d'un argument Windows ; aucune execution via shell.
    if ($Valeur.Length -gt 0 -and $Valeur -notmatch '[\s"]') { return $Valeur }
    $v = [regex]::Replace($Valeur, '(\\*)"', '$1$1\"')
    $v = [regex]::Replace($v, '(\\+)$', '$1$1')
    return '"' + $v + '"'
}
function Demarrer-Natif {
    param([string]$Executable, [string[]]$Arguments, [string]$Nom)
    $script:numeroCommande++
    $prefixe = Join-Path $script:dossier ('{0:D3}-{1}' -f $script:numeroCommande,$Nom)
    $argumentsTexte=($Arguments | ForEach-Object { Argument-Natif $_ }) -join ' '
    if ($Nom -ne 'sonde') { Write-Host "Controle : $Nom (delai borne)" }
    $debut=Utc
    # Redirection vers des fichiers : aucune attente ReadToEndAsync/GetResult.
    $p=Start-Process -FilePath $Executable -ArgumentList $argumentsTexte `
        -WorkingDirectory $racine -NoNewWindow -PassThru `
        -RedirectStandardOutput ($prefixe+'.stdout.txt') `
        -RedirectStandardError ($prefixe+'.stderr.txt')
    # Windows PowerShell 5.1 : conserver le handle avant la fin du processus
    # pour que ExitCode reste accessible apres WaitForExit.
    $handleConserve=$p.Handle
    return [pscustomobject]@{Processus=$p; Handle=$handleConserve; Debut=$debut; Prefixe=$prefixe}
}
function Terminer-Natif {
    param($Travail, [int]$DelaiSecondes=30, [switch]$TolereErreur)
    $p=$Travail.Processus
    $expire = -not $p.WaitForExit($DelaiSecondes * 1000)
    if ($expire) {
        # Sous Windows, fermer aussi les enfants du client Vagrant/Ruby/SSH.
        $taskkill=Get-Command taskkill.exe -ErrorAction SilentlyContinue
        if ($taskkill) {
            try {
                $k=Start-Process -FilePath $taskkill.Source `
                    -ArgumentList @('/PID',[string]$p.Id,'/T','/F') -NoNewWindow -PassThru
                if (-not $k.WaitForExit(3000)) { try { $k.Kill() } catch {} }
                $k.Dispose()
            } catch {}
        }
        try { if (-not $p.HasExited) { $p.Kill() } } catch {}
        $null=$p.WaitForExit(2000)
    }
    $fin=Utc
    # Attente de vidage courte et bornee des fichiers de sortie.
    Start-Sleep -Milliseconds 100
    $stdout=''; $stderr=''
    if (Test-Path -LiteralPath ($Travail.Prefixe+'.stdout.txt')) {
        $stdout=[string](Get-Content -LiteralPath ($Travail.Prefixe+'.stdout.txt') -Raw)
    }
    if (Test-Path -LiteralPath ($Travail.Prefixe+'.stderr.txt')) {
        $stderr=[string](Get-Content -LiteralPath ($Travail.Prefixe+'.stderr.txt') -Raw)
    }
    $code=-1
    $p.Refresh()
    if ($p.HasExited) { $code=$p.ExitCode }
    if ($expire) { $code=124 }
    if ($null -eq $code) {
        $p.Dispose()
        throw "Code de sortie du processus indisponible. Voir $($Travail.Prefixe).* ; aucune reussite supposee."
    }
    $r=[pscustomobject]@{Texte=$stdout; Erreur=$stderr; Code=$code; Expire=$expire; Debut=$Travail.Debut; Fin=$fin}
    $p.Dispose()
    if ($Travail.Prefixe -match '-sonde$' -and $code -eq 0 -and -not $expire) {
        Remove-Item -LiteralPath ($Travail.Prefixe+'.stdout.txt'),($Travail.Prefixe+'.stderr.txt') -ErrorAction SilentlyContinue
    }
    if (($expire -or $code -ne 0) -and -not $TolereErreur) {
        throw "Commande en echec (code=$code, timeout=$expire). Voir $($Travail.Prefixe).*"
    }
    return $r
}
function Vagrant-SSH([string]$Machine,[string]$Commande,[string]$Nom) {
    $w=Demarrer-Natif $script:vagrant @('ssh',$Machine,'-c',$Commande) $Nom
    return Terminer-Natif $w 30
}
function Avec-Vip([string]$Texte,[string]$Adresse) {
    return [regex]::IsMatch($Texte, '(?m)\binet\s+'+[regex]::Escape($Adresse)+'/\d+\b')
}
function Calibrer-Horloge([string]$Phase) {
    for ($i=1; $i -le 3; $i++) {
        $r=Vagrant-SSH 'lb2' 'LC_ALL=C date +%s.%N' "horloge-$Phase-$i"
        $m=[regex]::Matches($r.Texte,'(?m)^\s*(\d{10}\.\d+)\s*$')
        if ($m.Count -ne 1) { throw 'Horloge de lb2 illisible.' }
        $guest=[double]::Parse($m[0].Groups[1].Value,$culture)
        $avant=Secondes-Epoch $r.Debut; $apres=Secondes-Epoch $r.Fin
        $script:calibrations.Add([pscustomobject]@{
            phase=$Phase; avant_hote_utc=$r.Debut.ToString('o'); apres_hote_utc=$r.Fin.ToString('o')
            epoch_lb2=$guest; offset_min_s=($guest-$apres); offset_max_s=($guest-$avant)
            aller_retour_s=($apres-$avant)
        })
    }
}
function Sans-Couleurs([string]$Texte) {
    return [regex]::Replace($Texte, ([string][char]27)+'\[[0-?]*[ -/]*[@-~]', '')
}
function Lire-Preuve([string]$Motif) {
    $f=@(Get-ChildItem -LiteralPath $script:dossier -File -Filter $Motif)
    if ($f.Count -ne 1) { throw "Une seule preuve attendue pour $Motif ; trouve : $($f.Count)." }
    return [string](Get-Content -LiteralPath $f[0].FullName -Raw)
}
function Lire-JournalJson([string]$Texte) {
    $Texte=Sans-Couleurs $Texte
    foreach ($ligne in ($Texte -split "`r?`n")) {
        if ($ligne.TrimStart() -notmatch '^[\{\[]') { continue }
        try { $objets=ConvertFrom-Json -InputObject $ligne -ErrorAction Stop }
        catch { Write-Warning 'Entree JSON illisible dans le journal ; entree ignoree.'; continue }
        foreach ($objet in @($objets)) {
            if ($null -eq $objet) { continue }
            # Les entrees sans MESSAGE ne sont pas des annonces MASTER.
            if ($null -ne $objet.PSObject.Properties['MESSAGE']) { Write-Output $objet }
        }
    }
}
function Lire-Arret-VBox([string]$Texte) {
    $ancre=$null; $ancreRel=0.0; $evenements=@()
    foreach ($ligne in ($Texte -split "`r?`n")) {
        $m=[regex]::Match($ligne,'^\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)\s+(.*)$')
        if (-not $m.Success) { continue }
        $rel=3600*[double]$m.Groups[1].Value+60*[double]$m.Groups[2].Value+[double]::Parse($m.Groups[3].Value,$culture)
        $msg=$m.Groups[4].Value
        $a=[regex]::Match($msg,'^Log opened\s+(\d{4}-\d{2}-\d{2}T\S+)')
        if ($a.Success -and $null -eq $ancre) {
            $ancre=[DateTimeOffset]::Parse($a.Groups[1].Value,$culture)
            $ancreRel=$rel
        }
        if ($msg -match "Changing (?:the )?VM state from 'RUNNING' to 'POWERING_OFF'") {
            $evenements += [pscustomobject]@{ Relative=$rel; Ligne=$ligne }
        }
    }
    if ($null -eq $ancre -or $evenements.Count -eq 0) { return $null }
    $e=$evenements[-1]
    return [pscustomobject]@{ Heure=$ancre.AddSeconds($e.Relative-$ancreRel); Ligne=$e.Ligne }
}

Push-Location $racine
try {
    if ($AnalyserDossier) {
        $script:dossier=(Resolve-Path -LiteralPath $AnalyserDossier).Path
        Write-Host "Analyse seule des preuves : $script:dossier ; aucune action sur les VM."
        $ancienTexte=Get-Content -LiteralPath (Join-Path $script:dossier 'resume-v6.json') -Raw
        $ancien=$ancienTexte | ConvertFrom-Json
        $url=[string]$ancien.url
        $vip=([uri]$url).Host
        $debutSurveillance=[DateTimeOffset]::Parse(([regex]::Match($ancienTexte,'"debut_surveillance_utc"\s*:\s*"([^"]+)"').Groups[1].Value),$culture)
        $debutCoupure=[DateTimeOffset]::Parse(([regex]::Match($ancienTexte,'"demande_coupure_utc"\s*:\s*"([^"]+)"').Groups[1].Value),$culture)
        $finPreuves=[DateTimeOffset]::Parse(([regex]::Match($ancienTexte,'"fin_surveillance_utc"\s*:\s*"([^"]+)"').Groups[1].Value),$culture)
        $arret=[pscustomobject]@{Code=$ancien.code_arret_vagrant; Fin=$finPreuves}
        $etatTexte=Sans-Couleurs (Lire-Preuve '*etat-final.stdout.txt')
        $lb1Off=$etatTexte -match ',lb1,state,poweroff\s*(?:\r?\n|$)'
        $lb2Running=$etatTexte -match ',lb2,state,running\s*(?:\r?\n|$)'
        $vipFinale=Avec-Vip (Sans-Couleurs (Lire-Preuve '*vip-finale-lb2.stdout.txt')) $vip
        $bootInitial=(Lire-Preuve '*boot-id-avant.stdout.txt').Trim()
        $bootFinal=(Lire-Preuve '*boot-id-apres.stdout.txt').Trim()
        $journal=[pscustomobject]@{Texte=(Lire-Preuve '*keepalived-apres.stdout.txt')}
        $log=[pscustomobject]@{Code=0; Expire=$false; Texte=(Lire-Preuve '*virtualbox-lb1.stdout.txt')}
        $cal=@(Import-Csv -LiteralPath (Join-Path $script:dossier 'horloges.csv') -Delimiter ';')
        if ($cal.Count -eq 0) { throw 'Mesures horloges absentes.' }
        foreach ($c in $cal) {
            $script:calibrations.Add([pscustomobject]@{
                offset_min_s=[double]::Parse($c.offset_min_s,$culture)
                offset_max_s=[double]::Parse($c.offset_max_s,$culture)
            })
        }
        $mesures=@(Import-Csv -LiteralPath (Join-Path $script:dossier 'requetes.csv') -Delimiter ';' | ForEach-Object {
            [pscustomobject]@{http=$_.http; code_curl=[int]$_.code_curl; timeout_processus=([string]$_.timeout_processus -eq 'True')}
        })
    } else {
    if ($ArretApresSecondes -ge $DureeSecondes-10) { throw 'Prevoir au moins 10 secondes apres la coupure.' }
    $script:vagrant=(Get-Command vagrant.exe -ErrorAction Stop).Source
    $script:curl=(Get-Command curl.exe -ErrorAction Stop).Source
    if (-not $VBoxManage) {
        $v=Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
        if ($v) { $VBoxManage=$v.Source }
        else { $VBoxManage=Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe' }
    }
    if (-not (Test-Path -LiteralPath $VBoxManage -PathType Leaf)) { throw 'VBoxManage.exe introuvable ; utiliser -VBoxManage avec son chemin.' }
    $lignes=@(Get-Content .\config\plateforme.env | Where-Object { $_ -match '^\s*GROUPE\s*=' })
    if ($lignes.Count -ne 1 -or $lignes[0] -notmatch '^\s*GROUPE\s*=\s*(\d+)\s*$') { throw 'GROUPE absent ou invalide.' }
    $groupe=[int]$Matches[1]
    if (55+$groupe -gt 255) { throw 'GROUPE incompatible avec le sous-reseau.' }
    $vip='192.168.{0}.5' -f (55+$groupe)
    $url="http://$vip/resultat?matricule=BF000001"
    $idLb1=(Get-Content .\.vagrant\machines\lb1\virtualbox\id -Raw).Trim()
    if (-not $DossierResultats) { $DossierResultats=Join-Path $racine 'tests\resultats' }
    if (-not [IO.Path]::IsPathRooted($DossierResultats)) { $DossierResultats=Join-Path $racine $DossierResultats }
    $script:dossier=Join-Path $DossierResultats ('v6-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $script:dossier -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $script:dossier 'v6-execute.ps1')
    Write-Host "Preuves : $script:dossier"
    $etat=Terminer-Natif (Demarrer-Natif $script:vagrant @('status','lb1','lb2','--machine-readable') 'etat-initial') 30
    foreach ($vm in @('lb1','lb2')) {
        if ($etat.Texte -notmatch ",$vm,state,running\s*(?:\r?\n|$)") { throw "$vm doit etre running avant V6." }
        $services=Vagrant-SSH $vm 'systemctl is-active haproxy keepalived' "services-$vm"
        $actifs=@($services.Texte -split "`r?`n" | Where-Object { $_.Trim() -eq 'active' })
        if ($actifs.Count -ne 2) { throw "HAProxy et Keepalived doivent etre actifs sur $vm." }
    }
    $ip1=Vagrant-SSH 'lb1' 'ip -4 address show dev eth1' 'vip-initiale-lb1'
    $ip2=Vagrant-SSH 'lb2' 'ip -4 address show dev eth1' 'vip-initiale-lb2'
    if (-not (Avec-Vip $ip1.Texte $vip) -or (Avec-Vip $ip2.Texte $vip)) { throw 'VIP attendue uniquement sur lb1. Aucune coupure effectuee.' }
    $initial=Terminer-Natif (Demarrer-Natif $script:curl @('--noproxy','*','-fsS','--max-time','3',$url) 'http-initial') 5
    if (($initial.Texte | ConvertFrom-Json).matricule -ne 'BF000001') { throw 'Consultation initiale invalide.' }
    Calibrer-Horloge 'avant'
    $journalInitial=Vagrant-SSH 'lb2' 'sudo -n env SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat journalctl -u keepalived -n 1 -o json --show-cursor --no-pager' 'journal-curseur'
    $curseur=[regex]::Match($journalInitial.Texte,'(?m)^-- cursor:\s*(\S+)\s*$').Groups[1].Value
    $j0=@($journalInitial.Texte -split "`r?`n" | Where-Object { $_ -match '^\{' } | ForEach-Object { $_ | ConvertFrom-Json })
    if (-not $curseur -or $j0.Count -ne 1) { throw 'Impossible de reperer le debut du journal Keepalived.' }
    $bootAvant=Vagrant-SSH 'lb2' 'cat /proc/sys/kernel/random/boot_id' 'boot-id-avant'
    $bootInitial=$bootAvant.Texte.Trim()
    if ($bootInitial -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Identifiant de demarrage de lb2 illisible.' }
    if ($curseur -notmatch '^[A-Za-z0-9;=,_\-]+$') { throw 'Format de curseur inattendu.' }
    $mesures=[Collections.Generic.List[object]]::new()
    $fichier=Join-Path $script:dossier 'requetes.csv'
    $horloge=[Diagnostics.Stopwatch]::StartNew()
    $debutSurveillance=Utc
    $debutCoupure=$null
    Write-Host "Surveillance : $url"
    Write-Host "COUPURE AUTOMATIQUE de lb1 dans $ArretApresSecondes secondes. Ne pas lancer halt manuellement."
    while ($horloge.Elapsed.TotalSeconds -lt $DureeSecondes) {
        if ($null -eq $halt -and $horloge.Elapsed.TotalSeconds -ge $ArretApresSecondes) {
            $debutCoupure=Utc
            $halt=Demarrer-Natif $script:vagrant @('halt','lb1','--force') 'coupure-lb1'
            Write-Host "Coupure demandee : $($debutCoupure.ToString('o'))"
        }
        $r=Terminer-Natif (Demarrer-Natif $script:curl @('--noproxy','*','-sS','-o','NUL','-w','%{http_code}','--connect-timeout','1','--max-time','2',$url) 'sonde') 4 -TolereErreur
        $m=[pscustomobject]@{
            debut_utc=$r.Debut.ToString('o'); fin_utc=$r.Fin.ToString('o')
            duree_ms=[math]::Round(($r.Fin-$r.Debut).TotalMilliseconds,1)
            http=$r.Texte.Trim(); code_curl=$r.Code; timeout_processus=$r.Expire
        }
        $mesures.Add($m)
        $m | Export-Csv -Path $fichier -Append -Delimiter ';' -NoTypeInformation -Encoding UTF8
        Write-Host "$($m.debut_utc) HTTP=$($m.http) curl=$($m.code_curl)"
        Start-Sleep -Milliseconds $PauseMs
    }
    if ($null -eq $halt) { throw 'La coupure automatique ne sest pas executee.' }
    $arret=Terminer-Natif $halt 15 -TolereErreur
    $halt=$null
    $etatFinal=Terminer-Natif (Demarrer-Natif $script:vagrant @('status','lb1','lb2','--machine-readable') 'etat-final') 30
    $lb1Off=$etatFinal.Texte -match ',lb1,state,poweroff\s*(?:\r?\n|$)'
    $lb2Running=$etatFinal.Texte -match ',lb2,state,running\s*(?:\r?\n|$)'
    $ipFinal=Vagrant-SSH 'lb2' 'ip -4 address show dev eth1' 'vip-finale-lb2'
    $vipFinale=Avec-Vip $ipFinal.Texte $vip
    $journal=Vagrant-SSH 'lb2' "sudo -n env SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat journalctl -u keepalived --after-cursor='$curseur' -o json --no-pager" 'keepalived-apres'
    $bootApres=Vagrant-SSH 'lb2' 'cat /proc/sys/kernel/random/boot_id' 'boot-id-apres'
    $bootFinal=$bootApres.Texte.Trim()
    Calibrer-Horloge 'apres'
    $script:calibrations | Export-Csv (Join-Path $script:dossier 'horloges.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
    $log=Terminer-Natif (Demarrer-Natif $VBoxManage @('showvminfo',$idLb1,'--log','0') 'virtualbox-lb1') 15 -TolereErreur
    }
    $coupure=$null
    if ($log.Code -eq 0 -and -not $log.Expire) { $coupure=Lire-Arret-VBox $log.Texte }
    $evenements=@(Lire-JournalJson $journal.Texte)
    $master=@($evenements | Where-Object {
        ([string]$_.PSObject.Properties['MESSAGE'].Value) -match 'Entering MASTER STATE'
    })
    $offsetMin=($script:calibrations | Measure-Object offset_min_s -Maximum).Maximum
    $offsetMax=($script:calibrations | Measure-Object offset_max_s -Minimum).Minimum
    $temps=$null; $borneMin=$null; $borneMax=$null; $masterUtc=$null; $arretUtc=$null
    $ecartBrut=$null; $masterBrutUtc=$null
    $motif=''
    if (-not $lb1Off -or -not $lb2Running -or -not $vipFinale) { $motif='Arret de lb1 ou transfert de VIP non confirme.' }
    elseif ($null -eq $coupure) { $motif='Evenement POWERING_OFF du journal VirtualBox absent ou illisible.' }
    elseif ($master.Count -ne 1) { $motif='Un unique evenement MASTER est requis dans cette execution.' }
    elseif ($null -eq $master[0].PSObject.Properties['__REALTIME_TIMESTAMP']) { $motif='Horodatage du passage MASTER absent du journal.' }
    elseif ($bootFinal -ne $bootInitial) { $motif='lb2 a redemarre ou son identifiant est illisible ; mesure refusee.' }
    else {
        $arretUtc=$coupure.Heure.ToUniversalTime()
        $tPower=Secondes-Epoch $arretUtc
        $tMaster=[double]::Parse([string]$master[0].__REALTIME_TIMESTAMP,$culture)/1000000
        $debutEpoch=Secondes-Epoch $debutCoupure
        $finEpoch=Secondes-Epoch $arret.Fin
        if ($tPower -lt $debutEpoch-2 -or $tPower -gt $finEpoch+2) {
            $motif='Evenement VirtualBox hors de la fenetre de coupure ; mesure refusee.'
        } else {
            $ecartBrut=$tMaster-$tPower
            $masterBrutUtc=Depuis-Epoch $tMaster
            if ($offsetMin -gt $offsetMax) {
                $motif='Horloges incompatibles avant/apres ; correction impossible. Ecart brut indicatif uniquement.'
            } else {
            $borneMin=$tMaster-$offsetMax-$tPower
            $borneMax=$tMaster-$offsetMin-$tPower
            if ($borneMax -lt 0) { $motif='MASTER anterieur a la coupure ; chronologie invalide.'; $borneMin=$null; $borneMax=$null }
            else {
                $borneMin=[math]::Max(0.0,[double]$borneMin)
                $temps=$tMaster-($offsetMin+$offsetMax)/2-$tPower
                $masterUtc=Depuis-Epoch ($tMaster-($offsetMin+$offsetMax)/2)
            }
            }
        }
    }
    $erreurs=@($mesures | Where-Object { $_.http -ne '200' -or $_.code_curl -ne 0 -or $_.timeout_processus }).Count
    $resume=[pscustomobject]@{
        scenario='V6'; debut_surveillance_utc=$debutSurveillance.ToString('o')
        fin_surveillance_utc=$(if ($AnalyserDossier) {$finPreuves.ToString('o')} else {(Utc).ToString('o')}); url=$url
        analyse_utc=(Utc).ToString('o')
        estimateur='Ecart brut moins milieu de l''intervalle du decalage horloge ; valeur indicative.'
        demande_coupure_utc=$debutCoupure.ToString('o'); code_arret_vagrant=$arret.Code
        lb1_poweroff=$lb1Off; lb2_running=$lb2Running; vip_sur_lb2=$vipFinale
        evenement_arret_lb1_utc=$(if ($arretUtc) {$arretUtc.ToString('o')} else {$null})
        master_lb2_utc_horloge_corrigee=$(if ($masterUtc) {$masterUtc.ToString('o')} else {$null})
        master_lb2_utc_horloge_invitee=$(if ($masterBrutUtc) {$masterBrutUtc.ToString('o')} else {$null})
        ecart_brut_evenements_s=$(if ($null -ne $ecartBrut) {[math]::Round($ecartBrut,3)} else {$null})
        formule_ecart_brut='MASTER lb2 (horloge invitee) - POWERING_OFF lb1 (horloge hote)'
        nombre_evenements_master=$master.Count
        temps_bascule_estime_s=$(if ($null -ne $temps) {[math]::Round($temps,3)} else {$null})
        borne_basse_estimee_s=$(if ($null -ne $borneMin) {[math]::Round($borneMin,3)} else {$null})
        borne_haute_estimee_s=$(if ($null -ne $borneMax) {[math]::Round($borneMax,3)} else {$null})
        mesure_disponible=($null -ne $temps); raison_mesure_absente=$motif
        requetes=$mesures.Count; echecs_http_ou_curl=$erreurs
        methode='Evenement VirtualBox RUNNING vers POWERING_OFF, puis MASTER Keepalived ; horloge lb2 corrigee par mesures SSH avant et apres, offset suppose stable.'
        limite='Estimation de transitions logicielles ; bornes liees a la comparaison des horloges, pas une garantie de precision physique ni une mesure de reprise HTTP.'
    }
    $nomResume='resume-v6.json'
    if ($AnalyserDossier) { $nomResume='resume-v6-recalcule.json' }
    $resume | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:dossier $nomResume) -Encoding UTF8
    $resume | Format-List | Out-Host
    if ($null -ne $ecartBrut) {
        Write-Host ''
        Write-Host 'CALCUL DE LA DIFFERENCE ENTRE EVENEMENTS'
        Write-Host ('Arret lb1 (VirtualBox, UTC hote) : {0}' -f $arretUtc.ToString('o'))
        Write-Host ('MASTER lb2 (UTC invitee)        : {0}' -f $masterBrutUtc.ToString('o'))
        Write-Host ('Calcul : {0} - {1} = {2:N3} secondes' -f `
            $masterBrutUtc.ToString('HH:mm:ss.fffffff'),$arretUtc.ToString('HH:mm:ss.fffffff'),$ecartBrut)
        Write-Host 'Ecart BRUT : les deux horloges peuvent etre decalees.'
        if ($ecartBrut -lt 0) { Write-Warning 'Ecart brut negatif : ne pas interpreter comme un delai de bascule negatif.' }
    }
    if ($resume.mesure_disponible) {
        Write-Host ('Estimation corrigee indicative : {0:N3} s ; intervalle lie aux horloges [{1:N3} ; {2:N3}] s' -f $temps,$borneMin,$borneMax)
        if (($borneMax-$borneMin) -gt 1) { Write-Warning 'Incertitude des horloges superieure a 1 seconde : ne pas presenter une valeur exacte au milliseconde.' }
    } else { Write-Warning "Temps non calcule : $motif" }
    Write-Host "Preuves : $script:dossier"
    if (-not $AnalyserDossier) { Write-Host 'lb1 reste arretee. Apres conservation des preuves : vagrant up lb1' }
} catch {
    if ($script:dossier) { $_.Exception.Message | Set-Content (Join-Path $script:dossier 'echec-v6.txt') -Encoding UTF8 }
    throw
} finally {
    if ($null -ne $halt) {
        # Termine seulement le client Vagrant si necessaire ; ne redemarre aucune VM.
        try { Terminer-Natif $halt 10 -TolereErreur | Out-Null } catch {}
    }
    Pop-Location
}
