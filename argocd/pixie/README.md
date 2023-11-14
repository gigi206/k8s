# Pixie
## Requirements
* https://docs.px.dev/installing-pixie/requirements/

## Helm
* https://docs.px.dev/installing-pixie/install-schemes/helm/

## Self-hosting
**INFO:** Pixie use their cloud to store the data but you can deploy your own:
* https://docs.px.dev/installing-pixie/install-guides/self-hosted-pixie/

## Write custom scripts
* https://docs.px.dev/tutorials/pxl-scripts/write-pxl-scripts/

## Pixie with Grafana
* https://docs.px.dev/tutorials/integrations/grafana/

## Cli
### Download
```bash
bash -c "$(curl -fsSL https://withpixie.ai/install.sh)"
```

### Login
* You must create an api key [here](https://work.withpixie.ai/admin/keys/api):
```shell
px auth login --use_api_key --api_key px-api-xxx
```

### Deployment key
* Use the deployment key `px-dep-xxx` in the yaml file (or create manually one [here](https://work.withpixie.ai/admin/keys/deployment)):
```shell
$ px deploy-key create
Pixie CLI
Generated deployment key:
ID: xxx-0880-4f16-9a09-xxx
Key: px-dep-xxx
```

### Live script
```shell
px live -c pixie-demo_1849d5c3 px/cluster
```

## Deploy
* https://docs.px.dev/installing-pixie/install-schemes/helm/#3.-deploy-pixie

## Tuto
* [Youtube](https://www.youtube.com/watch?v=uo1pZQMTLyM)