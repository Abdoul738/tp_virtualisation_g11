#!/usr/bin/env bash
# =====================================================================
# ops/reintegrer_bdd1.sh — Remet l'ancien primaire en réplique (après ops/bascule.sh)
# Usage (racine du dépôt, Git Bash) :  bash ops/reintegrer_bdd1.sh
# Nom historique : après la première bascule, l'ancien primaire est bdd1.
# Le script fonctionne dans les deux sens (primaire courant lu dans config/primary.env).
#   1. le primaire prépare l'accueil (accès, droits pg_rewind, slot de réplication)
#   2. démarrage de la VM de l'ancien primaire, sans provisionnement
#   3. resynchronisation par pg_rewind (ou copie complète), démarrage en réplique
#   4. contrôle depuis le primaire : la réplique est connectée en flux
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

maintenant() { date +%s.%N; }
duree()      { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
etat_vm()    { vagrant status "$1" --machine-readable | tr -d '\r' | awk -F, '$3 == "state" {e = $4} END {print e}'; }
dans_vm()    { vagrant ssh "$1" -c "$2" | tr -d '\r'; }   # sortie analysée
afficher()   { vagrant ssh "$1" -c "$2"; }                  # sortie seulement affichée

primaire=$(awk -F= '/^PRIMARY_HOST=/ {print $2}' config/primary.env 2>/dev/null | tr -d '\r')
case "$primaire" in
  bdd1) ancien=bdd2 ;;
  bdd2) ancien=bdd1 ;;
  *) echo "config/primary.env absent ou invalide : aucune bascule a reparer." >&2; exit 1 ;;
esac
echo "[reintegration] primaire : $primaire -> $ancien redevient replique"
t0=$(maintenant)

afficher "$primaire" "sudo timeout 60s bash /vagrant/scripts/pg.sh preparer $ancien"
if [ "$(etat_vm "$ancien")" != running ]; then
  vagrant up "$ancien" --no-provision
fi
afficher "$ancien" 'sudo timeout 300s bash /vagrant/scripts/pg.sh rejoin'

etat=$(dans_vm "$primaire" 'sudo timeout 30s bash /vagrant/scripts/pg.sh status')
printf '%s\n' "$etat" | sed 's/$/\r/'                     # fins de ligne lisibles dans PowerShell
t1=$(maintenant)
if echo "$etat" | grep -q "replique connectee : $ancien .*streaming"; then
  echo "OK : $ancien est replique en flux de $primaire (reintegration en $(duree "$t0" "$t1") s)."
else
  echo "ECHEC : $primaire ne voit pas $ancien en flux." >&2; exit 1
fi
