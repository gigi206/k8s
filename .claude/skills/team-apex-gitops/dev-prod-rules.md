# Regles dev.yaml vs prod.yaml

Toujours creer dev.yaml ET prod.yaml avec les differences suivantes :

| Parametre | dev.yaml | prod.yaml |
|---|---|---|
| replicas | 1 (single instance) | 2-3+ (HA) |
| resources.requests | Minimal (cpu: 10m-50m, mem: 64Mi-256Mi) | Adapte a la charge (cpu: 200m+, mem: 512Mi+) |
| resources.limits | Raisonnables | 2-4x les requests |
| storageSize | Minimal (5Gi) | Production (20Gi+) |
| podAntiAffinity | Non requis (1 seul noeud dev) | Requis si replicas>1 : preferredDuringSchedulingIgnoredDuringExecution sur kubernetes.io/hostname |
| topologySpreadConstraints | Non requis | Recommande si replicas>=3 : maxSkew: 1, topologyKey: kubernetes.io/hostname |

## Checklist QA dev/prod

- [ ] dev: replicas=1, prod: replicas>=2 (HA)
- [ ] dev: resources minimales, prod: resources adaptees a la charge
- [ ] prod avec replicas>1: podAntiAffinity sur kubernetes.io/hostname present
- [ ] prod avec replicas>=3: topologySpreadConstraints recommande
- [ ] prod: storageSize suffisant (pas copie depuis dev)
