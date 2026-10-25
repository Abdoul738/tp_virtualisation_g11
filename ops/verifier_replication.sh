#!/usr/bin/env bash
# =====================================================================
# ops/verifier_replication.sh — Preuve de R5, dans les deux sens de bascule
# Usage (racine du dépôt, Git Bash) :  bash ops/verifier_replication.sh
# Écrit une ligne sur le primaire courant, mesure le délai avant qu'elle soit
# visible sur la réplique, puis la supprime (le jeu de données reste intact).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

primaire=$(awk -F= '/^PRIMARY_HOST=/ {print $2}' config/primary.env 2>/dev/null | tr -d '\r')
primaire=${primaire:-bdd1}
vagrant ssh "$primaire" -c 'sudo timeout 60s bash /vagrant/scripts/pg.sh verifier'
