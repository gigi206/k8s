# Shutdown a node

## Shutdown script

To shutdown a node:
```bash
#!/usr/bin/env bash
kubectl drain ${HOSTNAME} --delete-emptydir-data --grace-period=-1 --ignore-daemonsets=true --force=false --timeout=60s
kubectl drain ${HOSTNAME} --delete-emptydir-data --grace-period=-1 --ignore-daemonsets=true --disable-eviction --force=true
# kubectl get pods --field-selector status.phase=Running -n longhorn-system -o name | awk -F'/' '{print $2}' | xargs kubectl -n longhorn-system delete pod
/usr/local/bin/rke2-killall.sh
umount /var/lib/longhorn # && shutdown -h now
```

After rebooting the node, you need to `uncordon` the node:
```bash
#!/usr/bin/env bash
kubectl uncordon ${HOSTNAME}
```