# export INSTALL_RKE2_VERSION=v1.26.9+rke2r1

# Helper: read YAML value with yq, returns empty string if null/missing
yq_read() {
  local result
  result=$(yq eval "$1" "$2" 2>/dev/null)
  [ "$result" = "null" ] && echo "" || echo "$result"
}

# Shared CIS setup: etcd user + sysctl
# Requires: CIS_ENABLED and CIS_PROFILE to be set before calling
cis_base_setup() {
  if [ "$CIS_ENABLED" != "true" ]; then
    return
  fi

  echo "CIS Hardening enabled with profile: ${CIS_PROFILE:-cis}"

  # Create etcd user/group (required by CIS profile)
  if ! id etcd &>/dev/null; then
    useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
  fi

  # Apply CIS sysctl parameters
  if [ -f /usr/local/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  elif [ -f /usr/share/rke2/rke2-cis-sysctl.conf ]; then
    cp -f /usr/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
  fi
  systemctl restart systemd-sysctl
}

# Read common kubelet hardening options from config
# Sets: ANONYMOUS_AUTH, PROTECT_KERNEL_DEFAULTS, EVENT_QPS,
#       POD_MAX_PIDS, MAKE_IPTABLES_UTIL_CHAINS
# Usage: cis_read_kubelet_options <config_file>
cis_read_kubelet_options() {
  local config_file="$1"

  EVENT_QPS=$(yq_read '.rke2.cis.hardening.kubelet.eventQps' "$config_file")
  POD_MAX_PIDS=$(yq_read '.rke2.cis.hardening.kubelet.podMaxPids' "$config_file")
  ANONYMOUS_AUTH=$(yq_read '.rke2.cis.hardening.kubelet.anonymousAuth' "$config_file")
  MAKE_IPTABLES_UTIL_CHAINS=$(yq_read '.rke2.cis.hardening.kubelet.makeIptablesUtilChains' "$config_file")
  PROTECT_KERNEL_DEFAULTS=$(yq_read '.rke2.cis.hardening.kubelet.protectKernelDefaults' "$config_file")

  # Set defaults if not specified
  EVENT_QPS=${EVENT_QPS:-5}
  POD_MAX_PIDS=${POD_MAX_PIDS:-4096}
  ANONYMOUS_AUTH=${ANONYMOUS_AUTH:-false}
  MAKE_IPTABLES_UTIL_CHAINS=${MAKE_IPTABLES_UTIL_CHAINS:-true}
  PROTECT_KERNEL_DEFAULTS=${PROTECT_KERNEL_DEFAULTS:-true}
}
