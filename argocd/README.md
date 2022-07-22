# Install the requirements

1. Install [argocd](argocd/argocd)
2. Install [metallb](argocd/metallb) (installed by argocd) / or [kubevip](argocd/kubevip) + [kubevip-cloud-provider](argocd/kubevip-cloud-provider)
3. Install [cert-manager](argocd/cert-manager) (installed by argocd)
4. Install [ingress-nginx](argocd/ingress-nginx) (installed by argocd)
5. Install [kubevip](argocd/kubevip) (if [metallb](argocd/metallb))
6. Install [external-dns](argocd/external-dns)
7. Install [powerdns](argocd/powerdns) (installed by external-dns)
8. Install [longhorn](argocd/longhorn)

# Grow the VM disk

```bash
mkdir -p /home/kvm/vagrant/vagrantfiles/k8s/git
cd /home/kvm/vagrant/vagrantfiles/k8s/git
git clone https://github.com/gigi206/k8s .
cd ..
ln -s git/rke2/Vagrantfile .
```

```bash
virsh -c qemu:///system domblklist k8s-m1
 Target   Source
------------------------------------
 vda      /home/kvm/vms/k8s-m1.img
```

```bash
sudo qemu-img info /home/kvm/vms/k8s-m1.img
image: /home/kvm/vms/k8s-m1.img
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 10.8 GiB
cluster_size: 65536
backing file: /home/kvm/vms/debian-VAGRANTSLASH-bullseye64_vagrant_box_image_11.20220328.1_box.img
backing file format: qcow2
Format specific information:
    compat: 0.10
    compression type: zlib
    refcount bits: 16
```

```bash
sudo qemu-img resize /home/kvm/vms/k8s-m1.img +30G
Image resized.
```

```bash
sudo qemu-img info /home/kvm/vms/k8s-m1.img
image: /home/kvm/vms/k8s-m1.img
file format: qcow2
virtual size: 50 GiB (53687091200 bytes)
disk size: 10.8 GiB
cluster_size: 65536
backing file: /home/kvm/vms/debian-VAGRANTSLASH-bullseye64_vagrant_box_image_11.20220328.1_box.img
backing file format: qcow2
Format specific information:
    compat: 0.10
    compression type: zlib
    refcount bits: 16
```

```bash
vagrant up k8s-m1
```

```bash
virsh -c qemu:///system blockresize k8s-m1 /home/kvm/vms/k8s-m1.img 50G
Block device '/home/kvm/vms/k8s-m1.img' is resized
```

```bash
lsblk
NAME   MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
vda    254:0    0  50G  0 disk
└─vda1 254:1    0  50G  0 part /
```

```bash
lsblk -f
NAME   FSTYPE FSVER LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINT
vda
└─vda1 ext4   1.0         079b0964-fbfc-4836-9ae7-ab55d580fe72    7.4G    57% /
```

```bash
sudo resize2fs /dev/vda1
resize2fs 1.46.2 (28-Feb-2021)
Filesystem at /dev/vda1 is mounted on /; on-line resizing required
old_desc_blocks = 3, new_desc_blocks = 7
The filesystem on /dev/vda1 is now 13106939 (4k) blocks long.
```

```bash
df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/vda1        50G   12G   36G  24% /
```