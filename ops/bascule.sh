#!/usr/bin/env bash
# Bascule controlee bdd1 -> bdd2. A executer depuis la racine du depot Vagrant.
set -euo pipefail
cd "$(dirname "$0")/.."
debut=$(date +%s)

echo "Arret et isolation de bdd1 (protection contre le split-brain)..."
vagrant halt bdd1
echo "Promotion de bdd2..."
vagrant ssh bdd2 -c 'sudo bash /vagrant/scripts/pg.sh promote'
duree=$(( $(date +%s) - debut ))
printf 'Bascule terminee : bdd2 est primaire (%ss).\n' "$duree"
printf 'Mettre a jour/recharger les applications pour lire config/primary.env, puis lancer ops/reintegrer_bdd1.sh.\n'
