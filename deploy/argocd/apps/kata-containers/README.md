# Kata Containers

Kata Containers fournit une isolation hardware pour les conteneurs via des micro-VMs légères. Chaque pod Kata s'exécute dans sa propre machine virtuelle avec un kernel dédié, offrant une isolation similaire aux VMs traditionnelles tout en conservant la vitesse et la simplicité des conteneurs.

## Prérequis

### Hardware

- **Virtualisation matérielle** : Les nodes doivent supporter Intel VT-x ou AMD-V
- **KVM disponible** : `/dev/kvm` doit exister sur les nodes
- **Nested virtualization** : Requise si le cluster tourne dans des VMs

Vérification sur un node :

```bash
# Vérifier le support KVM
ls -la /dev/kvm

# Vérifier la virtualisation nested (si dans une VM)
cat /sys/module/kvm_intel/parameters/nested  # Intel
cat /sys/module/kvm_amd/parameters/nested    # AMD
```

### Nested Virtualization (VM dans VM)

Si votre cluster Kubernetes tourne dans des VMs (Proxmox, VMware, KVM, etc.), vous devez activer la nested virtualization sur l'hyperviseur **parent**.

#### Proxmox

Dans la configuration de la VM, onglet CPU :

- Type CPU : `host`
- Cocher `Enable Nested Virtualization` (ou ajouter `+vmx` aux flags CPU)

Ou via CLI :

```bash
qm set <vmid> --cpu host
```

#### VMware ESXi / vSphere

Dans les options de la VM :

- Hardware > CPU > Cocher `Expose hardware assisted virtualization to the guest OS`

Ou ajouter dans le fichier `.vmx` :

```
vhv.enable = "TRUE"
```

#### VMware Workstation / Fusion

Dans les paramètres de la VM :

- Processors > Cocher `Virtualize Intel VT-x/EPT or AMD-V/RVI`

#### KVM / libvirt (hôte Linux)

Vérifier que le module est chargé avec nested=Y :

```bash
# Intel
cat /sys/module/kvm_intel/parameters/nested  # Doit afficher Y ou 1

# AMD
cat /sys/module/kvm_amd/parameters/nested

# Activer si nécessaire
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel nested=1
# Ou permanent dans /etc/modprobe.d/kvm.conf :
# options kvm_intel nested=1
```

#### Hyper-V

```powershell
Set-VMProcessor -VMName <vm-name> -ExposeVirtualizationExtensions $true
```

### Configuration Vagrant (Dev)

Le Vagrantfile inclut déjà la configuration pour la nested virtualization :

```ruby
config.vm.provider :libvirt do |libvirt|
  libvirt.nested = true
  libvirt.cpu_mode = "host-passthrough"
end
```

> **Important** : Ces paramètres Vagrant ne fonctionnent que si l'hyperviseur parent
> à la nested virtualization activée (voir section précédente).

## Architecture

### Composants déployés

1. **kata-deploy DaemonSet** : Installe les binaires Kata sur chaque node (`/opt/kata/`)
2. **RuntimeClasses** : Classes de runtime Kubernetes pour utiliser Kata
3. **Shims (handlers)** : Différents hyperviseurs supportés
4. **kata-agent** : Agent qui tourne à l'intérieur de chaque micro-VM

### Kata Agent

Le `kata-agent` est un daemon (écrit en Rust) qui s'exécute dans la micro-VM comme PID 1 (init). Il est le point de contact entre le shim sur l'hôte et les conteneurs dans la VM :

```
┌─ Hôte ──────────────────────┐    ┌─ Micro-VM ─────────────────────┐
│                             │    │                                │
│  containerd                 │    │  kata-agent (PID 1)            │
│    └─ containerd-shim-kata  │◄──►│    ├─ gère les conteneurs      │
│         (gRPC/vsock)        │    │    ├─ monte les volumes        │
│                             │    │    ├─ configure le réseau      │
│  virtiofsd                  │◄──►│    ├─ applique les cgroups     │
│    (partage fichiers)       │    │    └─ collecte les logs/events │
│                             │    │                                │
└─────────────────────────────┘    └────────────────────────────────┘
```

Le shim communique avec l'agent via **vsock** (socket virtuel VM↔hôte) ou **virtio-serial**. L'agent :

- Reçoit les requêtes CRI (CreateContainer, StartContainer, ExecSync, etc.)
- Gère le cycle de vie des conteneurs OCI dans la VM
- Monte les volumes (virtiofs, block devices hotplugues)
- Configure les cgroups v2 dans la VM pour enforcer les `limits`
- Collecte stdout/stderr et les transmet au shim
- Gère les signaux (SIGTERM pour arrêt gracieux du pod)

L'agent n'est pas visible depuis le conteneur (il tourne dans le namespace PID racine de la VM, parent du namespace du pod). Même avec `hostPID: true` et `privileged: true`, seul le namespace sandbox est visible (`/pause` + conteneurs). La hiérarchie PID dans une VM Kata est :

```
Namespace PID racine VM :  kata-agent (PID 1) + kernel threads  ← invisible depuis les pods
  └─ Namespace sandbox :   /pause (PID 1)                       ← visible avec hostPID: true
       └─ Namespace container : entrypoint (PID 1)              ← visible par défaut
```

#### Répartition mémoire dans la VM (`default_memory=256`)

| Métrique                        | Valeur     | Source           |
| ------------------------------- | ---------- | ---------------- |
| RAM allouée QEMU                | 256 MB     | `-m 256M`        |
| `MemTotal` (visible userspace)  | 162 MB     | `/proc/meminfo`  |
| Réserve kernel (jamais visible) | **94 MB**  | 256 - 162        |
| Utilisé (agent + caches noyau)  | ~35 MB     | `free -m` (used) |
| `MemAvailable` (pour workloads) | **126 MB** | `/proc/meminfo`  |

Décomposition du "utilise" (~35 MB dans la VM) :

- **Slab** (caches noyau) : ~13 MB (`SUnreclaim` ~10 MB + `SReclaimable` ~3 MB)
- **Percpu** (données par CPU) : ~3.5 MB
- **AnonPages** (agent + conteneurs) : ~6.5 MB
- **Mapped** (fichiers mappés en mémoire) : ~17.5 MB
- **Buffers + Cached** : ~6 MB (reclaimable)

#### Empreinte des processus hôte par pod Kata (`kata-qemu-minimal`, idle)

| Processus hôte             | RSS         | Rôle                                    |
| -------------------------- | ----------- | --------------------------------------- |
| `containerd-shim-kata-v2`  | ~43 MB      | Shim Go, gestion lifecycle VM + gRPC    |
| `qemu-system-x86_64`       | ~210 MB     | Hyperviseur, inclut la RAM guest mappée |
| `virtiofsd` (2 threads)    | ~8 MB       | Daemon de partage de fichiers hôte ↔ VM |
| **Total RSS hôte par pod** | **~261 MB** |                                         |

### Chaîne de runtime containerd

```
Avec runc (défaut) :  containerd → containerd-shim-runc-v2 → runc → container
Avec Kata :           containerd → containerd-shim-kata-v2 → hyperviseur → VM → kata-agent → container
```

Kata utilise deux implémentations du shim :

- **Runtime Go** : `/opt/kata/bin/containerd-shim-kata-v2` (shim classique)
- **Runtime Rust** : `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2` (shim Rust, RSS plus faible)

### Shims disponibles

| Shim                    | Hyperviseur          | Langage VMM | Runtime shim | Cas d'usage                        |
| ----------------------- | -------------------- | ----------- | ------------ | ---------------------------------- |
| `kata-qemu`             | QEMU/KVM             | C           | Go           | Production, compatibilité maximale |
| `kata-qemu-runtime-rs`  | QEMU/KVM             | C           | Rust         | Production, shim léger             |
| `kata-clh`              | Cloud Hypervisor     | Rust        | Go           | Performance, footprint réduit      |
| `kata-cloud-hypervisor` | Cloud Hypervisor     | Rust        | Rust         | Idem kata-clh, shim Rust           |
| `kata-fc`               | Firecracker          | Rust        | Go           | Serverless, démarrage ultra-rapide |
| `kata-dragonball`       | Dragonball (intégré) | Rust        | Rust         | VMM intégré au shim, RSS minimal   |

#### QEMU

Hyperviseur le plus complet et le plus testé. Support de toutes les architectures (amd64, arm64, s390x, ppc64le). Binaire : `/opt/kata/bin/qemu-system-x86_64`.

Variantes TEE (Confidential Computing) :

- **qemu-coco-dev** : variante de test qui scanne le processeur au démarrage et fallback sur un mode non-TEE si aucune extension n'est trouvée. Utile pour les clusters mixtes AMD/Intel ou les environnements de test
- **qemu-tdx** : Intel TDX (Trust Domain Extensions). Nécessite un CPU Intel avec le flag TDX
- **qemu-snp** : AMD SEV-SNP (Secure Encrypted Virtualization - Secure Nested Paging). Nécessite un CPU AMD avec le flag SNP
- **qemu-se** : IBM Secure Execution (s390x)

#### Cloud Hypervisor

Hyperviseur standalone minimaliste écrit en Rust. Surface d'attaque réduite, excellente densité mémoire et latence I/O. Binaire : `/opt/kata/bin/cloud-hypervisor`. `kata-clh` (runtime Go) et `kata-cloud-hypervisor` (runtime Rust) produisent des résultats identiques.

#### Firecracker

Hyperviseur ultra-minimal (AWS). Démarrage rapide, idéal pour le serverless/FaaS (type AWS Lambda). Support limité de types de devices. Binaire : `/opt/kata/bin/firecracker`.

#### Dragonball

VMM intégré directement dans le shim Rust (pas de processus hyperviseur séparé). Footprint mémoire le plus faible (~180 MB RSS) mais performances réseau nettement inférieures. Développé par Alibaba. Binaire : `/opt/kata/runtime-rs/bin/containerd-shim-kata-v2` (VMM embedded).

> **Note** : StratoVirt (Huawei) est encore référence dans la [documentation officielle](https://github.com/kata-containers/kata-containers/blob/main/docs/hypervisors.md) mais n'est plus fonctionnel dans le chart Helm `kata-deploy` 3.26.0 : le binaire `/opt/kata/bin/stratovirt` et le handler containerd sont absents. Les pods échouent avec `no runtime for "kata-stratovirt" is configured`.

> Voir la comparaison officielle : https://github.com/kata-containers/kata-containers/blob/main/docs/hypervisors.md

### Chemin réseau

```
Sans Kata :  client → LB → kube-proxy → container
Avec Kata :  client → LB → kube-proxy → virtio-net → VM → container
```

Le hop `virtio-net` ajoute ~0.3 ms de latence par requête et réduit le débit d'un facteur ~6-7x (voir benchmarks réseau).

#### MTU et fragmentation avec Cilium

Kata crée un namespace réseau **intérieur** (dans la VM) en plus du namespace **extérieur** (créé par Cilium CNI). Lors de la création du namespace extérieur, Cilium :

1. Crée `eth0` avec le **device MTU** détecté (ex: 1500)
2. Ajuste le **route MTU** de la route par défaut = device MTU - overhead d'encapsulation

Lors de la création du namespace intérieur, Kata copie le **device MTU** (1) mais **ignore le route MTU** (2). Les paquets sortent donc avec un MTU trop grand, causant de la fragmentation et des pertes de paquets dans les échanges entre pods Kata et pods traditionnels.

Overheads d'encapsulation :

| Protocole  | Overhead | Route MTU effectif |
|------------|----------|--------------------|
| VXLAN      | +50 B    | 1450               |
| Geneve     | +50 B    | 1450               |
| WireGuard  | +80 B    | 1420               |

**Workaround recommandé** ([doc Cilium](https://docs.cilium.io/en/stable/network/kubernetes/kata/)) : ajouter un `initContainer` avec `NET_ADMIN` pour corriger le route MTU dans le pod Kata :

```yaml
initContainers:
  - name: fix-mtu
    image: busybox:latest
    command:
      - sh
      - -c
      - |
        DEFAULT="$(ip route show default)"
        ip route replace "$DEFAULT" mtu 1420
    securityContext:
      capabilities:
        add:
          - NET_ADMIN
```

> **Note** : ajuster la valeur `mtu` selon le protocole d'encapsulation utilisé (1450 pour VXLAN/Geneve, 1420 pour WireGuard). L'alternative (baisser le MTU global dans le ConfigMap Cilium) est déconseillée car elle impacte négativement **tous** les pods du cluster.

### Chemin stockage

```
Sans Kata :  Container → overlay2 → disque host (/var/lib/rancher/rke2/agent/containerd/.../snapshots/)
Avec Kata :  Container (VM) → virtiofs → virtiofsd (host) → disque host
```

La couche `virtiofs/virtiofsd` ajoute un overhead d'écriture ~20x (voir benchmarks I/O). La lecture bénéficie du page cache hôte et reste performante.

### Architecture à 2 niveaux (VM + cgroups)

Kata applique les `limits` à deux niveaux : la VM dimensionne les ressources hardware, puis les cgroups à l'intérieur de la VM enforcent les limites réelles.

```
┌─ Niveau 1 : QEMU VM ─────────────────────────────┐
│  RAM VM = default_memory + limits.memory          │
│  vCPU = default_vcpus + hotplug(limits.cpu)       │
│                                                   │
│  ┌─ Niveau 2 : Cgroups dans la VM ─────────────┐ │
│  │  memory.max = limits.memory (ex: 256Mi)      │ │
│  │  cpu.max = limits.cpu (ex: 50000/100000)     │ │
│  │  → OOM killer si dépassement mémoire         │ │
│  │  → throttling si dépassement CPU             │ │
│  └──────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────┘
```

L'overhead est significatif : pour un conteneur limité à 256 Mi / 500m CPU, runc n'utilise que des cgroups host (coût quasi nul), tandis que Kata alloue une VM entière (~256 MB base + hotplug) puis applique les cgroups dans la VM.

## Configuration

### Paramètres disponibles

```yaml
kataContainers:
  version: "3.26.0" # Version du chart Helm
  k8sDistribution: "rke2" # Distribution K8s (rke2, k8s, k3s)
  debug: false # Mode debug
  createDefaultRuntimeClass: true # Créer la RuntimeClass "kata" par défaut
  shims:
    qemu:
      enabled: true # QEMU/KVM (recommandé pour nested virt)
    clh:
      enabled: true # Cloud Hypervisor
    fc:
      enabled: false # Firecracker
    dragonball:
      enabled: true # Dragonball (experimental)
  customRuntimes: # Runtimes personnalisés (drop-in TOML)
    qemu-minimal:
      enabled: true # RuntimeClass kata-qemu-minimal
      baseConfig: "qemu" # Shim de base à surcharger (qemu, clh, etc.)
      defaultMemory: 256 # RAM par micro-VM (MB) - défaut QEMU: 2048
      defaultVcpus: 1 # vCPUs par micro-VM - défaut QEMU: 1
      blockDeviceEnabled: false # Block device passthrough (défaut: false)
      blockDeviceDriver: "" # Driver block device (virtio-scsi, virtio-blk)
    qemu-block-minimal:
      enabled: true # RuntimeClass kata-qemu-block-minimal
      baseConfig: "qemu"
      defaultMemory: 256
      defaultVcpus: 1
      blockDeviceEnabled: true # Active le passthrough block device
      blockDeviceDriver: "virtio-scsi" # Driver pour les PVC volumeMode: Block
```

> **Note**: Cloud Hypervisor (`clh`) fonctionne en nested virtualization. QEMU et CLH sont tous deux
> compatibles avec les environnements dev/nested (Vagrant/libvirt).

### RuntimeClasses créées

Une fois déployé, les RuntimeClasses suivantes sont disponibles (selon les shims activés) :

```bash
kubectl get runtimeclass
```

| RuntimeClass              | Handler                   | Description                             | Activé par défaut |
| ------------------------- | ------------------------- | --------------------------------------- | ----------------- |
| `kata-qemu`               | `kata-qemu`               | QEMU avec KVM                           | Oui               |
| `kata-clh`                | `kata-clh`                | Cloud Hypervisor                        | Non               |
| `kata-fc`                 | `kata-fc`                 | Firecracker                             | Non               |
| `kata-dragonball`         | `kata-dragonball`         | Dragonball                              | Non               |
| `kata-qemu-minimal`       | `kata-qemu-minimal`       | QEMU avec RAM/CPU réduits               | Non (custom)      |
| `kata-qemu-block-minimal` | `kata-qemu-block-minimal` | QEMU minimal + block device passthrough | Non (custom)      |

## Utilisation

### Déployer un Pod avec Kata

Spécifiez `runtimeClassName` dans votre Pod :

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-kata
spec:
  runtimeClassName: kata-qemu # QEMU/KVM (recommandé)
  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
```

### Vérification de l'isolation

```bash
# Créer un pod Kata
kubectl run test-kata --image=nginx --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"kata-qemu"}}'

# Vérifier le kernel (doit être différent du host)
kubectl exec test-kata -- uname -a

# Comparer avec un pod standard
kubectl run test-standard --image=nginx --restart=Never
kubectl exec test-standard -- uname -a

# Nettoyer
kubectl delete pod test-kata test-standard
```

Le pod Kata affichera un kernel différent (ex: `6.18.5`) tandis que le pod standard utilisera le kernel du node (ex: `6.8.0-64-generic`).

### Custom Runtimes (drop-in TOML)

Le chart Helm `kata-deploy` supporte `customRuntimes` pour créer des RuntimeClasses personnalisées basées sur un shim existant. Chaque custom runtime génère un répertoire dédié dans `/opt/kata/share/defaults/kata-containers/custom-runtimes/kata-<name>/` sur chaque node, contenant une copie de la configuration de base et un fichier drop-in TOML dans `config.d/50-overrides.toml` qui surcharge les paramètres sans modifier la configuration d'origine.

`kata-qemu-minimal` est un runtime pré-configuré qui réduit l'overhead mémoire QEMU de ~2 GB à ~290 MB par pod en limitant `default_memory` à 256 MB :

```yaml
spec:
  runtimeClassName: kata-qemu-minimal
```

Vérification :

```bash
# Vérifier la RuntimeClass
kubectl get runtimeclass kata-qemu-minimal

# Vérifier le drop-in sur un node
kubectl debug node/<node-name> -it --image=busybox -- \
  cat /host/opt/kata/share/defaults/kata-containers/custom-runtimes/kata-qemu-minimal/config.d/50-overrides.toml

# Tester avec un pod
kubectl run test-minimal --image=nginx --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"kata-qemu-minimal"}}'
kubectl exec test-minimal -- free -m  # ~290 MB au lieu de ~2 GB
kubectl delete pod test-minimal
```

### Dimensionnement mémoire de la VM

Kata dimensionne la RAM QEMU à partir de `default_memory` (drop-in) + les `limits.memory` des conteneurs. Les `requests.memory` sont ignorées par Kata (elles ne servent qu'au scheduler Kubernetes).

| Scenario (`default_memory=256`)       | RAM VM allouée | QEMU `-m` au boot   | `free -m` dans le guest |
| ------------------------------------- | -------------- | ------------------- | ----------------------- |
| Sans request ni limit                 | 256 MB         | 256M                | ~162 MB                 |
| `requests.memory: 512Mi` (sans limit) | 256 MB         | 256M                | ~162 MB                 |
| `limits.memory: 256Mi`                | 512 MB         | 256M + 256M hotplug | ~418 MB                 |

Kata utilise le **memory hotplug** QEMU : la VM démarre avec `default_memory` (`-m 256M,slots=10,maxmem=33117M`) puis hotplugue la mémoire des `limits` via des DIMM virtuels. L'écart entre la RAM allouée et `free -m` (~94 MB) correspond à l'overhead du kernel de la micro-VM.

> **Attention** : Les `requests.memory` sont ignorées par Kata (elles ne servent qu'au scheduler Kubernetes pour réserver de la capacité sur le noeud). Seules les `limits.memory` augmentent la RAM de la VM. Une `requests` élevée sans `limits` gaspille la capacité du noeud sans bénéfice pour le pod. Préférez toujours définir des `limits` pour les pods Kata.

Mémoire réellement utilisable par le conteneur (testé avec `stress --vm-bytes`, `limits.memory: 256Mi`, VM 418 MB) :

| Allocation résidente | Résultat      |
| -------------------- | ------------- |
| 200 MB               | OK            |
| 250 MB               | OK            |
| 256 MB               | **OOMKilled** |

L'overhead du kernel et de l'agent Kata (~168 MB) réduit la mémoire disponible pour le conteneur. En règle générale, la mémoire utilisable est d'environ `default_memory + limits.memory - 168 MB`.

### Impact de `default_memory` sur la consommation hôte

Kata utilise le memory hotplug : la VM démarre avec `default_memory` puis hotplugue `limits.memory` à la demande. Le coût réel sur l'hôte (RSS QEMU) dépend de la **mémoire effectivement utilisée** par le guest, pas de la taille configurée.

Benchmark sous charge (`stress --vm-bytes`) sur nested virtualization :

| Runtime             | `default_memory` | limits | VM Total | Stress | RSS hôte (idle) | RSS hôte (charge) |
| ------------------- | ---------------- | ------ | -------- | ------ | --------------- | ----------------- |
| `kata-qemu`         | 2048             | -      | 1923 MB  | 400 MB | ~645 MB         | **645 MB**        |
| `kata-qemu-minimal` | 256              | -      | 162 MB   | 100 MB | ~310 MB         | **310 MB**        |
| `kata-qemu-minimal` | 256              | 512Mi  | 674 MB   | 400 MB | ~330 MB         | **620 MB**        |

Points clés :

- **Sous charge identique (400 MB)**, le RSS hôte est quasi équivalent (~620-645 MB) quel que soit `default_memory`
- **Au repos**, `default_memory=2048` coûte ~645 MB de RSS vs ~310 MB pour `default_memory=256` — soit **~335 MB de plus par pod idle**
- **Le hotplug est on-demand** : augmenter `limits.memory` n'augmente le RSS que si le guest consomme réellement la mémoire
- **Les performances I/O sont indépendantes** de la taille de la VM (virtiofs + cache hôte)

> **Recommandation** : utiliser `kata-qemu-minimal` (`default_memory=256`) et dimensionner via `limits.memory` dans les specs des pods. Cela économise ~335 MB de RSS par pod idle tout en offrant les mêmes performances sous charge. Sur un noeud avec 20 pods Kata idle, c'est ~6.7 GB économisés

### Dimensionnement CPU de la VM

Kata dimensionne les vCPUs QEMU à partir de `default_vcpus` (drop-in) + les `limits.cpu` des conteneurs. Comme pour la mémoire, les `requests.cpu` sont ignorées par Kata.

| Scenario (`default_vcpus=1`)   | vCPUs dans la VM | `nproc` dans le guest |
| ------------------------------ | ---------------- | --------------------- |
| Sans request ni limit          | 1                | 1                     |
| `requests.cpu: 2` (sans limit) | 1                | 1                     |
| `limits.cpu: 1`                | 1 + 1 hotplug    | 2                     |
| `limits.cpu: 500m`             | 1 + 1 hotplug    | 2 (quota CFS 0.5)     |
| `limits.cpu: 1500m`            | 1 + 2 hotplug    | 3 (quota CFS 1.5)     |
| `limits.cpu: 2`                | 1 + 2 hotplug    | 3                     |
| `limits.cpu: 4`                | 1 + 4 hotplug    | 5                     |

Kata utilise le **CPU hotplug** QEMU : la VM démarre avec `default_vcpus` puis hotplugue les vCPUs des `limits` dynamiquement. Les vCPUs hotplugues apparaissent avec des IDs non contigus dans `/proc/cpuinfo` (ex: processor 0, 12, 13, 14, 15).

Pour les **limits fractionnaires** (ex: `1500m` = 1.5 CPU), Kata arrondit au supérieur pour le nombre de vCPUs hotpluguees (ceil(1.5) = 2 → 3 vCPUs total) puis applique un **quota CFS cgroup** (`cpu.max: 150000 100000`) pour limiter le temps CPU réel à exactement 1.5 CPU sur les 3 vCPUs disponibles.

> **Note** : avec `limits.cpu: 500m`, Kata hotplugue 1 vCPU (ceil(0.5) = 1 → 2 vCPUs total) mais throttle à 50% via CFS. La VM a 2 vCPUs pour n'en utiliser que 0.5 — c'est du gaspillage. Pour les petits workloads, ne pas définir de `limits.cpu` (1 vCPU sans throttle) est préférable à `limits.cpu < 1`.

> **Attention** : Les `requests.cpu` sont ignorées par Kata. Seules les `limits.cpu` ajoutent des vCPUs à la VM.

### Impact du nombre de vCPUs sur les performances

Benchmark avec 4 workers parallèles compressant chacun 500 MB de données aléatoires (gzip), sur nested virtualization :

| limits.cpu | vCPUs VM | Benchmark 4x gzip 500MB | Speedup | RSS hôte (idle) |
| ---------- | -------- | ----------------------- | ------- | --------------- |
| -          | 1        | 78s                     | 1x      | 215 MB          |
| 1          | 2        | 81s                     | 0.96x   | 222 MB          |
| 2          | 3        | 41s                     | 1.9x    | 225 MB          |
| 4          | 5        | 22s                     | 3.5x    | 227 MB          |

Points clés :

- **Le RSS hôte est quasi identique (~215-227 MB)** quel que soit le nombre de vCPUs, soit ~3 MB par vCPU supplémentaire
- **Le scaling est quasi-linéaire** à partir de 3 vCPUs pour les workloads parallélisables
- **2 vCPUs n'améliorent pas les performances** vs 1 vCPU : l'overhead du scheduling QEMU pour un seul vCPU hotplugue annule le gain. Préférez `limits.cpu >= 2` pour un bénéfice réel
- **`default_vcpus=1` est optimal** : le coût hôte est négligeable et les `limits.cpu` ajoutent des vCPUs à la demande

> **Recommandation** : garder `default_vcpus=1` dans le custom runtime et dimensionner via `limits.cpu` dans les specs des pods. Pour les workloads parallèles (builds, bases de données), définir `limits.cpu: 2` ou plus. Pour les workloads mono-thread, ne pas définir de limits CPU

### Block Device Passthrough (kata-qemu-block-minimal)

Le runtime `kata-qemu-block-minimal` active `disable_block_device_use = false` avec le driver `virtio-scsi`. Cela permet aux PVC `volumeMode: Block` d'être hotplugues directement dans la micro-VM Kata comme des devices SCSI (`/dev/xvda`), offrant des performances I/O proches du natif.

```yaml
spec:
  runtimeClassName: kata-qemu-block-minimal
  containers:
    - name: db
      volumeDevices:
        - name: rawblock
          devicePath: /dev/xvda
  volumes:
    - name: rawblock
      persistentVolumeClaim:
        claimName: my-raw-pvc # volumeMode: Block
```

Exemple complet avec PVC raw block :

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-block-pvc
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Block
  resources:
    requests:
      storage: 1Gi
  storageClassName: ceph-block
---
apiVersion: v1
kind: Pod
metadata:
  name: test-qemu-block-minimal
spec:
  runtimeClassName: kata-qemu-block-minimal
  containers:
    - name: test
      image: busybox
      command: ["sh", "-c"]
      args:
        - |
          echo "=== kata-qemu-block-minimal ==="
          free -m
          echo "Kernel: $(uname -r)"
          echo ""
          echo "=== Block device ==="
          ls -la /dev/xvda
          fdisk -l /dev/xvda
          echo ""
          echo "=== dd write 10MB ==="
          dd if=/dev/zero of=/dev/xvda bs=1M count=10 2>&1
          echo ""
          echo "=== dd read ==="
          dd if=/dev/xvda of=/dev/null bs=1M count=10 2>&1
      securityContext:
        runAsUser: 0
      volumeDevices:
        - name: rawblock
          devicePath: /dev/xvda
  volumes:
    - name: rawblock
      persistentVolumeClaim:
        claimName: test-block-pvc
  restartPolicy: Never
```

> **Avertissement sécurité** : Avec `disable_block_device_use = false`, les volumes `hostPath` de type `BlockDevice` sont aussi hotplugues dans la VM. Un pod utilisant `hostPath: /dev/vda, type: BlockDevice` aurait un accès direct en lecture/écriture au disque système de l'hôte, contournant l'isolation Kata. En production, une ClusterPolicy Kyverno/OPA bloquant les `hostPath BlockDevice` est **indispensable**.

Comportement par type de volume :

| Type de volume                        | Mécanisme               | Accès hôte                            |
| ------------------------------------- | ----------------------- | ------------------------------------- |
| PVC `volumeMode: Filesystem` (défaut) | virtiofs (inchangé)     | Non                                   |
| PVC `volumeMode: Block`               | virtio-scsi hotplug     | Non (device RBD dédié)                |
| `hostPath` répertoire                 | virtiofs (inchangé)     | Non                                   |
| `hostPath` type `BlockDevice`         | **virtio-scsi hotplug** | **Oui - accès direct au disque hôte** |

Exemple de `hostPath type: BlockDevice` (démonstration du risque sécurité) :

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-hostpath-block
spec:
  runtimeClassName: kata-qemu-block-minimal
  containers:
    - name: test
      image: busybox
      command: ["sh", "-c"]
      args:
        - |
          echo "=== Host disk accessible depuis la VM Kata ==="
          ls -la /dev/hostdisk
          fdisk -l /dev/hostdisk 2>&1 | head -5
          echo ""
          echo "=== MBR (premiers 512 octets) ==="
          dd if=/dev/hostdisk bs=512 count=1 2>/dev/null | hexdump -C | head -5
      securityContext:
        runAsUser: 0
      volumeDevices:
        - name: hostdisk
          devicePath: /dev/hostdisk
  volumes:
    - name: hostdisk
      hostPath:
        path: /dev/vda # Disque système de l'hôte !
        type: BlockDevice
  restartPolicy: Never
```

> **Ce pod accède en lecture/écriture au disque système de l'hôte**, contournant complètement l'isolation de la micro-VM Kata. C'est pourquoi une ClusterPolicy bloquant les `hostPath BlockDevice` est indispensable en production avec `kata-qemu-block-minimal`.

Un PVC `volumeMode: Filesystem` fonctionne aussi avec `kata-qemu-block-minimal` (virtiofs, inchangé) :

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-fs-pvc
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 1Gi
  storageClassName: ceph-block
---
apiVersion: v1
kind: Pod
metadata:
  name: test-qemu-block-minimal-fs
spec:
  runtimeClassName: kata-qemu-block-minimal
  containers:
    - name: test
      image: busybox
      command: ["sh", "-c"]
      args:
        - |
          echo "=== kata-qemu-block-minimal (Filesystem mode) ==="
          free -m
          echo ""
          echo "=== mount | grep data ==="
          mount | grep data
          echo ""
          echo "=== df -h /data ==="
          df -h /data
          echo ""
          echo "=== dd write 50MB ==="
          dd if=/dev/zero of=/data/bigfile bs=1M count=50 2>&1
          echo ""
          echo "=== dd read 50MB ==="
          dd if=/data/bigfile of=/dev/null bs=1M 2>&1
          echo ""
          echo "=== ls -la /data ==="
          ls -la /data/
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-fs-pvc
  restartPolicy: Never
```

Performances mesurées (Ceph RBD, nested virtualization) :

| Mode                     | Écriture 50 MB | Lecture 50 MB | Mécanisme             |
| ------------------------ | -------------- | ------------- | --------------------- |
| `volumeMode: Filesystem` | 89.6 MB/s      | 1.0 GB/s      | virtiofs (cache hôte) |
| `volumeMode: Block`      | 91.1 MB/s      | 760 MB/s      | virtio-scsi hotplug   |

Le débit séquentiel est comparable. Le block device passthrough apporte surtout une meilleure latence et un accès direct au device pour les workloads type base de données (pas d'intermédiaire virtiofs).

### Benchmark comparatif des runtimes

Tests réalisés sur un noeud RKE2 en nested virtualization (Vagrant/libvirt), Ceph RBD, image `busybox`.

#### Temps de démarrage

| Runtime                | Sans PVC | Avec PVC (Ceph RBD) |
| ---------------------- | -------- | ------------------- |
| `crun` (défaut)        | 2.3s     | 7.1s                |
| `kata-clh`             | 3.9s     | 10.9s               |
| `kata-qemu`            | 4.9s     | 14.0s               |
| `kata-qemu-runtime-rs` | 5.5s     | 14.8s               |
| `kata-dragonball`      | 6.2s     | 21.3s               |

> **Note** : `kata-clh` et `kata-cloud-hypervisor` sont le même hyperviseur (Cloud Hypervisor). Les résultats sont identiques.

#### Consommation mémoire (idle, `default_memory=2048`)

| Runtime                | Shim   | VMM     | virtiofsd | **RSS total hôte** | RAM guest |
| ---------------------- | ------ | ------- | --------- | ------------------ | --------- |
| `crun` (défaut)        | -      | -       | -         | **~2 MB**          | RAM hôte  |
| `kata-dragonball`      | 146 MB | (inclu) | ~34 MB    | **~180 MB**        | 1988 MB   |
| `kata-clh`             | 42 MB  | 136 MB  | ~34 MB    | **~212 MB**        | 1988 MB   |
| `kata-qemu-runtime-rs` | 20 MB  | 243 MB  | ~34 MB    | **~297 MB**        | 1924 MB   |
| `kata-qemu`            | 42 MB  | 245 MB  | ~34 MB    | **~321 MB**        | 1924 MB   |

- `kata-dragonball` a le VMM intégré dans le shim Rust (pas de processus séparé), d'où le RSS le plus faible
- `kata-clh` (Cloud Hypervisor) est ~34% plus léger que QEMU en RSS
- `kata-qemu-runtime-rs` utilise le shim Rust (20 MB vs 42 MB Go) mais le même QEMU

#### Overhead CPU (single-thread gzip 200 MB /dev/urandom)

| Runtime                 | Durée | Overhead vs crun |
| ----------------------- | ----- | ---------------- |
| `crun` (défaut)         | 10s   | -                |
| `kata-clh`              | 12s   | +20%             |
| `kata-cloud-hypervisor` | 11s   | +10%             |
| `kata-qemu`             | 12s   | +20%             |
| `kata-qemu-runtime-rs`  | 12s   | +20%             |
| `kata-dragonball`       | 12s   | +20%             |

L'overhead CPU est négligeable (~20%) pour tous les runtimes Kata.

#### Débit et latence I/O (PVC Ceph RBD, virtiofs, 100 MB séquentiel)

| Runtime                 | Écriture  | Lecture     | Overhead écriture |
| ----------------------- | --------- | ----------- | ----------------- |
| `crun` (défaut)         | 1.9 GB/s  | 6.4 GB/s    | -                 |
| `kata-qemu`             | 90.1 MB/s | 1.4 GB/s    | **~21x**          |
| `kata-clh`              | 96.5 MB/s | 1.2 GB/s    | **~20x**          |
| `kata-cloud-hypervisor` | 93.3 MB/s | 1.4 GB/s    | **~20x**          |
| `kata-qemu-runtime-rs`  | 95.3 MB/s | 1.1 GB/s    | **~20x**          |
| `kata-dragonball`       | 94.8 MB/s | 6.2 GB/s \* | **~20x**          |

L'écriture via virtiofs est ~20x plus lente que crun (couche VM). La lecture bénéficie du cache hôte et reste performante.

\* La lecture dragonball à 6.2 GB/s est un **artefact de cache** : les 100 MB écrits sont conservés en page cache dans la VM guest et relus sans repasser par virtiofs. Vérification avec `echo 3 > /proc/sys/vm/drop_caches` dans la VM (Ubuntu, `conv=fdatasync`) :

| Runtime           | Write (fdatasync) | Read (cache purge) | Read (page cache) |
| ----------------- | ----------------- | ------------------ | ----------------- |
| `crun`            | 714 MB/s          | 1.7 GB/s           | 3.1 GB/s          |
| `kata-qemu`       | 68.5 MB/s         | 770 MB/s           | 1.4 GB/s          |
| `kata-clh`        | 69.9 MB/s         | 677 MB/s           | 1.0 GB/s          |
| `kata-dragonball` | 74.0 MB/s         | **205 MB/s**       | **6.0 GB/s**      |

Après purge du cache guest, la lecture dragonball chute à **205 MB/s** — soit 3.7x plus lent que QEMU (770 MB/s). Dragonball conserve les données en page cache guest de manière plus agressive que les autres runtimes, donnant une fausse impression de performance en relecture immédiate.

#### Débit et latence réseau (iperf3, pod-to-pod même noeud)

| Runtime                 | Débit     | Ping avg | Overhead débit |
| ----------------------- | --------- | -------- | -------------- |
| `crun` (défaut)         | 31.4 Gbps | 0.08 ms  | -              |
| `kata-qemu`             | 4.80 Gbps | 0.31 ms  | **~6.5x**      |
| `kata-clh`              | 4.62 Gbps | 0.48 ms  | **~6.8x**      |
| `kata-cloud-hypervisor` | 4.70 Gbps | 0.32 ms  | **~6.7x**      |
| `kata-qemu-runtime-rs`  | 5.05 Gbps | 0.35 ms  | **~6.2x**      |
| `kata-dragonball`       | 0.90 Gbps | 0.94 ms  | **~35x**       |

La couche VM ajoute ~0.3 ms de latence et réduit le débit d'un facteur ~6-7x. `kata-dragonball` est nettement en retrait avec un débit réseau ~35x inférieur à crun.

### Cas d'usage recommandés

| Cas d'usage                     | RuntimeClass recommandée  | Raison                                          |
| ------------------------------- | ------------------------- | ----------------------------------------------- |
| Workloads non fiables           | `kata-qemu`               | Stabilité, compatibilité maximale               |
| Multi-tenancy sécurisé          | `kata-qemu`               | Isolation hardware éprouvée                     |
| Nested virtualization           | `kata-qemu`               | Compatible nested virt                          |
| CI/CD builds isolés             | `kata-qemu`               | Bon compromis sécurité/performance              |
| Performance (boot rapide, RSS)  | `kata-clh`                | RSS le plus faible après dragonball, bon réseau |
| Densité élevée (RAM limitée)    | `kata-qemu-minimal`       | ~310 MB idle vs ~645 MB pour kata-qemu (défaut) |
| Base de données / raw block I/O | `kata-qemu-block-minimal` | Block device passthrough virtio-scsi            |
| Démarrage rapide (serverless)   | `kata-clh`                | Boot le plus rapide (3.9s sans PVC)             |

> **Note** : `kata-dragonball` a le footprint mémoire le plus faible (180 MB) mais ses performances réseau sont nettement inférieures (~900 Mbps vs ~5 Gbps). À réserver aux workloads sans réseau intensif.

> **Note** : Seul `kata-qemu` est activé par défaut. Pour d'autres shims, modifiez `config/dev.yaml`.

### Stockage éphémère

Le stockage éphémère (`ephemeral-storage`) fonctionne avec Kata : les écritures du conteneur atterrissent sur le disque de l'hôte via virtiofs et le kubelet surveille l'espace disque de la même manière qu'avec runc.

## Modèle de sécurité

Kata exécute chaque pod dans une micro-VM avec son propre kernel. Cela change fondamentalement le modèle de sécurité par rapport à `runc` :

| Flag / Capacité           | Risque avec runc     | Risque avec Kata                     |
| ------------------------- | -------------------- | ------------------------------------ |
| `hostNetwork`             | Critique             | Aucun (ignoré par la VM) \*          |
| `hostPID`                 | Critique             | Aucun (ignoré par la VM)             |
| `hostIPC`                 | Critique             | Aucun (ignoré par la VM)             |
| `privileged: true`        | Critique (root host) | Faible (root dans la VM seulement)   |
| Capabilities dangèreuses  | Élevé                | Faible (confinées dans la VM)        |
| `hostPath` (répertoire)   | Critique             | **Critique (accès FS host !)** \*\*  |
| `hostPath` (block device) | Critique             | Dépend de `disable_block_device_use` |

\* `hostNetwork` n'est pas supporté — voir [Limitations > hostNetwork](#hostnetwork) pour les détails et résultats de test.

\*\* Les répertoires host sont accessibles via virtiofs. Un `hostPath: /etc` permet de lire des fichiers sensibles comme `/etc/shadow`. La VM ne protège pas contre les volumes montés par le kubelet avant le démarrage de QEMU. C'est le seul flag qui **doit** être bloqué par Kyverno dans les namespaces Kata.

### Comportement des hostPath par type

| `hostPath` vers...                                    | Résultat dans Kata                                             |
| ----------------------------------------------------- | -------------------------------------------------------------- |
| `/etc` (répertoire)                                   | Fonctionne — fichiers host lisibles via virtiofs               |
| `/dev` (répertoire)                                   | Fonctionne — mais expose les devices de la **VM**, pas du host |
| `/proc`, `/sys`                                       | Expose les données de la **VM** (RAM VM, kernel VM, etc.)      |
| `/dev/vda` + `disable_block_device_use=true` (défaut) | **Crash** du shim (StartError)                                 |
| `/dev/vda` + `disable_block_device_use=false`         | **Pas isolé** — disque hôte hotplugue dans la VM               |

### Mode privilégié

`privileged: true` est confiné à l'intérieur de la micro-VM et ne donne aucun accès aux devices du host. Cela permet d'exécuter en toute sécurité des opérations nécessitant des privilèges élevés (tuning sysctl, opérations réseau) sans compromettre le node. Un conteneur privilégié dans Kata peut néanmoins manipuler le réseau et les sysctls de la VM.

### Avantage : privileged sécurisé pour le tuning kernel

Avec `runc`, des applications comme Elasticsearch nécessitent un init container privilégié pour le tuning kernel (`sysctl -w vm.max_map_count=262144`), ce qui impose le PSA `privileged` au namespace et ouvre un risque de sécurité. Avec Kata, `privileged: true` est confiné dans la VM : le sysctl modifie le kernel de la micro-VM sans affecter le host. Cela permet d'exécuter ces init containers en toute sécurité tout en protégeant le node.

> **Note** : les modifications sysctl dans un pod Kata n'affectent que le kernel de la micro-VM. Les pods systèmes d'infrastructure (CNI, monitoring, stockage) qui ont besoin de modifier les sysctls du host **ne peuvent pas** utiliser Kata.

## Limitations

> Voir la documentation officielle des limitations : https://github.com/kata-containers/kata-containers/blob/main/docs/Limitations.md

### Namespace sharing (hostNetwork, hostPID, hostIPC)

`hostNetwork`, `hostPID` et `hostIPC` sont ignorés par Kata — le pod ne voit que les namespaces de sa propre VM. Les pods qui dépendant du partage de namespace réseau avec d'autres conteneurs (`shareProcessNamespace`, sidecar patterns partageant le réseau) fonctionnent à l'intérieur de la même VM Kata mais pas entre VMs.

#### hostNetwork

`hostNetwork: true` est **incompatible** avec Kata. Le pod démarre et Kubernetes lui attribue l'IP du node, mais la VM ne reçoit pas les interfaces réseau de l'hôte — seul le loopback est visible :

| | crun `hostNetwork` | kata `hostNetwork` |
|---|---|---|
| Interfaces visibles | eth0, eth1, cilium_*, lxc_* (toutes les interfaces du noeud) | `lo` uniquement |
| Table de routage | Complète (routes hôte) | Vide |
| DNS | Fonctionne | "Network is unreachable" |
| IP | IP du noeud (ex: 192.168.121.237) | Aucune |

Ceci est une conséquence de l'architecture : `hostNetwork` partage le network namespace du **host**, mais Kata exécute le conteneur dans une **VM invitée** dont le network namespace est isolé. Les interfaces de l'hôte ne sont pas passées à la VM.

> **Note** : la [doc officielle](https://github.com/kata-containers/kata-containers/blob/main/docs/Limitations.md) avertit que `hostNetwork` avec Kata peut modifier et casser le réseau de l'hôte. En pratique avec Kubernetes et Cilium CNI, ce comportement n'a pas été observé — le pod démarre simplement sans réseau. L'avertissement concerne probablement le cas Docker/nerdctl où le runtime manipule directement les interfaces du namespace partagé.

Les applications qui dépendent de `hostNetwork` (load balancers, VIP, agents réseau) sont incompatibles avec Kata et doivent utiliser le runtime par défaut (`crun`).

> **Attention** : si un conteneur Kata partage le namespace réseau d'un conteneur `runc`, le runtime Kata prend le contrôle de toutes les interfaces réseau et les attache à la VM, causant la perte de connectivité du conteneur `runc` ([Limitations.md](https://github.com/kata-containers/kata-containers/blob/main/docs/Limitations.md)).

### Programmes eBPF

Le kernel de la micro-VM est distinct du kernel host. Les programmes eBPF chargés depuis un pod Kata s'exécutent dans le kernel de la VM et n'ont aucun effet sur le trafic ou les processus du node. Les applications qui chargent des programmes eBPF dans le kernel host ne peuvent donc pas tourner dans un pod Kata :

- **CNI** : Cilium, Calico (datapath eBPF) — ne peuvent pas fonctionner dans un pod Kata
- **Observabilité** : Tetragon, Falco, Kubescape — ne peuvent pas observer le host depuis un pod Kata
- **Load balancing** : XDP — inopérant dans une VM Kata

> **Note** : ces outils fonctionnent normalement sur le cluster tant qu'ils tournent sur l'hôte (DaemonSets avec le runtime par défaut `crun`). Un CNI Cilium ou Calico sur l'hôte gère le réseau des pods Kata sans problème — seule l'exécution **dans** un pod Kata est incompatible. De même, Tetragon/Falco sur l'hôte voient la VM comme un processus QEMU opaque mais ne peuvent pas observer les conteneurs à l'intérieur de la micro-VM.

### Configuration Cilium requise pour Kata

Quand Cilium est utilisé comme CNI avec `kubeProxyReplacement: true`, le socket-level loadbalancer intercepte les appels `connect()` et `sendmsg()` via eBPF. Avec Kata, ces syscalls se font dans le kernel de la VM (pas le kernel hôte), rendant le socket LB inefficace. Cilium doit retomber sur le tc loadbalancer au niveau du veth.

Configuration requise ([doc Cilium](https://docs.cilium.io/en/stable/network/kubernetes/kata/), [kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)) :

```yaml
socketLB:
  hostNamespaceOnly: true  # Désactive le socket LB dans les pods, retombe sur tc LB au veth
```

> **Note** : ce paramètre est appliqué automatiquement par `configure_cilium.sh` quand `features.containerRuntime.enabled: true` et `features.containerRuntime.provider: "kata"` dans `config/config.yaml`. Il est aussi activé quand Istio est utilisé (pour préserver le ClusterIP original avant redirection sidecar).

### Montages /proc et /sys

Les `hostPath` vers `/proc` et `/sys` exposent les données de la micro-VM et non celles du host (ex: 2 GB de RAM VM au lieu de 32 GB host, kernel Kata au lieu du kernel host). Seules 8 destinations spécifiques de bind mount sous `/proc` sont autorisées : `/proc/cpuinfo`, `/proc/meminfo`, `/proc/stat`, `/proc/diskstats`, `/proc/swaps`, `/proc/uptime`, `/proc/loadavg`, `/proc/net/dev` (restriction de sécurité liée à CVE-2019-16884).

Les agents de monitoring qui collectent des métriques node-level via ces pseudo-filesystems rapportent des données incorrectes (celles de la VM).

### volumeMounts.subPath

`volumeMounts.subPath` n'est pas officiellement supporté par Kata ([Limitations.md](https://github.com/kata-containers/kata-containers/blob/main/docs/Limitations.md)). En pratique, le comportement dépend du type de volume :

- **ConfigMaps / Secrets** : subPath **fonctionne** — le kubelet résout le sous-chemin sur l'hôte et crée un bind mount individuel avant de le passer à la VM via virtiofs
- **emptyDir** : subPath **échoue** — le fichier apparaît comme un répertoire dans le conteneur (`cat: read error: Is a directory`)

### Annotations par pod (désactivées par défaut)

Les annotations `io.katacontainers.config.hypervisor.default_memory` et `io.katacontainers.config.hypervisor.default_vcpus` permettent théoriquement de configurer la VM par pod. Cependant, le chart kata-deploy a `allowedHypervisorAnnotations: []` par défaut, ce qui **ignore** ces annotations. Pour les activer, il faut modifier la valeur `allowedHypervisorAnnotations` dans le chart.

> **Recommandation** : préférer les `customRuntimes` (drop-in TOML) plutôt que les annotations par pod. Les drop-in sont appliqués uniformément sur tous les nodes et ne dépendent pas de la configuration des annotations autorisées.

## Mode TEE (Confidential Computing)

En mode TEE (Intel TDX, AMD SEV-SNP, ARM CCA), la VM tourne dans une enclave chiffrée du CPU. Même l'hyperviseur et le host ne peuvent pas lire la mémoire de la VM.

Dans ce mode, Kata **désactive virtiofs** et copie les fichiers dans la VM au démarrage. Cela a des conséquences importantes :

| Aspect                   | Mode normal (sans TEE)           | Mode TEE (Confidential Computing)    |
| ------------------------ | -------------------------------- | ------------------------------------ |
| hostPath                 | Lecture/écriture live (virtiofs) | Fichiers copiés au démarrage         |
| Sync host → guest        | Temps réel                       | Aucune (snapshot au boot)            |
| Sync guest → host        | Temps réel                       | Aucune (modifications perdues)       |
| Confidentialite          | Host voit les données            | Host ne voit rien (mémoire chiffrée) |
| ConfigMap/Secret modifié | Visible immédiatement            | Nécessite un restart du pod          |

### Prérequis : snapshotter nydus

Les runtimes TEE et CoCo configurent `snapshotter = "nydus"` dans le handler containerd. Le snapshotter nydus permet de télécharger les images de conteneurs directement dans la VM guest (guest pull) sans passer par le host, préservant la confidentialité des données.

Runtimes **sans nydus** (fonctionnent immédiatement) :

- `kata-qemu`, `kata-qemu-runtime-rs`, `kata-clh`, `kata-cloud-hypervisor`, `kata-dragonball`, `kata-fc`
- Custom runtimes (`kata-qemu-minimal`, `kata-qemu-block-minimal`)

Runtimes **avec nydus** (requièrent configuration préalable) :

- `kata-qemu-coco-dev`, `kata-qemu-snp`, `kata-qemu-tdx`, `kata-qemu-se`, `kata-qemu-cca`
- Variantes `-runtime-rs` : `kata-qemu-snp-runtime-rs`, `kata-qemu-tdx-runtime-rs`, `kata-qemu-coco-dev-runtime-rs`, `kata-qemu-se-runtime-rs`
- `kata-remote`

Sans nydus installé, les pods utilisant ces runtimes échouent avec :

```
Failed to create pod sandbox: error unpacking image: snapshotter nydus was not found: not found
```

> **Note** : Activer `shims.qemu-coco-dev.enabled: true` dans le chart crée le handler containerd et la RuntimeClass, mais les pods ne démarreront pas sans le snapshotter nydus. Il faut configurer nydus **avant** d'utiliser ces runtimes.

### Matériel requis

Les runtimes TEE (`kata-qemu-snp`, `kata-qemu-tdx`) nécessitent du matériel compatible (CPU Intel avec TDX ou AMD avec SEV-SNP). Ils ne fonctionnent pas en nested virtualization. `kata-qemu-coco-dev` est une variante de test qui détecte automatiquement les extensions CPU disponibles et fallback sur un mode non-TEE si aucune n'est trouvée.

## Default RuntimeClass (Kyverno)

Lorsque `features.containerRuntime.defaultRuntimeClass` est configuré dans `config.yaml`, une ClusterPolicy Kyverno est déployée. Elle mute les pods qui ne spécifient pas de `runtimeClassName` pour leur injecter la valeur configurée.

### Activation

1. Configurer le feature flag dans `deploy/argocd/config/config.yaml` :

```yaml
features:
  containerRuntime:
    enabled: true
    provider: "kata"
    defaultRuntimeClass: "kata-qemu" # ou kata-clh, kata-dragonball, etc.
```

2. Labeler les namespaces où la mutation doit s'appliquer (opt-in) :

```bash
kubectl label ns my-app runtime-sandbox=enabled
```

### Comportement

- **Opt-in par namespace** : seuls les namespaces avec le label `runtime-sandbox: enabled` sont affectés
- **Pas d'écrasement** : les pods qui spécifient déjà un `runtimeClassName` ne sont pas modifiés
- **Désactivation** : mettre `defaultRuntimeClass: ""` pour ne pas déployér la ClusterPolicy

### Valeurs possibles pour defaultRuntimeClass

| Valeur                    | Hyperviseur              | Notes                                        |
| ------------------------- | ------------------------ | -------------------------------------------- |
| `kata-qemu`               | QEMU/KVM                 | Recommandé, compatibilité maximale           |
| `kata-clh`                | Cloud Hypervisor         | Performance, compatible nested virt          |
| `kata-cloud-hypervisor`   | Cloud Hypervisor (alias) | Identique à kata-clh                         |
| `kata-dragonball`         | Dragonball               | Experimental                                 |
| `kata-qemu-runtime-rs`    | QEMU runtime-rs          | Runtime Rust                                 |
| `kata-qemu-minimal`       | QEMU low-memory          | RAM réduite (256 MB), idéal dev/densité      |
| `kata-qemu-block-minimal` | QEMU low-memory + block  | Idem + block device passthrough pour PVC raw |

### Kyverno PolicyException

Le DaemonSet kata-deploy nécessite un ServiceAccount token pour accéder à l'API Kubernetes. Une PolicyException est automatiquement déployée (conditionnée par `features.kyverno.enabled`) pour exempter le namespace `kata-containers` de la ClusterPolicy `disable-automount-sa-token`.

### Pod Security Admission

Le namespace `kata-containers` nécessite le mode PSA `privileged` car le DaemonSet kata-deploy utilise `hostPID`, des volumes `hostPath` et des conteneurs privilégiés. Un fichier `namespace.yaml` avec les labels PSA adéquats doit être inclus quand `rke2.cis.enabled: true`.

## Troubleshooting

### Vérifier l'installation

```bash
# Status du DaemonSet
kubectl get ds -n kata-containers

# Logs du DaemonSet kata-deploy
kubectl logs -n kata-containers -l name=kata-deploy

# Vérifier les binaires installés sur un node
kubectl debug node/<node-name> -it --image=busybox -- ls -la /host/opt/kata/

# Vérifier la compatibilité Kata sur un node
kubectl debug node/<node-name> -it --image=busybox -- \
  chroot /host /opt/kata/bin/kata-runtime check
# Attendu : "System is capable of running Kata Containers"
```

### Problèmes courants

#### Pod bloqué en "ContainerCreating"

```bash
# Vérifier les events
kubectl describe pod <pod-name>

# Vérifier si KVM est disponible sur le node
kubectl debug node/<node-name> -it --image=busybox -- ls -la /host/dev/kvm
```

Causes possibles :

- `/dev/kvm` non disponible (nested virt non activée)
- RuntimeClass inexistante
- Binaires Kata non installés sur le node
- **Snapshotter nydus manquant** : les runtimes TEE/CoCo (`qemu-coco-dev`, `qemu-snp`, `qemu-tdx`, etc.) configurent `snapshotter = "nydus"` dans containerd. Si nydus n'est pas installé, l'erreur est `snapshotter nydus was not found: not found`. Voir la section [Mode TEE > Prérequis : snapshotter nydus](#prerequis--snapshotter-nydus)

#### RuntimeClass non trouvée

```bash
# Lister les RuntimeClasses
kubectl get runtimeclass

# Vérifier le status de l'installation
kubectl get pods -n kata-containers -o wide
```

### Logs et debugging

```bash
# Logs du runtime sur un node
kubectl debug node/<node-name> -it --image=busybox -- \
  cat /host/opt/kata/share/defaults/kata-containers/configuration.toml

# Activer le mode debug (modifier config/dev.yaml)
kataContainers:
  debug: true
```

## Références

- [Kata Containers Documentation](https://katacontainers.io/docs/)
- [Kata Deploy Helm Chart](https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy/helm-chart)
- [RuntimeClass Kubernetes](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- [Kata Limitations](https://github.com/kata-containers/kata-containers/blob/main/docs/Limitations.md)
- [Kata Hypervisors Comparison](https://github.com/kata-containers/kata-containers/blob/main/docs/hypervisors.md)
