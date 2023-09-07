FROM debian:stable-slim
ARG VERSION=0.84.0
# ARG USER_UID=10001
# ARG GROUP_GID=101
RUN apt update && apt install -y ca-certificates systemd && apt-get autoremove
ADD https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${VERSION}/otelcol-contrib_${VERSION}_linux_amd64.tar.gz /tmp/otelcol-contrib_${VERSION}_linux_amd64.tar.gz
RUN tar xzf /tmp/otelcol-contrib_${VERSION}_linux_amd64.tar.gz -C /tmp && mv /tmp/otelcol-contrib / && rm -fr /tmp/*
# Require to be root to read /var/log/journal by journalctl
# USER ${USER_UID}:${GROUP_GID}
EXPOSE 4317 55680 55679
ENTRYPOINT ["/otelcol-contrib"]
CMD ["--config", "/etc/otel/config.yaml"]