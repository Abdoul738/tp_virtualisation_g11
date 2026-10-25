# Exploitation de la base de données — membre 3

Scripts à lancer **depuis la racine du dépôt, sur l'hôte** (Git Bash, ou PowerShell avec
`& "C:\Program Files\Git\bin\bash.exe" ops/<script>.sh`).

| Script | Exigence | Rôle |
|---|---|---|
| `ops/verifier_replication.sh` | R5 | Écrit une ligne sur le primaire, mesure le délai avant qu'elle soit visible sur la réplique, puis la supprime |
| `ops/bascule.sh` | R6, V4 | Fait de la réplique le nouveau primaire, en isolant l'ancien ; chronomètre chaque étape |
| `ops/reintegrer_bdd1.sh` | R6 | Remet l'ancien primaire en réplique du nouveau (`pg_rewind`, ou copie complète si impossible) |

Les trois scripts lisent le primaire courant dans `config/primary.env` : ils fonctionnent
dans les deux sens (bdd1 → bdd2, puis bdd2 → bdd1).

## Principe

- **Même configuration sur bdd1 et bdd2** (`scripts/pg.sh`, fonction `pg_configurer`) :
  seul le rôle diffère. N'importe quel nœud peut donc être promu, puis réintégré.
- **Le rôle est lu dans l'état réel de PostgreSQL** (`pg_is_in_recovery()`), jamais dans
  un fichier marqueur. Un ancien marqueur était copié par `pg_basebackup` : il n'était pas fiable.
- **Réplication en flux asynchrone** avec un slot par réplique (`resultats_bf_bdd1`,
  `resultats_bf_bdd2`). `max_slot_wal_keep_size = 1GB` empêche une réplique arrêtée de
  remplir le disque du primaire.
- **Mesure R5** : une session ouverte sur la réplique *avant* l'écriture y guette la ligne
  toutes les 10 ms. Le délai affiché exclut donc l'ouverture de connexion.
- **Mot de passe de réplication** dans `/var/lib/postgresql/.pgpass` (droits 600, dans la VM).
  Il n'apparaît ni dans le dépôt, ni dans la configuration de PostgreSQL (R7).

## Procédure de bascule (V4)

```bash
vagrant halt bdd1            # la panne (jouée par l'examinateur)
bash ops/bascule.sh          # bdd2 devient primaire
bash ops/reintegrer_bdd1.sh  # bdd1 redevient réplique de bdd2
bash ops/verifier_replication.sh
```

Pour revenir à la situation initiale, relancer `ops/bascule.sh` puis `ops/reintegrer_bdd1.sh`.

## Protection contre le split-brain

Un split-brain, c'est deux primaires en même temps : les écritures divergent et une partie
est perdue à la réconciliation.

| Protection | Où |
|---|---|
| L'ancien primaire est isolé avant toute promotion : PostgreSQL est arrêté et `start.conf` passe à `manual`, donc il ne redémarre pas seul au prochain démarrage de la VM | `pg.sh isoler`, appelé par `bascule.sh` |
| La promotion est refusée tant que la VM de l'ancien primaire tourne | `bascule.sh` |
| Si un ancien primaire est rallumé et reprovisionné avant sa réintégration, `bdd.sh` refuse d'en faire un second primaire et l'isole | `bdd.sh` |
| Après une panne brute (`vagrant halt bdd1` sans isolation), bdd1 redémarre en primaire à son démarrage. La réintégration l'isole immédiatement, puis `pg_rewind` **écarte** les écritures faites pendant ce laps de temps | `reintegrer_bdd1.sh` |

## Limites connues

- **Réplication asynchrone** : le primaire confirme une écriture sans attendre la réplique.
  Les dernières écritures (quelques millisecondes) peuvent être perdues si le primaire tombe.
  Un mode synchrone (`synchronous_standby_names`) supprimerait cette perte, mais bloquerait
  les écritures quand la réplique est arrêtée : avec deux nœuds, c'est un mauvais compromis.
- **Bascule manuelle** : rien ne la déclenche automatiquement (pas de Patroni ni de repmgr).
- Les applications trouvent le primaire dans `config/primary.env`, sur le dossier partagé `/vagrant`.
