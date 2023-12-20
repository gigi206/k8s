# Consul
## command-line
* Environment must be set:
```shell
# export CONSUL_APIGW_ADDR=http://$(kubectl get svc/api-gateway -n consul -o json | jq -r '.status.loadBalancer.ingress[0].hostname'):8080
# export CONSUL_HTTP_TOKEN=$(kubectl get -n consul secrets consul-bootstrap-acl-token --template={{.data.token}} | base64 -d)
export CONSUL_HTTP_SSL_VERIFY=false
export CONSUL_HTTP_ADDR=consul.gigix
```

### members
```shell
$ consul members
Node                    Address           Status  Type    Build   Protocol  DC   Partition  Segment
consul-consul-server-0  10.42.0.235:8301  alive   server  1.17.0  2         dc1  default    <all>
```

```shell
members --detailed
Node                    Address           Status  Tags
consul-consul-server-0  10.42.0.235:8301  alive   acls=0,ap=default,bootstrap=1,build=1.17.0:4e3f428b,dc=dc1,ft_fs=1,ft_si=1,grpc_port=8502,id=0a9ca71f-0488-68c4-8bec-b310e80f7d99,port=8300,raft_vsn=3,role=consul,segment=<all>,vsn=2,vsn_max=3,vsn_min=2,wan_join_port=8302
```

### catalog
* services:
```shell
$ consul catalog services
consul
```
Or with API:
```shell
curl -sk https://consul.gigix/v1/catalog/services | jq
```

* datacenters:
```shell
$ consul catalog datacenters
dc1
```

Or with API:
```shell
curl -sk https://consul.gigix/v1/catalog/datasenters | jq
```

* nodes:
```shell
$ consul catalog nodes
Node                    ID        Address      DC
consul-consul-server-0  0a9ca71f  10.42.0.235  dc1
```

Or with API:
```shell
curl -sk https://consul.gigix/v1/catalog/nodes | jq
```

### intention
```shell
consul intention list
```

## Configuration
Use the following command to start server and client:
```shell
consul agent -config-dir=/etc/consuld.d
```

Following config for client and server must be put in `/etc/consuld.d/config.hcl`.

### Server
* Example basic configuration server (without K8S):
```hcl
# https://developer.hashicorp.com/consul/docs/agent
advertise_addr = "192.168.121.1"
bind_addr = "192.168.121.1"
bootstrap_expect = 1
client_addr = "0.0.0.0"
datacenter = "mydc"
data_dir = "/home/gigi/consul/server/data"
domain = "consul"
enable_script_checks = true
dns_config = {
    enable_truncate = true
    only_passing = true
}
enable_syslog = true
leave_on_terminate = true
log_level = "INFO"
rejoin_after_leave = true
retry_join = [
    "192.168.121.1"
]
server = true
start_join = [
    "192.168.121.1"
],
ui = true
```

### Client
* Basic client configuration (port **8301** is used by default to join server):
```hcl
# https://developer.hashicorp.com/consul/docs/agent
advertise_addr = "192.168.121.2"
bind_addr = "192.168.121.2"
client_addr = "0.0.0.0"
datacenter = "mydc"
data_dir = "/home/gigi/consul/client/data"
domain = "consul"
enable_script_checks = true
dns_config = {
    enable_truncate = true
    only_passing    = true
}
enable_syslog = true
leave_on_terminate = true
log_level = "INFO"
rejoin_after_leave = true
retry_join = [
    "192.168.121.1"
]
```