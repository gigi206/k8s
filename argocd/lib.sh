NAMESPACE_ARGOCD="argo-cd"
DIRNAME="$(dirname $(realpath $0))"
BASENAME="$(basename ${DIRNAME})"
# NAMESPACE="$(kubectl apply -f \"${DIRNAME}/${BASENAME}.yaml\" --dry-run=client -o jsonpath='{.spec.destination.namespace}')"
MANIFEST="$(kubectl apply -f \"${DIRNAME}/${BASENAME}.yaml\" --dry-run=client -o json)"
NAMESPACE="$(echo ${MANIFEST} | jq -r '.spec.destination.namespace')"
VERSION="$(echo ${MANIFEST} | jq -r '.spec.source.targetRevision')"
APPNAME="$(echo ${MANIFEST} | jq -r '.metadata.name')"
#TARGET_REGISTRY="my.registry.com"
ARGOCD_CMD="argocd --port-forward --port-forward-namespace ${NAMESPACE_ARGOCD} --insecure"
#ARGOCD_CMD="argocd --port-forward --port-forward-namespace ${NAMESPACE_ARGOCD} --plaintext"
REPO_URL=$(kubectl apply -f \"${DIRNAME}/${BASENAME}.yaml\" --dry-run=client -o json | jq -r ".spec.source.repoURL")
RUNTIME_ENDPOINT="/run/k3s/containerd/containerd.sock"
CTR_CMD="/var/lib/rancher/rke2/bin/ctr --address ${RUNTIME_ENDPOINT} -n k8s.io"
CRICTL_CMD="/var/lib/rancher/rke2/bin/crictl --runtime-endpoint unix://${RUNTIME_ENDPOINT}"
DOWNLOAD_IMAGES="${DIRNAME}/images"
SKOPEO_IMAGE="quay.io/skopeo/stable:latest"
SKOPEO_REPO_DST="docker://demo.goharbor.io/gigi206"
REPO_DST_CREDS="${REPO_DST_CREDS}"

sync_app() {
    ${ARGOCD_CMD} app sync ${APPNAME} --async
}

install_app() {
    ${ARGOCD_CMD} app list &> /dev/null
    if [ $? -eq 20 ]
    then
        ${ARGOCD_CMD} login || exit 1
    fi
    APP_STATUS=$(${ARGOCD_CMD} app list -o json | jq -r ".[] | select(.metadata.name == \"${APPNAME}\") | .status.health.status")
    if [ "${APP_STATUS}" = "Healthy" ]
    then
        echo "${APPNAME} already in good state [SKIP]"
    else
        echo "Installing ${APPNAME} [${NAMESPACE}]"
        kubectl apply -f "${DIRNAME}/${BASENAME}.yaml"
        sync_app
    fi
}

uninstall_app() {
    # kubectl delete -n ${NAMESPACE_ARGOCD} Application ${APPNAME}
    CRDS="$(${ARGOCD_CMD} app resources ${APPNAME} | egrep CustomResourceDefinition | awk '{ print $3 }')"
    echo "Deleting all ressources from the application ${APPNAME}"
    ${ARGOCD_CMD} app delete ${APPNAME} --yes
    for CRD in ${CRDS}
    do
        echo "Deleting crd ${CRD}"
        kubectl delete crd ${CRD}
    done
    echo "Deleting namespace ${NAMESPACE}"
    kubectl patch ns ${NAMESPACE} -p '{"metadata":{"finalizers":[]}}' --type=merge
    kubectl delete ns ${NAMESPACE}
}

require_app() {
    for REQ in "$@"
    do
    if [ -x "$(dirname $0)/../${REQ}/install.sh" ]
        then
            "$(dirname $0)/../${REQ}/install.sh"
        else
            echo "$(realpath $(dirname $0)/../${REQ}/install.sh) not found"
            echo "A requirement is missing, exiting..."
            exit 1
        fi
        echo ${REQ}
    done
}

wait_app() {
    ${ARGOCD_CMD} app wait ${APPNAME}
    for RESSOURCE in $(kubectl get -n ${NAMESPACE} deploy -o name) $(kubectl get -n ${NAMESPACE} sts -o name) $(kubectl get -n ${NAMESPACE} daemonset -o name)
    do
        echo "Waiting ressource ${RESSOURCE}"
        kubectl rollout -n ${NAMESPACE} status ${RESSOURCE}
    done
}

list_images() {
    REPO_URL="$(echo ${MANIFEST} | jq -r '.spec.source.repoURL')"
    # REPO_NAME=$(helm repo list -o json | jq -r ".[] | select(.url==\"${REPO_URL}\") | .name")
    CHART_NAME="$echo ${MANIFEST} | jq -r '(.spec.source.chart)'"
    # [ -z "${REPO_NAME}" ] && helm repo add ${REPO_NAME:=$APPNAME} ${REPO_URL} > /dev/null

    # IMAGES=$(helm template ${APPNAME} ${REPO_NAME}/${APPNAME} | egrep -w image | awk -F':' '{ print $2":"$3 }' | xargs -I {} echo {} | sort -u)
    # IMAGES=$(kubectl get Application -n ${NAMESPACE_ARGOCD} ${APPNAME} -o json | jq -r '.status.summary.images[]')
    # IMAGES=$(helm install --dry-run ${APPNAME} ${REPO_NAME}/${APPNAME} -o json | jq -r '..|.image? | select(.repository?) | (.repository +":" + .tag)' | sort -u)
    IMAGES=$(helm install --dry-run ${APPNAME} ${APPNAME} --repo ${REPO_URL} -o json | jq -r '..|.image? | select(.repository?) | (.repository +":" + .tag)' | sort -u)
    echo "${IMAGES}"
}

download_images() {
    rm -f "${DOWNLOAD_IMAGES}/images.txt"
    for IMAGE in ${SKOPEO_IMAGE} $(list_images)
    do
    [ "${IMAGE}" = "${SKOPEO_IMAGE}" ] && ${CTR_CMD} images ls | egrep -w --color "^${SKOPEO_IMAGE}" &>/dev/null && continue
        echo "$(dirname ${IMAGE})" | egrep '\.' &>/dev/null || IMAGE="docker.io/${IMAGE}"
        mkdir -p "${DOWNLOAD_IMAGES}/$(dirname ${IMAGE})"
    echo "${IMAGE}.tar" >> "${DOWNLOAD_IMAGES}/images.txt"
        if [ -f "${DOWNLOAD_IMAGES}/${IMAGE}.tar" ]
        then
            echo "Pulling image ${IMAGE} [EXISTS]"
            continue
        else
            echo "Pulling image ${IMAGE}"
        fi
        ${CTR_CMD} images pull ${IMAGE}
        echo "Downloading image ${IMAGE} => ${DOWNLOAD_IMAGES}/${IMAGE}.tar"
        # cf https://manpages.debian.org/unstable/buildah/containers-transports.5.en.html
        # cf https://www.redhat.com/sysadmin/7-transports-features
        ${CTR_CMD} run --tty --rm --net-host --mount type=bind,src="${DOWNLOAD_IMAGES}",dst=/download,options=rbind "${SKOPEO_IMAGE}" skopeo skopeo copy "docker://${IMAGE}" oci-archive:"/download/${IMAGE//:/_}.tar"
    mv "${DOWNLOAD_IMAGES}/${IMAGE//:/_}.tar" "${DOWNLOAD_IMAGES}/${IMAGE}.tar"
    (cd ${DOWNLOAD_IMAGES}/$(dirname ${IMAGE}) && ln -sf "$(basename ${IMAGE}).tar" "$(basename ${IMAGE} | awk -F':' '{ print $1 }').tar")
    done
    echo "Cleanup unused images"
    ${CRICTL_CMD} rmi --prune
}

sync_images_offline() {
    if [ -z "${REPO_DST_CREDS}" ]
    then
        echo "Variable REPO_DST_CREDS is empty"
        exit 1
    fi

    ${CTR_CMD} images ls | egrep -w --color "^${SKOPEO_IMAGE}" &>/dev/null || ${CTR_CMD} images pull ${SKOPEO_IMAGE}

    while read IMAGE_PATH
    do
        IMAGE_SHORTNAME_PATH="$(echo ${IMAGE_PATH} | awk -F':' '{ print $1 }').tar"
        IMAGE_NAME="$(basename ${IMAGE_PATH//.tar})"
        IMAGE_DST="${SKOPEO_REPO_DST}/${IMAGE_NAME}"
        [ ! -f "${DOWNLOAD_IMAGES}/${IMAGE_PATH}" ] && echo "${DOWNLOAD_IMAGES}/${IMAGE_PATH} does not exist !" && continue
        echo "Sync ${IMAGE_PATH} => ${IMAGE_DST}"
        ${CTR_CMD} run --tty --rm --net-host --mount type=bind,src="${DOWNLOAD_IMAGES}",dst=/download,options=rbind "${SKOPEO_IMAGE}" skopeo skopeo copy --dest-creds="${REPO_DST_CREDS}" oci-archive:"/download/${IMAGE_SHORTNAME_PATH}" "${IMAGE_DST}"
    done < "${DOWNLOAD_IMAGES}/images.txt"
}

#sync_images() {
#    #REPO_URL="$(echo ${MANIFEST} | jq -r '.spec.source.repoURL')"
#    #REPO_NAME=$(helm repo list -o json | jq -r ".[] | select(.url==\"${REPO_URL}\") | .name")
#    #CHART_NAME="$echo ${MANIFEST} | jq -r '(.spec.source.chart)'"
#    #[ -z "${REPO_NAME}" ] && helm repo add ${REPO_NAME:=$APPNAME} ${REPO_URL}
#
#    ## IMAGES=$(helm template ${APPNAME} ${REPO_NAME}/${APPNAME} | egrep -w image | awk -F':' '{ print $2":"$3 }' | xargs -I {} echo {} | sort -u)
#    ## IMAGES=$(kubectl get Application -n ${NAMESPACE_ARGOCD} ${APPNAME} -o json | jq -r '.status.summary.images[]')
#    #IMAGES=$(helm install --dry-run ${APPNAME} ${REPO_NAME}/${APPNAME} -o json | jq -r '..|.image? | select(.repository?) | (.repository +":" + .tag)' | sort -u)
#
#
#    #for IMAGE in list_images
#    #do
#    #done
#    #"${DOCKER_BIN}" rmi --prune
#}

show_ressources() {
    ${ARGOCD_CMD} app resources ${APPNAME}
}
