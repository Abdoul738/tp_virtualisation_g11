#!/usr/bin/env bash
# Outils executes dans une VM PostgreSQL par les scripts ops/.
set -euo pipefail
source /vagrant/scripts/lib.sh

PG_VERSION=$(pg_lsclusters -h | awk 'NR == 1 {print $1}')
DATA_DIR="/var/lib/postgresql/$PG_VERSION/main"
CONF_DIR="/etc/postgresql/$PG_VERSION/main/conf.d"
action="${1:-status}"

est_replique() { runuser -u postgres -- psql -Atqc 'SELECT pg_is_in_recovery()' | grep -qx t; }
attendre_sql() { for _ in $(seq 1 30); do runuser -u postgres -- psql -Atqc 'SELECT 1' >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

case "$action" in
  status)
    attendre_sql
    if est_replique; then echo "replique"; else echo "primaire"; fi
    ;;
  promote)
    est_replique || { echo "REFUS : cette machine est deja primaire" >&2; exit 1; }
    pg_ctlcluster "$PG_VERSION" main promote
    for _ in $(seq 1 30); do ! est_replique && break; sleep 1; done
    ! est_replique || { echo "Echec de promotion PostgreSQL" >&2; exit 1; }
    touch "$DATA_DIR/.resultats-bf-primary"
    chown postgres:postgres "$DATA_DIR/.resultats-bf-primary"
    PRIMARY_FILE=$(mktemp)
    cat > "$PRIMARY_FILE" <<EOF
PRIMARY_HOST=$MON_NOM
PRIMARY_IP=$MON_IP
EOF
    if ! cmp -s "$PRIMARY_FILE" /vagrant/config/primary.env 2>/dev/null; then
      cat "$PRIMARY_FILE" > /vagrant/config/primary.env
    fi
    rm -f "$PRIMARY_FILE"
    echo "$MON_NOM est maintenant primaire"
    ;;
  rejoin)
    primaire_ip="${2:?Usage: pg.sh rejoin IP_DU_PRIMAIRE}"
    : "${PG_REPL_USER:?PG_REPL_USER doit etre defini dans .env}"
    : "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD doit etre defini dans .env}"
    systemctl stop postgresql
    runuser -u postgres -- env PGPASSWORD="$PG_REPL_PASSWORD" pg_rewind \
      -D "$DATA_DIR" --source-server="host=$primaire_ip user=$PG_REPL_USER dbname=postgres"
    install -d -m 755 "$CONF_DIR"
    ecrire_si_change "$CONF_DIR/99-resultats-bf-replica.conf" 640 postgres <<EOF
primary_conninfo = 'host=$primaire_ip port=5432 user=$PG_REPL_USER password=$PG_REPL_PASSWORD application_name=$MON_NOM'
EOF
    touch "$DATA_DIR/standby.signal"
    chown postgres:postgres "$DATA_DIR/standby.signal"
    systemctl start postgresql
    for _ in $(seq 1 30); do est_replique && { echo "$MON_NOM reintegree comme replique"; exit 0; }; sleep 1; done
    echo "Echec : $MON_NOM ne rejoint pas le primaire" >&2; exit 1
    ;;
  *) echo "Usage: $0 {status|promote|rejoin IP_DU_PRIMAIRE}" >&2; exit 2 ;;
esac
