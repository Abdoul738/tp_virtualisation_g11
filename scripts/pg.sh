#!/usr/bin/env bash
# =====================================================================
# scripts/pg.sh — Outils PostgreSQL du projet (membre 3, ingénieur données)
#
# Deux usages :
#  1. bibliothèque : « source /vagrant/scripts/pg.sh » dans bdd.sh et replique.sh
#  2. commande, dans bdd1 ou bdd2 :  sudo bash /vagrant/scripts/pg.sh ACTION
#       status           rôle du nœud (primaire | replique | isolee) et état du flux
#       promote          promeut la réplique et met à jour config/primary.env
#       isoler           arrête PostgreSQL et l'empêche de redémarrer seul (anti split-brain)
#       preparer NOEUD   sur le primaire : accès, droits et slot pour la future réplique NOEUD
#       rejoin           sur l'ancien primaire : redevient réplique du primaire courant
#       verifier         sur le primaire : test R5 avec mesure du délai de réplication
#
# Principe : bdd1 et bdd2 ont EXACTEMENT la même configuration ; seul le rôle
# diffère, et il est lu dans l'état réel de PostgreSQL (jamais dans un fichier marqueur).
# =====================================================================
set -euo pipefail
source /vagrant/scripts/lib.sh
cd /                                   # psql lancé en postgres : pas de répertoire courant interdit

PG_PORT=5432
FICHIER_PRIMAIRE=/vagrant/config/primary.env
PASSFILE=/var/lib/postgresql/.pgpass   # mot de passe de réplication, droits 600 (jamais dans le dépôt)

journal() { echo "[pg.sh $MON_NOM] $*"; }

pg_init() {                            # à appeler après l'installation des paquets
  PG_VERSION=$(pg_lsclusters -h | awk 'NR == 1 {print $1}')
  [ -n "$PG_VERSION" ] || { echo "Cluster PostgreSQL introuvable" >&2; exit 1; }
  PG_BIN=/usr/lib/postgresql/$PG_VERSION/bin   # pg_rewind n'est pas dans le PATH sous Ubuntu
  ETC_DIR=/etc/postgresql/$PG_VERSION/main
  CONF_DIR=$ETC_DIR/conf.d
  DATA_DIR=/var/lib/postgresql/$PG_VERSION/main
  HBA=$ETC_DIR/pg_hba.conf
}

# --- Petites briques ---------------------------------------------------
pg_cluster()  { pg_ctlcluster "$PG_VERSION" main "$@"; }
en_marche()   { pg_lsclusters -h | awk '$2 == "main" && $4 ~ /^online/ {ok = 1} END {exit !ok}'; }   # « online » ou « online,recovery »
sql()         { local db=$1; shift; runuser -u postgres -- psql -X -w -v ON_ERROR_STOP=1 -p "$PG_PORT" -d "$db" -Atqc "$*"; }
sql_distant() { local ip=$1 db=$2; shift 2
                PGCONNECT_TIMEOUT=5 runuser -u postgres -- psql -X -w -v ON_ERROR_STOP=1 \
                  -h "$ip" -p "$PG_PORT" -U "$PG_REPL_USER" -d "$db" -Atqc "$*"; }
attendre_sql(){ for _ in $(seq 1 30); do sql postgres 'SELECT 1' >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
autre_bdd()   { if [ "$MON_NOM" = bdd1 ]; then echo bdd2; else echo bdd1; fi; }
primaire_actuel() { awk -F= '/^PRIMARY_HOST=/ {print $2}' "$FICHIER_PRIMAIRE" 2>/dev/null | tr -d '\r'; }
ecrire_primaire() {
  local contenu
  contenu=$(printf 'PRIMARY_HOST=%s\nPRIMARY_IP=%s' "$MON_NOM" "$MON_IP")
  [ "$(cat "$FICHIER_PRIMAIRE" 2>/dev/null | tr -d '\r')" = "$contenu" ] || printf '%s\n' "$contenu" > "$FICHIER_PRIMAIRE"
}
start_conf() { printf '%s\n' "$1" | ecrire_si_change "$ETC_DIR/start.conf" 644 postgres || true; }

# IP de l'AUTRE nœud s'il est désigné primaire par config/primary.env et qu'il répond.
# Prudence volontaire : dans le doute, on le considère comme primaire (on refuse d'en créer un second).
autre_primaire_ip() {
  local h ip
  h=$(primaire_actuel)
  [ -n "$h" ] && [ "$h" != "$MON_NOM" ] || return 1
  ip=$(ip_de "$h"); [ -n "$ip" ] || return 1
  pg_isready -q -h "$ip" -p "$PG_PORT" -t 3 || return 1
  echo "$ip"
}

# Rôle réel : primaire | replique | isolee | vierge (cluster neuf, sans la base du projet)
# --sans-demarrer : ne démarre pas PostgreSQL s'il est arrêté (affiche « arrete »).
pg_role() {
  if ! en_marche; then
    if [ "$(grep -v '^[[:space:]]*#' "$ETC_DIR/start.conf" | tr -d ' \t\r\n')" = manual ]; then echo isolee; return 0; fi
    if [ "${1:-}" = --sans-demarrer ]; then echo arrete; return 0; fi
    { pg_cluster start && attendre_sql; } >&2 || return 1   # rien sur la sortie standard : elle porte le rôle
  fi
  case "$(sql postgres 'SELECT pg_is_in_recovery()')" in
    t) echo replique ;;
    f) if [ "$(sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$PG_DB'")" = 1 ]
       then echo primaire; else echo vierge; fi ;;
    *) return 1 ;;
  esac
}

# --- Configuration commune aux deux nœuds (idempotente) ----------------
pg_configurer() {
  : "${PG_DB:?}" "${PG_APP_USER:?}" "${PG_REPL_USER:?}" "${PG_REPL_PASSWORD:?}"
  local change=0 hba_change=0 tmp f
  install -d -m 755 -o postgres -g postgres "$CONF_DIR"
  for f in 99-resultats-bf-listen.conf 99-resultats-bf-replica.conf; do   # fichiers de l'ancienne version
    if [ -f "$CONF_DIR/$f" ]; then rm -f "$CONF_DIR/$f"; change=1; fi
  done
  ecrire_si_change "$CONF_DIR/99-resultats-bf.conf" 644 postgres <<'EOF' && change=1 || true
# Identique sur bdd1 et bdd2 : seul le rôle diffère (scripts/pg.sh)
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
wal_log_hints = on               # nécessaire à pg_rewind (réintégration de l'ancien primaire)
max_slot_wal_keep_size = '1GB'   # une réplique arrêtée ne peut pas remplir le disque du primaire
password_encryption = 'scram-sha-256'
EOF

  # pg_hba.conf : un seul bloc du projet, accès limités au réseau privé du groupe
  tmp=$(mktemp)
  awk -v db="$PG_DB" -v u="$PG_APP_USER" '
    /^# BEGIN RESULTATS-BF$/ {saute = 1; next}
    /^# END RESULTATS-BF$/   {saute = 0; next}
    saute {next}
    $1 == "host" && $2 == db && $3 == u && $4 ~ /\/32$/ {next}   # anciennes règles par serveur (couvertes par le /24)
    {print}' "$HBA" > "$tmp"
  cat >> "$tmp" <<EOF
# BEGIN RESULTATS-BF
# Accès limités au réseau privé du groupe (scripts/pg.sh)
host    $PG_DB       $PG_APP_USER       $RESEAU.0/24       scram-sha-256
host    replication  $PG_REPL_USER      $RESEAU.0/24       scram-sha-256
host    postgres     $PG_REPL_USER      $RESEAU.0/24       scram-sha-256
# END RESULTATS-BF
EOF
  if ! cmp -s "$tmp" "$HBA"; then install -m 640 -o postgres -g postgres "$tmp" "$HBA"; hba_change=1; fi
  rm -f "$tmp"

  printf '*:%s:*:%s:%s\n' "$PG_PORT" "$PG_REPL_USER" "$PG_REPL_PASSWORD" |
    ecrire_si_change "$PASSFILE" 600 postgres || true
  rm -f "$DATA_DIR/.resultats-bf-primary"   # ancien marqueur : copié par pg_basebackup, donc non fiable

  if en_marche; then
    if [ "$change" -eq 1 ]; then pg_cluster restart; attendre_sql
    elif [ "$hba_change" -eq 1 ]; then pg_cluster reload; fi
  fi
}

# --- Rôles, droits et jeu de données (sur le primaire, idempotent) -----
mdp_valide() { PGPASSWORD="$2" psql -X -w -h 127.0.0.1 -p "$PG_PORT" -U "$1" -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; }
fixer_mdp() {   # le mot de passe passe par une variable psql : jamais écrit dans un fichier ni affiché
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d postgres -v u="$1" -v p="$2" <<'SQL'
SELECT format('ALTER ROLE %I PASSWORD %L', :'u', :'p') \gexec
SQL
}
pg_roles_et_droits() {
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d postgres \
    -v app_user="$PG_APP_USER" -v repl_user="$PG_REPL_USER" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('CREATE ROLE %I LOGIN REPLICATION', :'repl_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user') \gexec
-- Droits minimaux exigés par pg_rewind (réintégration sans superutilisateur)
SELECT format('GRANT EXECUTE ON FUNCTION %s TO %I', f, :'repl_user')
FROM unnest(ARRAY['pg_catalog.pg_ls_dir(text, boolean, boolean)',
                  'pg_catalog.pg_stat_file(text, boolean)',
                  'pg_catalog.pg_read_binary_file(text)',
                  'pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)']) AS f
WHERE NOT has_function_privilege(:'repl_user', f, 'EXECUTE') \gexec
SQL
  mdp_valide "$PG_APP_USER" "$PG_APP_PASSWORD"   || fixer_mdp "$PG_APP_USER" "$PG_APP_PASSWORD"
  mdp_valide "$PG_REPL_USER" "$PG_REPL_PASSWORD" || fixer_mdp "$PG_REPL_USER" "$PG_REPL_PASSWORD"
}
pg_jeu_de_donnees() {
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d postgres -v db="$PG_DB" <<'SQL'
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
SQL
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d "$PG_DB" -v app_user="$PG_APP_USER" <<'SQL'
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
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user')
WHERE NOT has_database_privilege(:'app_user', current_database(), 'CONNECT') \gexec
SELECT format('GRANT SELECT ON resultats TO %I', :'app_user')
WHERE NOT has_table_privilege(:'app_user', 'resultats', 'SELECT') \gexec
SQL
}

# --- Réplication ---------------------------------------------------------
# Paramètres de réplique : écrits dans postgresql.auto.conf, qui est relu APRÈS conf.d
# (pg_rewind et pg_basebackup y recopient ceux du primaire : on les remplace).
pg_ecrire_recovery() {
  local ip=$1 auto="$DATA_DIR/postgresql.auto.conf" tmp
  tmp=$(mktemp)
  grep -vE '^[[:space:]]*(primary_conninfo|primary_slot_name)[[:space:]]*=' "$auto" > "$tmp" 2>/dev/null || true
  printf "primary_conninfo = 'host=%s port=%s user=%s application_name=%s passfile=%s'\n" \
    "$ip" "$PG_PORT" "$PG_REPL_USER" "$MON_NOM" "$PASSFILE" >> "$tmp"
  printf "primary_slot_name = 'resultats_bf_%s'\n" "$MON_NOM" >> "$tmp"
  install -m 600 -o postgres -g postgres "$tmp" "$auto"; rm -f "$tmp"
  install -m 600 -o postgres -g postgres /dev/null "$DATA_DIR/standby.signal"
}
# Remplace les données locales par une copie complète du primaire (nouvelle réplique).
pg_copier_depuis() {
  local ip=$1 slot="resultats_bf_$MON_NOM"
  journal "copie complete depuis le primaire $ip (pg_basebackup)"
  # Un slot laissé par une ancienne copie de ce nœud ferait échouer « pg_basebackup -C ».
  sql_distant "$ip" postgres "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots
                              WHERE slot_name = '$slot' AND NOT active" >/dev/null
  if en_marche; then pg_cluster stop; fi
  find "$DATA_DIR" -mindepth 1 -delete
  runuser -u postgres -- "$PG_BIN/pg_basebackup" -w -h "$ip" -p "$PG_PORT" -U "$PG_REPL_USER" \
    -D "$DATA_DIR" -X stream -C -S "$slot"
  pg_ecrire_recovery "$ip"
}
pg_attendre_flux() {
  for _ in $(seq 1 30); do
    [ "$(sql postgres 'SELECT status FROM pg_stat_wal_receiver' 2>/dev/null)" = streaming ] && return 0
    sleep 1
  done
  echo "Pas de flux de replication apres 30 s. Fin du journal PostgreSQL :" >&2
  tail -n 5 "/var/log/postgresql/postgresql-$PG_VERSION-main.log" >&2 || true
  return 1
}
pg_isoler() {
  start_conf manual                  # au prochain démarrage de la VM, PostgreSQL ne repart pas seul
  if en_marche; then pg_cluster stop; fi
}

# --- Actions en ligne de commande -------------------------------------------
action_status() {
  local role
  role=$(pg_role --sans-demarrer) || { echo "Role PostgreSQL indetermine" >&2; exit 1; }
  echo "$role"                       # ligne seule : lue par tests/campagne-*.ps1
  case "$role" in
    primaire) sql postgres "SELECT 'replique connectee : ' || application_name || ' (' || host(client_addr)
                            || ', ' || state || ', ' || sync_state || ')' FROM pg_stat_replication" ;;
    replique) sql postgres "SELECT 'flux depuis ' || sender_host || ' : ' || status FROM pg_stat_wal_receiver" ;;
    *) exit 1 ;;
  esac
}

action_promote() {
  local mode=""
  [ "$(pg_role)" = replique ] || { echo "REFUS : $MON_NOM n'est pas une replique." >&2; exit 1; }
  pg_configurer
  sql postgres 'SELECT pg_promote(true, 60)' >/dev/null
  for _ in $(seq 1 30); do
    mode=$(sql postgres 'SELECT pg_is_in_recovery()'); [ "$mode" = f ] && break; sleep 1
  done
  [ "$mode" = f ] || { echo "Echec de promotion PostgreSQL" >&2; exit 1; }
  start_conf auto
  ecrire_primaire                    # les applications relisent ce fichier à chaque requête
  echo "$MON_NOM est maintenant primaire"
}

action_preparer() {
  local cible=${1:?Usage: pg.sh preparer NOEUD}
  [ "$(pg_role)" = primaire ] || { echo "REFUS : $MON_NOM n'est pas le primaire." >&2; exit 1; }
  pg_configurer                      # même configuration que la future réplique (HBA de réplication inclus)
  pg_roles_et_droits                 # droits pg_rewind, au cas où le primaire vient d'une ancienne version
  sql postgres "SELECT pg_create_physical_replication_slot('resultats_bf_$cible', true)
                WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'resultats_bf_$cible')" >/dev/null
  journal "pret a accueillir $cible comme replique (slot resultats_bf_$cible)"
}

action_rejoin() {
  local ip methode
  ip=$(autre_primaire_ip) || { echo "REFUS : config/primary.env ne designe aucun autre primaire joignable." >&2; exit 1; }
  journal "1/4 isolation : PostgreSQL arrete et demarrage automatique coupe"
  pg_isoler
  pg_configurer
  journal "2/4 resynchronisation depuis $ip"
  if runuser -u postgres -- "$PG_BIN/pg_rewind" -D "$DATA_DIR" \
       --source-server="host=$ip port=$PG_PORT user=$PG_REPL_USER dbname=postgres passfile=$PASSFILE"; then
    methode=pg_rewind
  else
    journal "pg_rewind impossible : copie complete a la place"
    pg_copier_depuis "$ip"; methode=pg_basebackup
  fi
  pg_ecrire_recovery "$ip"
  journal "3/4 demarrage en replique"
  start_conf auto
  pg_cluster start; attendre_sql
  [ "$(sql postgres 'SELECT pg_is_in_recovery()')" = t ] || { echo "Echec : $MON_NOM n'est pas en replique." >&2; exit 1; }
  pg_attendre_flux || exit 1
  # Slots hérités de l'époque où ce nœud était primaire : ils retiendraient des WAL inutilement.
  sql postgres "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE NOT active" >/dev/null || true
  journal "4/4 controle : flux $(sql postgres 'SELECT status FROM pg_stat_wal_receiver') depuis $ip"
  echo "$MON_NOM reintegree comme replique de $(primaire_actuel) ($methode)"
}

action_verifier() {
  local rep ip_rep jeton t0 t1 attente pid ms resultat
  [ "$(pg_role)" = primaire ] || { echo "REFUS : $MON_NOM n'est pas le primaire." >&2; exit 1; }
  rep=$(autre_bdd); ip_rep=$(ip_de "$rep")
  echo "Repliques connectees a $MON_NOM (pg_stat_replication) :"
  runuser -u postgres -- psql -X -x -p "$PG_PORT" -d postgres -c \
    "SELECT application_name, client_addr, state, sync_state, write_lag, flush_lag, replay_lag FROM pg_stat_replication"
  jeton="REP-$(date +%s)-$RANDOM"
  attente=$(mktemp)
  # Une session sur la réplique, ouverte AVANT l'écriture, attend la ligne (lecture toutes les 10 ms) :
  # le délai mesuré n'inclut donc pas l'ouverture de connexion.
  PGPASSWORD="$PG_APP_PASSWORD" psql -X -w -q -At -v ON_ERROR_STOP=1 -h "$ip_rep" -p "$PG_PORT" \
    -U "$PG_APP_USER" -d "$PG_DB" -v jeton="$jeton" > "$attente" 2>&1 <<'SQL' &
SELECT set_config('rbf.jeton', :'jeton', false) IS NOT NULL AS pret;
DO $$
BEGIN
  FOR i IN 1..3000 LOOP
    IF EXISTS (SELECT 1 FROM resultats WHERE matricule = current_setting('rbf.jeton')) THEN RETURN; END IF;
    PERFORM pg_sleep(0.01);
  END LOOP;
  RAISE EXCEPTION 'ligne absente apres 30 s';
END $$;
SQL
  pid=$!
  for _ in $(seq 1 100); do grep -q '^t$' "$attente" && break; sleep 0.05; done   # session prête
  t0=$(date +%s%N)
  sql "$PG_DB" "INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
                VALUES ('$jeton', 'Verification replication', 'T', 20.00, true)" >/dev/null
  if wait "$pid"; then resultat=ok; else resultat=echec; fi
  t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
  sql "$PG_DB" "DELETE FROM resultats WHERE matricule = '$jeton'" >/dev/null   # le jeu de données reste intact
  if [ "$resultat" = ok ]; then
    echo "OK R5 : $jeton ecrit sur $MON_NOM, visible sur $rep apres $ms ms."
  else
    echo "ECHEC R5 : $jeton non visible sur $rep." >&2
    { grep -m 1 -iE 'error|erreur' "$attente" || tail -n 1 "$attente"; } | sed 's/^[[:space:]]*/  cause : /' >&2
    rm -f "$attente"; exit 1
  fi
  rm -f "$attente"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then   # exécuté (et non sourcé) : action en ligne de commande
  pg_init
  case "${1:-status}" in
    status)   action_status ;;
    promote)  action_promote ;;
    isoler)   pg_isoler; echo "$MON_NOM isolee : PostgreSQL arrete, demarrage automatique coupe" ;;
    preparer) action_preparer "${2:-}" ;;
    rejoin)   action_rejoin ;;
    verifier) action_verifier ;;
    *) echo "Usage: $0 {status|promote|isoler|preparer NOEUD|rejoin|verifier}" >&2; exit 2 ;;
  esac
fi
