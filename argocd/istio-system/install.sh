#!/usr/bin/env bash

. "$(dirname $0)/../lib.sh"

# require_app gateway-api-controller opentelemetry loki-stack prometheus-stack jaeger
require_app opentelemetry loki-stack prometheus-stack jaeger
install_app
wait_app
# show_ressources
