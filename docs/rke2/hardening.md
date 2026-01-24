# RKE2 Hardening

## CIS Benchmark Compliance

This cluster implements CIS Kubernetes Benchmark hardening via RKE2's built-in profiles and additional kubelet configuration.

### Configuration

All CIS hardening settings are centralized in `vagrant/config/rke2.yaml`:

```yaml
rke2:
  cis:
    enabled: true
    profile: "cis"  # Generic profile (auto-adapts to K8s version)
```

### CIS Profiles

| Profile | Kubernetes Version | Notes |
|---------|-------------------|-------|
| `cis` | Auto-detect | Recommended - adapts to K8s version |
| `cis-1.8` | 1.26 | Specific version |
| `cis-1.9` | 1.27-1.28 | Specific version |
| `cis-1.11` | 1.29+ | Specific version |
| `cis-1.23` | **OBSOLETE** | Removed - PSP deprecated since K8s 1.25 |

### Implemented Controls

#### API Server (K.1.2.x)

| Control | Description | Setting |
|---------|-------------|---------|
| K.1.2.3 | Block ExternalIP hijacking | `DenyServiceExternalIPs` admission plugin |
| K.1.2.9 | Limit API event flooding | `EventRateLimit` admission plugin |
| K.1.2.21 | Request timeout | `request-timeout=60s` |
| K.1.2.22 | Service account validation | `service-account-lookup=true` |

#### Kubelet (K.4.2.x)

| Control | Description | Setting |
|---------|-------------|---------|
| K.4.2.1 | Disable anonymous auth | `anonymous-auth=false` |
| K.4.2.6 | Allow iptables management | `make-iptables-util-chains=true` |
| K.4.2.8 | Limit event rate | `event-qps=5` |
| K.4.2.11 | Protect kernel defaults | `protect-kernel-defaults=true` |
| K.4.2.13 | Limit PIDs per pod | `pod-max-pids=4096` |

#### File Permissions (K.1.1.x)

| Control | Description | Implementation |
|---------|-------------|----------------|
| K.1.1.12 | etcd data ownership | `chown etcd:etcd` via systemd service |
| K.1.1.20 | PKI key permissions | `chmod 600 *.key` via systemd service |

### NeuVector Compliance

After deployment, NeuVector may report some findings as warnings. Known false positives for RKE2:

| Finding | Status | Reason |
|---------|--------|--------|
| K.4.1.8 | False positive | RKE2 manages client-ca-file automatically |
| K.4.2.3 | False positive | RKE2 provides client CA certificate |
| K.4.2.7 | Expected | `hostname-override` required for cloud compatibility |
| K.4.2.9 | False positive | RKE2 manages TLS certificates automatically |
| D.4.8 | Low risk | setgid on /var/local in pause containers |
| D.4.10 | Investigate | Check for real secrets in environment variables |

### References

- [RKE2 Security Documentation](https://docs.rke2.io/security/hardening_guide)
- [RKE2 CIS Benchmark](https://docs.rke2.io/security/cis_self_assessment16)
- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
