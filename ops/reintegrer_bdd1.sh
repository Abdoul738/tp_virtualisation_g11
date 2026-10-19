#!/usr/bin/env bash
# Rejoint l'ancien primaire bdd1 au nouveau primaire bdd2 avec pg_rewind.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Demarrage temporaire de bdd1 sans provisionnement..."
vagrant up bdd1 --no-provision
echo "Reintegration de bdd1 derriere bdd2..."
vagrant ssh bdd1 -c 'sudo bash /vagrant/scripts/pg.sh rejoin "$(awk -F= "/^PRIMARY_IP=/{print $2}" /vagrant/config/primary.env)"'
vagrant ssh bdd1 -c 'sudo bash /vagrant/scripts/pg.sh status'
echo "bdd1 est de nouveau une replique de bdd2."
