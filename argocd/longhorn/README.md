# Longhorn

## Dependencies
* [csi-external-snapshotter](argocd/csi-external-snapshotter/csi-external-snapshotter.yaml) (required by longhorn)
* [prometheus-stack](argocd/prometheus-stack/prometheus-stack.yaml) (required for the monitoring)

## Requirements
You can run the script `install-requirements.sh` to install all the requirements describe below.

### iscsi
Doc: https://longhorn.io/docs/1.3.0/advanced-resources/os-distro-specific/csi-on-k3s/#requirements

The installation of `open-iscsi` or `iscsiadm` are required:
```bash
apt install -y open-iscsi
systemctl enable --now iscsid.service
```

### CSI snapshot
Doc: https://longhorn.io/docs/1.3.0/snapshots-and-backups/csi-snapshot-support/enable-csi-snapshot-support/#if-your-kubernetes-distribution-does-not-bundle-the-snapshot-controller

Install [csi-external-snapshotter](/argocd/csi-external-snapshotter/csi-external-snapshotter.yaml)

And apply:
```yaml
kind: VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
metadata:
  name: longhorn
driver: driver.longhorn.io
deletionPolicy: Delete
```

### Monitoring
To enable the monitoring:
```
kubectl apply -f prometheus.yaml
```

And import the [grafana longhorn dashboard](https://grafana.com/grafana/dashboards/13032) (id 13032).
