#!/usr/bin/bash
# https://gist.github.com/fntlnz/cf14feb5a46b2eda428e000157447309

. "$(dirname $0)/../lib.sh"

cd "$(dirname $0)"

kubectl create ns ${NAMESPACE}

# Create Root Key
#openssl genrsa -des3 -out rootCA.key 4096
openssl genrsa -out CA.key 4096

# Create and self sign the Root Certificate
openssl req -x509 -new -nodes -key CA.key -sha256 -days 3650 -subj "/C=FR/ST=Yvelines/O=GigiX, Inc./CN=*.gitlab.gigix" -out CA.crt

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-tls-ca-key-pair
  namespace: ${NAMESPACE}
data:
  tls.crt: $(cat CA.crt | base64 -w0)
  tls.key: $(cat CA.key | base64 -w0)
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: gitlab-issuer
  namespace: ${NAMESPACE}
spec:
  ca:
    secretName: gitlab-tls-ca-key-pair
EOF

rm -f CA.crt CA.key
