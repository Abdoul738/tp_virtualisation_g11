#!/usr/bin/env bash
# Outils PostgreSQL du projet.
set -euo pipefail
source /vagrant/scripts/lib.sh

PG_VERSION=$(pg_lsclusters -h | awk 'NR == 1 {print $1}')
DATA_DIR="/var/lib/postgresql/$PG_VERSION/main"
CONF_DIR="/etc/postgresql/$PG_VERSION/main/conf.d"
action="${1:-status}"

lire_mode() {
  timeout 15s runuser -u postgres -- \
    psql -X -w -v ON_ERROR_STOP=1 -d postgres \
    -Atqc 'SELECT pg_is_in_recovery();'
}

attendre_sql() {
  for _ in $(seq 1 30); do
    if timeout 3s runuser -u postgres -- \
        psql -X -w -v ON_ERROR_STOP=1 -d postgres \
        -Atqc 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

configurer_acces() {
  : "${PG_DB:?PG_DB absent}"
  : "${PG_APP_USER:?PG_APP_USER absent}"

  local hba nom ip regle erreurs

  hba=$(timeout 15s runuser -u postgres -- \
    psql -X -w -v ON_ERROR_STOP=1 -d postgres -Atqc 'SHOW hba_file;')

  if [[ ! -f "$hba" ]]; then
    echo "Fichier pg_hba.conf introuvable" >&2
    return 1
  fi

  if [[ ! -f "${hba}.avant-acces-apps" ]]; then
    cp -p "$hba" "${hba}.avant-acces-apps"
  fi

  while read -r nom ip; do
    regle=$(printf 'host %s %s %s/32 scram-sha-256' \
      "$PG_DB" "$PG_APP_USER" "$ip")

    if ! grep -Fqx -- "$regle" "$hba"; then
      printf '\n%s\n' "$regle" >> "$hba"
    fi
  done < <(noeuds app)

  erreurs=$(timeout 15s runuser -u postgres -- \
    psql -X -w -v ON_ERROR_STOP=1 -d postgres \
    -Atqc 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;')

  if [[ "$erreurs" != "0" ]]; then
    echo "Configuration HBA invalide : rechargement refuse" >&2
    return 1
  fi

  pg_ctlcluster "$PG_VERSION" main reload
}

configurer_ecoute() {
  : "${MON_IP:?Adresse privee absente dans inventaire}"
  install -d -m 755 "$CONF_DIR"

  if printf "listen_addresses = '127.0.0.1,%s'\n" "$MON_IP" |
      ecrire_si_change \
        "$CONF_DIR/99-resultats-bf-listen.conf" 644 postgres; then
    pg_ctlcluster "$PG_VERSION" main restart
  fi

  attendre_sql
  configurer_acces
}

case "$action" in
  reseau)
    configurer_ecoute
    echo "Ecoute PostgreSQL configuree sur $MON_IP"
    ;;

  status)
    mode=$(lire_mode)
    case "$mode" in
      t) echo "replique" ;;
      f) echo "primaire" ;;
      *) echo "Role PostgreSQL indetermine" >&2; exit 1 ;;
    esac
    ;;

  promote)
    mode=$(lire_mode)
    if [[ "$mode" != "t" ]]; then
      echo "REFUS : cette machine n'est pas une replique." >&2
      exit 1
    fi

    configurer_ecoute
    pg_ctlcluster "$PG_VERSION" main promote

    for _ in $(seq 1 30); do
      mode=$(lire_mode)
      if [[ "$mode" == "f" ]]; then
        break
      fi
      sleep 1
    done

    if [[ "$mode" != "f" ]]; then
      echo "Echec de promotion PostgreSQL" >&2
      exit 1
    fi

    touch "$DATA_DIR/.resultats-bf-primary"
    chown postgres:postgres "$DATA_DIR/.resultats-bf-primary"

    printf 'PRIMARY_HOST=%s\nPRIMARY_IP=%s\n' \
      "$MON_NOM" "$MON_IP" |
      ecrire_si_change /vagrant/config/primary.env 644 || true

    echo "$MON_NOM est maintenant primaire"
    ;;

  rejoin)
    primaire_ip="${2:?Usage: pg.sh rejoin IP_DU_PRIMAIRE}"
    : "${PG_REPL_USER:?PG_REPL_USER absent}"
    : "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD absent}"

    systemctl stop postgresql

    runuser -u postgres -- env PGPASSWORD="$PG_REPL_PASSWORD" \
      pg_rewind -D "$DATA_DIR" \
      --source-server="host=$primaire_ip user=$PG_REPL_USER dbname=postgres"

    install -d -m 755 "$CONF_DIR"

    printf "primary_conninfo = 'host=%s port=5432 user=%s password=%s application_name=%s'\n" \
      "$primaire_ip" "$PG_REPL_USER" "$PG_REPL_PASSWORD" "$MON_NOM" |
      ecrire_si_change \
        "$CONF_DIR/99-resultats-bf-replica.conf" 640 postgres || true

    touch "$DATA_DIR/standby.signal"
    chown postgres:postgres "$DATA_DIR/standby.signal"

    pg_ctlcluster "$PG_VERSION" main start

    for _ in $(seq 1 30); do
      mode=$(lire_mode)
      if [[ "$mode" == "t" ]]; then
        echo "$MON_NOM reintegree comme replique"
        exit 0
      fi
      sleep 1
    done

    echo "Echec de reintegration" >&2
    exit 1
    ;;

  *)
    echo "Usage: $0 {status|reseau|promote|rejoin IP_DU_PRIMAIRE}" >&2
    exit 2
    ;;
esac