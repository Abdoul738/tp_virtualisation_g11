#!/usr/bin/env bash
# =====================================================================
# scripts/replique.sh — Provisionnement de bdd2 (membre 3)
# Premier démarrage : réplique en flux du primaire (pg_basebackup + slot).
# Rejoué (vagrant provision, R2) : ne modifie rien. Si bdd2 a été promue
# primaire, ses données ne sont JAMAIS écrasées.
# =====================================================================
set -euo pipefail
source /vagrant/scripts/pg.sh          # charge aussi lib.sh (.env, noeuds.yml)

: "${PG_DB:?PG_DB doit etre defini dans .env}"
: "${PG_APP_USER:?PG_APP_USER doit etre defini dans .env}"
: "${PG_REPL_USER:?PG_REPL_USER doit etre defini dans .env}"
: "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD doit etre defini dans .env}"

apt_installer postgresql postgresql-client
pg_init
pg_configurer                          # configuration identique à bdd1 : prête à être promue

case "$(pg_role)" in
  replique)
    node_exporter
    echo "$MON_NOM : replique deja configuree (flux $(sql postgres 'SELECT status FROM pg_stat_wal_receiver'))"
    exit 0 ;;
  primaire)
    node_exporter
    echo "$MON_NOM : primaire depuis une bascule, aucune donnee n'est touchee"
    exit 0 ;;
  isolee)
    echo "$MON_NOM : isolee apres une bascule, lancer ops/reintegrer_bdd1.sh depuis l'hote"
    exit 0 ;;
esac

# Cluster neuf : copie du primaire désigné par config/primary.env (bdd1 au premier démarrage).
echo "Attente du primaire..."
for essai in $(seq 1 60); do
  if ip=$(autre_primaire_ip); then break; fi
  [ "$essai" -eq 60 ] && { echo "Aucun primaire joignable apres 2 min (config/primary.env)" >&2; exit 1; }
  sleep 2
done
pg_copier_depuis "$ip"
pg_cluster start; attendre_sql
[ "$(sql postgres 'SELECT pg_is_in_recovery()')" = t ] || { echo "$MON_NOM n'est pas devenue une replique" >&2; exit 1; }
pg_attendre_flux
node_exporter
echo "$MON_NOM : replique en flux de $(primaire_actuel) prete"
