#!/usr/bin/env bash
# Bibliothèque commune. Tous les scripts sont idempotents.

# Sécurité et chargement de la configuration
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
[ -f /vagrant/.env ] || { echo "ERREUR : .env absent. Faire : cp .env.exemple .env" >&2; exit 1; }
set -a
. <(tr -d '\r' < /vagrant/.env)
. /vagrant/config/plateforme.env
set +a

# Lecture de la source unique de vérité (noeuds.yml)
NOEUDS_YML=/vagrant/config/noeuds.yml
# noeuds ROLE|* -> lignes "nom ip"
noeuds() { awk -v r="$1" '{gsub(/\047|"/,"")} /^- nom:/{n=$3} /^  ip:/{i=$2} /^  role:/{ if (r=="*" || $2==r) print n, i }' "$NOEUDS_YML"; }
ip_de()  { awk -v x="$1" '{gsub(/\047|"/,"")} /^- nom:/{n=$3} /^  ip:/{ if (n==x) print $2 }' "$NOEUDS_YML"; }

BDD1_IP=$(ip_de bdd1)
BDD2_IP=$(ip_de bdd2)
RESEAU=${BDD1_IP%.*}
MON_NOM=$(hostname)
MON_IP=$(ip_de "$MON_NOM")

# ecrire_si_change DEST [MODE] [PROPRIETAIRE] < contenu  -> code 0 si modifié, 1 sinon
ecrire_si_change() {
  local dest="$1" mode="${2:-644}" proprio="${3:-root}" tmp
  tmp=$(mktemp); cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
  install -m "$mode" -o "$proprio" -g "$proprio" "$tmp" "$dest"; rm -f "$tmp"; return 0
}

# apt_installer PAQUET... : n'installe (en un seul appel) que ce qui manque
apt_installer() {
  local manque=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || manque+=("$p"); done
  if [ "${#manque[@]}" -gt 0 ]; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${manque[@]}"
  fi
}

extension_active() { [[ ",${EXTENSIONS:-}," == *",$1,"* ]]; }

node_exporter() {
  if extension_active e2; then
    apt_installer prometheus-node-exporter
    systemctl enable --now prometheus-node-exporter >/dev/null 2>&1
  fi
}
