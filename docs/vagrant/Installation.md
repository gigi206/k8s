# Vagrant installation

https://vagrant-libvirt.github.io/vagrant-libvirt/installation.html

## Docker

To get the image with the most recent release:

```
docker pull vagrantlibvirt/vagrant-libvirt:latest
```

If you want the very latest code you can use the **edge** tag instead.

```
docker pull vagrantlibvirt/vagrant-libvirt:edge
```

Running the image:

```bash
docker run -i --rm \
  -e LIBVIRT_DEFAULT_URI \
  -v /var/run/libvirt/:/var/run/libvirt/ \
  -v ~/.vagrant.d:/.vagrant.d \
  -v $(realpath "${PWD}"):${PWD} \
  -w $(realpath "${PWD}") \
  --network host \
  vagrantlibvirt/vagrant-libvirt:latest \
    vagrant status
```

It’s possible to define a function in `~/.bashrc`, for example:

```bash
vagrant(){
  docker run -i --rm \
    -e LIBVIRT_DEFAULT_URI \
    -v /var/run/libvirt/:/var/run/libvirt/ \
    -v ~/.vagrant.d:/.vagrant.d \
    -v $(realpath "${PWD}"):${PWD} \
    -w $(realpath "${PWD}") \
    --network host \
    vagrantlibvirt/vagrant-libvirt:latest \
      vagrant $@
}
```

## Podman

Preparing the podman run, only once:

```
mkdir -p ~/.vagrant.d/{boxes,data,tmp}
```

N.B. This is needed until the entrypoint works for podman to only mount the `~/.vagrant.d` directory

To run with Podman you need to include

```
  --entrypoint /bin/bash \
  --security-opt label=disable \
  -v ~/.vagrant.d/boxes:/vagrant/boxes \
  -v ~/.vagrant.d/data:/vagrant/data \
  -v ~/.vagrant.d/tmp:/vagrant/tmp \
```

For example:

```bash
vagrant(){
  podman run -it --rm --group-add=keep-groups \
    -e LIBVIRT_DEFAULT_URI \
    -v /var/run/libvirt/:/var/run/libvirt/ \
    -v ~/.vagrant.d/boxes:/vagrant/boxes \
    -v ~/.vagrant.d/data:/vagrant/data \
    -v ~/.vagrant.d/tmp:/vagrant/tmp \
    -v $(realpath "${PWD}"):${PWD} \
    -w $(realpath "${PWD}") \
    --network host \
    --entrypoint /bin/bash \
    --security-opt label=disable \
    docker.io/vagrantlibvirt/vagrant-libvirt:latest \
      vagrant $@
}
```

Running Podman in rootless mode maps the root user inside the container to your host user so we need to bypass entrypoint.sh and mount persistent storage directly to /vagrant.

EXTENDING THE CONTAINER IMAGE WITH ADDITIONAL VAGRANT PLUGINS
By default the image published and used contains the entire tool chain required to reinstall the vagrant-libvirt plugin and it’s dependencies, as this is the default behaviour of vagrant anytime a new plugin is installed. This means it should be possible to use a simple FROM statement and ask vagrant to install additional plugins.

```dockerfile
FROM vagrantlibvirt/vagrant-libvirt:latest
RUN vagrant plugin install <plugin>
```

Actually the Podman image doesn't work with NFS, add the following line to the file `/root/.bashrc` as workaround:

```bash
test -e /vagrant/Vagrantfile || mount $(lsof -i:22 -Pn | egrep vagrant | egrep ESTABLISHED | awk -F'>' '{ print $2 }' | awk -F':' '{ print $1 }' | sort -u):/home/kvm/vagrant/vagrantfiles/k8s /vagrant
```