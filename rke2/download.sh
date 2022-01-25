#!/usr/bin/env bash
# Cf https://docs.rke2.io/install/airgap/
PRODUCT="rke2"
GITHUB_ID="rancher/${PRODUCT}"
#RANCHER_IMAGES_ARCHIVE="${PRODUCT}-images.linux-amd64.tar.zst"
RANCHER_IMAGES_ARCHIVE="${PRODUCT}-images.linux-amd64.tar.gz"
RANCHER_PRODUCT_ARCHIVE="${PRODUCT}.linux-amd64.tar.gz"
RANCHER_CHECKSUM="sha256sum-amd64.txt"
DOWNLOAD_DIR="$(dirname $0)/download"

get_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name'
}

check_archive() {
  echo "Verifying archive ${1}"
  EXPECTED_CHECKSUM="$(grep ${1} ${DOWNLOAD_DIR}/${RANCHER_CHECKSUM} | awk '{ print $1 }')"
  CURRENT_CHECKSUM="$(sha256sum ${DOWNLOAD_DIR}/${1} | awk '{ print $1 }')"
  [ "${EXPECTED_CHECKSUM}" != "${CURRENT_CHECKSUM}" ] && echo "${1} have wrong checksum" && exit 1
}

download_release_file() {
    mkdir -p "${DOWNLOAD_DIR}"
    if [ -f "${DOWNLOAD_DIR}/${3}" ]
    then
        echo "[SKIP] ${DOWNLOAD_DIR}/${3} already exists"
    else
        echo "Downloading ${3}"
        # wget -O "${DOWNLOAD_DIR}/${3}" https://github.com/$1/releases/download/${2}/${3}
        curl -o "${DOWNLOAD_DIR}/${3}" -fsSL https://github.com/$1/releases/download/${2}/${3}
    fi
}

RELEASE="$(get_latest_release ${GITHUB_ID})"

if [ -z "${RELEASE}" ]
then
    echo "No github release found for ${GITHUB_ID}"
    exit 1
else
    download_release_file "${GITHUB_ID}" "${RELEASE}" "${RANCHER_CHECKSUM}"
    download_release_file "${GITHUB_ID}" "${RELEASE}" "${RANCHER_IMAGES_ARCHIVE}"
    check_archive "${RANCHER_IMAGES_ARCHIVE}"
    download_release_file "${GITHUB_ID}" "${RELEASE}" "${RANCHER_PRODUCT_ARCHIVE}"
    check_archive "${RANCHER_PRODUCT_ARCHIVE}"
fi

### TOOLS ###

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# kubectl krew
(
  cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.tar.gz" &&
  tar zxvf krew.tar.gz &&
  KREW=./krew-"${OS}_${ARCH}" &&
  "$KREW" install krew
)

kubectl krew install ctx
kubectl krew install ns
