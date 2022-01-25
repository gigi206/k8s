# RKE 2

# Documentation

https://docs.rke2.io/backup_restore/

## Backup

```bash
rke2 etcd-snapshot save --name pre-upgrade-snapshot
```

## Restore

```bash
curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_VERSION=v1.24.2+rke2r1 sh -
rke2 server \
  --cluster-reset \
  --cluster-reset-restore-path=<PATH-TO-SNAPSHOT> --token <token used in the original cluster>
rke2-killall.sh
systemctl enable rke2-server
systemctl start rke2-server
```