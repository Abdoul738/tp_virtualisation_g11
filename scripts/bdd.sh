#!/usr/bin/env bash
# Initialise le primaire PostgreSQL et le jeu de donnees du projet.
set -euo pipefail
source /vagrant/scripts/lib.sh

: "${PG_DB:?PG_DB doit etre defini dans .env}"
: "${PG_APP_USER:?PG_APP_USER doit etre defini dans .env}"
: "${PG_APP_PASSWORD:?PG_APP_PASSWORD doit etre defini dans .env}"
: "${PG_REPL_USER:?PG_REPL_USER doit etre defini dans .env}"
: "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD doit etre defini dans .env}"

apt_installer postgresql postgresql-client
PG_VERSION=$(pg_lsclusters -h | awk 'NR == 1 {print $1}')
[ -n "$PG_VERSION" ] || { echo "Cluster PostgreSQL introuvable" >&2; exit 1; }
CONF_DIR="/etc/postgresql/$PG_VERSION/main/conf.d"
install -d -m 755 "$CONF_DIR"

# wal_log_hints permet pg_rewind lors de la reintegration de l'ancien primaire.
if ecrire_si_change "$CONF_DIR/99-resultats-bf.conf" 644 <<'EOF'
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_log_hints = on
password_encryption = 'scram-sha-256'
EOF
then
  systemctl restart postgresql
fi

HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
TMP=$(mktemp)
awk '/^# BEGIN RESULTATS-BF$/{skip=1; next} /^# END RESULTATS-BF$/{skip=0; next} !skip {print}' "$HBA" > "$TMP"
cat >> "$TMP" <<EOF
# BEGIN RESULTATS-BF
# Acces applicatif et replication limites au reseau prive du groupe.
host    $PG_DB       $PG_APP_USER       $RESEAU/24       scram-sha-256
host    replication  $PG_REPL_USER      $RESEAU/24       scram-sha-256
# END RESULTATS-BF
EOF
if ! cmp -s "$TMP" "$HBA"; then
  install -m 640 -o postgres -g postgres "$TMP" "$HBA"
  systemctl reload postgresql
fi
rm -f "$TMP"

# Les mots de passe ne sont jamais inscrits dans un fichier du depot : psql les
# recoit comme variables, puis format() les quote correctement cote serveur.
runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
  -v app_user="$PG_APP_USER" -v app_password="$PG_APP_PASSWORD" \
  -v repl_user="$PG_REPL_USER" -v repl_password="$PG_REPL_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
SELECT format('CREATE ROLE %I LOGIN REPLICATION PASSWORD %L', :'repl_user', :'repl_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user') \gexec
SELECT format('ALTER ROLE %I LOGIN REPLICATION PASSWORD %L', :'repl_user', :'repl_password') \gexec
SQL

runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v db="$PG_DB" <<'SQL'
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SQL

runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "$PG_DB" \
  -v app_user="$PG_APP_USER" <<'SQL'
CREATE TABLE IF NOT EXISTS resultats (
  matricule text PRIMARY KEY,
  nom text NOT NULL,
  serie text NOT NULL,
  moyenne numeric(4,2) NOT NULL CHECK (moyenne BETWEEN 0 AND 20),
  admis boolean NOT NULL
);
INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT 'BF' || lpad(n::text, 6, '0'), 'Candidat ' || n,
       CASE n % 3 WHEN 0 THEN 'A' WHEN 1 THEN 'C' ELSE 'D' END,
       round(((n % 2001) / 100.0)::numeric, 2), (n % 2001) >= 1000
FROM generate_series(1, 50000) AS n
ON CONFLICT (matricule) DO NOTHING;
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec
SELECT format('GRANT SELECT ON resultats TO %I', :'app_user') \gexec
SQL

PRIMARY_FILE=$(mktemp)
cat > "$PRIMARY_FILE" <<EOF
PRIMARY_HOST=bdd1
PRIMARY_IP=$BDD1_IP
EOF
if ! cmp -s "$PRIMARY_FILE" /vagrant/config/primary.env 2>/dev/null; then
  cat "$PRIMARY_FILE" > /vagrant/config/primary.env
fi
rm -f "$PRIMARY_FILE"
node_exporter
touch "/var/lib/postgresql/$PG_VERSION/main/.resultats-bf-primary"
chown postgres:postgres "/var/lib/postgresql/$PG_VERSION/main/.resultats-bf-primary"
echo "bdd1 : PostgreSQL primaire pret ($(runuser -u postgres -- psql -d "$PG_DB" -Atc 'SELECT count(*) FROM resultats') resultats)"
