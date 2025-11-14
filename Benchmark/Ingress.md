# Benchmark
## Test deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quote
  namespace: quote
spec:
  replicas: 1
  selector:
    matchLabels:
      app: quote
  strategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: quote
    spec:
      containers:
      - name: backend
        image: docker.io/datawire/quote:0.5.0
        ports:
        - name: http
          containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: quote
  namespace: quote
spec:
  ports:
  - name: http
    port: 80
    targetPort: 8080
  selector:
    app: quote
```

## Compare results
```shell
egrep -A25 -- "^###.*1$" benchmark.yaml | egrep -v \`
egrep -A25 -- "^###.*10$" benchmark.yaml | egrep -v \`
egrep -A25 -- "^###.*100$" benchmark.yaml | egrep -v \`
egrep -A25 -- "^###.*1000$" benchmark.yaml | egrep -v \`
egrep -A25 -- "^###.*10000$" benchmark.yaml | egrep -v \`
```


## Without ingress (LoadBalancer service)
### Without ingress (LoadBalancer service) 1
```shell
hey -n 100000 -c 1 http://192.168.121.241

Summary:
  Total:	10.4206 secs
  Slowest:	0.0033 secs
  Fastest:	0.0001 secs
  Average:	0.0001 secs
  Requests/sec:	9596.3684

  Total data:	15367745 bytes
  Size/request:	153 bytes

Response time histogram:
  0.000 [1]	|
  0.000 [99166]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.001 [758]	|
  0.001 [54]	|
  0.001 [11]	|
  0.002 [4]	|
  0.002 [4]	|
  0.002 [0]	|
  0.003 [1]	|
  0.003 [0]	|
  0.003 [1]	|


Latency distribution:
  10% in 0.0001 secs
  25% in 0.0001 secs
  50% in 0.0001 secs
  75% in 0.0001 secs
  90% in 0.0001 secs
  95% in 0.0002 secs
  99% in 0.0004 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0033 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0000 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0003 secs
  resp wait:	0.0001 secs, 0.0000 secs, 0.0033 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0004 secs

Status code distribution:
  [200]	100000 responses
```


### Without ingress (LoadBalancer service) 10
```shell
hey -n 100000 -c 10 http://192.168.121.241

Summary:
  Total:	2.6026 secs
  Slowest:	0.0133 secs
  Fastest:	0.0001 secs
  Average:	0.0003 secs
  Requests/sec:	38423.5688

  Total data:	15366181 bytes
  Size/request:	153 bytes

Response time histogram:
  0.000 [1]	|
  0.001 [99766]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.003 [209]	|
  0.004 [14]	|
  0.005 [0]	|
  0.007 [0]	|
  0.008 [0]	|
  0.009 [0]	|
  0.011 [0]	|
  0.012 [0]	|
  0.013 [10]	|


Latency distribution:
  10% in 0.0001 secs
  25% in 0.0002 secs
  50% in 0.0002 secs
  75% in 0.0003 secs
  90% in 0.0004 secs
  95% in 0.0006 secs
  99% in 0.0009 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0133 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0000 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0011 secs
  resp wait:	0.0002 secs, 0.0001 secs, 0.0132 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0010 secs

Status code distribution:
  [200]	100000 responses
```


### Without ingress (LoadBalancer service) 100
```shell
hey -n 100000 -c 100 http://192.168.121.241

Summary:
  Total:	2.1341 secs
  Slowest:	0.0765 secs
  Fastest:	0.0001 secs
  Average:	0.0021 secs
  Requests/sec:	46858.2698

  Total data:	15365788 bytes
  Size/request:	153 bytes

Response time histogram:
  0.000 [1]	|
  0.008 [97964]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.015 [1875]	|■
  0.023 [36]	|
  0.031 [18]	|
  0.038 [16]	|
  0.046 [27]	|
  0.054 [0]	|
  0.061 [29]	|
  0.069 [30]	|
  0.076 [4]	|


Latency distribution:
  10% in 0.0004 secs
  25% in 0.0007 secs
  50% in 0.0014 secs
  75% in 0.0028 secs
  90% in 0.0047 secs
  95% in 0.0058 secs
  99% in 0.0092 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0765 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0000 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0372 secs
  resp wait:	0.0020 secs, 0.0001 secs, 0.0415 secs
  resp read:	0.0001 secs, 0.0000 secs, 0.0602 secs

Status code distribution:
  [200]	100000 responses
```


### Without ingress (LoadBalancer service) 1000
```shell
hey -n 1000000 -c 1000 http://192.168.121.241

Summary:
  Total:	11.5561 secs
  Slowest:	0.2352 secs
  Fastest:	0.0001 secs
  Average:	0.0113 secs
  Requests/sec:	86534.3295

  Total data:	153698297 bytes
  Size/request:	153 bytes

Response time histogram:
  0.000 [1]	|
  0.024 [919760]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.047 [72891]	|■■■
  0.071 [5869]	|
  0.094 [465]	|
  0.118 [126]	|
  0.141 [2]	|
  0.165 [430]	|
  0.188 [27]	|
  0.212 [65]	|
  0.235 [364]	|


Latency distribution:
  10% in 0.0040 secs
  25% in 0.0059 secs
  50% in 0.0088 secs
  75% in 0.0137 secs
  90% in 0.0216 secs
  95% in 0.0278 secs
  99% in 0.0437 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.2352 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0000 secs
  req write:	0.0000 secs, 0.0000 secs, 0.1535 secs
  resp wait:	0.0100 secs, 0.0001 secs, 0.2328 secs
  resp read:	0.0009 secs, 0.0000 secs, 0.0487 secs

Status code distribution:
  [200]	1000000 responses
```


### Without ingress (LoadBalancer service) 10000
```shell
hey -n 1000000 -c 10000 http://192.168.121.241

Summary:
  Total:	22.5087 secs
  Slowest:	15.0441 secs
  Fastest:	0.0001 secs
  Average:	0.1447 secs
  Requests/sec:	44427.3280

  Total data:	153718626 bytes
  Size/request:	153 bytes

Response time histogram:
  0.000 [1]	|
  1.504 [989375]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  3.009 [5491]	|
  4.513 [3161]	|
  6.018 [7]	|
  7.522 [1409]	|
  9.026 [150]	|
  10.531 [0]	|
  12.035 [0]	|
  13.540 [0]	|
  15.044 [406]	|


Latency distribution:
  10% in 0.0066 secs
  25% in 0.0106 secs
  50% in 0.0169 secs
  75% in 0.0950 secs
  90% in 0.3547 secs
  95% in 0.6102 secs
  99% in 1.6075 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0010 secs, 0.0001 secs, 15.0441 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0000 secs
  req write:	0.0003 secs, 0.0000 secs, 0.6002 secs
  resp wait:	0.1351 secs, 0.0000 secs, 15.0425 secs
  resp read:	0.0046 secs, 0.0000 secs, 0.7863 secs

Status code distribution:
  [200]	1000000 responses
```


## Ingresses
### emissary-ingress
#### emissary-ingress 1
```shell
hey -n 100000 -c 1 http://quote.gigix/

Summary:
  Total:	16.0155 secs
  Slowest:	0.0067 secs
  Fastest:	0.0001 secs
  Average:	0.0002 secs
  Requests/sec:	6243.9408

  Total data:	15547155 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.001 [99838]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.001 [123]	|
  0.002 [23]	|
  0.003 [5]	|
  0.003 [7]	|
  0.004 [0]	|
  0.005 [2]	|
  0.005 [0]	|
  0.006 [0]	|
  0.007 [1]	|


Latency distribution:
  10% in 0.0001 secs
  25% in 0.0001 secs
  50% in 0.0001 secs
  75% in 0.0002 secs
  90% in 0.0002 secs
  95% in 0.0002 secs
  99% in 0.0003 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0067 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0001 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0006 secs
  resp wait:	0.0001 secs, 0.0001 secs, 0.0067 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0003 secs

Status code distribution:
  [200]	100000 responses
```


#### emissary-ingress 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	3.9867 secs
  Slowest:	0.0107 secs
  Fastest:	0.0001 secs
  Average:	0.0004 secs
  Requests/sec:	25083.3178

  Total data:	15570683 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.001 [98899]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.002 [914]	|
  0.003 [106]	|
  0.004 [35]	|
  0.005 [6]	|
  0.006 [22]	|
  0.008 [3]	|
  0.009 [12]	|
  0.010 [1]	|
  0.011 [1]	|


Latency distribution:
  10% in 0.0003 secs
  25% in 0.0003 secs
  50% in 0.0004 secs
  75% in 0.0004 secs
  90% in 0.0005 secs
  95% in 0.0007 secs
  99% in 0.0012 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0107 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0005 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0007 secs
  resp wait:	0.0004 secs, 0.0001 secs, 0.0107 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0008 secs

Status code distribution:
  [200]	100000 responses
```


#### emissary-ingress 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	1.9334 secs
  Slowest:	0.0344 secs
  Fastest:	0.0002 secs
  Average:	0.0019 secs
  Requests/sec:	51722.4237

  Total data:	15572784 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.004 [93196]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.007 [6274]	|■■■
  0.010 [358]	|
  0.014 [45]	|
  0.017 [26]	|
  0.021 [0]	|
  0.024 [0]	|
  0.028 [0]	|
  0.031 [0]	|
  0.034 [100]	|


Latency distribution:
  10% in 0.0010 secs
  25% in 0.0013 secs
  50% in 0.0016 secs
  75% in 0.0022 secs
  90% in 0.0031 secs
  95% in 0.0040 secs
  99% in 0.0060 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0002 secs, 0.0344 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0293 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0031 secs
  resp wait:	0.0018 secs, 0.0001 secs, 0.0171 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0027 secs

Status code distribution:
  [200]	100000 responses
```


#### emissary-ingress 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	18.3205 secs
  Slowest:	0.2584 secs
  Fastest:	0.0002 secs
  Average:	0.0180 secs
  Requests/sec:	54583.6731

  Total data:	165492650 bytes
  Size/request:	165 bytes

Response time histogram:
  0.000 [1]	|
  0.026 [826156]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.052 [165957]	|■■■■■■■■
  0.078 [6872]	|
  0.103 [631]	|
  0.129 [68]	|
  0.155 [168]	|
  0.181 [1]	|
  0.207 [0]	|
  0.233 [93]	|
  0.258 [53]	|


Latency distribution:
  10% in 0.0078 secs
  25% in 0.0112 secs
  50% in 0.0159 secs
  75% in 0.0227 secs
  90% in 0.0309 secs
  95% in 0.0370 secs
  99% in 0.0499 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0002 secs, 0.2584 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.1055 secs
  req write:	0.0000 secs, 0.0000 secs, 0.1083 secs
  resp wait:	0.0176 secs, 0.0002 secs, 0.2524 secs
  resp read:	0.0003 secs, 0.0000 secs, 0.0251 secs

Status code distribution:
  [200]	1000000 responses
```


#### emissary-ingress 10000
```shell
hey -n 1000000 -c 10000 http://quote.gigix/

Summary:
  Total:	73.3784 secs
  Slowest:	28.8209 secs
  Fastest:	0.0001 secs
  Average:	0.5913 secs
  Requests/sec:	13627.9928

  Total data:	109393125 bytes
  Size/request:	111 bytes

Response time histogram:
  0.000 [1]	|
  2.882 [927571]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  5.764 [18315]	|■
  8.646 [20711]	|■
  11.528 [7806]	|
  14.411 [2236]	|
  17.293 [1225]	|
  20.175 [852]	|
  23.057 [9]	|
  25.939 [2]	|
  28.821 [2]	|


Latency distribution:
  10% in 0.0142 secs
  25% in 0.0258 secs
  50% in 0.0634 secs
  75% in 0.2924 secs
  90% in 1.0913 secs
  95% in 3.2219 secs
  99% in 9.1159 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0036 secs, 0.0001 secs, 28.8209 secs
  DNS-lookup:	0.0997 secs, 0.0000 secs, 19.9894 secs
  req write:	0.0185 secs, 0.0000 secs, 18.4862 secs
  resp wait:	0.2758 secs, 0.0001 secs, 15.0649 secs
  resp read:	0.0840 secs, 0.0000 secs, 18.5513 secs

Status code distribution:
  [200]	591796 responses
  [503]	386934 responses

Error distribution:
  [717]	Get "http://quote.gigix/": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
  [20546]	Get "http://quote.gigix/": dial tcp 192.168.121.252:80: connect: cannot assign requested address
  [7]	Get "http://quote.gigix/": dial tcp 192.168.121.252:80: connect: connection refused
```


### Traefik
#### Traefik 1
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	269.8063 secs
  Slowest:	11.2852 secs
  Fastest:	0.0002 secs
  Average:	0.2663 secs
  Requests/sec:	3706.3629

  Total data:	151022779 bytes
  Size/request:	151 bytes

Response time histogram:
  0.000 [1]	|
  1.129 [958533]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  2.257 [28246]	|■
  3.386 [5678]	|
  4.514 [3998]	|
  5.643 [2350]	|
  6.771 [754]	|
  7.900 [329]	|
  9.028 [56]	|
  10.157 [49]	|
  11.285 [6]	|


Latency distribution:
  10% in 0.0105 secs
  25% in 0.0241 secs
  50% in 0.0613 secs
  75% in 0.2555 secs
  90% in 0.7954 secs
  95% in 1.0529 secs
  99% in 2.8413 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0001 secs, 0.0002 secs, 11.2852 secs
  DNS-lookup:	0.0001 secs, 0.0000 secs, 0.0940 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0460 secs
  resp wait:	0.2571 secs, 0.0002 secs, 11.2852 secs
  resp read:	0.0090 secs, 0.0000 secs, 3.3037 secs

Status code distribution:
  [200]	967714 responses
  [502]	32286 responses
```


#### Traefik 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	4.2376 secs
  Slowest:	0.0069 secs
  Fastest:	0.0001 secs
  Average:	0.0004 secs
  Requests/sec:	23598.3498

  Total data:	15558140 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.001 [96537]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.001 [2484]	|■
  0.002 [638]	|
  0.003 [223]	|
  0.004 [47]	|
  0.004 [34]	|
  0.005 [14]	|
  0.006 [0]	|
  0.006 [11]	|
  0.007 [11]	|


Latency distribution:
  10% in 0.0003 secs
  25% in 0.0003 secs
  50% in 0.0004 secs
  75% in 0.0005 secs
  90% in 0.0005 secs
  95% in 0.0007 secs
  99% in 0.0015 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0069 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0003 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0008 secs
  resp wait:	0.0004 secs, 0.0001 secs, 0.0068 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0006 secs

Status code distribution:
  [200]	100000 responses
```


#### Traefik 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	1.9610 secs
  Slowest:	0.0309 secs
  Fastest:	0.0002 secs
  Average:	0.0019 secs
  Requests/sec:	50993.9368

  Total data:	15561023 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.003 [89918]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.006 [9093]	|■■■■
  0.009 [772]	|
  0.012 [123]	|
  0.016 [0]	|
  0.019 [0]	|
  0.022 [0]	|
  0.025 [10]	|
  0.028 [31]	|
  0.031 [52]	|


Latency distribution:
  10% in 0.0010 secs
  25% in 0.0013 secs
  50% in 0.0016 secs
  75% in 0.0021 secs
  90% in 0.0032 secs
  95% in 0.0041 secs
  99% in 0.0063 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0002 secs, 0.0309 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0246 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0021 secs
  resp wait:	0.0018 secs, 0.0001 secs, 0.0242 secs
  resp read:	0.0001 secs, 0.0000 secs, 0.0030 secs

Status code distribution:
  [200]	100000 responses
```


#### Traefik 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	269.8063 secs
  Slowest:	11.2852 secs
  Fastest:	0.0002 secs
  Average:	0.2663 secs
  Requests/sec:	3706.3629

  Total data:	151022779 bytes
  Size/request:	151 bytes

Response time histogram:
  0.000 [1]	|
  1.129 [958533]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  2.257 [28246]	|■
  3.386 [5678]	|
  4.514 [3998]	|
  5.643 [2350]	|
  6.771 [754]	|
  7.900 [329]	|
  9.028 [56]	|
  10.157 [49]	|
  11.285 [6]	|


Latency distribution:
  10% in 0.0105 secs
  25% in 0.0241 secs
  50% in 0.0613 secs
  75% in 0.2555 secs
  90% in 0.7954 secs
  95% in 1.0529 secs
  99% in 2.8413 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0001 secs, 0.0002 secs, 11.2852 secs
  DNS-lookup:	0.0001 secs, 0.0000 secs, 0.0940 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0460 secs
  resp wait:	0.2571 secs, 0.0002 secs, 11.2852 secs
  resp read:	0.0090 secs, 0.0000 secs, 3.3037 secs

Status code distribution:
  [200]	967714 responses
  [502]	32286 responses
```

#### Traefik 10000
Not tested because Treafik crash at 1000 connections.


## Nginx
#### Nginx 1
```shell
hey -n 100000 -c 1 http://quote.gigix/

Summary:
  Total:	13.2884 secs
  Slowest:	0.0168 secs
  Fastest:	0.0001 secs
  Average:	0.0001 secs
  Requests/sec:	7525.3586

  Total data:	15560407 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.002 [99974]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.003 [19]	|
  0.005 [3]	|
  0.007 [1]	|
  0.008 [0]	|
  0.010 [1]	|
  0.012 [0]	|
  0.013 [0]	|
  0.015 [0]	|
  0.017 [1]	|


Latency distribution:
  10% in 0.0001 secs
  25% in 0.0001 secs
  50% in 0.0001 secs
  75% in 0.0001 secs
  90% in 0.0002 secs
  95% in 0.0002 secs
  99% in 0.0003 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0168 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0002 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0003 secs
  resp wait:	0.0001 secs, 0.0001 secs, 0.0164 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0003 secs

Status code distribution:
  [200]	100000 responses
```


#### Nginx 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	4.3331 secs
  Slowest:	0.0215 secs
  Fastest:	0.0001 secs
  Average:	0.0004 secs
  Requests/sec:	23078.4274

  Total data:	15571003 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.002 [99048]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.004 [663]	|
  0.007 [167]	|
  0.009 [72]	|
  0.011 [20]	|
  0.013 [15]	|
  0.015 [6]	|
  0.017 [6]	|
  0.019 [1]	|
  0.021 [1]	|


Latency distribution:
  10% in 0.0002 secs
  25% in 0.0003 secs
  50% in 0.0003 secs
  75% in 0.0004 secs
  90% in 0.0006 secs
  95% in 0.0009 secs
  99% in 0.0022 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0215 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0005 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0024 secs
  resp wait:	0.0004 secs, 0.0001 secs, 0.0214 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0007 secs

Status code distribution:
  [200]	100000 responses
```


#### Nginx 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	2.2562 secs
  Slowest:	0.0454 secs
  Fastest:	0.0001 secs
  Average:	0.0022 secs
  Requests/sec:	44323.1061

  Total data:	15567959 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.005 [93135]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.009 [5444]	|■■
  0.014 [757]	|
  0.018 [372]	|
  0.023 [72]	|
  0.027 [25]	|
  0.032 [99]	|
  0.036 [4]	|
  0.041 [87]	|
  0.045 [4]	|


Latency distribution:
  10% in 0.0009 secs
  25% in 0.0012 secs
  50% in 0.0017 secs
  75% in 0.0024 secs
  90% in 0.0038 secs
  95% in 0.0054 secs
  99% in 0.0112 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0454 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0346 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0048 secs
  resp wait:	0.0021 secs, 0.0001 secs, 0.0340 secs
  resp read:	0.0001 secs, 0.0000 secs, 0.0052 secs

Status code distribution:
  [200]	100000 responses
```


#### Nginx 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	22.6452 secs
  Slowest:	0.3517 secs
  Fastest:	0.0002 secs
  Average:	0.0223 secs
  Requests/sec:	44159.5599

  Total data:	165498050 bytes
  Size/request:	165 bytes

Response time histogram:
  0.000 [1]	|
  0.035 [857011]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.070 [125769]	|■■■■■■
  0.106 [14795]	|■
  0.141 [1506]	|
  0.176 [328]	|
  0.211 [61]	|
  0.246 [412]	|
  0.281 [94]	|
  0.317 [18]	|
  0.352 [5]	|


Latency distribution:
  10% in 0.0088 secs
  25% in 0.0126 secs
  50% in 0.0181 secs
  75% in 0.0272 secs
  90% in 0.0404 secs
  95% in 0.0512 secs
  99% in 0.0808 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0002 secs, 0.3517 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.1279 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0378 secs
  resp wait:	0.0216 secs, 0.0001 secs, 0.3201 secs
  resp read:	0.0005 secs, 0.0000 secs, 0.0380 secs

Status code distribution:
  [200]	1000000 responses
```

#### Nginx 10000
```shell
hey -n 1000000 -c 10000 http://quote.gigix/

Summary:
  Total:	128.6002 secs
  Slowest:	17.6125 secs
  Fastest:	0.0002 secs
  Average:	1.0900 secs
  Requests/sec:	7776.0356

  Total data:	119009102 bytes
  Size/request:	133 bytes

Response time histogram:
  0.000 [1]	|
  1.761 [740135]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  3.523 [59339]	|■■■
  5.284 [35354]	|■■
  7.045 [28834]	|■■
  8.806 [17855]	|■
  10.568 [9625]	|■
  12.329 [1843]	|
  14.090 [338]	|
  15.851 [60]	|
  17.613 [23]	|


Latency distribution:
  10% in 0.0333 secs
  25% in 0.0799 secs
  50% in 0.2280 secs
  75% in 0.9362 secs
  90% in 3.7950 secs
  95% in 5.9842 secs
  99% in 9.1479 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0044 secs, 0.0002 secs, 17.6125 secs
  DNS-lookup:	0.0019 secs, 0.0000 secs, 0.6799 secs
  req write:	0.0006 secs, 0.0000 secs, 0.4869 secs
  resp wait:	1.0101 secs, 0.0001 secs, 14.6984 secs
  resp read:	0.0026 secs, 0.0000 secs, 0.8620 secs

Status code distribution:
  [200]	828356 responses
  [502]	65049 responses
  [504]	2 responses

Error distribution:
  [5412]	Get "http://quote.gigix/": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
  [90839]	Get "http://quote.gigix/": dial tcp 192.168.121.13:80: connect: connection refused
  [10]	Get "http://quote.gigix/": dial tcp 192.168.121.13:80: connect: connection reset by peer
  [3366]	Get "http://quote.gigix/": dial tcp 192.168.121.13:80: i/o timeout (Client.Timeout exceeded while awaiting headers)
  [2]	Get "http://quote.gigix/": read tcp 192.168.121.1:32776->192.168.121.13:80: read: connection reset by peer
  [1]	Get "http://quote.gigix/": read tcp 192.168.121.1:32782->192.168.121.13:80: read: connection reset by peer
  [3]	Get "http://quote.gigix/": read tcp 192.168.121.1:32798->192.168.121.13:80: read: connection reset by peer
  [2]	Get "http://quote.gigix/": read tcp 192.168.121.1:32802->192.168.121.13:80: read: connection reset by peer
  [1]	Get "http://quote.gigix/": read tcp 192.168.121.1:32810->192.168.121.13:80: read: connection reset by peer
  [1]	Get "http://quote.gigix/": read tcp 192.168.121.1:32812->192.168.121.13:80: read: connection reset by peer
  [3]	Get "http://quote.gigix/": read tcp 192.168.121.1:32814->192.168.121.13:80: read: connection reset by peer
...
...
...
```

### Kong
#### Kong 1
```shell
hey -n 100000 -c 1 http://quote.gigix/

Summary:
  Total:	12.3610 secs
  Slowest:	0.0196 secs
  Fastest:	0.0001 secs
  Average:	0.0001 secs
  Requests/sec:	8089.9591

  Total data:	15577590 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.002 [99986]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.004 [9]	|
  0.006 [1]	|
  0.008 [0]	|
  0.010 [0]	|
  0.012 [0]	|
  0.014 [2]	|
  0.016 [0]	|
  0.018 [0]	|
  0.020 [1]	|


Latency distribution:
  10% in 0.0001 secs
  25% in 0.0001 secs
  50% in 0.0001 secs
  75% in 0.0001 secs
  90% in 0.0001 secs
  95% in 0.0002 secs
  99% in 0.0003 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0196 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0001 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0002 secs
  resp wait:	0.0001 secs, 0.0001 secs, 0.0195 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0006 secs

Status code distribution:
  [200]	100000 responses
```


#### Kong 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	3.0788 secs
  Slowest:	0.0064 secs
  Fastest:	0.0001 secs
  Average:	0.0003 secs
  Requests/sec:	32480.0606

  Total data:	15578327 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.001 [98075]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.001 [1569]	|■
  0.002 [256]	|
  0.003 [32]	|
  0.003 [16]	|
  0.004 [8]	|
  0.004 [23]	|
  0.005 [10]	|
  0.006 [0]	|
  0.006 [10]	|


Latency distribution:
  10% in 0.0002 secs
  25% in 0.0002 secs
  50% in 0.0003 secs
  75% in 0.0004 secs
  90% in 0.0005 secs
  95% in 0.0006 secs
  99% in 0.0009 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0064 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0003 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0004 secs
  resp wait:	0.0003 secs, 0.0001 secs, 0.0063 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0007 secs

Status code distribution:
  [200]	100000 responses
```


#### Kong 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	2.4720 secs
  Slowest:	0.0396 secs
  Fastest:	0.0001 secs
  Average:	0.0024 secs
  Requests/sec:	40453.5160

  Total data:	15564926 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.004 [96140]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.008 [3669]	|■■
  0.012 [52]	|
  0.016 [46]	|
  0.020 [0]	|
  0.024 [0]	|
  0.028 [0]	|
  0.032 [0]	|
  0.036 [4]	|
  0.040 [88]	|


Latency distribution:
  10% in 0.0017 secs
  25% in 0.0020 secs
  50% in 0.0023 secs
  75% in 0.0027 secs
  90% in 0.0033 secs
  95% in 0.0039 secs
  99% in 0.0051 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0396 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0323 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0018 secs
  resp wait:	0.0024 secs, 0.0001 secs, 0.0142 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0019 secs

Status code distribution:
  [200]	100000 responses
```


#### Kong 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	35.9126 secs
  Slowest:	0.2831 secs
  Fastest:	0.0001 secs
  Average:	0.0351 secs
  Requests/sec:	27845.3984

  Total data:	165499501 bytes
  Size/request:	165 bytes

Response time histogram:
  0.000 [1]	|
  0.028 [565614]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.057 [274930]	|■■■■■■■■■■■■■■■■■■■
  0.085 [155223]	|■■■■■■■■■■■
  0.113 [3750]	|
  0.142 [216]	|
  0.170 [167]	|
  0.198 [0]	|
  0.227 [21]	|
  0.255 [34]	|
  0.283 [44]	|


Latency distribution:
  10% in 0.0168 secs
  25% in 0.0209 secs
  50% in 0.0248 secs
  75% in 0.0519 secs
  90% in 0.0615 secs
  95% in 0.0662 secs
  99% in 0.0754 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.2831 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.1417 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0565 secs
  resp wait:	0.0350 secs, 0.0001 secs, 0.2780 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0298 secs

Status code distribution:
  [200]	1000000 responses
```


#### Kong 10000
```shell
hey -n 1000000 -c 10000 http://quote.gigix/

Summary:
  Total:	252.0948 secs
  Slowest:	19.9865 secs
  Fastest:	0.0001 secs
  Average:	2.5469 secs
  Requests/sec:	3966.7621

  Total data:	84485856 bytes
  Size/request:	134 bytes

Response time histogram:
  0.000 [1]	|
  1.999 [455859]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  3.997 [55438]	|■■■■■
  5.996 [20271]	|■■
  7.995 [25337]	|■■
  9.993 [26042]	|■■
  11.992 [14361]	|■
  13.991 [7356]	|■
  15.989 [8275]	|■
  17.988 [7698]	|■
  19.987 [6210]	|■


Latency distribution:
  10% in 0.1537 secs
  25% in 0.3831 secs
  50% in 0.8052 secs
  75% in 2.1046 secs
  90% in 8.5678 secs
  95% in 11.4757 secs
  99% in 17.8440 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0138 secs, 0.0001 secs, 19.9865 secs
  DNS-lookup:	0.0087 secs, 0.0000 secs, 1.0815 secs
  req write:	0.0006 secs, 0.0000 secs, 0.7047 secs
  resp wait:	2.3018 secs, 0.0001 secs, 19.9865 secs
  resp read:	0.0013 secs, 0.0000 secs, 0.4023 secs

Status code distribution:
  [200]	603658 responses
  [502]	23190 responses

Error distribution:
  [8626]	Get "http://quote.gigix/": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
  [363415]	Get "http://quote.gigix/": dial tcp 192.168.121.226:80: connect: connection refused
  [1]	Get "http://quote.gigix/": read tcp 192.168.121.1:40612->192.168.121.226:80: read: connection reset by peer
  [1]	Get "http://quote.gigix/": read tcp 192.168.121.1:40626->192.168.121.226:80: read: connection reset by peer
  [1]	Get "http://quote.gigix/": read tcp 192.168.121.1:40640->192.168.121.226:80: read: connection reset by peer
...
...
...
```


### Apisix
#### Apisix 1
```shell
hey -n 100000 -c 1 http://quote.gigix/

Summary:
  Total:	10.8846 secs
  Slowest:	0.0232 secs
  Fastest:	0.0001 secs
  Average:	0.0001 secs
  Requests/sec:	9187.3139

  Total data:	15574991 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.002 [99985]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.005 [10]	|
  0.007 [2]	|
  0.009 [1]	|
  0.012 [0]	|
  0.014 [0]	|
  0.016 [0]	|
  0.019 [0]	|
  0.021 [0]	|
  0.023 [1]	|


Latency distribution:
  10% in 0.0001 secs
  25% in 0.0001 secs
  50% in 0.0001 secs
  75% in 0.0001 secs
  90% in 0.0001 secs
  95% in 0.0001 secs
  99% in 0.0003 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0232 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0001 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0003 secs
  resp wait:	0.0001 secs, 0.0001 secs, 0.0231 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0002 secs

Status code distribution:
  [200]	100000 responses
```


#### Apisix 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	3.0559 secs
  Slowest:	0.1071 secs
  Fastest:	0.0001 secs
  Average:	0.0003 secs
  Requests/sec:	32723.2566

  Total data:	15561174 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.011 [99989]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.021 [4]	|
  0.032 [3]	|
  0.043 [1]	|
  0.054 [1]	|
  0.064 [0]	|
  0.075 [0]	|
  0.086 [0]	|
  0.096 [0]	|
  0.107 [1]	|


Latency distribution:
  10% in 0.0002 secs
  25% in 0.0002 secs
  50% in 0.0003 secs
  75% in 0.0003 secs
  90% in 0.0004 secs
  95% in 0.0005 secs
  99% in 0.0011 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.1071 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0004 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0005 secs
  resp wait:	0.0003 secs, 0.0001 secs, 0.1071 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0007 secs

Status code distribution:
  [200]	100000 responses
```


#### Apisix 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	1.5193 secs
  Slowest:	0.0676 secs
  Fastest:	0.0001 secs
  Average:	0.0015 secs
  Requests/sec:	65818.6005

  Total data:	15558129 bytes
  Size/request:	155 bytes

Response time histogram:
  0.000 [1]	|
  0.007 [99479]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.014 [361]	|
  0.020 [0]	|
  0.027 [9]	|
  0.034 [97]	|
  0.041 [5]	|
  0.047 [0]	|
  0.054 [0]	|
  0.061 [27]	|
  0.068 [21]	|


Latency distribution:
  10% in 0.0007 secs
  25% in 0.0009 secs
  50% in 0.0012 secs
  75% in 0.0016 secs
  90% in 0.0025 secs
  95% in 0.0033 secs
  99% in 0.0053 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0676 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0554 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0034 secs
  resp wait:	0.0014 secs, 0.0001 secs, 0.0550 secs
  resp read:	0.0001 secs, 0.0000 secs, 0.0255 secs

Status code distribution:
  [200]	100000 responses
```


#### Apisix 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	14.2449 secs
  Slowest:	0.3967 secs
  Fastest:	0.0001 secs
  Average:	0.0140 secs
  Requests/sec:	70200.8066

  Total data:	165447391 bytes
  Size/request:	165 bytes

Response time histogram:
  0.000 [1]	|
  0.040 [982232]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.079 [15894]	|■
  0.119 [1097]	|
  0.159 [268]	|
  0.198 [162]	|
  0.238 [229]	|
  0.278 [49]	|
  0.317 [0]	|
  0.357 [1]	|
  0.397 [67]	|


Latency distribution:
  10% in 0.0063 secs
  25% in 0.0087 secs
  50% in 0.0118 secs
  75% in 0.0165 secs
  90% in 0.0236 secs
  95% in 0.0295 secs
  99% in 0.0467 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.3967 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.1136 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0257 secs
  resp wait:	0.0133 secs, 0.0001 secs, 0.3951 secs
  resp read:	0.0005 secs, 0.0000 secs, 0.0305 secs

Status code distribution:
  [200]	1000000 responses
```


#### Apisix 10000
```shell
hey -n 1000000 -c 10000 http://quote.gigix/

Summary:
  Total:	17.5555 secs
  Slowest:	15.0521 secs
  Fastest:	0.0001 secs
  Average:	0.1397 secs
  Requests/sec:	56962.0595

  Total data:	131889136 bytes
  Size/request:	131 bytes

Response time histogram:
  0.000 [1]	|
  1.505 [989321]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  3.010 [7637]	|
  4.516 [2499]	|
  6.021 [1]	|
  7.526 [57]	|
  9.031 [355]	|
  10.537 [0]	|
  12.042 [0]	|
  13.547 [0]	|
  15.052 [129]	|


Latency distribution:
  10% in 0.0116 secs
  25% in 0.0168 secs
  50% in 0.0294 secs
  75% in 0.1106 secs
  90% in 0.3168 secs
  95% in 0.5251 secs
  99% in 1.6456 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0008 secs, 0.0001 secs, 15.0521 secs
  DNS-lookup:	0.0010 secs, 0.0000 secs, 0.3855 secs
  req write:	0.0003 secs, 0.0000 secs, 0.3679 secs
  resp wait:	0.1342 secs, 0.0001 secs, 14.8426 secs
  resp read:	0.0018 secs, 0.0000 secs, 0.3759 secs

Status code distribution:
  [200]	1000000 responses
```

### HAProxyTech
#### HAProxyTech 1
```shell
hey -n 100000 -c 1 http://quote.gigix/

Summary:
  Total:	9.6031 secs
  Slowest:	0.0029 secs
  Fastest:	0.0001 secs
  Average:	0.0001 secs
  Requests/sec:	10413.2886

  Total data:	17538047 bytes
  Size/request:	175 bytes

Response time histogram:
  0.000 [1]	|
  0.000 [99681]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.001 [232]	|
  0.001 [45]	|
  0.001 [14]	|
  0.001 [9]	|
  0.002 [9]	|
  0.002 [3]	|
  0.002 [1]	|
  0.003 [3]	|
  0.003 [2]	|


Latency distribution:
  10% in 0.0001 secs
  25% in 0.0001 secs
  50% in 0.0001 secs
  75% in 0.0001 secs
  90% in 0.0001 secs
  95% in 0.0001 secs
  99% in 0.0002 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0029 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0003 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0003 secs
  resp wait:	0.0001 secs, 0.0001 secs, 0.0028 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0002 secs

Status code distribution:
  [200]	100000 responses
```


#### HAProxyTech 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	2.9077 secs
  Slowest:	0.0085 secs
  Fastest:	0.0001 secs
  Average:	0.0003 secs
  Requests/sec:	34392.0030

  Total data:	17570878 bytes
  Size/request:	175 bytes

Response time histogram:
  0.000 [1]	|
  0.001 [98821]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.002 [984]	|
  0.003 [111]	|
  0.003 [56]	|
  0.004 [5]	|
  0.005 [0]	|
  0.006 [3]	|
  0.007 [18]	|
  0.008 [0]	|
  0.009 [1]	|


Latency distribution:
  10% in 0.0002 secs
  25% in 0.0002 secs
  50% in 0.0003 secs
  75% in 0.0003 secs
  90% in 0.0004 secs
  95% in 0.0005 secs
  99% in 0.0010 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.0085 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0004 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0007 secs
  resp wait:	0.0003 secs, 0.0001 secs, 0.0085 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0006 secs

Status code distribution:
  [200]	100000 responses
```

#### HAProxyTech 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	1.3188 secs
  Slowest:	0.1002 secs
  Fastest:	0.0001 secs
  Average:	0.0013 secs
  Requests/sec:	75827.2164

  Total data:	17554548 bytes
  Size/request:	175 bytes

Response time histogram:
  0.000 [1]	|
  0.010 [99898]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.020 [0]	|
  0.030 [0]	|
  0.040 [1]	|
  0.050 [0]	|
  0.060 [0]	|
  0.070 [2]	|
  0.080 [74]	|
  0.090 [0]	|
  0.100 [24]	|


Latency distribution:
  10% in 0.0006 secs
  25% in 0.0008 secs
  50% in 0.0011 secs
  75% in 0.0014 secs
  90% in 0.0019 secs
  95% in 0.0025 secs
  99% in 0.0046 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.1002 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0322 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0021 secs
  resp wait:	0.0012 secs, 0.0001 secs, 0.0681 secs
  resp read:	0.0001 secs, 0.0000 secs, 0.0026 secs

Status code distribution:
  [200]	100000 responses
```

#### HAProxyTech 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	11.8738 secs
  Slowest:	0.2636 secs
  Fastest:	0.0001 secs
  Average:	0.0117 secs
  Requests/sec:	84219.3719

  Total data:	143791688 bytes
  Size/request:	143 bytes

Response time histogram:
  0.000 [1]	|
  0.026 [959561]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.053 [38459]	|■■
  0.079 [779]	|
  0.106 [215]	|
  0.132 [94]	|
  0.158 [178]	|
  0.185 [52]	|
  0.211 [489]	|
  0.237 [58]	|
  0.264 [114]	|


Latency distribution:
  10% in 0.0052 secs
  25% in 0.0071 secs
  50% in 0.0098 secs
  75% in 0.0141 secs
  90% in 0.0203 secs
  95% in 0.0250 secs
  99% in 0.0367 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0001 secs, 0.2636 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.1064 secs
  req write:	0.0000 secs, 0.0000 secs, 0.1134 secs
  resp wait:	0.0110 secs, 0.0001 secs, 0.1062 secs
  resp read:	0.0005 secs, 0.0000 secs, 0.0597 secs

Status code distribution:
  [200]	1000000 responses
```

#### HAProxyTech 10000
```
hey -n 1000000 -c 10000 http://quote.gigix/

Summary:
  Total:	18.4248 secs
  Slowest:	15.0460 secs
  Fastest:	0.0001 secs
  Average:	0.1309 secs
  Requests/sec:	54274.7661

  Total data:	131888729 bytes
  Size/request:	131 bytes

Response time histogram:
  0.000 [1]	|
  1.505 [989509]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  3.009 [7837]	|
  4.514 [2198]	|
  6.018 [0]	|
  7.523 [269]	|
  9.028 [83]	|
  10.532 [0]	|
  12.037 [0]	|
  13.541 [0]	|
  15.046 [103]	|


Latency distribution:
  10% in 0.0102 secs
  25% in 0.0147 secs
  50% in 0.0246 secs
  75% in 0.0890 secs
  90% in 0.2914 secs
  95% in 0.5107 secs
  99% in 1.6205 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0007 secs, 0.0001 secs, 15.0460 secs
  DNS-lookup:	0.0010 secs, 0.0000 secs, 0.1709 secs
  req write:	0.0001 secs, 0.0000 secs, 0.1253 secs
  resp wait:	0.1266 secs, 0.0001 secs, 15.0049 secs
  resp read:	0.0014 secs, 0.0000 secs, 0.1064 secs

Status code distribution:
  [200]	1000000 responses
```


### ISTIO (NO MESH)
#### ISTIO (NO MESH) 1
```shell
hey -n 100000 -c 1 http://quote.gigix/

Summary:
  Total:	24.7540 secs
  Slowest:	0.0234 secs
  Fastest:	0.0002 secs
  Average:	0.0002 secs
  Requests/sec:	4039.7540

  Total data:	16166985 bytes
  Size/request:	161 bytes

Response time histogram:
  0.000 [1]	|
  0.002 [99980]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.005 [16]	|
  0.007 [1]	|
  0.009 [1]	|
  0.012 [0]	|
  0.014 [0]	|
  0.016 [0]	|
  0.019 [0]	|
  0.021 [0]	|
  0.023 [1]	|


Latency distribution:
  10% in 0.0002 secs
  25% in 0.0002 secs
  50% in 0.0002 secs
  75% in 0.0003 secs
  90% in 0.0003 secs
  95% in 0.0003 secs
  99% in 0.0006 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0002 secs, 0.0234 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0001 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0005 secs
  resp wait:	0.0002 secs, 0.0002 secs, 0.0233 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0004 secs

Status code distribution:
  [200]	100000 responses
```


#### ISTIO (NO MESH) 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	5.3822 secs
  Slowest:	0.0088 secs
  Fastest:	0.0002 secs
  Average:	0.0005 secs
  Requests/sec:	18579.8750

  Total data:	16173463 bytes
  Size/request:	161 bytes

Response time histogram:
  0.000 [1]	|
  0.001 [97947]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.002 [1801]	|■
  0.003 [126]	|
  0.004 [47]	|
  0.005 [39]	|
  0.005 [8]	|
  0.006 [6]	|
  0.007 [13]	|
  0.008 [8]	|
  0.009 [4]	|


Latency distribution:
  10% in 0.0003 secs
  25% in 0.0004 secs
  50% in 0.0005 secs
  75% in 0.0006 secs
  90% in 0.0008 secs
  95% in 0.0009 secs
  99% in 0.0013 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0002 secs, 0.0088 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0004 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0005 secs
  resp wait:	0.0005 secs, 0.0002 secs, 0.0088 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0006 secs

Status code distribution:
  [200]	100000 responses
```

#### ISTIO (NO MESH) 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	3.6010 secs
  Slowest:	0.0858 secs
  Fastest:	0.0002 secs
  Average:	0.0035 secs
  Requests/sec:	27770.0619

  Total data:	16160983 bytes
  Size/request:	161 bytes

Response time histogram:
  0.000 [1]	|
  0.009 [97184]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.017 [2645]	|■
  0.026 [49]	|
  0.034 [8]	|
  0.043 [28]	|
  0.052 [69]	|
  0.060 [2]	|
  0.069 [0]	|
  0.077 [0]	|
  0.086 [14]	|


Latency distribution:
  10% in 0.0012 secs
  25% in 0.0018 secs
  50% in 0.0030 secs
  75% in 0.0046 secs
  90% in 0.0065 secs
  95% in 0.0078 secs
  99% in 0.0110 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0002 secs, 0.0858 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0268 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0023 secs
  resp wait:	0.0034 secs, 0.0002 secs, 0.0583 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0019 secs

Status code distribution:
  [200]	100000 responses
```


#### ISTIO (NO MESH) 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	24.5196 secs
  Slowest:	0.3414 secs
  Fastest:	0.0003 secs
  Average:	0.0242 secs
  Requests/sec:	40783.7388

  Total data:	161677130 bytes
  Size/request:	161 bytes

Response time histogram:
  0.000 [1]	|
  0.034 [831561]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.068 [157540]	|■■■■■■■■
  0.103 [9082]	|
  0.137 [688]	|
  0.171 [303]	|
  0.205 [270]	|
  0.239 [414]	|
  0.273 [117]	|
  0.307 [21]	|
  0.341 [3]	|


Latency distribution:
  10% in 0.0116 secs
  25% in 0.0159 secs
  50% in 0.0211 secs
  75% in 0.0297 secs
  90% in 0.0400 secs
  95% in 0.0472 secs
  99% in 0.0699 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0003 secs, 0.3414 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.1174 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0469 secs
  resp wait:	0.0237 secs, 0.0002 secs, 0.2585 secs
  resp read:	0.0003 secs, 0.0000 secs, 0.0229 secs

Status code distribution:
  [200]	1000000 responses
```


#### ISTIO (NO MESH) 10000
```
hey -n 1000000 -c 10000 http://quote.gigix/

Summary:
  Total:	90.4657 secs
  Slowest:	26.5592 secs
  Fastest:	0.0002 secs
  Average:	0.7522 secs
  Requests/sec:	11053.9190

  Total data:	159823565 bytes
  Size/request:	161 bytes

Response time histogram:
  0.000 [1]	|
  2.656 [924271]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  5.312 [36746]	|■■
  7.968 [2984]	|
  10.624 [7177]	|
  13.280 [12985]	|■
  15.936 [4235]	|
  18.592 [65]	|
  21.247 [1]	|
  23.903 [19]	|
  26.559 [92]	|


Latency distribution:
  10% in 0.0557 secs
  25% in 0.1000 secs
  50% in 0.2000 secs
  75% in 0.4484 secs
  90% in 1.4039 secs
  95% in 3.4416 secs
  99% in 12.1022 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0090 secs, 0.0002 secs, 26.5592 secs
  DNS-lookup:	0.0884 secs, 0.0000 secs, 12.7389 secs
  req write:	0.0537 secs, 0.0000 secs, 11.9263 secs
  resp wait:	0.3879 secs, 0.0002 secs, 15.2579 secs
  resp read:	0.1439 secs, 0.0000 secs, 22.4836 secs

Status code distribution:
  [200]	988576 responses

Error distribution:
  [533]	Get "http://quote.gigix/": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
  [10880]	Get "http://quote.gigix/": dial tcp 192.168.121.236:80: connect: cannot assign requested address
  [11]	Get "http://quote.gigix/": dial tcp 192.168.121.236:80: connect: connection refused
```


### ISTIO (MESHED)
#### ISTIO (MESHED) 1
```shell
hey -n 100000 -c 1 http://quote.gigix/

Summary:
  Total:	50.6407 secs
  Slowest:	0.0131 secs
  Fastest:	0.0003 secs
  Average:	0.0005 secs
  Requests/sec:	1974.6980

  Total data:	16484370 bytes
  Size/request:	164 bytes

Response time histogram:
  0.000 [1]	|
  0.002 [99889]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.003 [59]	|
  0.004 [26]	|
  0.005 [8]	|
  0.007 [2]	|
  0.008 [4]	|
  0.009 [2]	|
  0.011 [0]	|
  0.012 [5]	|
  0.013 [4]	|


Latency distribution:
  10% in 0.0004 secs
  25% in 0.0004 secs
  50% in 0.0005 secs
  75% in 0.0005 secs
  90% in 0.0006 secs
  95% in 0.0007 secs
  99% in 0.0010 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0003 secs, 0.0131 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0001 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0003 secs
  resp wait:	0.0005 secs, 0.0003 secs, 0.0130 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0006 secs

Status code distribution:
  [200]	100000 responses
```


#### ISTIO (MESHED) 10
```shell
hey -n 100000 -c 10 http://quote.gigix/

Summary:
  Total:	11.1002 secs
  Slowest:	0.0297 secs
  Fastest:	0.0004 secs
  Average:	0.0011 secs
  Requests/sec:	9008.8113

  Total data:	16485445 bytes
  Size/request:	164 bytes

Response time histogram:
  0.000 [1]	|
  0.003 [99889]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.006 [79]	|
  0.009 [18]	|
  0.012 [2]	|
  0.015 [0]	|
  0.018 [0]	|
  0.021 [8]	|
  0.024 [0]	|
  0.027 [0]	|
  0.030 [3]	|


Latency distribution:
  10% in 0.0008 secs
  25% in 0.0009 secs
  50% in 0.0011 secs
  75% in 0.0013 secs
  90% in 0.0014 secs
  95% in 0.0015 secs
  99% in 0.0019 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0004 secs, 0.0297 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0005 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0007 secs
  resp wait:	0.0011 secs, 0.0004 secs, 0.0296 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0007 secs

Status code distribution:
  [200]	100000 responses
```


#### ISTIO (MESHED) 100
```shell
hey -n 100000 -c 100 http://quote.gigix/

Summary:
  Total:	7.5935 secs
  Slowest:	0.1411 secs
  Fastest:	0.0005 secs
  Average:	0.0075 secs
  Requests/sec:	13169.1335

  Total data:	16471768 bytes
  Size/request:	164 bytes

Response time histogram:
  0.001 [1]	|
  0.015 [99319]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.029 [533]	|
  0.043 [21]	|
  0.057 [26]	|
  0.071 [13]	|
  0.085 [19]	|
  0.099 [4]	|
  0.113 [23]	|
  0.127 [15]	|
  0.141 [26]	|


Latency distribution:
  10% in 0.0053 secs
  25% in 0.0061 secs
  50% in 0.0072 secs
  75% in 0.0084 secs
  90% in 0.0098 secs
  95% in 0.0109 secs
  99% in 0.0136 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0005 secs, 0.1411 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0339 secs
  req write:	0.0000 secs, 0.0000 secs, 0.0027 secs
  resp wait:	0.0074 secs, 0.0005 secs, 0.1072 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0027 secs

Status code distribution:
  [200]	100000 responses
```


#### ISTIO (MESHED) 1000
```shell
hey -n 1000000 -c 1000 http://quote.gigix/

Summary:
  Total:	81.5566 secs
  Slowest:	0.8622 secs
  Fastest:	0.0005 secs
  Average:	0.0813 secs
  Requests/sec:	12261.4211

  Total data:	164669766 bytes
  Size/request:	164 bytes

Response time histogram:
  0.001 [1]	|
  0.087 [726312]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.173 [272627]	|■■■■■■■■■■■■■■■
  0.259 [10]	|
  0.345 [46]	|
  0.431 [4]	|
  0.518 [14]	|
  0.604 [43]	|
  0.690 [28]	|
  0.776 [190]	|
  0.862 [725]	|


Latency distribution:
  10% in 0.0656 secs
  25% in 0.0726 secs
  50% in 0.0805 secs
  75% in 0.0875 secs
  90% in 0.0958 secs
  95% in 0.1014 secs
  99% in 0.1122 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0000 secs, 0.0005 secs, 0.8622 secs
  DNS-lookup:	0.0000 secs, 0.0000 secs, 0.0881 secs
  req write:	0.0000 secs, 0.0000 secs, 0.1230 secs
  resp wait:	0.0811 secs, 0.0005 secs, 0.7701 secs
  resp read:	0.0000 secs, 0.0000 secs, 0.0069 secs

Status code distribution:
  [200]	1000000 responses
```


#### ISTIO (MESHED) 10000
```shell
hey -n 1000000 -c 10000 http://quote.gigix/

Summary:
  Total:	92.1222 secs
  Slowest:	7.3856 secs
  Fastest:	0.0009 secs
  Average:	0.9143 secs
  Requests/sec:	10855.1505

  Total data:	164667678 bytes
  Size/request:	164 bytes

Response time histogram:
  0.001 [1]	|
  0.739 [15803]	|■
  1.478 [973322]	|■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  2.216 [750]	|
  2.955 [124]	|
  3.693 [0]	|
  4.432 [0]	|
  5.170 [874]	|
  5.909 [182]	|
  6.647 [2667]	|
  7.386 [6277]	|


Latency distribution:
  10% in 0.8012 secs
  25% in 0.8279 secs
  50% in 0.8539 secs
  75% in 0.8800 secs
  90% in 0.9177 secs
  95% in 0.9926 secs
  99% in 4.4455 secs

Details (average, fastest, slowest):
  DNS+dialup:	0.0045 secs, 0.0009 secs, 7.3856 secs
  DNS-lookup:	0.0005 secs, 0.0000 secs, 0.3065 secs
  req write:	0.0001 secs, 0.0000 secs, 0.1247 secs
  resp wait:	0.9093 secs, 0.0008 secs, 6.9295 secs
  resp read:	0.0001 secs, 0.0000 secs, 0.0567 secs

Status code distribution:
  [200]	1000000 responses
```
