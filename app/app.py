#!/usr/bin/env python3
"""RÉSULTATS-BF : service SANS ÉTAT, configuré par l'environnement (R7)."""
import json, os, re, socket
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import psycopg2

DB = {  # paramètres lus dans l'environnement, jamais écrits en dur
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": os.environ.get("DB_NAME", "resultats"),
    "user": os.environ.get("DB_USER", "app_user"),
    "password": os.environ.get("DB_PASSWORD", ""),
    "connect_timeout": 2,                    # abandonne vite si la base est absente
    "options": "-c statement_timeout=2000",  # aucune requête de plus de 2 s
}
PORT = int(os.environ.get("APP_PORT", "3000"))
FICHIER_PRIMAIRE = os.environ.get("DB_PRIMAIRE_FICHIER", "")
HOTE = socket.gethostname()
MATRICULE_OK = re.compile(r"^[A-Za-z0-9-]{1,20}$")
COLONNES = ("matricule", "nom", "serie", "moyenne", "admis")

def hote_primaire():
    """Base PRIMAIRE relue à chaque requête dans le fichier réécrit par
    ops/bascule.sh : l'application suit une bascule sans redémarrer."""
    try:
        with open(FICHIER_PRIMAIRE) as fichier:
            lignes = [l for l in fichier if l.startswith("PRIMARY_IP=")]
        return lignes[0].split("=", 1)[1].strip() if lignes else DB["host"]
    except OSError:  # pas de fichier : on garde DB_HOST
        return DB["host"]

def interroger(sql, params=()):
    """Connexion NEUVE à chaque appel, refermée ensuite : rien n'est gardé."""
    connexion = psycopg2.connect(**(DB | {"host": hote_primaire()}))
    try:
        with connexion.cursor() as curseur:
            curseur.execute(sql, params)
            return curseur.fetchone()
    finally:
        connexion.close()

def en_json(valeur):  # la moyenne arrive en Decimal, inconnu du module json
    return float(valeur) if isinstance(valeur, Decimal) else str(valeur)

class Gestionnaire(BaseHTTPRequestHandler):
    def repondre(self, code, contenu):
        """Toutes les réponses sont du JSON : jamais de page blanche."""
        corps = json.dumps(contenu, ensure_ascii=False, default=en_json).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        url = urlparse(self.path)
        try:
            if url.path == "/info":
                self.repondre(200, {"serveur": HOTE})
            elif url.path == "/sante":
                self.sante()
            elif url.path == "/resultat":
                self.resultat(parse_qs(url.query).get("matricule", [""])[0].strip())
            else:
                self.repondre(404, {"erreur": "adresse inconnue"})
        except Exception as erreur:  # filet de sécurité : jamais de réponse vide
            self.repondre(500, {"erreur": "erreur interne", "detail": str(erreur)})

    def sante(self):
        """200 SEULEMENT si la base répond vraiment ; 503 sinon."""
        try:
            interroger("SELECT 1")
            self.repondre(200, {"etat": "ok", "serveur": HOTE})
        except psycopg2.Error:
            self.repondre(503, {"etat": "base indisponible", "serveur": HOTE})

    def resultat(self, matricule):
        if not MATRICULE_OK.match(matricule):
            self.repondre(400, {"erreur": "matricule absent ou invalide"})
            return
        try:
            ligne = interroger(
                "SELECT matricule, nom, serie, moyenne, admis "
                "FROM resultats WHERE matricule = %s", (matricule,))
        except psycopg2.Error:       # base absente, bascule en cours...
            self.repondre(503, {"erreur": "service momentanément indisponible"})
            return
        if ligne is None:
            self.repondre(404, {"erreur": "matricule introuvable"})
        else:
            self.repondre(200, dict(zip(COLONNES, ligne)) | {"serveur": HOTE})

if __name__ == "__main__":
    ThreadingHTTPServer.daemon_threads = True
    serveur = ThreadingHTTPServer(("0.0.0.0", PORT), Gestionnaire)  # pas 127.0.0.1 !
    print(f"RESULTATS-BF : {HOTE} écoute sur 0.0.0.0:{PORT}", flush=True)
    serveur.serve_forever()
