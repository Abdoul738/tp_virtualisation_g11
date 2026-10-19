#!/usr/bin/env bash
# Construit bdd2 par pg_basebackup. Ne jamais executer apres une promotion.
set -euo pipefail
source /vagrant/scripts/lib.sh

: "${PG_REPL_USER:?PG_REPL_USER doit etre defini dans .env}"
: "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD doit etre defini dans .env}"
apt_installer postgresql postgresql-client
PG_VERSION=$(pg_lsclusters -h | awk 'NR == 1 {print $1}')
DATA_DIR="/var/lib/postgresql/$PG_VERSION/main"

# Une replique deja operationnelle est idempotente. Une ancienne primaire ne
# doit surtout pas etre ecrasee par un nouveau basebackup : utiliser pg_rewind.
if runuser -u postgres -- psql -Atqc 'SELECT pg_is_in_recovery()' 2>/dev/null | grep -qx t; then
  node_exporter
  echo "bdd2 : replique deja configuree"
  exit 0
fi
if [ -f "$DATA_DIR/.resultats-bf-primary" ]; then
  echo "REFUS : $MON_NOM contient un primaire. Lancez ops/reintegrer_bdd1.sh, pas replique.sh." >&2
  exit 1
fi

systemctl stop postgresql
rm -rf -- "$DATA_DIR"/*
install -d -m 700 -o postgres -g postgres "$DATA_DIR"

echo "Attente du primaire $BDD1_IP..."
for essai in $(seq 1 60); do
  if PGPASSWORD="$PG_REPL_PASSWORD" pg_isready -h "$BDD1_IP" -U "$PG_REPL_USER" -d postgres -q; then break; fi
  [ "$essai" -eq 60 ] && { echo "bdd1 reste indisponible" >&2; exit 1; }
  sleep 2
done

# Le slot retient les WAL necessaires tant que bdd2 est arretee.
runuser -u postgres -- env PGPASSWORD="$PG_REPL_PASSWORD" pg_basebackup \
  -h "$BDD1_IP" -U "$PG_REPL_USER" -D "$DATA_DIR" -R -X stream \
  -C -S resultats_bf_bdd2
chown -R postgres:postgres "$DATA_DIR"
systemctl start postgresql
for essai in $(seq 1 30); do
  runuser -u postgres -- psql -Atqc 'SELECT pg_is_in_recovery()' | grep -qx t && break
  [ "$essai" -eq 30 ] && { echo "bdd2 n'est pas devenue une replique" >&2; exit 1; }
  sleep 1
done
node_exporter
echo "bdd2 : replique en flux de bdd1 prete"
