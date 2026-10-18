# Service applicatif — Membre 2

Fichier : `app/app.py` (Python 3, moins de 100 lignes, sans état).

## Ce qu'il fait

| Adresse | Réponse |
|---|---|
| `GET /resultat?matricule=...` | 200 + JSON du candidat, 404 si introuvable, 400 si matricule invalide, 503 si la base ne répond pas |
| `GET /sante` | 200 seulement si la base répond à `SELECT 1`, sinon 503 |
| `GET /info` | 200 + nom d'hôte du serveur (`{"serveur": "app1"}`) |

Toutes les réponses sont en JSON, y compris les erreurs (jamais de page blanche).

## Ce dont il a besoin pour fonctionner

**1. Écoute** : `0.0.0.0`, port `3000` (modifiable avec `APP_PORT`).

**2. Paquet** : `python3-psycopg2` (installé par `scripts/app.sh`).

**3. Une base PostgreSQL avec une table `resultats`** contenant au minimum
ces colonnes : `matricule`, `nom`, `serie`, `moyenne`, `admis`.

**4. Variables d'environnement** (aucune n'est écrite dans le code) :

| Variable | Valeur par défaut | Rôle |
|---|---|---|
| `DB_HOST` | `127.0.0.1` | Adresse de la base primaire (ex. `192.168.58.31`) |
| `DB_PORT` | `5432` | Port PostgreSQL |
| `DB_NAME` | `resultats` | Nom de la base |
| `DB_USER` | `app_user` | Utilisateur de la base (lecture seule suffit) |
| `DB_PASSWORD` | *(vide)* | Mot de passe, vient du fichier `.env` |
| `APP_PORT` | `3000` | Port d'écoute de l'application |

**Si l'équipe a choisi d'autres noms** (de base, d'utilisateur…), il n'y a
**rien à changer dans `app.py`** : il suffit de donner les bonnes valeurs à
ces variables.

## Comportement en cas de panne

- Une connexion neuve est ouverte à chaque requête, puis refermée : rien
  n'est gardé en mémoire.
- Base absente au démarrage ou pendant une bascule : l'application démarre
  quand même, répond 503, puis repasse à 200 toute seule dès que la base
  revient. Aucun redémarrage nécessaire.
- Délai maximal d'attente de la base : 2 secondes. Le répartiteur peut donc
  écarter un serveur malade en moins de 5 secondes (R4).

## Tester à la main

```bash
DB_HOST=192.168.58.31 DB_PASSWORD=... python3 app/app.py
curl http://localhost:3000/sante
curl "http://localhost:3000/resultat?matricule=BF000001"
```
