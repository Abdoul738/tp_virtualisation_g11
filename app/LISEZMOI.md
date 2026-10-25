# Service applicatif — Membre 2

Fichier : `app/app.py` (Python 3, moins de 100 lignes comme l'exige le sujet, sans état).

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

**Passage à l'échelle (R3)** : `./ops/scale.sh 4` (Git Bash, à la racine) change
`NB_APP` dans `.env`, crée les machines, régénère lb1 et vérifie la répartition.

**3. Une base PostgreSQL avec une table `resultats`** contenant au minimum
ces colonnes : `matricule`, `nom`, `serie`, `moyenne`, `admis`.

**4. Installation** : `scripts/app.sh`, lancé par Vagrant sur chaque appN.
Il utilise `scripts/lib.sh` (commun au groupe) et lit dans `.env` :
`PG_DB`, `PG_APP_USER`, `PG_APP_PASSWORD` (les mêmes noms que `scripts/bdd.sh`).

Il écrit dans la VM le fichier `/etc/resultats-bf/app.env` (droits 600) :

| Variable lue par app.py | Valeur donnée par app.sh |
|---|---|
| `DB_HOST` | adresse de bdd1, lue dans `config/noeuds.yml` |
| `DB_PRIMAIRE_FICHIER` | `/vagrant/config/primary.env` (écrit par `ops/bascule.sh`) |
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` | `PG_DB` / `PG_APP_USER` / `PG_APP_PASSWORD` |
| `APP_PORT` | `3000` |

Aucune adresse ni aucun mot de passe n'est écrit dans `app.py` ou `app.sh`.

## Comportement en cas de panne

- Aucune donnée d'usager n'est gardée en mémoire (service **sans état**) :
  n'importe quel serveur peut répondre à n'importe quelle requête.
- Les connexions à la base sont **réutilisées** (4 au maximum par serveur,
  « pool ») : sur un poste de test, environ 1 100 requêtes/s au lieu de 140 avec une connexion
  neuve à chaque fois. Une connexion cassée est jetée et remplacée.
- À chaque requête, l'adresse de la base **primaire** est relue dans
  `config/primary.env`. Après `ops/bascule.sh`, les applications utilisent
  bdd2 **sans redémarrage** (si le fichier est absent : `DB_HOST`).
- Base absente au démarrage ou pendant une bascule : l'application démarre
  quand même, répond 503, puis repasse à 200 toute seule dès que la base
  revient. Aucun redémarrage nécessaire.
- Délai maximal d'attente de la base : 2 secondes. Le répartiteur peut donc
  écarter un serveur malade en moins de 5 secondes (R4).

## Tester à la main

```bash
DB_HOST=192.168.58.31 DB_USER=... DB_PASSWORD=... python3 app/app.py
curl http://localhost:3000/sante
curl "http://localhost:3000/resultat?matricule=BF000001"
```
