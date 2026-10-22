import csv
import io
import json
import re
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, build_opener

DUREE = 240
CLIENTS = 10
URL = "http://127.0.0.1/resultat?matricule=BF000001"
SOCKET_HA = "/run/haproxy/admin.sock"

# Lecture du format YAML engendre par le Vagrantfile du projet.
inventaire = Path("/vagrant/config/noeuds.yml").read_text()
adresse = re.search(
    r"(?m)^- nom: app1\r?\n  ip: ([0-9.]+)", inventaire
)
if adresse is None:
    raise SystemExit("Adresse de app1 introuvable dans noeuds.yml")
APP1_IP = adresse.group(1)

def utc():
    return datetime.now(timezone.utc).isoformat()

def etat_haproxy():
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as canal:
        canal.settimeout(1)
        canal.connect(SOCKET_HA)
        canal.sendall(b"show stat\n")
        morceaux = []
        while True:
            bloc = canal.recv(65536)
            if not bloc:
                break
            morceaux.append(bloc)
    texte = b"".join(morceaux).decode().lstrip("# ")
    for ligne in csv.DictReader(io.StringIO(texte)):
        if ligne["pxname"] == "app_be" and ligne["svname"] == "app1":
            return ligne["status"]
    raise RuntimeError("app1 absente des statistiques HAProxy")

if not etat_haproxy().startswith("UP"):
    raise SystemExit("app1 doit etre UP avant le test")
with socket.create_connection((APP1_IP, 3000), timeout=2):
    pass

dossier = Path("/vagrant/tests/resultats") / (
    "v2-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
)
dossier.mkdir(parents=True)

verrou = threading.Lock()
arret = threading.Event()
compteurs = {"requetes": 0, "echecs": 0}
origine = time.monotonic()
limite = origine + DUREE

def client(numero, fichier):
    navigateur = build_opener(ProxyHandler({}))
    while time.monotonic() < limite:
        debut_utc = utc()
        debut = time.monotonic()
        code, serveur, erreur = 0, "", ""
        try:
            with navigateur.open(URL, timeout=5) as reponse:
                code = reponse.status
                contenu = json.load(reponse)
            serveur = contenu.get("serveur", "")
            if contenu.get("matricule") != "BF000001":
                erreur = "Contenu inattendu"
        except HTTPError as exception:
            code = exception.code
            erreur = exception.read().decode(errors="replace")[:300]
        except Exception as exception:
            erreur = str(exception)[:300]
        fin = time.monotonic()
        with verrou:
            fichier.writerow([
                debut_utc, utc(), numero,
                round(debut - origine, 4),
                round(fin - origine, 4),
                code, serveur, erreur
            ])
            compteurs["requetes"] += 1
            compteurs["echecs"] += int(code != 200 or bool(erreur))

def surveiller():
    with (dossier / "surveillance.csv").open("w", newline="") as sortie:
        fichier = csv.writer(sortie)
        fichier.writerow([
            "debut_utc", "fin_utc", "debut_s", "fin_s",
            "tcp_app1", "etat_haproxy", "erreur"
        ])
        while not arret.is_set():
            debut_utc = utc()
            debut = time.monotonic()
            erreurs = []
            try:
                with socket.create_connection((APP1_IP, 3000), timeout=0.3):
                    pass
                tcp = "accessible"
            except OSError:
                tcp = "indisponible"
            try:
                etat = etat_haproxy()
            except Exception as exception:
                etat = "INCONNU"
                erreurs.append(str(exception))
            fichier.writerow([
                debut_utc, utc(),
                round(debut - origine, 4),
                round(time.monotonic() - origine, 4),
                tcp, etat, " | ".join(erreurs)
            ])
            sortie.flush()
            arret.wait(0.2)

with (dossier / "requetes.csv").open("w", newline="") as sortie:
    fichier = csv.writer(sortie)
    fichier.writerow([
        "debut_utc", "fin_utc", "client", "debut_s", "fin_s",
        "http", "serveur", "erreur"
    ])
    surveillance = threading.Thread(target=surveiller)
    surveillance.start()
    print("CHARGE DEMARREE : arrete maintenant app1 dans le second terminal.",
          flush=True)
    print("Dossier : " + str(dossier), flush=True)
    try:
        with ThreadPoolExecutor(max_workers=CLIENTS) as executeur:
            taches = [
                executeur.submit(client, numero, fichier)
                for numero in range(1, CLIENTS + 1)
            ]
            (dossier / "charge-prete.txt").write_text(utc())
            for tache in taches:
                tache.result()
    finally:
        arret.set()
        surveillance.join()

resume = {
    "duree_secondes": round(time.monotonic() - origine, 3),
    "clients": CLIENTS,
    **compteurs,
}
(dossier / "resume.json").write_text(json.dumps(resume, indent=2))
print(json.dumps(resume, indent=2))
print("Preuves : " + str(dossier))