#!/usr/bin/env bash
# Répartiteur. La liste des serveurs est ENGENDRÉE depuis config/noeuds.yml.
source /vagrant/scripts/lib.sh
# On installe uniquement les paquets manquants, en un seul appel
apt_installer haproxy keepalived socat curl apache2-utils

SERVEURS=$(noeuds app | awk '{printf "    server %s %s:3000 maxconn 2 check\n", $1, $2}')

# Métriques Prometheus pour l'observabilité (extension E2), seulement si c'est possible
PROM=""
if extension_active e2; then
  if ! haproxy -vv 2>&1 | grep -i '+PROMEX' >/dev/null; then
    echo "ERREUR : exporteur Prometheus HAProxy absent." >&2
    exit 1
  fi

  PROM="
frontend metriques
    bind *:8405
    http-request use-service prometheus-exporter if { path /metrics }
    no log"
fi

# On écrit la configuration HAProxy dans un FICHIER TEMPORAIRE
NOUVEAU=$(mktemp)
cat > "$NOUVEAU" <<EOF
global
    log /dev/log local0
    maxconn 4096
    stats socket /run/haproxy/admin.sock mode 660 level admin
    user haproxy
    group haproxy

defaults
    mode http
    log global
    timeout connect 1s
    timeout client 30s
    timeout server 30s
    timeout check 1s
    timeout queue 15s
    retries 3
    option redispatch

frontend entree
    bind *:80
    default_backend app_be

backend app_be
    balance roundrobin
    option httpchk
    http-check send meth GET uri /sante
    http-check expect status 200
    default-server inter 1s fall 2 rise 2
$SERVEURS

listen stats
    bind *:8404
    stats enable
    stats uri /stats
$PROM
EOF
haproxy -c -q -f "$NOUVEAU"
if ecrire_si_change /etc/haproxy/haproxy.cfg 644 < "$NOUVEAU"; then
  systemctl enable haproxy >/dev/null 2>&1
  if systemctl is-active --quiet haproxy; then systemctl reload haproxy; else systemctl start haproxy; fi
fi
rm -f "$NOUVEAU"
systemctl enable --now haproxy >/dev/null 2>&1

# E1 : keepalived n'est configuré que s'il existe un second répartiteur
PAIR=$(noeuds lb | awk -v me="$MON_NOM" '$1!=me {print $2}')
if [ -n "$PAIR" ]; then
  # Le protocole VRRP limite le mot de passe à 8 caractères
  [ "${#VRRP_PASSWORD}" -le 8 ] || { echo "ERREUR : VRRP_PASSWORD > 8 caractères" >&2; exit 1; }
  IFACE=$(ip -o -4 addr show | awk -v ip="$MON_IP" 'index($4, ip"/")==1 {print $2}')
  if [ "$MON_NOM" = lb1 ]; then ETAT=MASTER; PRIO=110; else ETAT=BACKUP; PRIO=100; fi
  ecrire_si_change /etc/keepalived/keepalived.conf 600 <<EOF && systemctl restart keepalived || true
vrrp_script chk_haproxy {
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 1
    fall 2
    rise 2
    weight -20
}
vrrp_instance VI_1 {
    state $ETAT
    interface $IFACE
    virtual_router_id $((50 + GROUPE))
    priority $PRIO
    advert_int 1
    unicast_src_ip $MON_IP
    unicast_peer {
        $PAIR
    }
    authentication {
        auth_type PASS
        auth_pass $VRRP_PASSWORD
    }
    track_script {
        chk_haproxy
    }
    virtual_ipaddress {
        $RESEAU.5/24 dev $IFACE
    }
}
EOF
  systemctl enable --now keepalived >/dev/null 2>&1
fi

# Installer node_exporter (métriques machine) seulement si E2 est actif
node_exporter
echo "$MON_NOM : $(noeuds app | wc -l) serveur(s) applicatif(s) configuré(s)"
