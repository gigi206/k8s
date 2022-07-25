FROM debian:testing-slim
WORKDIR /app
COPY ./hello-world /app/hello-world
RUN chmod +x /app/hello-world
ENTRYPOINT [ "/app/hello-world" ]
