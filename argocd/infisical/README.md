# Infisical
## secrets-operator
* [Infisical Open Source SecretOps: Apply it using GitOps approach](https://mrdevops.medium.com/infisical-open-source-secretops-apply-it-using-gitops-approach-245f57fcd67e)
* Example of CRD `InfisicalSecret` deployed by the `secrets-operator`:
```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
name: infisical-demo
namespace: infisical-demo
spec:
hostAPI: http://infisical-backend.infisical.svc.cluster.local:4000/api
resyncInterval: 10
authentication:
    serviceToken:
    serviceTokenSecretReference:
        secretName: infisical-secret         #Secret that has our token
        secretNamespace: infisical-demo
    secretsScope:
        envSlug: dev
        secretsPath: "/"
managedSecretReference:
    secretName: infisical-ui-managed-secret   #Secret that will be generated
    secretNamespace: infisical-demo
```