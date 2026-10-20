#!/usr/bin/env bash
# =====================================================================
# scripts/app.sh — Installe le service applicatif RÉSULTATS-BF (Membre 2)
# Lancé par Vagrant (en root) sur chaque machine app1 ... appN.
# IDEMPOTENT (R2) : rejoué deux fois, il ne change rien la 2e fois.
# =====================================================================
# lib.sh (commun au groupe) charge .env, config/plateforme.env et
# config/noeuds.yml, et fournit BDD1_IP, ecrire_si_change, apt_installer.
source /vagrant/scripts/lib.sh

: "${PG_DB:?PG_DB doit etre defini dans .env}"
: "${PG_APP_USER:?PG_APP_USER doit etre defini dans .env}"
: "${PG_APP_PASSWORD:?PG_APP_PASSWORD doit etre defini dans .env}"
: "${BDD1_IP:?bdd1 absente de config/noeuds.yml}"

DEST=/opt/resultats-bf               # où le code est installé dans la VM
CONF=/etc/resultats-bf/app.env       # paramètres + mot de passe (hors Git)
UNIT=/etc/systemd/system/resultats-bf.service
APP_PORT=${APP_PORT:-3000}
CHANGE=0                             # passe à 1 si un fichier a changé

journal() { echo "[app.sh $MON_NOM] $*"; }

# --- 1. Paquets : installés une seule fois -----------------------------
apt_installer python3-psycopg2 curl

# --- 2. Utilisateur dédié, sans droits particuliers --------------------
id resultats >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin resultats
install -d -m 755 "$DEST"
install -d -m 700 /etc/resultats-bf

# --- 3. Le code : copié dans la VM (écrasé, jamais ajouté : piège n°2) --
ecrire_si_change "$DEST/app.py" 644 < /vagrant/app/app.py && CHANGE=1 || true

# --- 4. Les paramètres : lisibles par root seulement -------------------
# DB_PRIMAIRE_FICHIER : réécrit par ops/bascule.sh -> l'app suit la bascule.
ecrire_si_change "$CONF" 600 <<EOF && CHANGE=1 || true
DB_HOST=$BDD1_IP
DB_PRIMAIRE_FICHIER=/vagrant/config/primary.env
DB_PORT=5432
DB_NAME=$PG_DB
DB_USER=$PG_APP_USER
DB_PASSWORD=$PG_APP_PASSWORD
APP_PORT=$APP_PORT
EOF

# --- 5. Le service systemd : démarre au boot, redémarre s'il plante ---
ecrire_si_change "$UNIT" 644 <<EOF && CHANGE=1 || true
[Unit]
Description=RESULTATS-BF service applicatif
After=network-online.target
Wants=network-online.target

[Service]
User=resultats
EnvironmentFile=$CONF
ExecStart=/usr/bin/python3 $DEST/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# --- 6. Démarrage : on ne redémarre que si quelque chose a changé ------
systemctl daemon-reload
systemctl enable --quiet resultats-bf
if [ "$CHANGE" -eq 1 ]; then
  systemctl restart resultats-bf; journal "fichiers mis à jour, service redémarré"
else
  systemctl start resultats-bf;   journal "rien à changer (idempotent)"
fi
node_exporter                        # supervision, seulement si l'extension e2 est active

# --- 7. Vérification : l'application répond-elle ? ---------------------
# (/info ne dépend pas de la base : une base pas encore prête ne bloque rien)
for _ in $(seq 1 15); do
  if curl -fsS "http://127.0.0.1:$APP_PORT/info" >/dev/null 2>&1; then
    journal "OK : l'application répond sur le port $APP_PORT"
    exit 0
  fi
  sleep 1
done
journal "ERREUR : l'application ne répond pas" >&2
systemctl status resultats-bf --no-pager >&2 || true
exit 1
