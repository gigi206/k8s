#!/usr/bin/env bash

github_last_version() {
  curl -s https://api.github.com/repos/${1}/releases/latest | jq -r '.tag_name'
}

get_helm() {
  GITHUB_PATH="helm/helm"
  VERSION="$(github_last_version ${GITHUB_PATH})"
  wget https://get.helm.sh/helm-${VERSION}-linux-amd64.tar.gz -O helm-${VERSION}-linux-amd64.tar.gz
}

get_k9s() {
  GITHUB_PATH="derailed/k9s"
  VERSION="$(github_last_version ${GITHUB_PATH})"
  wget https://github.com/${GITHUB_PATH}/releases/download/${VERSION}/k9s_Linux_amd64.tar.gz -O k9s-${VERSION}-Linux_amd64.tar.gz
}

get_kustomize() {
  GITHUB_PATH="kubernetes-sigs/kustomize"
  VERSION="$(github_last_version ${GITHUB_PATH})"
  wget https://github.com/kubernetes-sigs/kustomize/releases/download/${VERSION/\//%2F}/${VERSION/\//_}_linux_amd64.tar.gz -O kustomize-${VERSION}-linux_amd64.tar.gz
}

get_argocd() {
  GITHUB_PATH="argoproj/argo-cd"
  VERSION="$(github_last_version ${GITHUB_PATH})"
  wget https://github.com/${GITHUB_PATH}/releases/download/${VERSION}/argocd-linux-amd64 -O argocd-${VERSION}-linux-amd64
}

get_krew() {
  GITHUB_PATH="kubernetes-sigs/krew"
  VERSION="$(github_last_version ${GITHUB_PATH})"
  wget https://github.com/${GITHUB_PATH}/releases/download/${VERSION}/krew-linux_amd64.tar.gz -O krew-${VERSION}-linux_amd64.tar.gz
}

get_helm
get_k9s
get_kustomize
get_argocd
get_krew
