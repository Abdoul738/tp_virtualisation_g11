"""RÉSULTATS-BF : service SANS ÉTAT, configuré par l'environnement (R7)."""
import json, os, re, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from queue import Queue, Empty
import psycopg2

E = os.environ.get  # tous les paramètres viennent de l'environnement, rien en dur
DB = {"host": E("DB_HOST", "127.0.0.1"), "port": int(E("DB_PORT", "5432")),
      "dbname": E("DB_NAME", "resultats"), "user": E("DB_USER", "app_user"),
      "password": E("DB_PASSWORD", ""),
      "connect_timeout": 2,                    # abandonne vite si la base est absente
      "options": "-c statement_timeout=2000"}  # aucune requête de plus de 2 s
PORT, FICHIER_PRIMAIRE = int(E("APP_PORT", "3000")), E("DB_PRIMAIRE_FICHIER", "")
HOTE, MATRICULE_OK = socket.gethostname(), re.compile(r"^[A-Za-z0-9-]{1,20}$")
COLONNES = ("matricule", "nom", "serie", "moyenne", "admis")
BASE_KO = (psycopg2.Error, Empty)  # base absente, bascule en cours, pool saturé

def hote_primaire():
    """Base PRIMAIRE relue à chaque requête (écrite par ops/bascule.sh)."""
    try:
        with open(FICHIER_PRIMAIRE) as fichier:
            lignes = [l for l in fichier if l.startswith("PRIMARY_IP=")]
        return lignes[0].split("=", 1)[1].strip() if lignes else DB["host"]
    except OSError:  # pas de fichier : on garde DB_HOST
        return DB["host"]

POOL = Queue()  # 4 connexions réutilisées (performance, V3) : aucune donnée d'usager
for _ in range(4): POOL.put(None)

def interroger(sql, params=()):
    """Emprunte une connexion du pool, neuve si la primaire a changé (bascule)."""
    entree = POOL.get(timeout=0.5)  # Empty si les 4 sont occupées depuis 0,5 s
    hote = hote_primaire()
    connexion = entree[1] if entree and entree[0] == hote else None
    try:
        if connexion is None or connexion.closed:
            if entree: entree[1].close()
            connexion = psycopg2.connect(**(DB | {"host": hote}))
            connexion.set_session(readonly=True, autocommit=True)
        with connexion.cursor() as curseur:
            curseur.execute(sql, params)
            return curseur.fetchone()
    except Exception:  # connexion douteuse : on la jette, la suivante sera neuve
        if connexion is not None: connexion.close()
        connexion = None
        raise
    finally:  # toujours rendre la place au pool, même en cas d'erreur
        POOL.put((hote, connexion) if connexion is not None else None)

class Gestionnaire(BaseHTTPRequestHandler):
    def repondre(self, code, contenu):  # toujours du JSON : jamais de page blanche
        corps = json.dumps(contenu, ensure_ascii=False, default=float).encode()
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
        except (BrokenPipeError, ConnectionResetError): pass  # le client est parti
        except Exception as erreur:  # filet de sécurité : jamais de réponse vide
            self.repondre(500, {"erreur": "erreur interne", "detail": str(erreur)})

    def sante(self):  # 200 SEULEMENT si la base répond vraiment, 503 sinon
        try:
            interroger("SELECT 1")
            self.repondre(200, {"etat": "ok", "serveur": HOTE})
        except BASE_KO:
            self.repondre(503, {"etat": "base indisponible", "serveur": HOTE})

    def resultat(self, matricule):
        if not MATRICULE_OK.match(matricule):
            return self.repondre(400, {"erreur": "matricule absent ou invalide"})
        try:
            ligne = interroger("SELECT matricule, nom, serie, moyenne, admis "
                               "FROM resultats WHERE matricule = %s", (matricule,))
        except BASE_KO as erreur:
            self.log_message("PostgreSQL : %s",  # sans jamais écrire le mot de passe
                             str(erreur).replace(DB["password"] or "\0", "[masque]"))
            return self.repondre(503, {"erreur": "service momentanément indisponible"})
        if ligne is None:
            return self.repondre(404, {"erreur": "matricule introuvable"})
        self.repondre(200, dict(zip(COLONNES, ligne)) | {"serveur": HOTE})

if __name__ == "__main__":  # 0.0.0.0 et pas 127.0.0.1 : sinon lb1 ne nous joint pas
    serveur = ThreadingHTTPServer(("0.0.0.0", PORT), Gestionnaire)
    print(f"RESULTATS-BF : {HOTE} écoute sur 0.0.0.0:{PORT}", flush=True)
    serveur.serve_forever()
