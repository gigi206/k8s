# Configuration pour l'environnement de développement
# 1 master all-in-one, pas de management node

# Configuration générale
$vm_box = "bento/ubuntu-24.04"
$box_check_update = true
$keymap = "fr"
$network_prefix = "192.168.121"
$api_server_ip = "192.168.121.200"  # IP du LoadBalancer pour l'API Kubernetes
$cluster_name = "dev"

# Management node (désactivé pour dev)
$management = false
$management_cpu = 4
$management_memory = 8192
$management_disk = 20

# Configuration master (all-in-one pour dev)
$masters = 1
$master_cpu = 16
$master_memory = 32768
$master_disk = 64

# Workers (désactivés pour dev - all-in-one)
$workers = 0
$worker_cpu = 8
$worker_memory = 8192
$worker_disk = 64

# Disque de stockage supplémentaire (pour Longhorn)
$storage_disk_enabled = true
$storage_disk_size = "50G"
