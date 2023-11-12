# K8S / Container
## Container
### BUILD
- [Kaniko](https://github.com/GoogleContainerTools/kaniko)
  - [Youtube](https://www.youtube.com/watch?v=mCesuGk-Fks)
- [Kim](https://github.com/rancher/kim)
- [Buildah](https://buildah.io)
- [Skaffold](https://skaffold.dev)
  - [Youtube](https://www.youtube.com/watch?v=qS_4Qf8owc0)
- [Shipwright](https://shipwright.io)
  - [Github](https://github.com/shipwright-io/build)
  - [Youtube](https://www.youtube.com/watch?v=tqsSQTewcwM)

### Manage
- [Skopeo](https://github.com/containers/skopeo)

### Inspect
- [Dive](https://github.com/wagoodman/dive)

## Kubernets
### Installation
- [Kubespray](https://github.com/kubernetes-sigs/kubespray)
- [Minikube](https://github.com/kubernetes/minikube)
- [K3d](https://k3d.io/)
  - [Github](https://github.com/rancher/k3d)
  - [Youtube](https://www.youtube.com/watch?v=mCesuGk-Fks)
- [K3s](https://k3s.io/)
  - [Github](https://github.com/k3s-io/k3s/blob/master/README.md)
- [RKE](https://rancher.com/docs/rke/latest/en/)
  - [Github](https://github.com/rancher/rke)
- [RKE2](https://docs.rke2.io/)
  - [Github](https://github.com/rancher/rke2)
- [Kind](https://kind.sigs.k8s.io/)
  - [Github](https://github.com/kubernetes-sigs/kind)
  - [Youtube](https://www.youtube.com/watch?v=C0v5gJSWuSo)
- [Crossplane](https://www.crossplane.io) (UI: [Komoplane](https://github.com/komodorio/komoplane))
  - [Github](https://github.com/crossplane/crossplane)
  - [Youtube](https://www.youtube.com/watch?v=yrj4lmScKHQ)
- [Cluster API](https://cluster-api.sigs.k8s.io) (CAPI)
  - [Github](https://github.com/kubernetes-sigs/cluster-api)
  - [Youtube](https://www.youtube.com/watch?v=8yUDUhZ6ako)

### Hardening
- [Fortifying Kubernetes with Strace, Falco, AppArmor, and Seccomp](https://medium.com/@seifeddinerajhi/securing-kubernetes-a-comprehensive-guide-to-runtime-security-and-system-hardening-33f5a5328f1)

### Monitoring
- [Prometheus](https://prometheus.io)
  - [Youtube](https://www.youtube.com/watch?v=h4Sl21AKiDg)
  - [Github](https://github.com/prometheus-community)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/prometheus-community/prometheus)
  - [Tuto](https://blog.ineat-group.com/2020/05/prometheus-operator-dans-kubernetes)
  <!-- - [Operator](https://artifacthub.io/packages/olm/community-operators/prometheus) -->
  <!-- - [Operator](https://operatorhub.io/operator/prometheus) -->
- [metrics-server](https://github.com/kubernetes-sigs/metrics-server)
  - [Youtube](https://www.youtube.com/watch?v=WVxK1k_blPQ&list=PL34sAs7_26wNBRWM6BDhnonoA5FMERax0&index=67)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/metrics-server/metrics-server)

### Logging
To DO

### Secrets
- [Kubeseal](https://github.com/bitnami-labs/sealed-secrets)
  - [Youtube](https://www.youtube.com/watch?v=xd2QoV6GJlc)
- [Sops](https://github.com/mozilla/sops)
  - [Tuto](https://itnext.io/goodbye-sealed-secrets-hello-sops-3ee6a92662bb#8f5b)
- [external-secrets](https://external-secrets.io)
  - [Youtube](https://www.youtube.com/watch?v=PgiXKBTel1E)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/external-secrets-operator/external-secrets)
  - [Github](https://github.com/external-secrets/external-secrets)
  - [Operator](https://operatorhub.io/operator/external-secrets-operator)
- [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io) (SSCSID)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/secret-store-csi-driver/secrets-store-csi-driver)
  - [Github](https://github.com/kubernetes-sigs/secrets-store-csi-driver)
  - [Youtube](https://www.youtube.com/watch?v=DsQu66ZMG4M)
- [Infisical](https://infisical.com/)
  - [Medium](https://mrdevops.medium.com/infisical-open-source-secretops-apply-it-using-gitops-approach-245f57fcd67e)

### Events
- [Argo Events](https://argoproj.github.io/argo-events/)
  - [Github](https://github.com/argoproj/argo-events)
  - [Youtube](https://www.youtube.com/watch?v=sUPkGChvD54)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/argo/argo-events)

### Continuous Integration (CI)
- [Argo Workflows](https://argoproj.github.io/argo-workflows/)
  - [Github](https://github.com/argoproj/argo-workflows)
  - [Youtube](https://www.youtube.com/watch?v=UMaivwrAyTA)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/argo/argo-events)

### Continuous Delivery (CD)
- [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)
  - [Youtube](https://www.youtube.com/watch?v=avPUQin9kzU)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/argo/argo-cd)
  - [Operator](https://operatorhub.io/operator/argocd-operator)
- [ArgoCD Image Updater](https://argocd-image-updater.readthedocs.io/en/stable/)
    - [Github](https://github.com/argoproj-labs/argocd-image-updater)
    - [ArtifactHUB](https://artifacthub.io/packages/helm/argo/argocd-image-updater)
- [Flux](https://fluxcd.io/)
  - [Github](https://github.com/fluxcd/flux)
  - [Operator](https://artifacthub.io/packages/olm/community-operators/flux)
  - [Operator](https://operatorhub.io/operator/flux)
- [Fleet](https://fleet.rancher.io) (Rancher)
  - [Github](https://github.com/rancher/fleet/)
  - [Youtube](https://www.youtube.com/watch?v=rIH_2CUXmwM)

### CI/CD
- [Tekton](https://tekton.dev/)
  - [Github](https://github.com/tektoncd/pipeline)
  - [Youtube](https://www.youtube.com/watch?v=7mvrpxz_BfE)
  - [Operator](https://artifacthub.io/packages/olm/community-operators/tektoncd-operator)
  - [Operator](https://operatorhub.io/operator/tektoncd-operator)
  - [Tekton dashboard](https://tekton.dev/docs/dashboard/)
    - [Github](https://github.com/tektoncd/dashboard)
- [Jenkins X](https://jenkins-x.io/)
- [Devtron](https://devtron.ai/)
  - [Github](https://github.com/devtron-labs/devtron)
  - [Youtube](https://www.youtube.com/watch?v=ZKcfZC-zSMM)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/devtron/devtron-generic-helm)
  - [Operator](https://artifacthub.io/packages/helm/devtron/devtron-operator)

### Progressive Delivery
- [Argo Rollouts](https://argoproj.github.io/rollouts/)
  - [Github](https://github.com/argoproj/argo-rollouts)
  - [Youtube](https://www.youtube.com/watch?v=84Ky0aPbHvY)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/argo/argo-rollouts)
- [Flagger](https://flagger.app)
  - [Github](https://github.com/fluxcd/flagger)
  - [Youtube](https://www.youtube.com/watch?v=NrytqS43dgw)

### Identity and Access Management (IAM)
- [Keycloak](https://www.keycloak.org)
  - [Github](https://github.com/keycloak/keycloak)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/bitnami/keycloak)
  - [Operator](https://artifacthub.io/packages/olm/community-operators/keycloak-operator)
  - [Operator](https://operatorhub.io/operator/keycloak-operator)
  - [Medium](https://kvaps.medium.com/adding-ldap-authentication-to-kubernetes-5c1f894a5a98)

### Certificates
- [cert-manager](https://cert-manager.io/docs/installation/supported-releases/)
  - [Github](website/edit/master/content/en/docs/installation/supported-releases.md)
  - [Youtube](https://www.youtube.com/watch?v=7m4_kZOObzw)
  - [Youtube](https://www.youtube.com/watch?v=hoLUigg4V18)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/cert-manager/cert-manager)
  - [Operator](https://artifacthub.io/packages/olm/community-operators/cert-manager)
  - [Operator](https://operatorhub.io/operator/cert-manager)

### API Gateway
- [Ambassador](https://www.getambassador.io)
  - [Github](https://github.com/emissary-ingress/emissary)

### Ingress
- [Voyager](https://voyagermesh.com/) (based on HAProxy)
  - [Community vs enterprise](https://voyagermesh.com/pricing/)
  - [Documentation](https://voyagermesh.com/docs/v2022.12.11/guides/ingress/)
- [Kong](https://docs.konghq.com/gateway/3.4.x/install/kubernetes/helm-quickstart/)
  - [Annotations](https://docs.konghq.com/kubernetes-ingress-controller/latest/references/annotations/)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/kong/kong)
  - [Medium](https://medium.com/btech-engineering/ingress-controller-with-kong-alternative-way-ingress-instead-nginx-fca202459ac0)

### S3
- [MinIO](https://docs.min.io/)
  - [Github](https://github.com/minio/minio)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/minio/minio)
  - [Operator](https://artifacthub.io/packages/olm/community-operators/minio-operator)
  - [Operator](https://operatorhub.io/operator/minio-operator)

### Storage class
- [Longhorn](https://longhorn.io/)
  - [Github](https://github.com/longhorn/longhorn)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/longhorn/longhorn)
  - [Youtube](https://www.youtube.com/watch?v=SDI9Tly5YDo&t=2s)
- [TopoLVM](https://github.com/topolvm/topolvm)
  - [Operator](https://operatorhub.io/operator/topolvm-operator)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/topolvm/topolvm)

### Backup
- [Velero](https://velero.io/)
  - [Github](https://github.com/vmware-tanzu/velero)
  - [Youtube](https://www.youtube.com/watch?v=C9hzrexaIDA&list=PL34sAs7_26wNBRWM6BDhnonoA5FMERax0&index=79)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/vmware-tanzu/velero)

### Policy engine (admission controller)
- [Gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/docs/howto/) (Open Policy Agent (OPA))
  - [Github](https://github.com/open-policy-agent/gatekeeper)
  - [Youtube](https://www.youtube.com/watch?v=14lGc7xMAe4)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/gogatekeeper/gatekeeper)
- [Kyverno](https://kyverno.io/)
  - [Github](https://github.com/kyverno/kyverno)
  - [Youtube](https://www.youtube.com/watch?v=DREjzfTzNpA)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/kyverno/kyverno)
- [kubewarden](https://www.kubewarden.io)
- [jsPolicy](https://www.jspolicy.com)
  - [Github](https://github.com/loft-sh/jspolicy)
  - [Youtube](https://www.youtube.com/watch?v=s7dt27pMchk)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/loft/jspolicy)

### Scanner
- [Trivy](https://aquasecurity.github.io/trivy/v0.29.2/)
  - [Github](https://github.com/aquasecurity/trivy)
  - [Youtube](https://www.youtube.com/watch?v=bgYrhQ6rTXA)
  - [Artifactory](https://artifacthub.io/packages/helm/devopstales/trivy-operator)

### Manifest validation
 - [Datree](https://datree.io/)
   - [Github](https://github.com/datreeio/datree)
   - [Youtube](https://youtu.be/3jZTqCETW2w)

### Open Application Model (OAM)
- [KubeVela](https://kubevela.io/)
  - [Github](https://github.com/oam-dev/kubevela)
  - [Youtube](https://www.youtube.com/watch?v=2CBu6sOTtwk)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/kubevela/vela-core)

### Service Mesh
- [Istio](https://istio.io/)
  - [Github](https://github.com/istio/istio)
  - [Youtube](https://www.youtube.com/playlist?list=PL34sAs7_26wPkw9g-5NQPP_rHVzApGpKP)
- [Linkerd](https://linkerd.io/)
  - [Github](https://github.com/linkerd/linkerd2)
  - [Youtube](https://www.youtube.com/watch?v=-7KjZGpqHOg) / [Github](https://github.com/isItObservable/Linkerd)
  - [Youtube](https://www.youtube.com/watch?v=Hc-XFPHDDk4)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/linkerd2/linkerd2)

### Autoprovisionning DNS
- [External-dns](https://github.com/kubernetes-sigs/external-dns)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/external-dns/external-dns)

### Cost
- [Kubecost](https://www.kubecost.com/)
  - [Github](https://github.com/kubecost/kubectl-cost)

### Multi-tenant
- [Loft](https://loft.sh)
  - [Github](https://github.com/loft-sh/loft)
  - [Youtube](https://www.youtube.com/watch?v=tt7hope6zU0)
- [Capsule](https://github.com/clastix/capsule)
  - [Youtube](https://www.youtube.com/watch?v=H8bzEJN7fj8)
  - [Artifactory](https://artifacthub.io/packages/helm/capsule/capsule)

### Kubernetest in kubernetes
- [Vcluster](https://www.vcluster.com/) By Loft
  - [Github](https://github.com/loft-sh/vcluster)
  - [Youtube](https://www.youtube.com/watch?v=JqBjpvp268Y)

### Security
- [Snyk](https://snyk.io)
  - [Youtube](https://www.youtube.com/watch?v=iri7Nv0k13g)

#### Pentest
- [Kubescape](https://www.armosec.io/armo-kubescape)
  - [Github](https://github.com/armosec/kubescape)
  - [Youtube](https://www.youtube.com/watch?v=ZATGiDIDBQk)

### Autoscaling
- [Keda](https://keda.sh)
  - [Youtube](https://www.youtube.com/watch?v=8KuA5fsT0e0)
- [Knative](https://knative.dev/docs/)
  - [Github](https://github.com/knative/operator)
  - [Youtube](https://www.youtube.com/watch?v=HZIKQwwSRXc)

### Application As Code (AaC)
- [Shipa](https://shipa.io)
  - [Youtube](https://www.youtube.com/watch?v=PW44JaAlI_8)
  - [Youtube](https://www.youtube.com/watch?v=aCwlI3AhNOY)
  - [Youtube](https://www.youtube.com/watch?v=_f8QfKx4rws)
- [Ketch](https://www.theketch.io) by Shipa
  - [Github](https://github.com/theketchio/ketch)
  - [Youtube](https://www.youtube.com/watch?v=sMOIiTfGnj0)
- [Devspace](https://devspace.sh)
  - [Github](https://github.com/loft-sh/devspace)
  - [Youtube](https://www.youtube.com/watch?v=nQly_CEjJc4)

### Performance testing
- [K6s](https://k6.io/)
  - [Github](https://github.com/grafana/k6)
  - [Youtube](https://www.youtube.com/watch?v=5OgQuVAR14I)

### Databases
#### PostgreSQL
- [Cloudnative-pg](https://cloudnative-pg.io)
  - [ArtifactHUB](https://artifacthub.io/packages/helm/cloudnative-pg/cloudnative-pg)
  - [Github](https://github.com/cloudnative-pg/cloudnative-pg)
  - [Medium](https://8grams.medium.com/cloud-native-postgresql-install-scalable-postgresql-distribution-on-kubernetes-bbfa6c877dde)

#### Multi-databases
- [KubeDB](https://kubedb.com/) (allow to manage PostgreSQL, Elasticsearch, MySQL, MongoDB, Redis, Memcache, ...)
  - [Community VS Enterprise](https://kubedb.com/pricing/)
  - [Home](https://kubedb.com)
  - [Documentation](https://kubedb.com/docs/v2022.10.18/welcome/)

## Tools
- [Lens](https://k8slens.dev)
- [K9s](https://k9scli.io)
  - [Github](https://github.com/derailed/k9s)
- [Kubens/kubectx](https://github.com/ahmetb/kubectx/blob/master/kubens)
- [Kail](https://github.com/boz/kail/releases)
- [Kustomize](https://github.com/kubernetes-sigs/kustomize)


## Others
- [Rancher desktop](https://github.com/rancher-sandbox/rancher-desktop)
