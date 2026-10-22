import json

SOURCE = {
    "type": "prometheus",
    "uid": "resultats-prometheus",
}

mesures = [
    (
        "Collecte : 1 = accessible, 0 = echec",
        "up",
        "{{job}} / {{noeud}}",
        "short",
    ),
    (
        "CPU utilise (%)",
        '100 * (1 - avg by (noeud) '
        '(rate(node_cpu_seconds_total'
        '{job="systeme",mode="idle"}[1m])))',
        "{{noeud}}",
        "percent",
    ),
    (
        "Memoire utilisee (%)",
        '100 * (1 - node_memory_MemAvailable_bytes{job="systeme"} '
        '/ node_memory_MemTotal_bytes{job="systeme"})',
        "{{noeud}}",
        "percent",
    ),
    (
        "Reseau : reception par VM",
        'sum by (noeud) '
        '(rate(node_network_receive_bytes_total'
        '{job="systeme",device!="lo"}[1m]))',
        "{{noeud}}",
        "Bps",
    ),
    (
        "Charge systeme sur une minute",
        'node_load1{job="systeme"}',
        "{{noeud}}",
        "short",
    ),
    (
        "HAProxy : connexions courantes du processus",
        'haproxy_process_current_connections{job="haproxy"}',
        "{{noeud}}",
        "short",
    ),
]

mesures.extend([
    (
        "Applications disponibles : 1 = UP, 0 = autre etat",
        'haproxy_server_status'
        '{job="haproxy",proxy="app_be",state="UP"}',
        "{{noeud}} / {{server}}",
        "short",
    ),
    (
        "Debit HTTP entrant (requetes/s)",
        'sum by (noeud) '
        '(rate(haproxy_frontend_http_requests_total'
        '{job="haproxy",proxy="entree"}[1m]))',
        "{{noeud}}",
        "reqps",
    ),
    (
        "Reponses HTTP 5xx (reponses/s)",
        'sum by (noeud) '
        '(rate(haproxy_frontend_http_responses_total'
        '{job="haproxy",proxy="entree",code="5xx"}[1m]))',
        "{{noeud}}",
        "reqps",
    ),
    (
        "Requetes en attente dans le backend",
        'haproxy_backend_current_queue'
        '{job="haproxy",proxy="app_be"}',
        "{{noeud}}",
        "short",
    ),
    (
        "Temps total moyen des 1024 dernieres connexions reussies",
        'haproxy_backend_total_time_average_seconds'
        '{job="haproxy",proxy="app_be"}',
        "{{noeud}}",
        "s",
    ),
])

panneaux = []

for numero, (titre, requete, legende, unite) in enumerate(mesures):
    panneaux.append({
        "id": numero + 1,
        "title": titre,
        "type": "timeseries",
        "datasource": SOURCE,
        "gridPos": {
            "x": (numero % 2) * 12,
            "y": (numero // 2) * 8,
            "w": 12,
            "h": 8,
        },
        "targets": [{
            "refId": "A",
            "datasource": SOURCE,
            "expr": requete,
            "legendFormat": legende,
            "range": True,
        }],
        "fieldConfig": {
            "defaults": {"unit": unite, "min": 0},
            "overrides": [],
        },
        "options": {
            "legend": {
                "displayMode": "list",
                "placement": "bottom",
            },
            "tooltip": {"mode": "multi"},
        },
    })

tableau = {
    "uid": "resultats-bf",
    "title": "RESULTATS-BF - Supervision",
    "schemaVersion": 39,
    "version": 1,
    "editable": False,
    "tags": ["RESULTATS-BF", "E2"],
    "timezone": "utc",
    "refresh": "30s",
    "time": {"from": "now-15m", "to": "now"},
    "panels": panneaux,
}

print(json.dumps(tableau, ensure_ascii=True, indent=2))