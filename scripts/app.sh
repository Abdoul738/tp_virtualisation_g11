#!/usr/bin/env bash
# =====================================================================
# scripts/app.sh — Installe le service applicatif RÉSULTATS-BF (Membre 2)
# Lancé par Vagrant (en root) sur chaque machine app1 ... appN.
# IDEMPOTENT (R2) : rejoué deux fois, il ne change rien la 2e fois.
# =====================================================================
set -euo pipefail

SRC=/vagrant/app/app.py              # le code, partagé par Vagrant
DEST=/opt/resultats-bf               # où le code est installé dans la VM
CONF=/etc/resultats-bf/app.env       # paramètres + mot de passe (hors Git)
UNIT=/etc/systemd/system/resultats-bf.service
CHANGE=0                             # passe à 1 si quelque chose a changé

journal() { echo "[app.sh $(hostname)] $*"; }

# Écrit le contenu reçu dans le fichier $1 SEULEMENT s'il est différent.
# On écrase avec ">" (jamais ">>" : piège n°2, les doublons).
ecrire_si_change() {
  local cible=$1 mode=$2 tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$cible" ] && cmp -s "$tmp" "$cible"; then
    rm -f "$tmp"
  else
    install -D -m "$mode" "$tmp" "$cible"; rm -f "$tmp"
    journal "mis à jour : $cible"; CHANGE=1
  fi
}

# --- 1. Paramètres : variables reçues de Vagrant, sinon fichier .env ---
if [ -f /vagrant/.env ]; then
  # tr -d '\r' : protège contre un .env écrit sous Windows (piège CRLF)
  set -a; . <(tr -d '\r' < /vagrant/.env); set +a
fi
if [ -z "${DB_HOST:-}" ] && [ -f /vagrant/config/noeuds.yml ]; then
  # Adresse de bdd1 lue dans la source unique de vérité (config/noeuds.yml)
  DB_HOST=$(awk '/:nom: bdd1/{t=1} t && /:ip:/{print $2; exit}' /vagrant/config/noeuds.yml)
fi
: "${DB_HOST:?DB_HOST introuvable (ni variable, ni config/noeuds.yml)}"
: "${DB_PASSWORD:?DB_PASSWORD absent : copiez .env.exemple en .env}"

# --- 2. Paquets : installés une seule fois (connexion lente) ---------
if ! dpkg -s python3-psycopg2 >/dev/null 2>&1; then
  journal "installation de python3-psycopg2"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3-psycopg2 curl
fi

# --- 3. Utilisateur dédié, sans droits particuliers ---------------------
id resultats >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin resultats

# --- 4. Le code : copié dans la VM (la VM ne dépend pas du dossier partagé)
ecrire_si_change "$DEST/app.py" 644 < "$SRC"

# --- 5. Les paramètres : lisibles par root seulement -------------------
ecrire_si_change "$CONF" 600 <<EOF
DB_HOST=$DB_HOST
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-resultats}
DB_USER=${DB_USER:-app_user}
DB_PASSWORD=$DB_PASSWORD
APP_PORT=${APP_PORT:-3000}
EOF

# --- 6. Le service systemd : démarre au boot, redémarre s'il plante ---
ecrire_si_change "$UNIT" 644 <<EOF
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

# --- 7. Démarrage : on ne redémarre que si quelque chose a changé ------
systemctl daemon-reload
systemctl enable --quiet resultats-bf
if [ "$CHANGE" -eq 1 ]; then
  systemctl restart resultats-bf; journal "service redémarré"
else
  systemctl start resultats-bf;   journal "rien à changer (idempotent)"
fi

# --- 8. Vérification : l'application répond-elle ? ---------------------
for _ in $(seq 1 15); do
  if curl -fsS "http://127.0.0.1:${APP_PORT:-3000}/info" >/dev/null 2>&1; then
    journal "OK : l'application répond sur le port ${APP_PORT:-3000}"
    exit 0
  fi
  sleep 1
done
journal "ERREUR : l'application ne répond pas" >&2
systemctl status resultats-bf --no-pager >&2 || true
exit 1
