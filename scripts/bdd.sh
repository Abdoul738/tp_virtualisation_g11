#!/usr/bin/env bash
# =====================================================================
# scripts/bdd.sh — Provisionnement de bdd1 (membre 3)
# Premier démarrage : PostgreSQL primaire, rôles, droits, 50 000 résultats.
# Rejoué (vagrant provision, R2) : ne modifie rien, et ne touche jamais
# un nœud devenu réplique après une bascule.
# =====================================================================
set -euo pipefail
source /vagrant/scripts/pg.sh          # charge aussi lib.sh (.env, noeuds.yml)

: "${PG_DB:?PG_DB doit etre defini dans .env}"
: "${PG_APP_USER:?PG_APP_USER doit etre defini dans .env}"
: "${PG_APP_PASSWORD:?PG_APP_PASSWORD doit etre defini dans .env}"
: "${PG_REPL_USER:?PG_REPL_USER doit etre defini dans .env}"
: "${PG_REPL_PASSWORD:?PG_REPL_PASSWORD doit etre defini dans .env}"

apt_installer postgresql postgresql-client
pg_init
pg_configurer                          # configuration identique à bdd2

role=$(pg_role)
case "$role" in
  replique)
    journal "replique de $(primaire_actuel) depuis une bascule : rien a initialiser"
    node_exporter; exit 0 ;;
  isolee)
    journal "isolee apres une bascule : lancer ops/reintegrer_bdd1.sh depuis l'hote"
    exit 0 ;;
esac

# Un autre nœud est déjà primaire (bascule) : ne jamais en créer un second.
if ip=$(autre_primaire_ip); then
  if [ "$role" = vierge ]; then        # bdd1 reconstruite seule : elle devient réplique du primaire
    pg_copier_depuis "$ip"
    pg_cluster start; attendre_sql; pg_attendre_flux
    node_exporter
    echo "$MON_NOM : reconstruite comme replique de $(primaire_actuel)"
    exit 0
  fi
  pg_isoler
  echo "ALERTE : $(primaire_actuel) est deja primaire. $MON_NOM est isolee pour eviter un split-brain." >&2
  echo "Lancer ops/reintegrer_bdd1.sh depuis l'hote." >&2
  exit 1
fi

pg_roles_et_droits
pg_jeu_de_donnees
ecrire_primaire                        # config/primary.env : lu par les applications
node_exporter
echo "$MON_NOM : PostgreSQL primaire pret ($(sql "$PG_DB" 'SELECT count(*) FROM resultats') resultats)"
