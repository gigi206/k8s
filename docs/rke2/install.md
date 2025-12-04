# RKE2

## Installation

### Selinux

Cf https://docs.rke2.io/install/airgap#tarball-method

**Note:** tested with SELinux set to `permissive` mode.

#### Cgroups V2

For old systems like CentOS7 that are not compatible avec cgroups V2:

- edit `/etc/default/grub`, and add to the end of `GRUB_CMDLINE_LINUX` the string `systemd.unified_cgroup_hierarchy=0`:

```
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="rd.lvm.lv=centos/root rd.lvm.lv=centos/swap rhgb quiet systemd.unified_cgroup_hierarchy=0"
GRUB_DISABLE_RECOVERY="true"
```

- Apply change and reboot:

```shell
grub2-mkconfig -o /boot/grub2/grub.cfg
reboot
```

#### Disable interfaces from NetworkManager

To disable interfaces managed by `canal`, create the file `/etc/NetworkManager/conf.d/rke2-canal.conf`:

```ini
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*
```

Reload `NetworkManager` service:

```shell
systemctl reload NetworkManager
```

#### Download rke2

Download RKE2 archives:

```shell
RKE2_VERSION=v1.30.1%2Brke2r1
mkdir /root/rke2-artifacts && cd /root/rke2-artifacts/
wget https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2-images.linux-amd64.tar.zst
wget https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2.linux-amd64.tar.gz
wget https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/sha256sum-amd64.txt
curl -sfL https://get.rke2.io --output install.sh
```

##### Offline install RKE2 (tarball Airgap)

Install RKE2:

```shell
INSTALL_RKE2_ARTIFACT_PATH=/root/rke2-artifacts sh install.sh
```

#### Configuration for RKE2

```shell
mkdir -p /etc/rancher/rke2
echo "disable:
- rke2-ingress-nginx
write-kubeconfig-mode: "0644"
tls-san:
- k8s-api.k8s.lan
- 192.168.121.200
# debug:true
etcd-expose-metrics: true" \
>> /etc/rancher/rke2/config.yaml
```

#### Start rke2

Enable `rke2-server` service and start it:

```shell
systemctl enable --now rke2-server.service
```
