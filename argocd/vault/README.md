# Vault

<!-- TOC -->

- [Vault](#vault)
    - [Tutorial](#tutorial)
        - [Kubernetes](#kubernetes)
        - [List root accessor](#list-root-accessor)
        - [Remove the root token](#remove-the-root-token)
        - [Generate a new root token](#generate-a-new-root-token)
    - [Policy](#policy)
    - [Vault Agent](#vault-agent)
        - [Vault Agent Templates](#vault-agent-templates)
        - [Vault Agent - secrets as environment variables](#vault-agent---secrets-as-environment-variables)
    - [Cli](#cli)
        - [server](#server)
        - [status](#status)
        - [operator](#operator)
            - [init](#init)
            - [unseal](#unseal)
        - [login](#login)
        - [path-help](#path-help)
        - [policy](#policy)
        - [audit](#audit)
        - [debug](#debug)
        - [system /sys](#system-sys)
            - [sys/leases](#sysleases)
            - [sys/quotas](#sysquotas)
        - [Secrets engine](#secrets-engine)
            - [totp](#totp)
            - [identity](#identity)
            - [cubbyhole](#cubbyhole)
            - [KV](#kv)
            - [Databases](#databases)
                - [Postgres](#postgres)
            - [ssh](#ssh)
            - [Transit](#transit)
            - [pki](#pki)
        - [auth](#auth)
            - [token](#token)
                - [lookup](#lookup)
                - [capabilities](#capabilities)
                - [create](#create)
                - [renew](#renew)
                - [revoke](#revoke)
            - [read](#read)
            - [userpass](#userpass)
            - [approle](#approle)
            - [kubernetes](#kubernetes)

<!-- /TOC -->

## Tutorial
* [Youtube](https://www.youtube.com/watch?v=I4Xu3DGfk60&list=PLCFwfUlM-doNzjCQDDU9jvZ57tNWX03xy&index=1&pp=iAQB)

### Kubernetes
* [Vault on Kubernetes deployment guide](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-raft-deployment-guide)
  * [Helm configuration](https://developer.hashicorp.com/vault/docs/platform/k8s/helm/configuration)
* Configure Vault as a certificate manager in Kubernetes:
  * [CertManager documentation](https://cert-manager.io/docs/configuration/vault/)
  * [Vault documentation](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-cert-manager)

### List root accessor
* List accessor that have the `root` policy:
```shell
for ACCESSOR in $(for KEY in $(vault list -format=json auth/token/accessors | jq -r ".[]"); do vault token lookup -format json -accessor $KEY | jq -r '.data | select(.policies | index("root")) | .accessor'; done); do vault token lookup -accessor $ACCESSOR; done
Key                 Value
---                 -----
accessor            4uosAn33QdFD5Xc7f59D2aow
creation_time       1702511834
creation_ttl        0s
display_name        root
entity_id           n/a
expire_time         <nil>
explicit_max_ttl    0s
id                  n/a
meta                <nil>
num_uses            0
orphan              true
path                auth/token/root
policies            [root]
ttl                 0s
type                service
```

* Or with python:
```py
#!/usr/bin/env python3

import os
import time
<!-- TOC -->

- [Vault](#vault)
    - [Tutorial](#tutorial)
        - [Kubernetes](#kubernetes)
        - [List root accessor](#list-root-accessor)
        - [Remove the root token](#remove-the-root-token)
        - [Generate a new root token](#generate-a-new-root-token)
    - [Policy](#policy)
    - [Vault Agent](#vault-agent)
    - [Cli](#cli)
        - [server](#server)
        - [status](#status)
        - [operator](#operator)
            - [init](#init)
            - [unseal](#unseal)
        - [login](#login)
        - [path-help](#path-help)
        - [policy](#policy)
        - [audit](#audit)
        - [debug](#debug)
        - [system /sys](#system-sys)
            - [sys/leases](#sysleases)
            - [sys/quotas](#sysquotas)
        - [Secrets engine](#secrets-engine)
            - [KV](#kv)
            - [Databases](#databases)
                - [Postgres](#postgres)
            - [Transit](#transit)
            - [pki](#pki)
        - [auth](#auth)
            - [token](#token)
                - [lookup](#lookup)
                - [capabilities](#capabilities)
                - [create](#create)
                - [renew](#renew)
                - [revoke](#revoke)
            - [read](#read)
            - [userpass](#userpass)
            - [approle](#approle)
            - [kubernetes](#kubernetes)

<!-- /TOC -->import hvac
import urllib3
from prettytable import PrettyTable

urllib3.disable_warnings()

try:
    os.environ["VAULT_ADDR"]
except Exception:
    print("The VAULT_ADDR environment must be set.")
    os._exit(1)

try:
    os.environ["VAULT_TOKEN"]
except Exception:
    print("The VAULT_TOKEN environment must be set.")
    os._exit(1)

client = hvac.Client(url=os.environ['VAULT_ADDR'], verify=False, token=os.environ["VAULT_TOKEN"])

payload = client.list('auth/token/accessors')
keys = payload['data']['keys']
x = PrettyTable()
x.field_names = ["Display Name", "Creation Time", "Expiration Time", "Policies", "Token Accessor"]

for key in keys:
    output = client.lookup_token(key, accessor=True)
    display_name = output['data']['display_name']
    creation_date = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(output['data']['creation_time']))
    expire_time = output['data']['expire_time']
    policies = output['data']['policies']
    accessor = key
    if "root" in policies:
        x.add_row([display_name, creation_date, expire_time, policies, accessor])
print(x)
```

* Execute this script:
```shell
$ ./vault.py
+--------------+---------------------+-----------------+----------+--------------------------+
| Display Name |    Creation Time    | Expiration Time | Policies |      Token Accessor      |
+--------------+---------------------+-----------------+----------+--------------------------+
|     root     | 2023-12-14 00:57:14 |       None      | ['root'] | 4uosAn33QdFD5Xc7f59D2aow |
+--------------+---------------------+-----------------+----------+--------------------------+
```

### Remove the root token
* [Documentation](https://developer.hashicorp.com/vault/tutorials/operations/generate-root)

* Before removing create the `vault-admins` policy (alternatively you can write directly to the `sys/policy/vault-admins` path):
```shell
$ vault policy write vault-admins - <<EOF
path "*" {
  capabilities = ["create", "read", "update", "delete", "patch", "list", "sudo"]
}
EOF
```

* You can verify:
```shell
$ vault policy read vault-admins
$ vault read sys/policy/vault-admins
```

* Create a user:
```shell
$ vault auth enable userpass
$ vault write auth/userpass/users/gigix password=changme policies=vault-admins
```

* Revoke:
```shell
vault token revoke <token>
```

Or by accessor:
```shell
vault token revoke -accessor 4uosAn33QdFD5Xc7f59D2aow
```

* You can now use your admin account:
```shell
$ vault login -method=userpass username=gigix
export VAULT_TOKEN=$(cat ~/.vault-token)
```

### Generate a new root token
```shell
$ vault operator generate-root -init
A One-Time-Password has been generated for you and is shown in the OTP field.
You will need this value to decode the resulting root token, so keep it safe.
Nonce         42a6365e-d8dd-bb05-a647-6745771eb06c
Started       true
Progress      0/1
Complete      false
OTP           14UREXm0fI6QE6rD4uopy0GHXiYe
OTP Length    28
```

```shell
$ vault operator generate-root -otp="14UREXm0fI6QE6rD4uopy0GHXiYe"
Operation nonce: 42a6365e-d8dd-bb05-a647-6745771eb06c
Unseal Key (will be hidden):
Nonce            42a6365e-d8dd-bb05-a647-6745771eb06c
Started          true
Progress         1/1
Complete         true
Encoded Token    WUImfBYRXmgiPgQ7AAMGKUQzKxtIWXE/MAAsMg
```

```shell
$ vault operator generate-root -decode WUImfBYRXmgiPgQ7AAMGKUQzKxtIWXE/MAAsMg -otp 14UREXm0fI6QE6rD4uopy0GHXiYe
hvs.SI3XDw2jE5tmpFDk1i6whiuW
```

* Verify the generated token:
```shell
$ vault token lookup hvs.SI3XDw2jE5tmpFDk1i6whiuW
Key                 Value
---                 -----
accessor            vguw2TmH3NVJN4Qr7LHQT1fI
creation_time       1702837178
creation_ttl        0s
display_name        root
entity_id           n/a
expire_time         <nil>
explicit_max_ttl    0s
id                  hvs.SI3XDw2jE5tmpFDk1i6whiuW
meta                <nil>
num_uses            0
orphan              true
path                auth/token/root
policies            [root]
ttl                 0s
type                service
```

## Policy
* [Documentation](https://developer.hashicorp.com/vault/docs/commands/policy)
* [Tuto - ACL policy path templating](https://developer.hashicorp.com/vault/tutorials/policies/policy-templating)

Examples:
```json
path "secret/" {
    capabilities = ["list"]
}

path "secret/*" {
    capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/confidential" {
    capabilities = ["deny"]
}

path "secret/+/admin" {
    capabilities = ["deny"]
}
```

* Standard:

| Capabilities | create   | read | update   | delete | list |
|:-:           |:-:       |:-:   |:-:       |:-:     |:-:   |
| HTTP Verbs   | POST/PUT | GET  | POST/PUT | DELETE | LIST |

* Special:

| Capabilities | sudo | deny | patch |
|:-:           |:-:   |:-:   |:-:    |
| HTTP Verbs   | N/A  | N/A  | PATCH |


* **read:** Similar to the GET HTTP method, allows reading the data at the given path.
* **create:** Similar to the POST & PUT HTTP Method, allows creating data at the given path. Very few parts of Vault distinguish between create and update, so most operations require both create and update capabilities. Parts of Vault that provide such a distinction are noted in documentation.
* **update:** Similar to the POST & PUT HTTP Method, allows changing the data at the given path. In most parts of Vault, this implicitly includes the ability to create the initial value at the path.
delete: Similar to the DELETE HTTP Method, allows deleting the data at the given path.
* **list:** Allows listing values at the given path.
* **sudo:** Allows access to paths that are root-protected. Tokens are not permitted to interact with these paths unless they have the sudo capability
* **deny:** Disallows access. This always takes precedence regardless of any other defined capabilities, including sudo.

## Vault Agent
* [Documentation](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent)
* [Agent generate-config](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/generate-config)
* [Secrets as environment variables](https://developer.hashicorp.com/vault/tutorials/vault-agent/agent-env-vars)
* [Caching](https://developer.hashicorp.com/vault/tutorials/vault-agent/agent-caching)
* [Vault agent templates](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template)
  * [Tuto](https://developer.hashicorp.com/vault/tutorials/vault-agent/agent-templates)

* [Use Consul Template and Envconsul with Vault](https://developer.hashicorp.com/vault/tutorials/app-integration/application-integration)

### Vault Agent Templates
* [Tuto](https://developer.hashicorp.com/vault/tutorials/vault-agent/agent-templates)

* Generate the file `agent-config.hcl`:
```hcl
# https://developer.hashicorp.com/vault/docs/agent-and-proxy/autoauth/methods/approle
# https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent/template
# export VAULT_SKIP_VERIFY=true

pid_file = "./pidfile"

auto_auth {
  method {
    type = "approle"
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "roleid"
      secret_id_file_path = "secretid"
      remove_secret_id_file_after_reading = false # Will remove the file specified in secret_id_file_path
    }
  }

  sink "file" {
    wrap_ttl = "1m"
    config = {
      path = "vault-token-via-agent"
      mode = 0600
    }
  }
}

vault {
  address = "https://vault.gigix:443"
  tls_disable = false
  retry {
    num_retries = 5
  }
}

template_config {
  exit_on_retry_failure = true
  static_secret_render_interval = "10s"
}

template {
  source      = "./customer.tmpl"
  destination = "./customer.txt"
  error_on_missing_key = true
}
```

* Start the Vault agent:
```shell
vault agent -config=agent-config.hcl -log-level=error -tls-skip-verify
```

### Vault Agent - secrets as environment variables
This method allow to run a binary (or script) with a specific environment given by Vault.

* [Tuto](https://developer.hashicorp.com/vault/tutorials/vault-agent/agent-env-vars)

* Generate the file `agent-config.hcl`:
```shell
vault agent generate-config -type="env-template" \
  -exec="./kv-demo.sh" \
  -path="kv/demo/*" \
  -path="kv/user" \
  agent-config.hcl
```

* File `agent-config.hcl` and updated manually (change method config):
```hcl
auto_auth {
  method {
    type = "token_file"

    config {
      token_file_path = "/home/gigi/.vault-token"
    }
  }
}

template_config {
  #static_secret_render_interval = "5m"
  static_secret_render_interval = "10s"
  exit_on_retry_failure         = true
}

vault {
  address = "https://vault.gigix:443"
}

env_template "CONFIG_PASSWORD" {
  contents             = "{{ with secret \"kv/data/demo/config\" }}{{ .Data.data.password }}{{ end }}"
  error_on_missing_key = true
}
env_template "CONFIG_USERNAME" {
  contents             = "{{ with secret \"kv/data/demo/config\" }}{{ .Data.data.username }}{{ end }}"
  error_on_missing_key = true
}
env_template "USER_PASSWORD" {
  contents             = "{{ with secret \"kv/data/user\" }}{{ .Data.data.password }}{{ end }}"
  error_on_missing_key = true
}
env_template "USER_USER" {
  contents             = "{{ with secret \"kv/data/user\" }}{{ .Data.data.user }}{{ end }}"
  error_on_missing_key = true
}

exec {
  command                   = ["./kv-demo.sh"]
  restart_on_secret_changes = "always"
  restart_stop_signal       = "SIGTERM"
}
```

* The script `./kv-demo.sh` will be restarted each time a kv is updated with new env vars:
```shell
#!/usr/bin/bash
echo "CONFIG_PASSWORD: $CONFIG_PASSWORD"
echo "USER_PASSWORD: $USER_PASSWORD"
sleep 1000
```

* Start the Vault agent:
```shell
vault agent -config=agent-config.hcl -log-level=error -tls-skip-verify
```

## Cli
You can access vault directly from vault container with kubectl:
```shell
kubectl exec -n vault statefulsets/vault -- vault
```

Or you can [download vault](https://developer.hashicorp.com/vault/install#Linux) and configure your environment:
```shell
export VAULT_ADDR="https://vault.gigix:443"
export VAULT_TOKEN="mytoken"
export VAULT_SKIP_VERIFY=true
```

### server
* Start a server from cli (no kubernetes) in `dev` mod with `root` token:
```shell
vault server -dev -dev-root-token-id root
```

### status
```shell
$ vault status
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Total Shares    1
Threshold       1
Version         1.15.2
Build Date      2023-11-06T11:33:28Z
Storage Type    file
Cluster Name    vault-cluster-280b5874
Cluster ID      fa5711ee-143a-ea11-bc80-e86ab1b974fc
HA Enabled      false
```

### operator

#### init
* [Documentation](https://developer.hashicorp.com/vault/docs/commands/operator/init)

Example:
```shell
vault operator init \
    -key-shares=3 \
    -key-threshold=2
```

#### unseal
* Unseal the vault:
```shell
vault operator unseal <key>
```

Or (preferred):
```shell
$ vault operator unseal
Unseal Key (will be hidden):
```

### login
```shell
vault login
```

Or:
```shell
export VAULT_TOKEN="$(vault login -token-only -method=userpass username=gigix)"
```

### path-help
* Get help:
```shell
vault path-help kv
vault auth help github
```

### policy
* [Documentation](https://developer.hashicorp.com/vault/docs/concepts/policies)
* [Hashicorp tuto](https://developer.hashicorp.com/vault/tutorials/policies/policies)

* List policies:
```
vault policy list
```

* Display a policy:
```
vault policy read default
```

* Create a new policy called user with full permission on `secret/data/mysecret`:
```shell
$ cat << EOF > policy.hcl
path "kv/*" {
  capabilities = ["list"]
}

# data
path "kv/data/mysecret" {
  capabilities = ["read", "create", "update", "delete", "patch"]
}

# Metadata
path "kv/mysecret" {
  capabilities = ["read", "create", "update", "delete", "patch"]
}
EOF
```

```
vault policy write user policy.hcl
```

**IMPORTANT:** `kv/data/mysecret` is only for **data** and the direct access `kv/mysecret` is for **metadata** !

### audit
* [K8S - server.auditStorage.enabled](https://artifacthub.io/packages/helm/hashicorp/vault?modal=values&path=server.auditStorage.enabled)

* Enable audit:
```shell
vault audit enable file file_path=/vault/vault-audit.log
```

* List audit files:
```shell
$ vault audit list -detailed
Path     Type    Description    Replication    Options
----     ----    -----------    -----------    -------
file/    file    n/a            replicated     file_path=/vault/vault-audit.log
```

```shell
kubectl -n vault exec vault-0 -- tail -n 1 /vault/vault-audit.log
```

### debug
* [Documentation](https://developer.hashicorp.com/vault/tutorials/monitoring/kubernetes-troubleshooting#gather-debugging-data-with-vault-debug)

* Configure debugging for a time period:
```shell
vault debug -interval=1m -duration=2m
```

### system (/sys)
* [API documentation](https://developer.hashicorp.com/vault/api-docs/system)

#### sys/leases
* [API documentation](https://developer.hashicorp.com/vault/api-docs/system/leases)

* Show current tokens (6 leases in this example):
```shell
$ vault list sys/leases/lookup/auth/userpass/login/glemeur
Keys
----
h499b91b737e6f7f7914491c5b7e730efd1e40c4850322b6cdadcc4deb87bc9be
h93cbe4f96547381d3e556a9889d9b54f26e79b088e3937f735fba771657465f3
haccbd171dd54a279a4bef8ce84ab359da241ea9f13c67fde7e5fb2d19870e424
hca9ac394ca663620537dcd55841287bf98866ef4c93b4b3ab23457b9c82289d2
heb4489cd950e1449c79b6122c7f25908f65669a79de17a66eb3108a14b74688e
hfb4640cdf5fd426b0b266af1e4eab27a2dcd6d92dbc421d8bb95f146d55b3833
```

#### sys/quotas
* API documentation:
  * [/sys/quotas/config](https://developer.hashicorp.com/vault/api-docs/system/quotas-config)
  * [/sys/quotas/rate-limit](https://developer.hashicorp.com/vault/api-docs/system/rate-limit-quotas)
  * [/sys/quotas/lease-count](https://developer.hashicorp.com/vault/api-docs/system/lease-count-quotas)

* [Hashicorp tuto](https://developer.hashicorp.com/vault/tutorials/new-release/resource-quotas)

* Show quotas configuration:
```shell
$ vault read sys/quotas/config
Key                                   Value
---                                   -----
enable_rate_limit_audit_logging       false
enable_rate_limit_response_headers    false
rate_limit_exempt_paths               [sys/generate-recovery-token/attempt sys/generate-recovery-token/update sys/generate-root/attempt sys/generate-root/update sys/health sys/seal-status sys/unseal]
```

* Set `global-rate` quota to `1500`:
```shell
vault write sys/quotas/rate-limit/global-rate rate=1500
```

Verify:
```shell
$ vault read sys/quotas/rate-limit/global-rate
Key               Value
---               -----
block_interval    0
inheritable       true
interval          1
name              global-rate
path              n/a
rate              1500
role              n/a
type              rate-limit
```

### Secrets engine
* List actives secrets engine:
```shell
$ vault secrets list
Path          Type         Accessor              Description
----          ----         --------              -----------
cubbyhole/    cubbyhole    cubbyhole_8858eaa9    per-token private secret storage
identity/     identity     identity_1375af52     identity store
kv/           kv           kv_7a702080           n/a
sys/          system       system_a9299817       system endpoints used for control, policy and debugging
```

More details:
```shell
vault secrets list -detailed
```

#### totp
One popular MFA method is Time-based One-time Password (TOTP), which requires users to enter a unique code generated by an authentication app every time they log in.

* [Documentation](https://developer.hashicorp.com/vault/docs/secrets/totp)
* [Vault API](https://developer.hashicorp.com/vault/api-docs/secret/totp)

* Enable `totp` auth method:
```shell
vault secrets enable totp
```

* Create the `admin` user:
```shell
vault write auth/userpass/users/admin password=MY_PASSWORD
```

* Get the accessor of the `userpass` auth method:
```shell
USERPASS_ACCESSOR=$(vault auth list -format=json | jq -r '.["userpass/"].accessor')
```

* Create the entity `admin`:
```shell
ENTITY_ID=$(vault write -field=id identity/entity name="admin")
```

* Create the `admin` alias:
```shell
$ vault write identity/entity-alias \
  name="admin" \
  canonical_id="$ENTITY_ID" \
  mount_accessor="$USERPASS_ACCESSOR"
Key             Value
---             -----
canonical_id    5587c197-eed1-cf26-201d-e3b68393eb93
id              b2262956-e689-aaa0-3aea-a61b753f918e
```

* Enable MFA method (TOTP):
```shell
METHOD_ID=$(vault write -field=method_id identity/mfa/method/totp \
  issuer=Vault \
  period=30 \
  key_size=30 \
  qr_size=200 \
  algorithm=SHA256 \
  digits=6 \
  name=admin
)
```

* Verify:
```shell
$ vault read identity/mfa/method/totp/$METHOD_ID
Key                        Value
---                        -----
algorithm                  SHA256
digits                     6
id                         c2a33b32-c380-24a0-3e19-118881d19cda
issuer                     Vault
key_size                   30
max_validation_attempts    5
name                       n/a
namespace_id               root
namespace_path             n/a
period                     30s
qr_size                    200
skew                       1
type                       totp
```

* Generate the QR code for the `admin` entity (each entities must be added to login !!!):
```shell
$ vault write identity/mfa/method/totp/admin-generate method_id=$METHOD_ID entity_id=$ENTITY_ID
Key        Value
---        -----
barcode    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
url        otpauth://totp/Vault:5587c197-eed1-cf26-201d-e3b68393eb93?algorithm=SHA256&digits=6&issuer=Vault&period=30&secret=BQPATHCFUWNHUSB2QTDLCRABFPDMS3BDUVYH5J5HX4UL2S5U
```

* Generate the QR code:
```shell
$ echo "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" | base64 -d > otp.png
```

* Open the QR code:
```shell
open otp.png
```

* All users in `userpass` auth method must use TOTP to login:
```shell
vault write identity/mfa/login-enforcement/mfa-userpass \
   mfa_method_ids="$METHOD_ID" \
   auth_method_accessors="$USERPASS_ACCESSOR"
```

Instead, I can force only the `admin` entify to force to use TOTP:
```shell
vault write identity/mfa/login-enforcement/mfa-identity-admin \
   mfa_method_ids="$METHOD_ID" \
   identity_entity_ids="$ENTITY_ID"
```

Or you can use an `identity_group_ids` (called `mfa` or `totp` for example)
```shell
vault write identity/mfa/login-enforcement/mfa-group \
   mfa_method_ids="$METHOD_ID" \
   identity_group_ids="$GROUP_ID"
```

Verify:
```shell
$ vault read identity/mfa/login-enforcement/mfa-identity-admin
Key                      Value
---                      -----
auth_method_accessors    []
auth_method_types        []
id                       add819e3-388a-6cd4-2e1e-a8a4fe833080
identity_entity_ids      [5587c197-eed1-cf26-201d-e3b68393eb93]
identity_group_ids       []
mfa_method_ids           [c2a33b32-c380-24a0-3e19-118881d19cda]
name                     mfa-identity-admin
namespace_id             root
namespace_path           n/a
```

* Configure OTP:
```shell
$ vault write totp/keys/vault url="otpauth://totp/Vault:5587c197-eed1-cf26-201d-e3b68393eb93?algorithm=SHA256&digits=6&issuer=Vault&period=30&secret=BQPATHCFUWNHUSB2QTDLCRABFPDMS3BDUVYH5J5HX4UL2S5U"
Success! Data written to: totp/keys/vault
```

* Test OTP:
```shell
$ vault read totp/code/vault
Key     Value
---     -----
code    150946
```

```shell
$ vault login -method userpass username=admin
Initiating Interactive MFA Validation...
Enter the passphrase for methodID "c2a33b32-c380-24a0-3e19-118881d19cda" of type "totp":
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
again. Future Vault requests will automatically use this token.

Key                    Value
---                    -----
token                  hvs.CAESINt89ZxeBIEgoHsXLweO_KkD_KqvDsjS_j-CQJYetCAiGh4KHGh2cy5hVTJWTm1EVFR0eDZScG54aEtzVmtMSFk
token_accessor         ZuUQ64yTzaGrpOUJsSWcUQXW
token_duration         768h
token_renewable        true
token_policies         ["default"]
identity_policies      []
policies               ["default"]
token_meta_username    admin
```

![OTP UI](https://docmoa.github.io/assets/vault-login-mfa-totp-84ec4286.gif)

#### identity
* [Documentation](https://developer.hashicorp.com/vault/docs/concepts/identity)
* [Hashicorp tutorial - Identity: entities and groups](https://developer.hashicorp.com/vault/tutorials/auth-methods/identity)

* Create a `demo` user:
```shell
vault write auth/userpass/users/demo password="P@ssw0rd"
```

* Create a `demo` identity attached to the `demo` policy:
```shell
$ vault write identity/entity name="demo" policies="demo" \
     metadata=organization="Demo Inc." \
     metadata=team="QA"

Key        Value
---        -----
aliases    <nil>
id         985c99bd-1c02-fbbb-a81f-b6ee51d28b05
name       demo
```

* Verify:
```shell
$ vault read identity/entity/id/985c99bd-1c02-fbbb-a81f-b6ee51d28b05
Key                    Value
---                    -----
aliases                [map[canonical_id:985c99bd-1c02-fbbb-a81f-b6ee51d28b05 creation_time:2023-12-21T11:40:12.554499398Z custom_metadata:map[account:Demo Account] id:81aa9a69-87c5-96b6-5798-a6303d604d95 last_update_time:2023-12-21T11:40:12.554499398Z local:false merged_from_canonical_ids:<nil> metadata:<nil> mount_accessor:auth_userpass_57c420f1 mount_path:auth/userpass/ mount_type:userpass name:demo]]
creation_time          2023-12-21T11:34:27.153901932Z
direct_group_ids       []
disabled               false
group_ids              []
id                     985c99bd-1c02-fbbb-a81f-b6ee51d28b05
inherited_group_ids    []
last_update_time       2023-12-21T11:34:27.153901932Z
merged_entity_ids      <nil>
metadata               map[organization:Demo Inc. team:QA]
name                   demo
namespace_id           root
policies               [demo]
```

* Get the accessor of the `userpass` auth:
```shell
$ vault auth list -format=json | jq -r '.["userpass/"].accessor'
auth_userpass_57c420f1
```

* Create a `demo` entity alias referenced by the `demo` entity (id `985c99bd-1c02-fbbb-a81f-b6ee51d28b05`) and the auth `userpass` accessor (`auth_userpass_57c420f1`):
```shell
$ vault write identity/entity-alias name="demo" \
     canonical_id=985c99bd-1c02-fbbb-a81f-b6ee51d28b05 \
     mount_accessor=auth_userpass_57c420f1 \
     custom_metadata=account="Demo Account"

Key             Value
---             -----
canonical_id    985c99bd-1c02-fbbb-a81f-b6ee51d28b05
id              81aa9a69-87c5-96b6-5798-a6303d604d95
```

* Test to login (we can see that have the *identity_policies* set to `demo`):
```shell
$ vault login -method=userpass username=demo
Password (will be hidden):
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
again. Future Vault requests will automatically use this token.

Key                    Value
---                    -----
token                  hvs.CAESIEeN4NRMJnFfO8IUTDh1fPV2XG3Wz0tD96Xav6aL99QFGh4KHGh2cy5qbEdvMXNaUUpPWGVrQ0trWDczU3N2UXg
token_accessor         0naB9veMXFRnqdRRc3YZjv7u
token_duration         768h
token_renewable        true
token_policies         ["default"]
identity_policies      ["demo"]
policies               ["default" "demo"]
token_meta_username    demo
```

* Show the `demo` policy:
```shell
$ vault policy read demo
path "kv/data/demo/config" {
  capabilities = ["read"]
}

path "kv/demo/config" {
  capabilities = ["read"]
}
```

* The user demo can access to the kv `demo` (with the policy `demo`):
```shell
kv get -mount=kv demo/config
=== Secret Path ===
kv/data/demo/config

======= Metadata =======
Key                Value
---                -----
created_time       2023-12-20T16:46:53.886363978Z
custom_metadata    map[meta1:value1 meta2:value2]
deletion_time      n/a
destroyed          false
version            7

====== Data ======
Key         Value
---         -----
password    P@ssw0rd!
username    admin
```

But he can't assess to the kv user:
```shell
$ vault kv get -mount=kv user
Error reading kv/data/user: Error making API request.

URL: GET https://vault.gigix:443/v1/kv/data/user
Code: 403. Errors:

* 1 error occurred:
	* permission denied
```

* Create a `user` **internal** group with the `user` policy and add `demo` entity inside:
```shell
vault write identity/group name="user" \
     policies="user" \
     member_entity_ids="985c99bd-1c02-fbbb-a81f-b6ee51d28b05" \
     metadata=team="Users" \
     metadata=region="North America"

Key     Value
---     -----
id      f1f73c3e-40f4-718d-9e0a-e4d470c6c6e7
name    user
```

* **NOTE:** it's possible to create [external group](https://developer.hashicorp.com/vault/tutorials/auth-methods/identity#create-an-external-group) to enable auth methods such as LDAP, Okta,...

* Login again to test (we can see that the *identity_policies* has 2 policies: `demo` and `user`):
```shell
vault login -method=userpass username=demo
Password (will be hidden):
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
again. Future Vault requests will automatically use this token.

Key                    Value
---                    -----
token                  hvs.CAESIEY2TpViQBL94OwEoi-sQI2YTy8abg7Pe6hTriY70-C-Gh4KHGh2cy5venpJcURDUmFpdlZoNVpGZTA0ejNaRXA
token_accessor         9dKImoMw50aJtNKEBMuAhMB7
token_duration         768h
token_renewable        true
token_policies         ["default"]
identity_policies      ["demo" "user"]
policies               ["default" "demo" "user"]
token_meta_username    demo
```

* And the user `demo` has now access to the kv `user`:
```shell
$ vault kv get -mount=kv user
== Secret Path ==
kv/data/user

======= Metadata =======
Key                Value
---                -----
created_time       2023-12-19T17:02:14.439463424Z
custom_metadata    <nil>
deletion_time      n/a
destroyed          false
version            4

====== Data ======
Key         Value
---         -----
password    test
user        admin
```


#### cubbyhole
* [Documentation](https://developer.hashicorp.com/vault/docs/secrets/cubbyhole)
* [Hashicorp tutorial - Cubbyhole response wrapping](https://developer.hashicorp.com/vault/tutorials/secrets-management/cubbyhole-response-wrapping)

* Write a secret:
```shell
$ vault write cubbyhole/my-secret my-value=s3cr3t
Success! Data written to: cubbyhole/my-secret
```

* List secrets:
```shell
$ vault list cubbyhole
Keys
----
my-secret
```

* Read the secret:
```shell
$ vault read cubbyhole/my-secret
Key         Value
---         -----
my-value    s3cr3t
```

#### KV
* [Documentation](https://developer.hashicorp.com/vault/docs/secrets/kv)
* [Hashicorp tuto](https://developer.hashicorp.com/vault/tutorials/secrets-management/versioned-kv)
* Key-value engine secret:
  * **V1**: basic (no verionning)
  * **V2**: versionning (data + metadata)

* Migrate kv from **V1** to **V2**:
```shell
vault kv enable-versioning kv/
```

* Enable a new KV engine:
```shell
vault secrets enable kv/kv
vault secrets enable -path=kv kv
```

* Disable (where `kv` is the path):
```shell
vault secrets enable kv
```

* Write secret (ou update with a new version):
```shell
vault kv put kv/user user=admin password=test
```

* Update only a `key=value`:
```shell
vault kv patch kv/mysecret password=test2
vault kv patch -mount=kv mysecret password=test2
```
* Retrieve the secret:
```shell
vault kv get kv/user
vault kv get -version=1 kv/user
```

* Delete the last secret or a specific version:
```shell
vault kv delete kv/user
vault kv delete -versions=1,2 kv/user
```

We can't read the secret anymore and the filed `deletion_time` is provided:
```shell
$ vault kv get -version=1 kv/user
== Secret Path ==
kv/data/user

======= Metadata =======
Key                Value
---                -----
created_time       2023-12-14T17:53:22.293493737Z
custom_metadata    <nil>
deletion_time      2023-12-15T18:01:27.138616706Z
destroyed          false
version            1
```

* Display all the metadata:
```shell
vault kv metadata get kv/user
vault kv get -mount=kv user
```

* Delete the whole key (no restore):
```shell
vault kv metadata delete kv/user
vault kv metadata delete -mount=kv user
```

* Restore a previous secret that has been deleted (not destroyed):
```shell
vault kv undelete kv/user
vault kv undelete -mount=kv user

vault kv undelete -versions=1 kv/user
vault kv undelete -mount=kv user
```

* Destroy a secret:
```shell
vault kv destroy kv/user
vault kv destroy -versions=1 kv/user

vault kv destroy -mount=kv user
vault kv destroy -versions=1 -mount=kv user
```

This time the field `destroyed` is set to `true`:
```shell
$ vault kv get -version=1 kv/user
== Secret Path ==
kv/data/user

======= Metadata =======
Key                Value
---                -----
created_time       2023-12-14T17:53:22.293493737Z
custom_metadata    <nil>
deletion_time      n/a
destroyed          true
version            1
```

If the secret was deleted before beeing destroyed, the fields `deletion_time` is provided and `destroyed` is set to `true`:
```shell
$ vault kv get -version=2 kv/user
== Secret Path ==
kv/data/user

======= Metadata =======
Key                Value
---                -----
created_time       2023-12-15T17:55:05.17607155Z
custom_metadata    <nil>
deletion_time      2023-12-15T17:57:59.114373513Z
destroyed          true
version            2
```

* Wrap / unwrap:
  * [Hashicorp tuto](https://developer.hashicorp.com/vault/tutorials/secrets-management/cubbyhole-response-wrapping)

Create a wrap with a TTL set to 300s:
```shell
$ vault kv get -mount=kv -wrap-ttl=300 user
Key                              Value
---                              -----
wrapping_token:                  hvs.CAESIP_9g0fNHAnvn44-TKzaQHS83OtcVYQ5I6BrOwVFNvq4Gh4KHGh2cy4wc2pIRUJYQU9zaXZ5bHJRTjBCVWZ5RDQ
wrapping_accessor:               wu7fs89cx7mHrnFXll8zGWYd
wrapping_token_ttl:              5m
wrapping_token_creation_time:    2023-12-15 19:48:58.704958995 +0000 UTC
wrapping_token_creation_path:    kv/data/user
```

Send this token by email for example. The person that receive the email can unwrap with this token only one time to see the secret:
```shell
$ vault unwrap hvs.CAESIP_9g0fNHAnvn44-TKzaQHS83OtcVYQ5I6BrOwVFNvq4Gh4KHGh2cy4wc2pIRUJYQU9zaXZ5bHJRTjBCVWZ5RDQ
Key         Value
---         -----
data        map[password:mypassword user:admin]
metadata    map[created_time:2023-12-15T18:26:58.577873308Z custom_metadata:<nil> deletion_time: destroyed:false version:2]
```

If you try to unwrap again:
```shell
$ vault unwrap hvs.CAESIP_9g0fNHAnvn44-TKzaQHS83OtcVYQ5I6BrOwVFNvq4Gh4KHGh2cy4wc2pIRUJYQU9zaXZ5bHJRTjBCVWZ5RDQ
Error unwrapping: Error making API request.

URL: PUT https://vault.gigix:443/v1/sys/wrapping/unwrap
Code: 400. Errors:

* wrapping token is not valid or does not exist
```

#### Databases
* [API documentation](https://developer.hashicorp.com/vault/api-docs/secret/databases)

* Enable auth `database`:
```shell
vault secrets enable database
```

##### Postgres
* [Documentation](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)
* [API documentation](https://developer.hashicorp.com/vault/api-docs/secret/databases/postgresql)
* [Hashicorp tuto - dynamic secrets](https://developer.hashicorp.com/vault/tutorials/db-credentials/database-secrets?in=vault%2Fdb-credentials)
* [Hashciro tuto - static creds](https://developer.hashicorp.com/vault/tutorials/db-credentials/database-creds-rotation)
* [Youtube tuto](https://www.youtube.com/watch?v=ECQD3aW419k)
  * [Commands](https://github.com/mehdilaruelle/vault-youtube/blob/master/vault_secret_dynamic_demonstration.sh)

* Run a docker database:
```shell
$ docker pull postgres:latest
$ docker run \
      --name postgres \
      --env POSTGRES_USER=root \
      --env POSTGRES_PASSWORD=secretpassword \
      --detach  \
      --publish 5432:5432 \
      postgres
```

* Setup configuration connection for Postgres database:
```shell
vault write database/config/postgresql \
  plugin_name=postgresql-database-plugin \
  allowed_roles="*" \
  connection_url="postgresql://{{username}}:{{password}}@192.168.121.1:5432/postgres?sslmode=disable" \
  username="root" \
  password="secretpassword" \
  password_authentication="scram-sha-256"
```

* Create an `admin` role:
```shell
$ docker run -it --rm postgres psql -h 192.168.121.1 -p 5432 -U root -d postgres -c "CREATE ROLE "admin" WITH LOGIN PASSWORD 'mypassword';"
Password for user root:
CREATE ROLE
```

* Grant all privileges to `admin`:
```
$ docker run -it --rm postgres psql -h 192.168.121.1 -p 5432 -U root -d postgres -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"admin\";"
Password for user root:
GRANT
```

* Rotate the `root` credential:
```shell
vault write -force database/rotate-root/postgresql
```

* Configure the template `admin` role:
```shell
$  tee admin.sql <<EOF
ALTER USER "{{name}}" WITH PASSWORD '{{password}}';
EOF
```

* Configure the template `readonly` role:
```shell
$ tee readonly.sql <<EOF
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";
EOF
```

* Create the static role `admin`:
```shell
vault write database/static-roles/admin \
    db_name=postgresql \
    rotation_statements=@admin.sql \
    username="admin" \
    rotation_period=86400
```

* Create the dynamic role `readonly`:
```shell
vault write database/roles/readonly \
      db_name=postgresql \
      creation_statements=@readonly.sql \
      default_ttl=1h \
      max_ttl=24h
```

* Verify the dynamic `readonly` role:
```shell
$ vault read database/roles/readonly

Key                      Value
---                      -----
creation_statements      [CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' INHERIT;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";]
credential_type          password
db_name                  postgresql
default_ttl              1h
max_ttl                  24h
renew_statements         []
revocation_statements    []
rollback_statements      []
```

* Verify the static `admin` role:
```shell
$ vault read database/static-roles/admin
Key                    Value
---                    -----
credential_type        password
db_name                postgresql
last_vault_rotation    2023-12-20T18:19:00.301111975Z
rotation_period        24h
rotation_statements    [ALTER USER "{{name}}" WITH PASSWORD '{{password}}';]
username               admin
```

* Generate a new credential for the `admin` user:
```shell
$ vault read database/static-creds/admin
Key                    Value
---                    -----
last_vault_rotation    2023-12-20T18:19:00.301111975Z
password               HELPOd83B26E-C5oPy-8
rotation_period        24h
ttl                    23h53m18s
username               admin
```

* Generate a new credential for a `readonly` user:
```shell
$ vault read database/creds/readonly
Key                Value
---                -----
lease_id           database/creds/readonly/zJtwXOGp2ctlU00XEdqIiY0D
lease_duration     1h
lease_renewable    true
password           rFjWgMW1Bt5-uzGquOPT
username           v-userpass-readonly-fbrlifR7rpvJWrufDaFC-1703093880
```

* Test the credential:
```shell
$ docker run -it --rm postgres psql -h 192.168.121.1 -p 5432 -U v-userpass-readonly-fbrlifR7rpvJWrufDaFC-1703093880 -d postgres
Password for user v-userpass-readonly-fbrlifR7rpvJWrufDaFC-1703093880:
psql (16.1 (Debian 16.1-1.pgdg120+1))
Type "help" for help.

postgres=>
```

* Revoke all `readonly` creds:
```shell
vault lease revoke -prefix database/creds/readonly
```

**TIPS:**
```shell
$ vault secrets disable database/
Error disabling secrets engine at database/: Error making API request.

URL: DELETE https://vault.gigix:443/v1/sys/mounts/database
Code: 400. Errors:

* failed to revoke "database/creds/readonly/Y3YtBQG9UbnTZAW9dsyD924O" (1 / 1): failed to revoke entry: resp: (*logical.Response)(nil) err: error verifying connection: failed to connect to `host=192.168.121.1 user=root database=postgres`: failed SASL auth (FATAL: password authentication failed for user "root" (SQLSTATE 28P01))
```

* You must revoke first:
```shell
$ vault lease revoke -force -prefix database/creds/readonly/Y3YtBQG9UbnTZAW9dsyD924O
Warning! Force-removing leases can cause Vault to become out of sync with
secret engines!
Success! Force revoked any leases with prefix: database/creds/readonly/Y3YtBQG9UbnTZAW9dsyD924O
```

Or you can revoke all:
```shell
$ vault lease revoke -force -prefix database/creds/
Warning! Force-removing leases can cause Vault to become out of sync with
secret engines!
Success! Force revoked any leases with prefix: database/creds/
```

#### ssh
* [Documentation](https://developer.hashicorp.com/vault/docs/secrets/ssh/signed-ssh-certificates)
* [Hashicorp blog](https://www.hashicorp.com/blog/managing-ssh-access-at-scale-with-hashicorp-vault)
* [Youtube](https://www.youtube.com/watch?v=P93f7eQdecg)

#### Transit
* [Documentation](https://developer.hashicorp.com/vault/docs/secrets/transit)
* [API documentation](https://developer.hashicorp.com/vault/api-docs/secret/transit)
* [Documentation - Bring Your Own Key (BYOK)](https://developer.hashicorp.com/vault/docs/secrets/transit#bring-your-own-key-byok)
* [Hashicorp tuto - Encryption as a service: transit secrets engine](https://developer.hashicorp.com/vault/tutorials/encryption-as-a-service/eaas-transit?in=vault%2Fencryption-as-a-service)
* [Youtube - Vault secret engine transit EaaS - Concepts](https://www.youtube.com/watch?v=EglpRA7aONo)
* [Youtube - Vault secret engine transit EaaS - Demo](https://www.youtube.com/watch?v=W1LhHUlMMo0)
* [Commands](https://github.com/mehdilaruelle/vault-youtube/blob/master/vault_transit_demonstration.sh)


* Enable the backend `transit`:
```Shell
vault secrets enable transit
```

* Create `app1`:
```shell
vault write -f transit/keys/app1
```

* Verify the key `app1`:
```shell
vault read transit/keys/app1
```

* Encrypt:
```shell
ENCRYPTED_SECRET=$(vault write -field="ciphertext" transit/encrypt/app1 plaintext=$(echo "test" | base64))
```

* Decrypt:
```shell
$ vault write -field=plaintext transit/decrypt/app1 ciphertext=$ENCRYPTED_SECRET | base64 --decode
test
```

* Rotate the key:
```shell
vault write -f transit/keys/app1/rotate
```

* Rotate the key of `app1` everydays:
```shell
vault write transit/keys/app1/config auto_rotate_period=24h
```

* Force `$ENCRYPTED_SECRET` to be rencoded (`rewrap`) with the new key (`rotate`):
```shell
vault write transit/rewrap/app1 ciphertext=$ENCRYPTED_SECRET
Key            Value
---            -----
ciphertext     vault:v2:MobjeAVL6clj9kFwFnRITrRw/GBaKWD+PCfDSihN+Fyx
key_version    2
```

* Decrypt the new one:
```shell
vault write -field=plaintext transit/decrypt/app1 ciphertext="vault:v2:MobjeAVL6clj9kFwFnRITrRw/GBaKWD+PCfDSihN+Fyx" | base64 --decode
test
```

* Force only the version2 to be decrypted:
```shell
vault write transit/keys/app1/config min_decryption_version=2
```

Now the version 1 failed to be decrypted:
```shell
$ vault write -field=plaintext transit/decrypt/app1 ciphertext=$ENCRYPTED_SECRET | base64 --decode
Error writing data to transit/decrypt/app1: Error making API request.

URL: PUT https://vault.gigix:443/v1/transit/decrypt/app1
Code: 400. Errors:

* ciphertext or signature version is disallowed by policy (too old)
```

* Generate a datakey:
```shell
$ vault write -f transit/datakey/plaintext/app1
Key            Value
---            -----
ciphertext     vault:v2:RFDOdRVXaBYRXdSdTlgV9yM8mL9xGycdyr/zg3CLdZW6bANIVn2KWbf4N9woJMBL/NdfAWC5oXiuDQbo
key_version    2
plaintext      aSlN/yjWGZXCDGE4G08nz97FNqkVCv3NdngYWOB6cp4=
```

* Decrypt from `ciphertext` (we retrieve the `plaintext`):
```shell
vault write -field=plaintext transit/decrypt/app1 ciphertext=vault:v2:RFDOdRVXaBYRXdSdTlgV9yM8mL9xGycdyr/zg3CLdZW6bANIVn2KWbf4N9woJMBL/NdfAWC5oXiuDQbo
aSlN/yjWGZXCDGE4G08nz97FNqkVCv3NdngYWOB6cp4=
```

#### pki
* [Hashicorp tuto](https://developer.hashicorp.com/vault/tutorials/new-release/pki-cieps)
* [Documentation](https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine)
* [API documentation](https://developer.hashicorp.com/vault/api-docs/secret/pki)

* Enable the PKI secrets engine at its default path:
```shell
vault secrets enable pki
```

* Configure the max lease time-to-live (TTL) to 8760h:
```shell
vault secrets tune -max-lease-ttl=87600h pki
```

* Generate a self-signed certificate valid for `8760h`:
```shell
vault write pki/root/generate/internal \
  issuer_name="root_CA" \
  common_name=example.com \
  ttl=8760h
```

You can use `-field=certificate` to generate the certificate like:
```shell
vault write -field=certificate pki/root/generate/internal \
  issuer_name="root_CA" \
  common_name=example.com \
  ttl=8760h > root_CA.crt
```

* Configure the PKI secrets engine certificate issuing and certificate revocation list (CRL) endpoints:
```shell
vault write pki/config/urls \
  issuing_certificates="https://vault.gigix/v1/pki/ca,http://vault-internal.vault:8200/v1/pki/ca" \
  crl_distribution_points="https://vault.gigix/v1/pki/crl,http://vault-internal.vault:8200/v1/pki/crl"
```

* Create a role:
```shell
vault write pki/roles/example-dot-com \
  allowed_domains=example.com \
  allow_subdomains=true \
  allow_bare_domains=false \
  # allow_glob_domains=true \
  # allow_any_name=true \
  allow_wildcard_certificates=true \
  allow_localhost=false \
  key_bits=4096 \
  # not_after=YYYY-MM-ddTHH:MM:SSZ
  max_ttl=72h
```

Example:
```shell
$ vault write pki/roles/example.com \
  allowed_domains=example.com \
  allow_subdomains=true \
  allow_bare_domains=false \
  allow_wildcard_certificates=true \
  allow_localhost=false \
  key_bits=4096 \
  max_ttl=72h
Key                                   Value
---                                   -----
allow_any_name                        false
allow_bare_domains                    false
allow_glob_domains                    false
allow_ip_sans                         true
allow_localhost                       false
allow_subdomains                      true
allow_token_displayname               false
allow_wildcard_certificates           true
allowed_domains                       [example.com]
allowed_domains_template              false
allowed_other_sans                    []
allowed_serial_numbers                []
allowed_uri_sans                      []
allowed_uri_sans_template             false
allowed_user_ids                      []
basic_constraints_valid_for_non_ca    false
client_flag                           true
cn_validations                        [email hostname]
code_signing_flag                     false
country                               []
email_protection_flag                 false
enforce_hostnames                     true
ext_key_usage                         []
ext_key_usage_oids                    []
generate_lease                        false
issuer_ref                            default
key_bits                              4096
key_type                              rsa
key_usage                             [DigitalSignature KeyAgreement KeyEncipherment]
locality                              []
max_ttl                               72h
no_store                              false
not_after                             n/a
not_before_duration                   30s
organization                          []
ou                                    []
policy_identifiers                    []
postal_code                           []
province                              []
require_cn                            true
server_flag                           true
signature_bits                        256
street_address                        []
ttl                                   0s
use_csr_common_name                   true
use_csr_sans                          true
use_pss                               false
```

### auth
* [Documentation](https://developer.hashicorp.com/vault/docs/auth)
* [Youtube - HashiCorp Vault auth methods](https://www.youtube.com/watch?v=XElE2ia_qbA)

* List enabled auth:
```
$ vault auth list
Path         Type        Accessor                  Description                Version
----         ----        --------                  -----------                -------
approle/     approle     auth_approle_221d74fc     n/a                        n/a
token/       token       auth_token_ed828765       token based credentials    n/a
userpass/    userpass    auth_userpass_57c420f1    n/a                        n/a
```

* Destroy auth userpass:
```shell
vault auth disable userpass
```

* After **login** the token is put in `~/.vault-token`:
```shell
cat ~/.vault-token
```

#### token
* [API documentation](https://developer.hashicorp.com/vault/api-docs/auth/token)

##### lookup
* Information about the current token:
```shell
$ vault token lookup
Key                 Value
---                 -----
accessor            4uosAn33QdFD5Xc7f59D2aow
creation_time       1702511834
creation_ttl        0s
display_name        root
entity_id           n/a
expire_time         <nil>
explicit_max_ttl    0s
id                  hvs.RZSPGDrwRfS4Njc8ZBHQOERm
meta                <nil>
num_uses            0
orphan              true
path                auth/token/root
policies            [root]
ttl                 0s
type                service
```

Or:
```shell
vault token lookup <token>
```

Or
```shell
vault token lookup -accessor <accessor>
```

##### capabilities
```shell
$ vault token capabilities secret/foo
read
```

```shell
$ vault token capabilities <token> database/creds/readonly
deny
```

##### create
* Create a token (type **service** by default) with 10m TTL and a max policy to 20min with the `default` policy:
```shell
vault token create -ttl=600s -explicit-max-ttl=1200s -policy=default
```

* Create an **orphan** token with the `default` policy:
```shell
vault token create -orphan -policy=default
```

* Create a **periodic** (can be renewed endlessly) token only valid **2** times:
```shell
vault token create -policy=default -use-limit=2 -period=1h
```

* Create a **batch** token:
```shell
vault token create -policy=default -type=batch -ttl=10m
```

* Create child token (`-field=token`). `root` polixy has full permissions, require to create a child token. `default` policy does not have the permission to create child token:
```shell
TOKEN_ID=$(vault token create -ttl=10m -policy=root -field=token)
VAULT_TOKEN=${TOKEN_ID} vault token create -policy=default
```

##### renew
* Renew a token to its initial TTL:
```shell
vault token renew <token>
```

* Renew to a specific TTL (can't be exceed the max TTL):
```shell
vault token renew -increment=30m <token>
```

##### revoke
* Revoke a token:
```shell
vault token revoke <token>
```

* Revoke a token from an accessor:
```shell
vault token revoke -accessor <accessor>
```

#### read
* Display various information about token on the system:
```shell
vault read sys/auth/token/tune
```

#### userpass
The `userpass` authentication method allow to authenticate users.

* [Documentation](https://developer.hashicorp.com/vault/docs/auth/userpass)
* [API documentation](https://developer.hashicorp.com/vault/api-docs/auth/userpass)

* Enable auth `userpass`:
```shell
vault auth enable userpass
```

You can change the default pass `userpass` to test to deploy multiple time the `userpass` auth method:
```shell
vault auth enable -path="test" userpass
```

* Create a user:
```shell
vault write auth/userpass/users/glemeur password=gigix policies=user,default
```

* List users:
```shell
$ vault list auth/userpass/users/
Keys
----
glemeur
```

* Display information about the user `glemeur`:
```shell
$ vault read auth/userpass/users/glemeur
Key                        Value
---                        -----
policies                   [user]
token_bound_cidrs          []
token_explicit_max_ttl     0s
token_max_ttl              0s
token_no_default_policy    false
token_num_uses             0
token_period               0s
token_policies             [user]
token_ttl                  0s
token_type                 default
```

* Use the credential glemeur to login:
```shell
vault login -method=userpass username=glemeur
vault login -method=userpass -path=test username=glemeur password=gigix
```

* Use the generated token to override the current env `VAULT_TOKEN`:
```shell
VAULT_TOKEN=$(cat ~/.vault-token) vault token lookup
```

#### approle
The `approle` authentication method allow to authenticate applications.

* [Documentation](https://developer.hashicorp.com/vault/docs/auth/approle)
* [API documentation](https://developer.hashicorp.com/vault/api-docs/auth/approle)

* Enable auth `approle`:
```shell
vault auth enable approle
```

* Create role app:
```shell
vault write auth/approle/role/app token_policies="default"
```

* List approle:
```shell
$ vault list auth/approle/role/
Keys
----
app
```

* Display information about approle `app`:
```shell
$ vault read auth/approle/role/app
Key                        Value
---                        -----
bind_secret_id             true
local_secret_ids           false
secret_id_bound_cidrs      <nil>
secret_id_num_uses         0
secret_id_ttl              0s
token_bound_cidrs          []
token_explicit_max_ttl     0s
token_max_ttl              0s
token_no_default_policy    false
token_num_uses             0
token_period               0s
token_policies             [default]
token_ttl                  0s
token_type                 default
```

* Display the `role-id` (static):
```shell
$ vault read auth/approle/role/app/role-id
Key        Value
---        -----
role_id    f9d849fd-b5c4-5edb-bd98-a076bcc07ba7
```

* Generate the `secret-id`:
```shell
$ vault write -f auth/approle/role/app/secret-id
Key                   Value
---                   -----
secret_id             fe8318d2-675f-3f5f-43c2-df0e06686b13
secret_id_accessor    79f00f0c-e6b8-3536-ff21-a7c5b68861af
secret_id_num_uses    0
secret_id_ttl         0s
```

* Use `role_id` and `secret_id` to login and generate the token:
```shell
$ vault write auth/approle/login role_id=f9d849fd-b5c4-5edb-bd98-a076bcc07ba7 secret_id=fe8318d2-675f-3f5f-43c2-df0e06686b13
Key                     Value
---                     -----
token                   hvs.CAESIM-1iWuUqvquAmH6PZ8VD9vyAZPrv6ykn8rIREY77fBcGh4KHGh2cy5ZSkNtd1kxR1JtOGx6eDNjblluanhVU1o
token_accessor          FtcdMqwrxowiJ5wL2LzqNOL3
token_duration          768h
token_renewable         true
token_policies          ["default"]
identity_policies       []
policies                ["default"]
token_meta_role_name    app
```

#### kubernetes
* [API documentation](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
  * [Youtube - Vault + Kubernetes Sidecar Injection](https://www.youtube.com/watch?v=xUuJhgDbUJQ)

* [Documentation - Vault secret operator](https://developer.hashicorp.com/vault/tutorials/kubernetes/vault-secrets-operator#install-the-vault-secrets-operator)
  * [Youtube - Seamless secret management with Vault Kubernetes Secrets Operator](https://www.youtube.com/watch?v=NGLMPz3kAUU)
  * [Examples](https://docmoa.github.io/assets/vault-login-mfa-totp-84ec4286.gif)

* [ArgoCD Vault Plugin](https://argocd-vault-plugin.readthedocs.io/en/stable/)
  * [Example](https://docmoa.github.io/assets/vault-login-mfa-totp-84ec4286.gif)

* [ExternalDNS Documentation - HashiCorp Vault](https://external-secrets.io/latest/provider/hashicorp-vault/)
  * [Youtube - External Secret Operator | Installation and Vault Integration using AppRole auth](https://www.youtube.com/watch?v=RHlJtVD1K38)

Example:
```yaml
# Auth with kubernetes with ClusterSecretStore
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: http://vault-internal.vault:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: k8s
          serviceAccountRef:
            name: default
            namespace: demo
---
# Auth by a token named vault-token with the key named token with SecretStore (namespaced)
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
# kind: ClusterSecretStore
metadata:
  name: vault-backend
  namespace: demo
spec:
  provider:
    vault:
      server: http://vault-internal.vault:8200
      path: kv
      version: v2
      auth:
        # kubernetes:
        #  mountPath: kubernetes
        #  role: k8s
        tokenSecretRef:
          name: vault-token
          key: token
          # namespace: xxx
---
# Use ClusterSecretStore instead of SecretStore
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mypassword2
  namespace: demo
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: password2
  data:
  - secretKey: MyPassword
    remoteRef:
      key: demo/config
      property: password
---
# Specific keys
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mypassword
  namespace: demo
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    immutable: true
    name: password
  data:
  - secretKey: MyPassword
    remoteRef:
      key: demo/config
      property: password
  # metadataPolicy to fetch vault metadata in json format
  - secretKey: tags
    remoteRef:
      metadataPolicy: Fetch
      key: demo/config
  # metadataPolicy to fetch vault metadata meta1
  - secretKey: meta1
    remoteRef:
      metadataPolicy: Fetch
      key: demo/config
      property: meta1
---
# All keys
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gigix
  namespace: demo
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: gigix
  dataFrom:
  - extract:
      key: demo/config
---
# Template
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: template
  namespace: demo
spec:
  refreshInterval: 15s
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    deletionPolicy: Delete
    name: template
    template:
      engineVersion: v2
      data:
        uri: "tcp://localhost:{{ .username }}:{{ .password }}"
  dataFrom:
  - extract:
      key: demo/config
---
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: pushsecret
  namespace: demo
spec:
  deletionPolicy: Delete # the provider' secret will be deleted if the PushSecret is deleted
  refreshInterval: 10s
  secretStoreRefs:
    - name: vault-backend
      kind: SecretStore
  selector:
    secret:
      name: pushsecret
  data:
    - match:
        secretKey: mysecret
        remoteRef:
          remoteKey: secret
```

* [Kubernetes Secrets Store CSI Driver - Documentation](https://secrets-store-csi-driver.sigs.k8s.io/)
  * [Github - secrets-store-csi-driver](https://github.com/kubernetes-sigs/secrets-store-csi-driver)
  * [Github - vault-csi-provider](https://github.com/hashicorp/vault-csi-provider)
  * [Tuto](https://gauthier.frama.io/post/vault/)

* Enable kubernetes:
```shell
vault auth enable kubernetes
```

* Configure kubernetes:
```shell
$ KUBERNETES_HOST=$(kubectl -n vault exec vault-0 -- sh -c "echo https://\${KUBERNETES_SERVICE_HOST}:\${KUBERNETES_SERVICE_PORT}")
$ vault write auth/kubernetes/config \
  kubernetes_host=${KUBERNETES_HOST}
```

* Add an entry `username` and `password` in `kv/demo/config`:
```shell
vault kv put kv/demo/config username='admin' password='P@ssw0rd!'
```

* Create a demo policy:
```shell
$ vault policy write demo - <<EOF
path "kv/data/demo/config" {
  capabilities = ["read"]
}
EOF

Success! Uploaded policy: demo
```

* Configure the role:
```shell
vault write auth/kubernetes/role/vault-demo \
  bound_service_account_names=default \
  bound_service_account_namespaces=demo \
  policies=demo \
  ttl=24h
```

* Deploy the demo app in kubernetes:

```shell
$ kubectl create ns demo
$ cat <<EOF | kubectl apply -n demo -f -
apiVersion: v1
kind: Pod
metadata:
  name: vault-demo
  namespace: demo
spec:
  serviceAccountName: default
  restartPolicy: "OnFailure"
  containers:
    - name: vault-demo
      image: badouralix/curl-jq
      command: ["sh", "-c"]
      resources: {}
      args:
      - |
        VAULT_ADDR="http://vault-internal.vault:8200"
        SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
        VAULT_RESPONSE=$(curl -X POST -H "X-Vault-Request: true" -d '{"jwt": "'"$SA_TOKEN"'", "role": "vault-demo"}' \
          $VAULT_ADDR/v1/auth/kubernetes/login | jq .)

        echo $VAULT_RESPONSE
        echo ""

        VAULT_TOKEN=$(echo $VAULT_RESPONSE | jq -r '.auth.client_token')
        echo $VAULT_TOKEN

        echo "Fetching vault-demo/mysecret from vault...."
        VAULT_SECRET=$(curl -s -H "X-Vault-Token: $VAULT_TOKEN" $VAULT_ADDR/v1/kv/data/demo/config)
        echo $VAULT_SECRET
EOF
```

* Demo:
```shell
$ kubectl -n demo logs pods/vault-demo
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  1767  100   734  100  1033  34949  49185 --:--:-- --:--:-- --:--:-- 88350
{ "request_id": "8b8fc502-f97f-2bdf-678b-0ccf666c6dd3", "lease_id": "", "renewable": false, "lease_duration": 0, "data": null, "wrap_info": null, "warnings": null, "auth": { "client_token": "hvs.CAESILywqA9vfpQ9IAi21MCUlCYlheskAbvcMtNKRGA-5PPcGh4KHGh2cy5yT1JyeHp5eGhCMnVyejdkS1JXaDJHSmY", "accessor": "ZTd7Dkpaiy5SacNdUJb7peun", "policies": [ "default", "demo" ], "token_policies": [ "default", "demo" ], "metadata": { "role": "vault-demo", "service_account_name": "default", "service_account_namespace": "demo", "service_account_secret_name": "", "service_account_uid": "efc41baa-852f-42f3-ac77-f73d32f547ad" }, "lease_duration": 3600, "renewable": true, "entity_id": "74a984d5-c589-fa53-7679-372ab386c9bb", "token_type": "service", "orphan": true, "mfa_requirement": null, "num_uses": 0 } }

hvs.CAESILywqA9vfpQ9IAi21MCUlCYlheskAbvcMtNKRGA-5PPcGh4KHGh2cy5yT1JyeHp5eGhCMnVyejdkS1JXaDJHSmY
Fetching vault-demo/mysecret from vault....
{"request_id":"b6d2e42b-0052-da40-ae6b-2c2ef01bd4b6","lease_id":"","renewable":false,"lease_duration":0,"data":{"data":{"password":"P@ssw0rd!","username":"admin"},"metadata":{"created_time":"2023-12-16T23:08:16.061824325Z","custom_metadata":null,"deletion_time":"","destroyed":false,"version":1}},"wrap_info":null,"warnings":null,"auth":null}
```
