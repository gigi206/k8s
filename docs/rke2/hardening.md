# RKE 2

## Hardening

### CIS

Please read the official [documentation](https://docs.rke2.io/security/policies/)

Add to `/etc/rancher/rke2/config.yalm`:

```
# profile: cis-1.6
profile: cis-1.23
```

The profile `cis-1.6` is deprecated since kubernetes **1.25** due to the deprecation of PSP (Pod Security Policy) and it as been replaced by PSA (Pod Security Admission). Due to the deprecation of the PSP in the 1.25 kubernetes release, use [cis-1.23](https://github.com/rancher/rke2/pull/3282/files#diff-75d7f580c10292938388f76ada5b7b1a01ecd477ef604d40bbe0802c7451740eR65) instead.
