#!/usr/bin/env bash
# Verifie R5 par une ecriture unique sur le primaire, puis une lecture bdd2.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . <(tr -d '\r' < .env); set +a
: "${PG_DB:?PG_DB doit etre defini dans .env}"
token="REP-$(date +%s)-$RANDOM"

vagrant ssh bdd1 -c "sudo -u postgres psql -v ON_ERROR_STOP=1 -d '$PG_DB' -c \"INSERT INTO resultats (matricule, nom, serie, moyenne, admis) VALUES ('$token', 'Verification replication', 'T', 20.00, true);\""
for essai in $(seq 1 30); do
  trouve=$(vagrant ssh bdd2 -c "sudo -u postgres psql -At -d '$PG_DB' -c \"SELECT count(*) FROM resultats WHERE matricule='$token';\"" | tr -d '\r')
  [ "$trouve" = "1" ] && { echo "OK R5 : $token est visible sur bdd2."; exit 0; }
  sleep 1
done
echo "ECHEC R5 : l'ecriture $token n'est pas visible sur bdd2 apres 30 s." >&2
exit 1
