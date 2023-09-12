#!/usr/bin/env bash

# Cf https://linkerd.io/2.14/tasks/generate-certificates/

wget -O step.tar.gz https://dl.step.sm/gh-release/cli/docs-ca-install/v0.17.5/step_linux_0.17.5_amd64.tar.gz

tar xzf step_linux_0.17.5_amd64.tar.gz
./pkgs/step_0.17.5/bin/step certificate create root.linkerd.cluster.local ca.crt ca.key --profile root-ca --no-password --insecure
./pkgs/step_0.17.5/bin/step certificate create identity.linkerd.cluster.local issuer.crt issuer.key --profile intermediate-ca --not-after 8760h --no-password --insecure --ca ca.crt --ca-key ca.key
