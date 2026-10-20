#!/usr/bin/env bash
# =====================================================================
# ops/scale.sh — Change le nombre de serveurs applicatifs (R3)
# Usage   : ./ops/scale.sh 4      (depuis la racine du dépôt, Git Bash)
# Effet   : crée ou supprime les machines appN, puis régénère la
#           configuration du répartiteur depuis config/noeuds.yml.
# Une seule valeur change : NB_APP. Aucune adresse n'est écrite en dur.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."                       # toujours à la racine du dépôt

CIBLE=${1:-}
LB_URL=${LB_URL:-http://localhost:8080}       # port exposé par lb1 (R8)
ESSAIS=${ESSAIS:-20}                          # requêtes du test de répartition

journal() { echo "[scale.sh] $*"; }

# --- 1. Vérifier la demande --------------------------------------------
if ! [[ "$CIBLE" =~ ^[0-9]+$ ]] || [ "$CIBLE" -lt 2 ] || [ "$CIBLE" -gt 9 ]; then
  echo "Usage : $0 NOMBRE   (entre 2 et 9, ex. : $0 4)" >&2
  exit 1
fi

# --- 2. Combien de serveurs aujourd'hui ? (lu dans la source de vérité) --
ACTUEL=2
if [ -f config/noeuds.yml ]; then
  ACTUEL=$(grep -c ':role: app' config/noeuds.yml || true)
fi
journal "serveurs applicatifs : $ACTUEL -> $CIBLE"

# --- 3. Réduire : supprimer d'abord les machines en trop -----------------
# (avec l'ANCIENNE valeur, sinon Vagrant ne les connaît plus)
if [ "$CIBLE" -lt "$ACTUEL" ]; then
  for i in $(seq $((CIBLE + 1)) "$ACTUEL"); do
    journal "suppression de app$i"
    NB_APP=$ACTUEL vagrant destroy -f "app$i"
  done
fi

# --- 4. Créer les machines manquantes (et régénérer noeuds.yml) ----------
export NB_APP=$CIBLE
for i in $(seq 1 "$CIBLE"); do
  vagrant up "app$i"            # ne fait rien si la machine tourne déjà
done

# --- 5. Le répartiteur relit noeuds.yml et régénère sa configuration ----
journal "mise à jour du répartiteur"
vagrant provision lb1

# --- 6. Preuve : quels serveurs répondent derrière le répartiteur ? -----
journal "test de répartition : $ESSAIS requêtes sur $LB_URL/info"
REPONSES=$(for _ in $(seq 1 "$ESSAIS"); do
  curl -s --max-time 3 "$LB_URL/info" | grep -o '"serveur": *"[^"]*"' | cut -d'"' -f4
  echo
done | grep -v '^$' | sort | uniq -c)
echo "$REPONSES"

VUS=$(echo "$REPONSES" | grep -c 'app' || true)
if [ "$VUS" -eq "$CIBLE" ]; then
  journal "OK : les $CIBLE serveurs reçoivent du trafic"
else
  journal "ATTENTION : $VUS serveur(s) sur $CIBLE répondent" >&2
  exit 1
fi
journal "Rappel : pour les prochaines commandes vagrant, garder NB_APP=$CIBLE"
