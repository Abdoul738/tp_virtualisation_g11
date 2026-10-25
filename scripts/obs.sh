#!/usr/bin/env bash
# E2 : installation et configuration de la supervision.
source /vagrant/scripts/lib.sh

if ! extension_active e2; then
  echo "Extension e2 inactive."
  exit 0
fi

apt_installer ca-certificates curl prometheus

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Depot officiel Grafana : necessaire a la premiere installation.
if ! dpkg -s grafana >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings

  curl --fail --silent --show-error --location \
    --retry 3 --connect-timeout 10 --max-time 120 \
    https://apt.grafana.com/gpg-full.key \
    -o "$TEMP_DIR/grafana.asc"

  ecrire_si_change /etc/apt/keyrings/grafana.asc 644 \
    < "$TEMP_DIR/grafana.asc" || true

  ecrire_si_change /etc/apt/sources.list.d/grafana.list 644 <<'EOF' || true
deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main
EOF

  apt_installer grafana
fi

# Exporteur systeme de la VM obs.
node_exporter

# Configuration Prometheus engendree depuis l'inventaire.
{
  cat <<'EOF'
global:
  scrape_interval: 5s
  scrape_timeout: 3s
  evaluation_interval: 5s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']
        labels:
          noeud: obs

  - job_name: systeme
    static_configs:
EOF

  while read -r nom ip; do
    printf "      - targets: ['%s:9100']\n" "$ip"
    printf "        labels:\n"
    printf "          noeud: '%s'\n" "$nom"
  done < <(noeuds '*')

  cat <<'EOF'

  - job_name: haproxy
    static_configs:
EOF

  while read -r nom ip; do
    printf "      - targets: ['%s:8405']\n" "$ip"
    printf "        labels:\n"
    printf "          noeud: '%s'\n" "$nom"
  done < <(noeuds lb)
} > "$TEMP_DIR/prometheus.yml"

# Refuser une configuration invalide avant son installation.
promtool check config "$TEMP_DIR/prometheus.yml"

PROM_CHANGE=0
if ecrire_si_change /etc/prometheus/prometheus.yml 644 prometheus \
    < "$TEMP_DIR/prometheus.yml"; then
  PROM_CHANGE=1
fi

systemctl enable prometheus >/dev/null 2>&1
if systemctl is-active --quiet prometheus; then
  if [ "$PROM_CHANGE" = 1 ]; then
    systemctl restart prometheus
  fi
else
  systemctl start prometheus
fi

# Source de donnees Grafana creee automatiquement.
install -d -m 0755 /etc/grafana/provisioning/datasources

GRAFANA_CHANGE=0
if ecrire_si_change \
    /etc/grafana/provisioning/datasources/resultats-bf.yml \
    644 root <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: resultats-prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
EOF
then
  GRAFANA_CHANGE=1
fi

# Tableau de bord genere depuis le script du projet.
install -d -m 0755 /var/lib/grafana/dashboards
install -d -m 0755 /etc/grafana/provisioning/dashboards

python3 /vagrant/scripts/generer-dashboard.py \
  > "$TEMP_DIR/resultats-bf.json"

if ecrire_si_change \
    /var/lib/grafana/dashboards/resultats-bf.json \
    644 root < "$TEMP_DIR/resultats-bf.json"; then
  GRAFANA_CHANGE=1
fi

if ecrire_si_change \
    /etc/grafana/provisioning/dashboards/resultats-bf.yml \
    644 root <<'EOF'
apiVersion: 1
providers:
  - name: resultats-bf
    orgId: 1
    folder: RESULTATS-BF
    type: file
    disableDeletion: false
    allowUiUpdates: false
    updateIntervalSeconds: 15
    options:
      path: /var/lib/grafana/dashboards
EOF
then
  GRAFANA_CHANGE=1
fi

systemctl enable grafana-server >/dev/null 2>&1
if systemctl is-active --quiet grafana-server; then
  if [ "$GRAFANA_CHANGE" = 1 ]; then
    systemctl restart grafana-server
  fi
else
  systemctl start grafana-server
fi

echo "Prometheus : $(systemctl is-active prometheus)"
echo "Grafana : $(systemctl is-active grafana-server)"
echo "Acces Prometheus : http://${MON_IP}:9090"
echo "Acces Grafana : http://${MON_IP}:3000"