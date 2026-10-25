# -*- mode: ruby -*-
# vi: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.

# =============================================================================
require 'yaml'        # pour écrire la table NOEUDS au format YAML
require 'fileutils'   # pour créer le dossier config/ s'il n'existe pas

# Fonction de lecture de la configuration du fichier .env
def charger_env(chemin)
  return {} unless File.exist?(chemin)          # pas de .env : dictionnaire vide
  File.readlines(chemin).each_with_object({}) do |l, h|
    l = l.strip                                  # retire espaces et fin de ligne
    next if l.empty? || l.start_with?('#')       # ignore lignes vides et commentaires
    k, v = l.split('=', 2)                       # coupe au PREMIER '=' seulement
    h[k.strip] = v.to_s.strip.gsub(/\A["']|["']\z/, '')  # retire les guillemets éventuels
  end
end
 
# On charge le contenu du fichier .env.
DOTENV = charger_env(File.join(__dir__, '.env'))
 
# Fonction qui retourne la valeur d'un paramètre, par ordre de priorité :
def cfg(cle, defaut)
  ENV[cle] || DOTENV[cle] || defaut
end

# Paramètres de la plateforme
GROUPE     = cfg('GROUPE', '3').to_i
NB_APP     = cfg('NB_APP', '2').to_i
EXTENSIONS = cfg('EXTENSIONS', '').downcase.split(',').map(&:strip)
 
# Garde-fous de sécurité : la plage 192.168.56.0/21 est la seule autorisée par VirtualBox.
abort "GROUPE doit valoir de 1 à 8 (plage VirtualBox 192.168.56.0/21)" unless (1..8).cover?(GROUPE)
# Les serveurs applicatifs occupent .21 à .29 ; .31 et .32 sont pris par les bases.
abort "NB_APP doit valoir de 2 à 9 (adresses .21 à .29)" unless (2..9).cover?(NB_APP)
 
# Sous-réseau du groupe : 192.168.(55 + G).0/24  ->  groupe 1 = 192.168.56.x
RESEAU = "192.168.#{55 + GROUPE}"
BOITE   = "bento/ubuntu-24.04"
VERSION = '202510.26.0'
 
# Table NOEUDS : Chaque entrée = une machine (nom, adresse IP, mémoire en Mo, rôle)
NOEUDS = []
 


# Bases de données (primaire + réplique) et serveurs applicatifs (NB_APP, .21 à .29)
NOEUDS << { "nom" => "bdd1", "ip" => "#{RESEAU}.31", "mem" => 768, "role" => "bdd" }
NOEUDS << { "nom" => "bdd2", "ip" => "#{RESEAU}.32", "mem" => 768, "role" => "replique" }
(1..NB_APP).each do |i|
  NOEUDS << { "nom" => "app#{i}", "ip" => "#{RESEAU}.#{20 + i}", "mem" => 512, "role" => "app" }
end

# Répartiteur de charge actif (HAProxy), passif et supervision (Prometheus + Grafana)
NOEUDS << { "nom" => "lb1", "ip" => "#{RESEAU}.11", "mem" => 512, "role" => "lb" }
NOEUDS << { "nom" => "lb2", "ip" => "#{RESEAU}.12", "mem" => 512, "role" => "lb" } if EXTENSIONS.include?('e1')

# E2 : supervision Prometheus et Grafana.
if EXTENSIONS.include?('e2')
  NOEUDS << {
    "nom" => "obs",
    "ip" => "#{RESEAU}.41",
    "mem" => 768,
    "role" => "obs"
  }
end

# binwrite (et non write) : sous Windows, write ajouterait des fins de ligne CRLF
# que les scripts Linux ne savent pas lire (piège n°5 du sujet).
# Fichiers engendrés et réécrits à chaque exécution de vagrant et lus par les scripts dans les VM, via le dossier partagé /vagrant/config/.
FileUtils.mkdir_p(File.join(__dir__, "config"))
# La table NOEUDS au format YAML : liste des machines, adresses, rôles
File.binwrite(File.join(__dir__, "config", "noeuds.yml"), NOEUDS.to_yaml)
# Les paramètres utiles aux scripts (ceux qui ne sont pas des secrets)
File.binwrite(File.join(__dir__, "config", "plateforme.env"), "GROUPE=#{GROUPE}\nNB_APP=#{NB_APP}\nEXTENSIONS=#{EXTENSIONS.join(',')}\n")
 
# Association rôle -> script de provisionnement
SCRIPTS = { 
  "bdd" => "bdd.sh", 
  "replique" => "replique.sh", 
  "app" => "app.sh",
  "lb" => "lb.sh", 
  "obs" => "obs.sh" 
}
# Rôles dont le script est rejoué à CHAQUE démarrage (run: "always") : leur configuration dépend de NOEUDS, donc doit suivre si NB_APP change.
TOUJOURS = %w[lb obs] # lb et obs ont donc des scripts strictement idempotents.

# Définition des machines virtuelles
Vagrant.configure("2") do |config|
  config.vm.box = BOITE
  config.vm.box_version = VERSION     # version épinglée (reproductibilité)
  config.vm.box_check_update = false  # pas de vérification de mise à jour (connexion lente)
  config.vm.boot_timeout = 600        # 10 minutes max pour le démarrage d'une VM
 
  # Une VM par entrée de la table NOEUDS.
  NOEUDS.each do |n|
    config.vm.define n["nom"] do |m|
      m.vm.hostname = n["nom"]                              # nom d'hôte (renvoyé par /info)
      m.vm.network "private_network", ip: n["ip"]           # réseau privé hôte-seul (R8)
 
      # Seul le répartiteur expose un port vers l'hôte : lb1 -> localhost:8080, lb2 -> localhost:8081.
      # host_ip 127.0.0.1 : accessible seulement depuis le poste.
      # auto_correct: false : si le port est pris, on échoue clairement au lieu de choisir un autre port sans prévenir.
      if n["role"] == "lb"
        port_hote = n["nom"] == "lb1" ? 8080 : 8081
        m.vm.network "forwarded_port", guest: 80, host: port_hote,
                     host_ip: "127.0.0.1", auto_correct: false
      end
 
      # Ressources VirtualBox de la VM
      m.vm.provider "virtualbox" do |vb|
        vb.name = "tp_virtual-g#{GROUPE}-#{n['nom']}"  # nom lisible dans VirtualBox
        vb.memory = n["mem"]                            # mémoire en Mo (depuis la table)
        vb.cpus = 1                                     # un seul processeur par VM
        vb.linked_clone = true                          # clone lié : plus rapide, moins de disque
      end
 
      # Provisionnement : exécute le script correspondant au rôle de la machine.
      # run "always" pour lb et obs, run "once" pour les autres.
      m.vm.provision "shell", name: n["role"], path: "scripts/#{SCRIPTS[n['role']]}",
                     run: (TOUJOURS.include?(n["role"]) ? "always" : "once")
    end
  end
end
