# Teleport
* https://charts.releases.teleport.dev/
* https://goteleport.com/docs/kubernetes-access/introduction/
* https://youtu.be/xdizlpIdrYw?t=1270

# CE vs Enterprise
https://goteleport.com/docs/choose-an-edition/introduction/

# teleport-cluster
Cf https://github.com/gravitational/teleport/tree/master/examples/chart/teleport-cluster

Create the `admin` user:
```bash
kubectl exec -it -n teleport deployments/teleport-auth -- tctl users add admin --roles=editor,auditor,access
User "admin" has been created but requires a password. Share this URL with the user to complete user setup, link is valid for 1h:
https://teleport.gigix:443/web/invite/af05d976e290b522510bf471f7c3276c
```

# teleport-kube-agent
Cf https://github.com/gravitational/teleport/tree/master/examples/chart/teleport-kube-agent