#!/usr/bin/env bash
PRODUCT="rke2"
DOWNLOAD_DIR="$(realpath $(dirname $0))/download"
RANCHER_IMAGES_DIR="/var/lib/rancher/${PRODUCT}/agent/images/"
RANCHER_IMAGES_ARCHIVE="${PRODUCT}-images.linux-amd64.tar.gz"
RANCHER_PRODUCT_ARCHIVE="${PRODUCT}.linux-amd64.tar.gz"
RANCHER_CONFIG_file="/etc/rancher/${PRODUCT}/config.yaml" # RKE2_CONFIG_FILE
! test -d "${DOWNLOAD_DIR}" && echo "${DOWNLOAD_DIR} does not exist. Please run download.sh first" && exit 1
test -d /etc/sysconfig && CONFIG_PATH="/etc/sysconfig/${PRODUCT}-server" || CONFIG_PATH="/etc/default/${PRODUCT}-server"
export PATH="${PATH}:/var/lib/rancher/${PRODUCT}/bin"
export KUBECONFIG="/etc/rancher/${PRODUCT}/rke2.yaml"

install() {
    mkdir -p /var/lib/rancher/rke2/agent/images
    cp "${DOWNLOAD_DIR}/${RANCHER_IMAGES_ARCHIVE}" "${RANCHER_IMAGES_DIR}"
    mkdir -p /usr/local
    tar xzf "${DOWNLOAD_DIR}/${RANCHER_PRODUCT_ARCHIVE}" -C /usr/local
    systemctl daemon-reload
}

configure() {
    # Cf https://docs.rke2.io/install/install_options/install_options/#configuration-file => /etc/rancher/rke2/config.yaml
    #echo "RKE2_CNI=calico" >> /usr/local/lib/systemd/system/rke2-server.env
    # echo "RKE2_CNI=calico" >> "${CONFIG_PATH}"
    mkdir -p "$(dirname ${RANCHER_CONFIG_file})"
    echo "cni: calico" > "${RANCHER_CONFIG_file}"
    # systemctl enable --now rke2-server.service
    systemctl enable rke2-server.service
}

start_service() {
    systemctl start rke2-server.service
}

post_install() {
    crictl config --set runtime-endpoint=unix:///run/k3s/containerd/containerd.sock
}

install
configure
start_service
post_install
