# Configuration pour l'environnement de staging
# 3 masters sans workers (master + worker sur les mêmes nœuds)

# Configuration générale
$vm_box = "bento/ubuntu-24.04"
$box_check_update = true
$keymap = "fr"
$network_prefix = "192.168.121"
$api_server_ip = "192.168.121.200"  # IP du LoadBalancer pour l'API Kubernetes
$cluster_name = "staging"

# Management node (désactivé pour staging)
$management = false
$management_cpu = 4
$management_memory = 8192
$management_disk = 20

# Configuration masters (fonctionnent aussi comme workers)
$masters = 3
$master_cpu = 8
$master_memory = 16384
$master_disk = 64

# Workers (désactivés - les masters jouent ce rôle)
$workers = 0
$worker_cpu = 8
$worker_memory = 8192
$worker_disk = 64

# Disque de stockage supplémentaire (pour Longhorn)
# Désactivé car pas de workers en staging
$storage_disk_enabled = false
$storage_disk_size = "50G"
