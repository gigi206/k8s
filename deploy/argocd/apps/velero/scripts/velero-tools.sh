#!/usr/bin/env bash
# =============================================================================
# velero-tools.sh - Unified backup & snapshot management tool
# =============================================================================
# Manages Velero backups (S3) and local CSI snapshots (Ceph RBD).
#
# Velero backups: full namespace backup (manifests + volumes) stored in S3.
#   Restore requires downloading data from S3 (slower but survives Ceph loss).
#
# Local snapshots: instant PVC snapshot stored on Ceph (COW clone).
#   Restore is instantaneous but requires Ceph to be operational.
#
# Usage:
#   ./velero-tools.sh <type> [action] [options]
#
# Types (required for create/restore/delete):
#   -b, --backup     Velero backup (S3)
#   -s, --snapshot   Local CSI snapshot (Ceph)
#
# Actions (combined with type):
#   -c, --create     Create (default when no action flag)
#   -l, --list       List
#   -r, --restore    Restore
#   -d, --delete     Delete
#
# Other:
#   -l               List all (without -b/-s)
#   -h, --help       Show this help
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<'EOF'
Usage: velero-tools.sh <type> [action] [options]

Types:
  -b, --backup     Velero backup (S3)
  -s, --snapshot   Local CSI snapshot (Ceph)

Actions (combine with -b or -s):
  -c, --create     Create (default if no action specified)
  -l, --list       List (or details if name given: -b -l <name>)
  -r, --restore    Restore
  -d, --delete     Delete

Other:
  -h, --help                            Show this help
  --yes                                 Skip confirmation prompts

Backup options:
  --ns <ns1,ns2>         Namespace(s) to include (comma-separated)
  --exclude-ns <ns1,ns2> Namespace(s) to exclude (comma-separated)
  --no-volumes           Skip volume snapshots (metadata/manifests only)
  --wait                 Wait for backup to complete
  --cold                 Scale down workloads before backup, scale up after (requires --ns)
  --details              Show full describe + logs after create

Snapshot options:
  --ns <namespace>   Target namespace (required)
  --pvc <pvc>        Target PVC (omit to operate on all PVCs)
  --snap <snapshot>  Snapshot name (for restore/delete)
  --deploy <deploy>  Deployment to scale down/up (for single PVC restore)
  --name <name>      Custom snapshot name (for create)
  --cold             Scale down workloads before snapshot, scale up after

Backup examples:
  velero-tools.sh -b -c daily --ns keycloak --wait              # Create backup
  velero-tools.sh -b -c daily --ns keycloak --wait --details    # Create + full details
  velero-tools.sh -b -l                                         # List all backups
  velero-tools.sh -b -l daily                                   # Details of backup 'daily'
  velero-tools.sh -b -r daily --ns keycloak                     # Restore backup
  velero-tools.sh -b -d daily                                   # Delete backup

Snapshot examples:
  velero-tools.sh -s -c --ns dokuwiki --pvc dokuwiki-data       # Snapshot one PVC
  velero-tools.sh -s -c --ns dokuwiki                           # Snapshot ALL PVCs in namespace
  velero-tools.sh -s -l                                         # List all snapshots
  velero-tools.sh -s -l --ns dokuwiki                           # List snapshots in namespace
  velero-tools.sh -s -r --ns dokuwiki --pvc dokuwiki-data \
                  --snap dokuwiki-data-snap-20260220 \
                  --deploy dokuwiki                             # Restore one PVC
  velero-tools.sh -s -r --ns dokuwiki                           # Restore ALL PVCs (latest snaps)
  velero-tools.sh -s -d --ns dokuwiki --snap snap-name          # Delete one snapshot
  velero-tools.sh -s -d --ns dokuwiki                           # Delete ALL snapshots in ns

List all:
  velero-tools.sh -l                                            # List backups + snapshots

Note: -c is optional (default action), so "-b daily" is equivalent to "-b -c daily".
EOF
}

confirm() {
    local msg="$1"
    if [[ "${YES:-}" == "true" ]]; then
        return 0
    fi
    echo -e "${YELLOW}WARNING: ${msg}${NC}"
    read -rp "Continue? [y/N] " answer
    [[ "$answer" == [yY] ]]
}

# =============================================================================
# LIST
# =============================================================================
cmd_list_backups() {
    local name="${1:-}"
    if [[ -n "$name" ]]; then
        echo -e "${CYAN}=== Backup: ${name} ===${NC}"
        velero backup describe "$name" --details 2>/dev/null || { echo -e "${RED}ERROR: Backup '$name' not found${NC}"; exit 1; }
        echo ""
        echo -e "${CYAN}=== Logs ===${NC}"
        velero backup logs "$name" 2>/dev/null || echo "No logs available"
    else
        echo -e "${CYAN}=== Velero Backups ===${NC}"
        velero backup get 2>/dev/null || echo "No backups found"
    fi
}

cmd_list_snapshots() {
    local namespace=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ns) namespace="$2"; shift 2 ;;
            -*) echo "Unknown option: $1"; exit 1 ;;
            *) namespace="$1"; shift ;;
        esac
    done
    echo -e "${CYAN}=== Local VolumeSnapshots ===${NC}"
    if [[ -n "$namespace" ]]; then
        kubectl get volumesnapshots -n "$namespace" 2>/dev/null || echo "No snapshots in namespace '$namespace'"
    else
        kubectl get volumesnapshots -A 2>/dev/null || echo "No snapshots found"
    fi
}

cmd_list_all() {
    local namespace="${1:-}"
    cmd_list_backups
    echo ""
    cmd_list_snapshots "$namespace"
}

# =============================================================================
# BACKUP (Velero → S3)
# =============================================================================
cmd_backup() {
    local name="" namespaces="" exclude_ns="" wait="" cold="" details="" no_volumes=""

    name="${1:?ERROR: backup name required. Usage: $0 -b <name> [--ns <ns>] [--exclude-ns <ns>] [--wait] [--cold] [--details] [--no-volumes]}"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ns) namespaces="$2"; shift 2 ;;
            --exclude-ns) exclude_ns="$2"; shift 2 ;;
            --wait) wait="--wait"; shift ;;
            --cold) cold="true"; shift ;;
            --details) details="true"; shift ;;
            --no-volumes) no_volumes="true"; shift ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ "$cold" == "true" && -z "$namespaces" ]]; then
        echo -e "${RED}ERROR: --cold requires --ns (cannot cold-backup entire cluster)${NC}"
        exit 1
    fi

    local save_file=""
    if [[ "$cold" == "true" ]]; then
        echo -e "${YELLOW}Cold backup: scaling down workloads before backup${NC}"
        save_file=$(mktemp /tmp/velero-cold-XXXXXX)
        # --ns can be comma-separated, scale down each namespace
        IFS=',' read -ra ns_list <<< "$namespaces"
        for ns in "${ns_list[@]}"; do
            save_workload_replicas "$ns" "${save_file}.${ns}"
            scale_down_all "$ns"
        done
    fi

    local args=(backup create "$name")
    [[ -n "$namespaces" ]] && args+=(--include-namespaces "$namespaces")
    [[ -n "$exclude_ns" ]] && args+=(--exclude-namespaces "$exclude_ns")
    [[ "$no_volumes" == "true" ]] && args+=(--snapshot-volumes=false)
    [[ -n "$wait" ]] && args+=($wait)
    # Cold backups should always wait (need to scale up after)
    [[ "$cold" == "true" && -z "$wait" ]] && args+=(--wait)

    echo -e "${GREEN}Creating backup: ${name}${NC}"
    [[ -n "$namespaces" ]] && echo "  Namespaces: $namespaces"
    [[ -n "$exclude_ns" ]] && echo "  Exclude: $exclude_ns"
    [[ "$no_volumes" == "true" ]] && echo "  Volumes: skipped (metadata only)"
    [[ "$cold" == "true" ]] && echo "  Mode: cold (workloads stopped)"

    velero "${args[@]}"

    if [[ "$cold" == "true" ]]; then
        echo ""
        echo "Scaling workloads back up..."
        for ns in "${ns_list[@]}"; do
            scale_up_saved "$ns" "${save_file}.${ns}"
        done
    fi

    echo ""
    if [[ "$details" == "true" ]]; then
        velero backup describe "$name" --details
        echo ""
        echo -e "${CYAN}Logs:${NC}"
        velero backup logs "$name" 2>/dev/null || echo "No logs available yet"
    else
        velero backup describe "$name" | grep -E "Phase:|Items backed|Errors:|Warnings:|Started:|Completed:"
    fi
}

# =============================================================================
# RESTORE (Velero ← S3)
# =============================================================================
cmd_restore() {
    local backup_name="" namespace=""

    backup_name="${1:?ERROR: backup name required. Usage: $0 -b -r <backup-name> [--ns <namespace>]}"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ns) namespace="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Verify backup exists
    local status
    status=$(velero backup get "$backup_name" -o json 2>/dev/null | grep -o '"phase": *"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ "$status" != "Completed" ]]; then
        echo -e "${RED}ERROR: Backup '$backup_name' not found or not Completed (status: ${status:-not found})${NC}"
        exit 1
    fi

    local restore_name="${backup_name}-restore-$(date +%s)"
    local args=(restore create "$restore_name" --from-backup "$backup_name" --wait)

    if [[ -n "$namespace" ]]; then
        args+=(--include-namespaces "$namespace")
        confirm "Namespace '$namespace' will be deleted before restore (required for PVC data)." || exit 0
        echo "Deleting namespace '$namespace'..."
        kubectl delete namespace "$namespace" --wait=true 2>/dev/null || true
    else
        confirm "Full cluster restore from backup '$backup_name'." || exit 0
    fi

    echo -e "${GREEN}Restoring from backup '${backup_name}'...${NC}"
    velero "${args[@]}"

    echo ""
    velero restore describe "$restore_name" | grep -E "Phase:|Items Restored|Errors:|Warnings:|Started:|Completed:"

    if [[ -n "$namespace" ]]; then
        echo ""
        echo "Resources in namespace '$namespace':"
        kubectl get pods,pvc,svc -n "$namespace" 2>/dev/null || echo "Namespace not yet ready"
    fi
}

# =============================================================================
# DELETE (Velero backup)
# =============================================================================
cmd_delete() {
    local backup_name=""
    backup_name="${1:?ERROR: backup name required. Usage: $0 -b -d <backup-name> [--yes]}"

    if ! velero backup get "$backup_name" &>/dev/null; then
        echo -e "${RED}ERROR: Backup '$backup_name' not found${NC}"
        exit 1
    fi

    confirm "Backup '$backup_name' and its S3 data will be permanently deleted." || exit 0

    velero backup delete "$backup_name" --confirm
    echo -e "${GREEN}Backup '$backup_name' deletion requested.${NC}"
}

# =============================================================================
# SNAPSHOT HELPERS
# =============================================================================

# Create a single VolumeSnapshot and wait for readiness
create_single_snapshot() {
    local namespace="$1" pvc_name="$2" snapshot_name="$3"

    if ! kubectl get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
        echo -e "${RED}ERROR: PVC '$pvc_name' not found in namespace '$namespace'${NC}"
        return 1
    fi

    echo -e "${GREEN}Creating snapshot '${snapshot_name}' from PVC '${pvc_name}'...${NC}"

    kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${snapshot_name}
  namespace: ${namespace}
spec:
  volumeSnapshotClassName: ceph-block-snapshot-retain
  source:
    persistentVolumeClaimName: ${pvc_name}
EOF

    echo "Waiting for snapshot to be ready..."
    for _ in $(seq 1 30); do
        local ready
        ready=$(kubectl get volumesnapshot "$snapshot_name" -n "$namespace" -o jsonpath='{.status.readyToUse}' 2>/dev/null)
        if [[ "$ready" == "true" ]]; then
            echo -e "${GREEN}Snapshot '${snapshot_name}' ready.${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "${YELLOW}Snapshot '${snapshot_name}' not ready after 30s${NC}"
    return 1
}

# Restore a single PVC from a VolumeSnapshot (delete + recreate)
restore_single_pvc() {
    local namespace="$1" pvc_name="$2" snapshot_name="$3"

    local storage_size storage_class
    storage_size=$(kubectl get volumesnapshot "$snapshot_name" -n "$namespace" -o jsonpath='{.status.restoreSize}')
    storage_class=$(kubectl get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "ceph-block")

    echo "  Deleting PVC '$pvc_name'..."
    kubectl delete pvc "$pvc_name" -n "$namespace" --wait=true

    echo "  Creating PVC from snapshot '${snapshot_name}' (instant clone)..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${namespace}
spec:
  storageClassName: ${storage_class}
  dataSource:
    name: ${snapshot_name}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${storage_size}
EOF

    kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/"$pvc_name" -n "$namespace" --timeout=60s
    echo -e "  ${GREEN}PVC '${pvc_name}' restored.${NC}"
}

# Save replica counts for all deployments/statefulsets in a namespace
save_workload_replicas() {
    local namespace="$1" save_file="$2"
    : > "$save_file"
    kubectl get deployments -n "$namespace" -o jsonpath='{range .items[*]}{"deploy/"}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null >> "$save_file"
    kubectl get statefulsets -n "$namespace" -o jsonpath='{range .items[*]}{"sts/"}{.metadata.name}{" "}{.spec.replicas}{"\n"}{end}' 2>/dev/null >> "$save_file"
}

# Scale down all deployments/statefulsets in a namespace
scale_down_all() {
    local namespace="$1"
    echo "Scaling down all workloads in '$namespace'..."
    kubectl scale deployments --all -n "$namespace" --replicas=0 2>/dev/null || true
    kubectl scale statefulsets --all -n "$namespace" --replicas=0 2>/dev/null || true
    echo "Waiting for pods to terminate..."
    kubectl wait --for=delete pod --all -n "$namespace" --timeout=60s 2>/dev/null || sleep 5
}

# Restore original replica counts from saved file
scale_up_saved() {
    local namespace="$1" save_file="$2"
    echo "Restoring workload replicas..."
    while IFS=' ' read -r workload replicas; do
        [[ -z "$workload" ]] && continue
        local kind="${workload%%/*}"
        local name="${workload##*/}"
        case "$kind" in
            deploy) kubectl scale deployment "$name" -n "$namespace" --replicas="$replicas" ;;
            sts)    kubectl scale statefulset "$name" -n "$namespace" --replicas="$replicas" ;;
        esac
    done < "$save_file"
    rm -f "$save_file"
}

# Get the latest ready snapshot for each PVC in a namespace
# Output: one line per PVC: "pvc_name snapshot_name"
get_latest_snapshots() {
    local namespace="$1"
    kubectl get volumesnapshots -n "$namespace" --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{range .items[?(@.status.readyToUse==true)]}{.spec.source.persistentVolumeClaimName}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | awk '{ latest[$1]=$2 } END { for (pvc in latest) print pvc, latest[pvc] }'
}

# =============================================================================
# SNAPSHOT CREATE (local CSI)
# =============================================================================
cmd_snapshot() {
    local namespace="" pvc_name="" snapshot_name="" cold=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ns)   namespace="$2"; shift 2 ;;
            --pvc)  pvc_name="$2"; shift 2 ;;
            --name) snapshot_name="$2"; shift 2 ;;
            --cold) cold="true"; shift ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$namespace" ]] && { echo -e "${RED}ERROR: --ns required. Usage: $0 -s -c --ns <namespace> [--pvc <pvc>] [--name <name>] [--cold]${NC}"; exit 1; }

    local save_file=""
    if [[ "$cold" == "true" ]]; then
        echo -e "${YELLOW}Cold snapshot: scaling down workloads before snapshot${NC}"
        save_file=$(mktemp /tmp/velero-cold-XXXXXX)
        save_workload_replicas "$namespace" "$save_file"
        scale_down_all "$namespace"
    fi

    if [[ -n "$pvc_name" ]]; then
        # Single PVC
        snapshot_name="${snapshot_name:-${pvc_name}-snap-$(date +%Y%m%d-%H%M%S)}"
        create_single_snapshot "$namespace" "$pvc_name" "$snapshot_name"
        kubectl get volumesnapshot "$snapshot_name" -n "$namespace"
    else
        # All PVCs in namespace
        local pvcs
        pvcs=$(kubectl get pvc -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -z "$pvcs" ]]; then
            [[ -n "$save_file" ]] && scale_up_saved "$namespace" "$save_file"
            echo -e "${RED}ERROR: No PVCs found in namespace '$namespace'${NC}"
            exit 1
        fi

        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        local count=0

        echo -e "${CYAN}Snapshotting all PVCs in namespace '$namespace':${NC}"
        for pvc in $pvcs; do
            echo ""
            create_single_snapshot "$namespace" "$pvc" "${pvc}-snap-${timestamp}" || true
            count=$((count + 1))
        done

        echo ""
        echo -e "${GREEN}${count} snapshot(s) created.${NC}"
        kubectl get volumesnapshots -n "$namespace"
    fi

    if [[ -n "$save_file" ]]; then
        echo ""
        scale_up_saved "$namespace" "$save_file"
    fi
}

# =============================================================================
# SNAPSHOT RESTORE (local CSI → PVC clone)
# =============================================================================
cmd_snap_restore() {
    local namespace="" pvc_name="" snapshot_name="" deploy_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ns)     namespace="$2"; shift 2 ;;
            --pvc)    pvc_name="$2"; shift 2 ;;
            --snap)   snapshot_name="$2"; shift 2 ;;
            --deploy) deploy_name="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$namespace" ]] && { echo -e "${RED}ERROR: --ns required. Usage: $0 -s -r --ns <namespace> [--pvc <pvc> --snap <snap> --deploy <deploy>]${NC}"; exit 1; }

    if [[ -n "$pvc_name" ]]; then
        # --- Single PVC restore ---
        [[ -z "$snapshot_name" ]] && { echo -e "${RED}ERROR: --snap required for single PVC restore${NC}"; exit 1; }
        [[ -z "$deploy_name" ]]  && { echo -e "${RED}ERROR: --deploy required for single PVC restore${NC}"; exit 1; }

        # Verify snapshot
        local ready
        ready=$(kubectl get volumesnapshot "$snapshot_name" -n "$namespace" -o jsonpath='{.status.readyToUse}' 2>/dev/null)
        if [[ "$ready" != "true" ]]; then
            echo -e "${RED}ERROR: Snapshot '$snapshot_name' not found or not ready${NC}"
            exit 1
        fi

        local storage_size
        storage_size=$(kubectl get volumesnapshot "$snapshot_name" -n "$namespace" -o jsonpath='{.status.restoreSize}')
        local storage_class
        storage_class=$(kubectl get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "ceph-block")

        echo "Restore plan:"
        echo "  Namespace:    $namespace"
        echo "  PVC:          $pvc_name"
        echo "  Snapshot:     $snapshot_name"
        echo "  Deployment:   $deploy_name"
        echo "  Size:         $storage_size"
        echo "  StorageClass: $storage_class"
        echo ""
        confirm "PVC '$pvc_name' will be deleted and recreated from snapshot." || exit 0

        echo "Scaling down '$deploy_name'..."
        kubectl scale deployment "$deploy_name" -n "$namespace" --replicas=0
        sleep 5

        restore_single_pvc "$namespace" "$pvc_name" "$snapshot_name"

        echo "Scaling up '$deploy_name'..."
        kubectl scale deployment "$deploy_name" -n "$namespace" --replicas=1

        echo -e "${GREEN}Restore complete.${NC}"
        kubectl wait --for=condition=Ready pod -l app="$deploy_name" -n "$namespace" --timeout=120s 2>/dev/null || true
        kubectl get pods,pvc -n "$namespace"
    else
        # --- All PVCs from latest snapshots ---
        local snap_map
        snap_map=$(get_latest_snapshots "$namespace")
        if [[ -z "$snap_map" ]]; then
            echo -e "${RED}ERROR: No ready snapshots found in namespace '$namespace'${NC}"
            exit 1
        fi

        echo "Restore plan (all PVCs from latest snapshots):"
        echo "  Namespace: $namespace"
        echo ""
        echo "  PVC                              Snapshot"
        echo "  ---                              --------"
        while IFS=' ' read -r pvc snap; do
            printf "  %-35s%s\n" "$pvc" "$snap"
        done <<< "$snap_map"
        echo ""

        confirm "ALL listed PVCs will be deleted and recreated. All workloads in '$namespace' will be scaled down." || exit 0

        local save_file
        save_file=$(mktemp /tmp/velero-replicas-XXXXXX)
        save_workload_replicas "$namespace" "$save_file"
        scale_down_all "$namespace"

        while IFS=' ' read -r pvc snap; do
            echo ""
            restore_single_pvc "$namespace" "$pvc" "$snap"
        done <<< "$snap_map"

        echo ""
        scale_up_saved "$namespace" "$save_file"

        echo ""
        echo -e "${GREEN}Restore complete for namespace '$namespace'.${NC}"
        kubectl get pods,pvc -n "$namespace"
    fi
}

# =============================================================================
# SNAPSHOT DELETE (local CSI)
# =============================================================================
cmd_snap_delete() {
    local namespace="" snapshot_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ns)   namespace="$2"; shift 2 ;;
            --snap) snapshot_name="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    [[ -z "$namespace" ]] && { echo -e "${RED}ERROR: --ns required. Usage: $0 -s -d --ns <namespace> [--snap <snapshot>]${NC}"; exit 1; }

    if [[ -n "$snapshot_name" ]]; then
        # Single snapshot
        if ! kubectl get volumesnapshot "$snapshot_name" -n "$namespace" &>/dev/null; then
            echo -e "${RED}ERROR: Snapshot '$snapshot_name' not found in namespace '$namespace'${NC}"
            exit 1
        fi

        kubectl get volumesnapshot "$snapshot_name" -n "$namespace"
        echo ""
        confirm "Snapshot '$snapshot_name' will be permanently deleted." || exit 0

        kubectl delete volumesnapshot "$snapshot_name" -n "$namespace"
        echo -e "${GREEN}Snapshot '$snapshot_name' deleted.${NC}"
    else
        # All snapshots in namespace
        local snapshots
        snapshots=$(kubectl get volumesnapshots -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -z "$snapshots" ]]; then
            echo "No snapshots found in namespace '$namespace'"
            exit 0
        fi

        echo -e "${CYAN}Snapshots in namespace '$namespace':${NC}"
        kubectl get volumesnapshots -n "$namespace"
        echo ""

        local count
        count=$(echo "$snapshots" | wc -w)
        confirm "All $count snapshot(s) in namespace '$namespace' will be permanently deleted." || exit 0

        for snap in $snapshots; do
            kubectl delete volumesnapshot "$snap" -n "$namespace"
            echo -e "${GREEN}Deleted: $snap${NC}"
        done
    fi
}

# =============================================================================
# MAIN
# =============================================================================
if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

# Parse --yes flag globally
for arg in "$@"; do
    if [[ "$arg" == "--yes" ]]; then
        YES="true"
    fi
done
# Remove --yes from args
ARGS=()
for arg in "$@"; do
    [[ "$arg" != "--yes" ]] && ARGS+=("$arg")
done
set -- "${ARGS[@]}"

# Parse type (-b/-s) and action (-r/-d) flags
TYPE=""
ACTION="create"
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        -b|--backup)   TYPE="backup" ;;
        -s|--snapshot) TYPE="snapshot" ;;
        -c|--create)   ACTION="create" ;;
        -l|--list)     ACTION="list" ;;
        -r|--restore)  ACTION="restore" ;;
        -d|--delete)   ACTION="delete" ;;
        -h|--help)     usage; exit 0 ;;
        *)             POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

case "${TYPE}:${ACTION}" in
    backup:create)       cmd_backup "$@" ;;
    backup:list)         cmd_list_backups "$@" ;;
    backup:restore)      cmd_restore "$@" ;;
    backup:delete)       cmd_delete "$@" ;;
    snapshot:create)     cmd_snapshot "$@" ;;
    snapshot:list)       cmd_list_snapshots "$@" ;;
    snapshot:restore)    cmd_snap_restore "$@" ;;
    snapshot:delete)     cmd_snap_delete "$@" ;;
    :list)               cmd_list_all "$@" ;;
    :create)             echo "ERROR: -b or -s is required"; echo ""; usage; exit 1 ;;
    :*)                  echo "ERROR: -b or -s is required"; echo ""; usage; exit 1 ;;
    *)                   echo "Unknown combination: type=$TYPE action=$ACTION"; usage; exit 1 ;;
esac
