# K8S issues

# Show deprecation warnings
Check the current kubernetes version (v1.23.8):
```shell
$ kubectl get node -o wide
NAME     STATUS   ROLES                       AGE   VERSION          INTERNAL-IP       EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION    CONTAINER-RUNTIME
k8s-m1   Ready    control-plane,etcd,master   33d   v1.23.8+rke2r1   192.168.121.202   <none>        Debian GNU/Linux 11 (bullseye)   5.10.0-17-amd64   containerd://1.5.13-k3s1
```

2 api used are deprecated:
```shell
$ kubectl deprecations --k8s-version v1.23.8
W0820 22:09:18.237808   53625 warnings.go:70] v1 ComponentStatus is deprecated in v1.19+
W0820 22:09:18.239663   53625 warnings.go:70] policy/v1beta1 PodSecurityPolicy is deprecated in v1.21+, unavailable in v1.25+
RESULTS:
Deprecated APIs:

ComponentStatus found in /v1
	 ├─ ComponentStatus (and ComponentStatusList) holds the cluster validation info. Deprecated: This API is deprecated in v1.19+
		-> GLOBAL: controller-manager
		-> GLOBAL: etcd-0
		-> GLOBAL: scheduler

PodSecurityPolicy found in policy/v1beta1
	 ├─ PodSecurityPolicy governs the ability to make requests that affect the Security Context that will be applied to a pod and container. Deprecated in 1.21.
		-> GLOBAL: global-restricted-psp
		-> GLOBAL: global-unrestricted-psp
		-> GLOBAL: longhorn-psp
		-> GLOBAL: metallb-controller
		-> GLOBAL: metallb-speaker
		-> GLOBAL: system-unrestricted-psp


Deleted APIs:

```

# Check if I can migrate to the next kubernetes version
Suppose that the version is anterior to `v1.24.0`:
```
$ kubectl deprecations --k8s-version v1.24.0
```

If the output shows something below `Deleted APIs`, you can't migrate without break some resources.

# Delete old resources
Sometimes some charts leave some resources uninstalled, to fix it (example with neuvector):
```shell
$ kubectl delete ns neuvector
namespace "neuvector" deleted
$ kubectl get-all -o name 2>/dev/null | egrep -i neuvector | xargs kubectl delete
customresourcedefinition.apiextensions.k8s.io "nvadmissioncontrolsecurityrules.neuvector.com" deleted
customresourcedefinition.apiextensions.k8s.io "nvclustersecurityrules.neuvector.com" deleted
customresourcedefinition.apiextensions.k8s.io "nvdlpsecurityrules.neuvector.com" deleted
customresourcedefinition.apiextensions.k8s.io "nvsecurityrules.neuvector.com" deleted
customresourcedefinition.apiextensions.k8s.io "nvwafsecurityrules.neuvector.com" deleted
apiservice.apiregistration.k8s.io "v1.neuvector.com" deleted
```

# Delete a namespace get stuck

```shell
$ kubectl delete APIServices v1alpha1.
v1alpha1.argoproj.io            v1alpha1.metallb.io             v1alpha1.monitoring.coreos.com  v1alpha1.objectbucket.io        v1alpha1.tap.linkerd.io
root@k8s-m1:/vagrant/git/argocd/linkerd# kubectl delete APIServices v1alpha1.tap.linkerd.io
apiservice.apiregistration.k8s.io "v1alpha1.tap.linkerd.io" deleted
root@k8s-m1:/vagrant/git/argocd/linkerd# k describe ns demo
Name:         demo
Labels:       kubernetes.io/metadata.name=demo
Annotations:  <none>
Status:       Terminating
Conditions:
  Type                                         Status  LastTransitionTime               Reason                  Message
  ----                                         ------  ------------------               ------                  -------
  NamespaceDeletionDiscoveryFailure            True    Sat, 20 Aug 2022 20:53:55 +0000  DiscoveryFailed         Discovery failed for some groups, 1 failing: unable to retrieve the complete list of server APIs: tap.linkerd.io/v1alpha1: the server is currently unable to handle the request
  NamespaceDeletionGroupVersionParsingFailure  False   Sat, 20 Aug 2022 20:53:55 +0000  ParsedGroupVersions     All legacy kube types successfully parsed
  NamespaceDeletionContentFailure              False   Sat, 20 Aug 2022 20:53:55 +0000  ContentDeleted          All content successfully deleted, may be waiting on finalization
  NamespaceContentRemaining                    False   Sat, 20 Aug 2022 20:53:55 +0000  ContentRemoved          All content successfully removed
  NamespaceFinalizersRemaining                 False   Sat, 20 Aug 2022 20:53:55 +0000  ContentHasNoFinalizers  All content-preserving finalizers finished

No resource quota.

No LimitRange
```

We can fix it with:
```shell
$ kubectl delete APIServices v1alpha1.tap.linkerd.io
```
