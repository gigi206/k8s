# Matrice d'impact cross-applications

Avant de coder, identifier TOUTES les applications impactees par le changement.
Utiliser Grep pour scanner les dependances croisees.

| Domaine modifie | Apps impactees | Comment trouver |
|---|---|---|
| gatewayAPI.controller.provider | Apps avec kustomize/httproute/, kustomize/apisix/, kustomize/gateway/ | Grep "gatewayAPI\|httpRoute\|ApisixRoute\|Gateway" dans apps/*/applicationset.yaml |
| cni.primary (cilium<>calico) | Apps avec network policies | Grep "cni.primary\|cilium.*policy\|calico.*policy" dans apps/*/applicationset.yaml |
| storage.provider (longhorn<>rook) | Apps avec PVC/StorageClass | Grep "storage\.\|storageClass\|persistentVolume" dans apps/*/applicationset.yaml |
| features.sso.provider | Apps avec kustomize/sso/, secrets/ | Grep "sso\.\|keycloak\|oauth" dans apps/*/applicationset.yaml |
| features.monitoring | Apps avec kustomize/monitoring/ | ls apps/*/kustomize/monitoring/ |
| features.loadBalancer.provider | metallb, cilium, loxilb, kube-vip + staticIPs | Grep "loadBalancer\|staticIP\|L2\|BGP" dans apps/*/applicationset.yaml |
| common.domain | Apps avec ingress/HTTPRoute/hostname | Grep "common.domain\|\.domain\|hostname" dans apps/*/applicationset.yaml |
| features.serviceMesh | istio, istio-gateway + sidecar/waypoint | Grep "serviceMesh\|istio\|waypoint" dans apps/*/applicationset.yaml |
| features.networkPolicy.* | Apps avec *-policy.yaml dans resources/ | ls apps/*/resources/*-policy.yaml |
| Helm chart d'un provider | Apps consommatrices (HTTPRoutes, Gateway refs) | Grep namespace/gatewayClassName dans apps/*/ |

## Processus

a) Execute les Grep pertinents pour identifier les apps impactees
b) Liste TOUTES les apps touchees dans ton message au QA
c) Si >3 apps impactees, le mentionner explicitement dans ton message au QA
d) Modifie dev.yaml ET prod.yaml de CHAQUE app impactee
