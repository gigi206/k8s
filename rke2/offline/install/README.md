To avoid this error when you pull container images: Error: short-name resolution enforced but cannot prompt without a TTY
In the file /etc/containers/registries.conf:
Comment the line: unqualified-search-registries = ["registry.access.redhat.com", "registry.redhat.io", "docker.io"]
And just below add the line unqualified-search-registries = ["docker.io"]
