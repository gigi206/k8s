# Configuration pour l'environnement de production
# 3 masters + 3 workers

# Configuration générale
$vm_box = "bento/ubuntu-24.04"
$box_check_update = true
$keymap = "fr"
$network_prefix = "192.168.121"
$api_server_ip = "192.168.121.200"  # IP du LoadBalancer pour l'API Kubernetes
$cluster_name = "prod"

# Management node (optionnel)
$management = false
$management_cpu = 4
$management_memory = 8192
$management_disk = 20

# Configuration masters
$masters = 3
$master_cpu = 8
$master_memory = 16384
$master_disk = 50

# Configuration workers
$workers = 3
$worker_cpu = 8
$worker_memory = 16384
$worker_disk = 100
