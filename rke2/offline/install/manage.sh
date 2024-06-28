#!/usr/bin/env bash
# AUTHOR: Ghislain LE MEUR
# DATE: 25/06/2024

CTR="ctr --address /run/k3s/containerd/containerd.sock -n k8s.io"
DOCKER=podman
HELM="$(realpath $(dirname ${0})/bin/helm)"
KUSTOMIZE="$(realpath $(dirname ${0})/bin/kustomize)"
MAPPING_FILE="mapping"
EXTRA_MAPPING_FILE="extra-mapping"
INSTALL_FILE="install.sh"
IMAGES_DIR="images"
CHARTS_DIR="charts"
CHARTS_ENV_FILE="${CHARTS_DIR}/env.sh"
PROG_PATH="$(realpath $(dirname ${0}))"
POST_MAPPING_FILE="post-mapping.sh"

install() {
  APP_PATH="${PROG_PATH}/${1}"
  cd "${APP_PATH}"
  if [ ! -x "${INSTALL_FILE}" ]
  then
    echo "The file ${APP_PATH}/${INSTALL_FILE} does not exist or is not executable !"
    exit 1
  fi

  ./${INSTALL_FILE}
}

get_mapping() {
  APP_PATH="${PROG_PATH}/${1}"
  cd "${APP_PATH}"

  if [[ ! -f "${CHARTS_ENV_FILE}" ]]
  then
    echo "The file ${CHARTS_ENV_FILE} does not exist !"
    exit 1
  fi

  source "${CHARTS_ENV_FILE}"
  cd "${CHARTS_DIR}"

  if [[ -f "${CHART}-${VERSION}/kustomization.yaml" ]]
  then
    IMAGES="$(${KUSTOMIZE} build ${CHART}-${VERSION} | egrep "image:" | awk '{ print $2 }' | sed 's@\"@@g')"
  else
    IMAGES="$(${HELM} template ${CHART}-${VERSION} -f values.yaml | egrep "image:" | awk '{ print $2 }' | sed 's@\"@@g')"
  fi

  for line in ${IMAGES}
  do
    echo "$(echo ${line} | awk -F/ '{ print $NF }' | sed 's@:@_@g') ${line}"
  done | sort -u | tee "${APP_PATH}/${MAPPING_FILE}"

  # Post script
  test -x "${APP_PATH}/${POST_MAPPING_FILE}" && "${APP_PATH}/${POST_MAPPING_FILE}"
}

pull_images() {
  APP_PATH="${PROG_PATH}/${1}"
  cd "${APP_PATH}"
  check_mapping "${MAPPING_FILE}"
  cat ${MAPPING_FILE} ${EXTRA_MAPPING_FILE} 2>/dev/null | while read line
  do
    echo "${line}" | egrep "^\s*$|^\s*#" &>/dev/null && continue
    unset TAG
    TAG=$(echo "${line}" | awk '{ print $2 }')
    [ -z "${TAG}" ] && continue
    # ${CTR} image pull ${TAG}
    ${DOCKER} pull ${TAG}
  done
}

pull_charts() {
  APP_PATH="${PROG_PATH}/${1}"
  cd "${APP_PATH}"

  if [[ ! -f "${CHARTS_ENV_FILE}" ]]
  then
    echo "The file ${1}/${CHARTS_ENV_FILE} does not exist !"
    exit 1
  fi

  source "${CHARTS_ENV_FILE}"

  if [[ ! "${CHART_URL}" =~ ^http ]]
  then
    return
  fi

  cd "${CHARTS_DIR}"
  ${HELM} repo add ${REPO} ${CHART_URL} || exit 1
  ${HELM} repo update ${REPO} || exit 1
  test -d ${CHART} && rm -fr ${CHART}
  test -d ${CHART}-${VERSION} && rm -fr ${CHART}-${VERSION}
  # helm pull --untar --version=${VERSION} --untardir=${REPO}-${VERSION} ${REPO}/${CHART} || exit 1
  ${HELM} pull --untar --version=${VERSION} ${REPO}/${CHART} || exit 1
  ${HELM} dependency update ${CHART} || exit 1
  mv ${CHART} ${CHART}-${VERSION}
}

export_images() {
  APP_PATH="${PROG_PATH}/${1}"
  cd "${APP_PATH}"
  check_mapping "${MAPPING_FILE}"
  test -d "${IMAGES_DIR}" || mkdir -p "${IMAGES_DIR}"
  cat ${MAPPING_FILE} ${EXTRA_MAPPING_FILE} 2>/dev/null | while read line
  do
    echo "${line}" | egrep "^\s*$|^\s*#" &>/dev/null && continue
    unset IMAGE TAG SKIP_MSG
    IMAGE=$(echo "${line}" | awk '{ print $1 }')
    TAG=$(echo "${line}" | awk '{ print $2 }')
    [ -z "${IMAGE}" ] && continue
    [ -z "${TAG}" ] && continue
    test -f "${APP_PATH}/${IMAGES_DIR}/${IMAGE}" && SKIP_MSG="[SKIPPED]"
    echo "Export ${TAG} => ${IMAGE} ${SKIP_MSG}"
    test -n "${SKIP_MSG}" && continue
    # (cd "${IMAGES_DIR}" && ${CTR} image export ${IMAGE} ${TAG})
    (cd "${IMAGES_DIR}" && ${DOCKER} save ${TAG} -o ${IMAGE})
  done
}

import_images() {
  APP_PATH="${PROG_PATH}/${1}"
  cd "${APP_PATH}"
  check_mapping "${MAPPING_FILE}"
  while read line
  do
    echo "${line}" | egrep "^\s*$|^\s*#" &>/dev/null && continue
    unset IMAGE TAG
    IMAGE=$(echo "${line}" | awk '{ print $1 }')
    TAG=$(echo "${line}" | awk '{ print $2 }')
    [ -z "${IMAGE}" ] && continue
    [ -z "${TAG}" ] && continue
    (cd "${IMAGES_DIR}" && ${CTR} image import ${IMAGE} ${TAG})
  done < "${MAPPING_FILE}"
}

check_mapping() {
  MAPPING="${1}"
  if [ ! -r "${MAPPING}" ]
  then
    echo "The file ${MAPPING} does not exist !"
    exit 1
  fi
}

check_docker() {
  if [ ! which ${DOCKER} &>/dev/null ]
  then
    echo "Please install docker or podman !"
    exit 1
  fi
}

#check_helm() {
#  if [ ! which ${HELM} &>/dev/null ]
#  then
#    echo "Please install helm !"
#    exit 1
#  fi
#}

usage() {
  cat <<EOF
${0} [option] <directory>

OPTIONS:
  --get-all: download charts and export container images
  --pull-images: download container images
  --pull-charts: download helm charts (with dependancies)
  --export: export container images download (require --pull-images before)
  --import: import container images in kubernetes
  --install: install application in kubernetes

EXEMPLES:
  ${0} --get-all harbor
  ${0} --pull-images harbor
  ${0} --pull-charts harbor
  ${0} --export harbor
  ${0} --import harbor
  ${0} --install harbor

EOF
}

VALID_ARGS=$(getopt -o a:g:c:o:m:i:h --long get-all:,pull-images:,pull-charts:,export:,mapping:,install:,import:,help -- "$@")
if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

eval set -- "$VALID_ARGS"
while [ : ]; do
  case "${1}" in
    -a | --get-all)
        check_docker
        pull_charts ${2}
        get_mapping ${2}
        pull_images ${2}
        export_images ${2}
        shift 2
        ;;
    -g | --pull-images)
        check_docker
        pull_images ${2}
        shift 2
        ;;
    -c | --pull-charts)
        check_docker
        pull_charts ${2}
        shift 2
        ;;
    -o | --export)
        check_docker
        export_images ${2}
        shift 2
        ;;
    -s | --mapping)
        get_mapping ${2}
        shift 2
        ;;
    -m | --import)
        import_images ${2}
        shift 2
        ;;
    -i | --install)
        import_images ${2}
        install ${2}
        shift 2
        ;;
    -h | --help)
        usage
        shift
        ;;
    --) shift;
        break
        ;;
  esac
done
