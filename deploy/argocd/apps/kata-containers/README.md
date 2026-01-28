# Kata Containers

Kata Containers fournit une isolation hardware pour les conteneurs via des micro-VMs legeres. Chaque conteneur Kata s'execute dans sa propre machine virtuelle avec un kernel dedie, offrant une isolation similaire aux VMs traditionnelles tout en conservant la vitesse et la simplicite des conteneurs.

## Prerequisites

### Hardware

- **Virtualisation materielle** : Les nodes doivent supporter Intel VT-x ou AMD-V
- **KVM disponible** : `/dev/kvm` doit exister sur les nodes
- **Nested virtualization** : Requise si le cluster tourne dans des VMs

Verification sur un node :
```bash
# Verifier le support KVM
ls -la /dev/kvm

# Verifier la virtualisation nested (si dans une VM)
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

Dans les parametres de la VM :
- Processors > Cocher `Virtualize Intel VT-x/EPT or AMD-V/RVI`

#### KVM / libvirt (hote Linux)

Verifier que le module est charge avec nested=Y :
```bash
# Intel
cat /sys/module/kvm_intel/parameters/nested  # Doit afficher Y ou 1

# AMD
cat /sys/module/kvm_amd/parameters/nested

# Activer si necessaire
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

Le Vagrantfile inclut deja la configuration pour la nested virtualization :
```ruby
config.vm.provider :libvirt do |libvirt|
  libvirt.nested = true
  libvirt.cpu_mode = "host-passthrough"
end
```

> **Important** : Ces parametres Vagrant ne fonctionnent que si l'hyperviseur parent
> a la nested virtualization activee (voir section precedente).

## Architecture

### Composants deployes

1. **kata-deploy DaemonSet** : Installe les binaires Kata sur chaque node (`/opt/kata/`)
2. **RuntimeClasses** : Classes de runtime Kubernetes pour utiliser Kata
3. **Shims (handlers)** : Differents hyperviseurs supportes

### Shims disponibles

| Shim | Description | Utilisation |
|------|-------------|-------------|
| `kata-qemu` | QEMU/KVM (recommande) | Production, compatibilite maximale |
| `kata-clh` | Cloud Hypervisor | Performance, footprint reduit |
| `kata-fc` | Firecracker | Serverless, demarrage ultra-rapide |
| `kata-dragonball` | Dragonball (Rust) | Experimental |

## Configuration

### Parametres disponibles

```yaml
kataContainers:
  version: "3.25.0"           # Version du chart Helm
  k8sDistribution: "rke2"     # Distribution K8s (rke2, k8s, k3s)
  debug: false                # Mode debug
  createDefaultRuntimeClass: false  # Ne pas creer de classe par defaut
  shims:
    qemu:
      enabled: true           # QEMU/KVM (recommande pour nested virt)
    clh:
      enabled: false          # Cloud Hypervisor (bare-metal uniquement)
    fc:
      enabled: false          # Firecracker
    dragonball:
      enabled: false          # Dragonball (experimental)
```

> **Note**: Cloud Hypervisor (`clh`) ne fonctionne pas en nested virtualization (VMs Vagrant).
> Utilisez `kata-qemu` pour les environnements dev/nested.

### RuntimeClasses creees

Une fois deploye, les RuntimeClasses suivantes sont disponibles (selon les shims actives) :

```bash
kubectl get runtimeclass
```

| RuntimeClass | Handler | Description | Active par defaut |
|--------------|---------|-------------|-------------------|
| `kata-qemu` | `kata-qemu` | QEMU avec KVM | Oui |
| `kata-clh` | `kata-clh` | Cloud Hypervisor | Non |
| `kata-fc` | `kata-fc` | Firecracker | Non |
| `kata-dragonball` | `kata-dragonball` | Dragonball | Non |

## Utilisation

### Deployer un Pod avec Kata

Specifiez `runtimeClassName` dans votre Pod :

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-kata
spec:
  runtimeClassName: kata-qemu  # QEMU/KVM (recommande)
  containers:
   - name: nginx
      image: nginx:alpine
      ports:
       - containerPort: 80
```

### Verification de l'isolation

```bash
# Creer un pod Kata
kubectl run test-kata --image=nginx --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"kata-qemu"}}'

# Verifier le kernel (doit etre different du host)
kubectl exec test-kata -- uname -a

# Comparer avec un pod standard
kubectl run test-standard --image=nginx --restart=Never
kubectl exec test-standard -- uname -a

# Nettoyer
kubectl delete pod test-kata test-standard
```

Le pod Kata affichera un kernel different (ex: `5.15.x kata`) tandis que le pod standard utilisera le kernel du node.

### Cas d'usage recommandes

| Cas d'usage | RuntimeClass recommandee |
|-------------|--------------------------|
| Workloads non fiables | `kata-qemu` |
| Multi-tenancy securise | `kata-qemu` |
| Nested virtualization | `kata-qemu` |
| CI/CD builds isoles | `kata-qemu` |
| Bare-metal (performance) | `kata-clh` |

> **Note**: Seul `kata-qemu` est active par defaut. Pour d'autres shims, modifiez `config/dev.yaml`.

## Troubleshooting

### Verifier l'installation

```bash
# Status du DaemonSet
kubectl get ds -n kata-containers

# Logs du DaemonSet kata-deploy
kubectl logs -n kata-containers -l name=kata-deploy

# Verifier les binaires installes sur un node
kubectl debug node/<node-name> -it --image=busybox -- ls -la /host/opt/kata/
```

### Problemes courants

#### Pod bloque en "ContainerCreating"

```bash
# Verifier les events
kubectl describe pod <pod-name>

# Verifier si KVM est disponible sur le node
kubectl debug node/<node-name> -it --image=busybox -- ls -la /host/dev/kvm
```

Causes possibles :
- `/dev/kvm` non disponible (nested virt non activee)
- RuntimeClass inexistante
- Binaires Kata non installes sur le node

#### RuntimeClass non trouvee

```bash
# Lister les RuntimeClasses
kubectl get runtimeclass

# Verifier le status de l'installation
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

## References

- [Kata Containers Documentation](https://katacontainers.io/docs/)
- [Kata Deploy Helm Chart](https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy/helm-chart)
- [RuntimeClass Kubernetes](https://kubernetes.io/docs/concepts/containers/runtime-class/)
