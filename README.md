# tp_virtualisation_g11
RÉSULTATS-BF
Plateforme pédagogique de consultation de résultats, réalisée dans le cadre du cours de Virtualisation et cloud computing — Master 1, semestre 2, groupe 11.

Le projet déploie une architecture virtualisée avec Vagrant et VirtualBox. Il permet d'étudier la répartition de charge, la réplication PostgreSQL, les bascules de service, la reconstruction de l'environnement et la supervision.
Architecture
Machine	Rôle
bdd1	Base PostgreSQL initialement primaire
bdd2	Réplique PostgreSQL, pouvant devenir primaire après promotion
app1, app2	Serveurs applicatifs de la configuration à deux applications
app3, app4	Serveurs supplémentaires pour le passage à quatre applications
lb1, lb2	HAProxy pour la répartition et Keepalived pour l'adresse virtuelle
obs	Supervision avec Prometheus et Grafana


Une consultation passe par HAProxy, est traitée par une application et interroge PostgreSQL. L'adresse virtuelle permet de conserver la même adresse d'accès lors du transfert entre les répartiteurs.

bdd1 et bdd2 désignent les machines : leur nom ne garantit pas leur rôle après une bascule. Le rôle doit être vérifié par SQL.
Prérequis
- Git, Vagrant et VirtualBox installés sur le poste hôte.
- Virtualisation matérielle activée.
- Accès Internet pour le téléchargement de la box et des paquets au premier provisionnement.
- Mémoire et espace disque disponibles pour les VM choisies ; les ressources sont définies dans le Vagrantfile.
- Sous Windows : PowerShell et curl.exe pour les tests .ps1.
- ApacheBench (ab) accessible dans l'environnement où le script de charge l'exécute ; le V3 PowerShell utilise lb1.
Le projet a notamment été utilisé avec Windows 11, Vagrant 2.4.9, VirtualBox 7.2.6 et Ubuntu 24.04 dans les VM. Ces versions décrivent l'environnement employé, sans imposer une compatibilité avec toute autre combinaison.
Organisation des fichiers
Chemin	Contenu
Vagrantfile	Définition des VM, réseaux et provisionnements
app/	Application de consultation
config/	Inventaire et configuration de la plateforme
scripts/	Scripts shell de provisionnement et d'administration
tests/	Scripts des scénarios et des campagnes de mesures
tests/resultats/	Preuves brutes et mesures des exécutions, exclues de Git
docs/	Documentation et bilans du projet


Les paramètres utilisés comprennent config/plateforme.env, l'inventaire et config/primary.env. Examiner le Vagrantfile et les scripts avant de modifier leur contenu. Ne pas publier les mots de passe, les clés privées ou les fichiers de configuration contenant des secrets.
Récupération et démarrage
Cloner le dépôt, puis entrer dans le dossier qui contient le Vagrantfile :
git clone https://github.com/Abdoul738/tp_virtualisation_g11.git
Set-Location .\tp_virtualisation_g11
Vérifier la configuration locale requise par le dépôt et adapter les paramètres à son environnement. Ne pas écraser un fichier de configuration existant sans l'examiner.

Pour la configuration de référence à deux applications avec les extensions utilisées dans les essais, sous PowerShell :
$env:NB_APP = "2"
$env:EXTENSIONS = "e1,e2"

vagrant validate
vagrant up
vagrant status
Sous Bash, définir ces variables avant les commandes Vagrant :
export NB_APP=2
export EXTENSIONS=e1,e2
vagrant validate
vagrant up
vagrant status
Les variables d'environnement appartiennent au terminal courant. Les définir dans chaque nouvelle fenêtre utilisée pour administrer la même configuration.

Les VM saved sont suspendues : elles doivent être reprises avant les tests. Vérifier la disponibilité des bases, applications et répartiteurs avant de produire une charge.
Accès à la plateforme
Les essais du groupe utilisent le réseau privé 192.168.58.0/24. Les adresses ci-dessous correspondent à cette configuration ; vérifier les paramètres du dépôt si le groupe ou le réseau change.
Service	Adresse
Consultation par la VIP	http://192.168.58.5
Accès local au répartiteur depuis Windows	http://localhost:8080
Prometheus	http://192.168.58.41:9090
Grafana	http://192.168.58.41:3000


La VIP est 192.168.(55 + GROUPE).5 selon le calcul employé par les scripts de test. Le groupe de travail 11 utilise ici la valeur de configuration GROUPE=3, soit le sous-réseau 58.
Routes HTTP
Route	Fonction
/info	Identifier l'application qui répond
/sante	Vérifier l'état applicatif et, dans la version testée, la disponibilité de la base
/resultat?matricule=BF000001	Consulter un résultat métier


Exemples depuis Windows :
curl.exe -sS -i --max-time 10 "http://localhost:8080/info"
curl.exe -sS -i --max-time 10 "http://localhost:8080/sante"
curl.exe -sS -i --max-time 10 "http://localhost:8080/resultat?matricule=BF000001"
Un HTTP 200 sur /info ne valide pas à lui seul l'accès aux données. Effectuer aussi une consultation de résultat. Pendant une panne SQL, une réponse 503 peut provenir de l'application ou de HAProxy si aucun serveur n'est considéré disponible.
Commandes d'administration
Exécuter les commandes depuis le dossier contenant le Vagrantfile :
vagrant status
vagrant ssh app1
vagrant up app1
vagrant halt app1
vagrant provision lb1
Un git pull met à jour les fichiers du dépôt, mais n'applique pas automatiquement tous leurs changements aux services déjà démarrés. Identifier les composants concernés avant de provisionner ou redémarrer.
Scénarios de validation
Exécuter un seul scénario à la fois. Les scénarios de panne et de reconstruction changent l'état de la plateforme. Examiner le script avant de le lancer et conserver ses preuves.

Les commandes ci-dessous concernent les scripts PowerShell de tests/ :
Scénario	Commande	Objectif et effets
V1	.\tests\v1.ps1	Réaliser vingt appels à /info et examiner la répartition
V2	.\tests\v2.ps1	Arrêter app1 pendant les consultations ; elle peut rester arrêtée à la fin
V3	.\tests\v3.ps1	Comparer deux puis quatre applications avec 2 000 requêtes et 50 clients ; laisse quatre applications actives
V4	.\tests\v4.ps1	Arrêter bdd1, promouvoir bdd2 et vérifier la reprise ; conserver bdd1 arrêtée ensuite
V5	.\tests\v5.ps1	Détruire puis reconstruire l'environnement et mesurer les durées
V6	.\tests\v6.ps1	Couper automatiquement lb1, observer la prise de relais de lb2 et mesurer les événements


V5 détruit les VM concernées et leurs données locales. Sauvegarder les données utiles et vérifier que l'initialisation permet de reconstruire les données attendues avant de l'exécuter.
Préparer V4
L'état de référence attendu est bdd1 primaire, bdd2 réplique et une consultation métier fonctionnelle :
vagrant ssh bdd1 -c "sudo -u postgres psql -X -P pager=off -Atc 'SELECT pg_is_in_recovery();'"
vagrant ssh bdd2 -c "sudo -u postgres psql -X -P pager=off -Atc 'SELECT pg_is_in_recovery();'"
Résultats attendus : f sur le primaire et t sur la réplique. Après une promotion, ne pas simplement redémarrer l'ancien primaire pour rejouer le scénario : sa réintégration doit tenir compte du nouveau rôle des bases.

V4 distingue la durée de la commande de promotion et la procédure complète jusqu'aux contrôles. Désactiver le pager de psql pour éviter qu'un affichage interactif ne retarde la mesure.
Préparer V6
Les deux répartiteurs doivent fonctionner, les services HAProxy et Keepalived doivent être actifs, la VIP doit être uniquement sur lb1, et la consultation par cette VIP doit réussir.
vagrant status lb1 lb2
vagrant ssh lb1 -c "ip -br -4 address show eth1"
vagrant ssh lb2 -c "ip -br -4 address show eth1"
curl.exe -sS -i --max-time 10 "http://192.168.58.5/resultat?matricule=BF000001"
La version instrumentée de V6 coupe brutalement lb1 automatiquement après dix secondes et réalise environ cinq minutes de sondes. Ne pas lancer un second arrêt manuel. La préparation et les contrôles finaux s'ajoutent à cette durée. lb1 reste arrêtée à la fin.

Le script enregistre la coupure logicielle dans VirtualBox, le passage MASTER de Keepalived sur lb2, la présence finale de la VIP, les réponses HTTP et des comparaisons d'horloges.

Pour recalculer un essai déjà enregistré, sans action sur les VM :
.\tests\v6.ps1 -AnalyserDossier ".\tests\resultats\v6-20261025-233027-142"
Remplacer le dossier par celui de l'essai à analyser. Ce mode conserve le résumé original et écrit resume-v6-recalcule.json.

L'écart brut entre les événements compare deux horloges. Il doit être présenté avec les limites de synchronisation. La durée de vagrant halt n'est pas le temps de bascule ; une absence d'échec HTTP ne prouve pas une interruption de zéro seconde.
Scripts Python
Si tests/scenarios.py est utilisé :
python .\tests\scenarios.py v1
python .\tests\scenarios.py --help
Ce fichier n'est pas nécessairement équivalent aux scénarios PowerShell. Dans la version examinée, le V3 Python répétait des mesures sur la configuration actuelle, sans préparer automatiquement deux puis quatre applications. Vérifier également le nom du champ d'identification retourné par /info (serveur dans les réponses observées).
Campagnes de mesures
Les campagnes répètent la comparaison de capacité afin d'observer la variabilité des résultats :
.\tests\campagne-2-apps.ps1
.\tests\campagne-4-apps.ps1
Lire leurs paramètres et prérequis avant exécution. Ils peuvent modifier les VM actives et la configuration des répartiteurs. Prévoir les ressources pour les quatre applications.

Pour comparer les configurations, conserver la même consultation, la même charge, les mêmes réglages et le même code applicatif. Relever le débit, les erreurs, les percentiles de latence et les ressources disponibles. Vérifier la collecte Prometheus avant les essais.
Gain de débit (%) = (débit à 4 applications - débit à 2 applications)
                    / débit à 2 applications × 100
Le p95 est le temps sous lequel se situent 95 % des requêtes. Sa baisse est favorable lorsque la charge et la méthode sont comparables. Ne pas mélanger des séries réalisées avant et après une modification de l'application sans documenter cette différence.

Le générateur ApacheBench partage lb1 avec HAProxy dans les tests concernés ; cette concurrence de ressources limite l'interprétation des performances.
Preuves et résultats
Les scripts enregistrent leurs sorties dans des dossiers horodatés sous tests/resultats/. Selon le scénario, ils comprennent CSV, JSON, transcriptions et journaux. Lire le résumé et les erreurs avant de déclarer un test valide.

La règle Git suivante exclut ces preuves brutes :
/tests/resultats/
Les scripts et les synthèses documentaires peuvent être versionnés. Conserver séparément les archives de preuves nécessaires au rendu. Ne pas supprimer les essais précédents pour ne garder que les résultats favorables.
Travail sous Windows et Linux
Les membres travaillent dans des environnements Windows 11 et Linux. L'interpréteur doit correspondre au script :
Extension	Exécution
.ps1	PowerShell ; les scripts utilisant curl.exe, NUL ou VirtualBox pour Windows sont prévus pour Windows
.sh	Bash dans l'environnement prévu, notamment les VM Ubuntu
.py	Python, avec les dépendances éventuellement nécessaires


Ne pas renommer une extension pour changer de langage. Conserver des fins de ligne LF pour les scripts shell et documenter les chemins propres à chaque système.

Sous Windows, pour un script téléchargé et vérifié dont l'exécution est bloquée :
Unblock-File -LiteralPath .\tests\v6.ps1
Cette commande retire le marquage de téléchargement du fichier ; elle ne contourne pas une stratégie imposant la signature de tous les scripts.
Dépannage
Symptôme	Vérification
Vagrant ne trouve pas d'environnement	Se placer dans le dossier contenant le Vagrantfile
HTTP 503	Vérifier les bases, les applications, les contrôles HAProxy et la cible du primaire
Application active mais consultations en échec	Vérifier l'accès PostgreSQL ; l'état systemd ne suffit pas
Connexion SSH fermée pendant un arrêt	Contrôler l'état final avec vagrant status avant de conclure
V6 refuse lb1 non running	Démarrer lb1, puis vérifier la VIP avant un nouvel essai
Temps V6 absent	Consulter les journaux, les événements MASTER et les mesures d'horloge ; ne pas inventer de durée
Clés JSON Keepalived non reconnues	Vérifier les couleurs ANSI ; la version corrigée les désactive et les nettoie
Script SSH en dépassement de délai	Examiner les fichiers stdout/stderr et tester la commande directement ; ne pas répéter les pannes sans diagnostic


Documentation et livrables
Le rapport présente l'implémentation, les scénarios et les campagnes, avec leurs résultats et leurs limites. Le journal de bord L3, de une à deux pages, décrit la répartition réelle des rôles, les décisions justifiées et les difficultés rencontrées avec les solutions appliquées.

Les résultats évoluent avec les essais. Les preuves horodatées et les bilans associés sont les références pour les valeurs chiffrées ; le présent README décrit le fonctionnement et les procédures.