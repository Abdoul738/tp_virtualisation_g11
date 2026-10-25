#!/usr/bin/env bash
# =====================================================================
# ops/bascule.sh — Bascule de la base vers la réplique (R6), chronométrée
# Usage (racine du dépôt, Git Bash) :  bash ops/bascule.sh
# Le sens est automatique : le primaire courant est lu dans config/primary.env
# (bdd1 -> bdd2 la première fois, bdd2 -> bdd1 pour revenir).
#   1. contrôle : la future primaire est bien une réplique en fonctionnement
#   2. isolation de l'ancien primaire (il ne pourra pas redémarrer en primaire)
#   3. promotion de la réplique (met à jour config/primary.env)
#   4. attente du retour du service à travers le répartiteur
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
LB_URL=${LB_URL:-http://localhost:8080}

maintenant() { date +%s.%N; }
duree()      { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
etat_vm()    { vagrant status "$1" --machine-readable | tr -d '\r' | awk -F, '$3 == "state" {e = $4} END {print e}'; }
dans_vm()    { vagrant ssh "$1" -c "$2" | tr -d '\r'; }   # sortie analysée
afficher()   { vagrant ssh "$1" -c "$2"; }                  # sortie seulement affichée

ancien=$(awk -F= '/^PRIMARY_HOST=/ {print $2}' config/primary.env 2>/dev/null | tr -d '\r')
ancien=${ancien:-bdd1}
case "$ancien" in
  bdd1) cible=bdd2 ;;
  bdd2) cible=bdd1 ;;
  *) echo "config/primary.env invalide : PRIMARY_HOST=$ancien" >&2; exit 1 ;;
esac
echo "[bascule] primaire actuel : $ancien -> nouveau primaire : $cible"
t0=$(maintenant)

# 1. La future primaire doit être une réplique en fonctionnement
[ "$(etat_vm "$cible")" = running ] || { echo "REFUS : $cible n'est pas demarree." >&2; exit 1; }
role=$(dans_vm "$cible" 'sudo timeout 30s bash /vagrant/scripts/pg.sh status' | awk 'NR == 1')
[ "$role" = replique ] || { echo "REFUS : $cible n'est pas une replique (role : $role)." >&2; exit 1; }

# 2. Isolation de l'ancien primaire : jamais deux primaires en même temps
if [ "$(etat_vm "$ancien")" = running ]; then
  echo "[bascule] isolation de $ancien"
  afficher "$ancien" 'sudo timeout 30s bash /vagrant/scripts/pg.sh isoler' ||
    echo "[bascule] isolation logicielle impossible : arret de la VM"
  vagrant halt "$ancien"
else
  echo "[bascule] $ancien est deja arretee (panne)"
fi
[ "$(etat_vm "$ancien")" != running ] ||
  { echo "REFUS : $ancien tourne encore, promotion annulee (risque de split-brain)." >&2; exit 1; }
t1=$(maintenant)

# 3. Promotion
echo "[bascule] promotion de $cible"
afficher "$cible" 'sudo timeout 60s bash /vagrant/scripts/pg.sh promote'
t2=$(maintenant)

# 4. Retour du service, vu par un client, à travers le répartiteur
retabli=non
for _ in $(seq 1 120); do
  if curl -fsS --max-time 2 "$LB_URL/sante" >/dev/null 2>&1 &&
     curl -fsS --max-time 2 "$LB_URL/resultat?matricule=BF000001" 2>/dev/null | grep -q BF000001; then
    retabli=oui; break
  fi
  sleep 0.5
done
t3=$(maintenant)

echo
echo "Bascule $ancien -> $cible"
printf '  %-36s %6s s\n' "controle + isolation de $ancien" "$(duree "$t0" "$t1")"
printf '  %-36s %6s s\n' "promotion de $cible" "$(duree "$t1" "$t2")"
printf '  %-36s %6s s\n' "retour du service ($LB_URL)" "$(duree "$t2" "$t3")"
printf '  %-36s %6s s\n' "TOTAL" "$(duree "$t0" "$t3")"
echo "  service retabli : $retabli"
[ "$retabli" = oui ] || { echo "ECHEC : le service ne repond pas apres 60 s." >&2; exit 1; }
echo "Remettre $ancien en replique : bash ops/reintegrer_bdd1.sh"
