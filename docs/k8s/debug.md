# Debugging

## Ephemeral container

See the [official documentation](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/):
* [Debugging with container exec](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#container-exec)
* [Debugging with an ephemeral debug container](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container)
* [Debugging using a copy of the Pod](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#debugging-using-a-copy-of-the-pod)
* [https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#node-shell-session](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#node-shell-session)

* List containers from pod pro
```bash
kubectl get pod productpage-v1-6f89b6c557-h5q6z -n bookinfo -o=jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' && echo
productpage
istio-proxy
```

* Now you can attach an ephemeral container:
```bash
kubectl --namespace bookinfo debug productpage-v1-6f89b6c557-h5q6z --image alpine --stdin --tty --target productpage
Targeting container "productpage". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-8hs2j.
If you don't see a command prompt, try pressing enter.
/ # ps faux
PID   USER     TIME  COMMAND
    1 1000      0:00 python productpage.py 9080
    9 1000      0:14 /usr/local/bin/python /opt/microservices/productpage.py 9080
  779 root      0:00 /bin/sh
  785 root      0:00 ps faux
```

```bash
kubectl get pod productpage-v1-6f89b6c557-h5q6z -n bookinfo -o=jsonpath='{.spec.ephemeralContainers[*].image}' | tr ' ' '\n' && echo
alpine
```

**WARNING**: ephemeral containers cannont be removed, the only way is to restart the pod !

```bash
kubectl rollout restart deployment -n bookinfo productpage-v1
deployment.apps/productpage-v1 restarted

kubectl get pod productpage-v1-59d6db8998-jtc7l -n bookinfo -o=jsonpath='{.spec.ephemeralContainers[*].image}' | tr ' ' '\n' && echo
```

To avoid this behaviour, you can copy it in a new pod:
```bash
kubectl --namespace bookinfo debug productpage-v1-6f89b6c557-h5q6z --image alpine --stdin --tty --share-processes --copy-to debug
```

### tcpdump
* Identify the pod to tcpdump
```bash
kubectl get pod -n bookinfo -o wide -l app=productpage
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE     NOMINATED NODE   READINESS GATES
productpage-v1-6f89b6c557-h5q6z   2/2     Running   0          21h   10.42.0.35   k8s-m1   <none>           <none>
```

### tcpdump from an ephemeral container
```bash
kubectl --namespace bookinfo debug productpage-v1-6897d4689b-p4dk5 --image dockersec/tcpdump --stdin --tty --target productpage
Targeting container "productpage". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-6j2f8.
If you don't see a command prompt, try pressing enter.
21:21:23.571100 IP 192-168-121-102.kubernetes.default.svc.cluster.local.48440 > productpage-v1-6897d4689b-p4dk5.15021: Flags [S], seq 1454537936, win 64860, options [mss 1410,sackOK,TS val 2844987463 ecr 0,nop,wscale 7], length 0
21:21:23.571125 IP productpage-v1-6897d4689b-p4dk5.15021 > 192-168-121-102.kubernetes.default.svc.cluster.local.48440: Flags [S.], seq 2420325485, ack 1454537937, win 64308, options [mss 1410,sackOK,TS val 3619822354 ecr 2844987463,nop,wscale 7], length 0
21:21:23.571146 IP 192-168-121-102.kubernetes.default.svc.cluster.local.48440 > productpage-v1-6897d4689b-p4dk5.15021: Flags [.], ack 1, win 507, options [nop,nop,TS val 2844987463 ecr 3619822354], length 0
```
Or

```bash
kubectl --namespace bookinfo debug productpage-v1-6897d4689b-p4dk5 --image dockersec/tcpdump --stdin --tty --target productpage -- sh
# tcpdump -n port 53
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
21:26:35.663586 IP 10.42.0.77.60158 > 10.43.0.10.53: 21445+ A? zipkin.istio-system.bookinfo.svc.cluster.local. (64)
21:26:35.664015 IP 10.43.0.10.53 > 10.42.0.77.60158: 21445 NXDomain*- 0/1/0 (157)
```

### from the host

* Identify the index:
```bash
kubectl exec productpage-v1-6f89b6c557-h5q6z -n bookinfo -- cat /sys/class/net/eth0/iflink
40
```

* Retreive the network from the index:
```bash
ip a | egrep ^40:
40: cali50bb99dcb26@if3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP group default
```

Or:

```bash
for i in /sys/class/net/*/ifindex; do egrep -l 40 $i; done
/sys/class/net/cali50bb99dcb26/ifindex
```


