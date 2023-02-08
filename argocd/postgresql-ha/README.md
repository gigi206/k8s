# postgresql-ha
## psql
```bash
docker run -it --rm postgres psql -h 192.168.122.204 -d demo -p 5432 -U admin
```
# repmgr
```bash
kubectl -n postgres-ha exec postgres-ha-postgresql-ha-postgresql-0 -- /opt/bitnami/scripts/postgresql-repmgr/entrypoint.sh repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show
postgresql-repmgr 14:44:44.81
postgresql-repmgr 14:44:44.82 Welcome to the Bitnami postgresql-repmgr container
postgresql-repmgr 14:44:44.82 Subscribe to project updates by watching https://github.com/bitnami/containers
postgresql-repmgr 14:44:44.82 Submit issues and feature requests at https://github.com/bitnami/containers/issues
postgresql-repmgr 14:44:44.82

 ID   | Name                                   | Role    | Status    | Upstream                               | Location | Priority | Timeline | Connection string
------+----------------------------------------+---------+-----------+----------------------------------------+----------+----------+----------+---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 1000 | postgres-ha-postgresql-ha-postgresql-0 | standby |   running | postgres-ha-postgresql-ha-postgresql-1 | default  | 100      | 4        | user=repmgr password=VEJ6bHuPYv host=postgres-ha-postgresql-ha-postgresql-0.postgres-ha-postgresql-ha-postgresql-headless.postgres-ha.svc.cluster.local dbname=repmgr port=5432 connect_timeout=5
 1001 | postgres-ha-postgresql-ha-postgresql-1 | primary | * running |                                        | default  | 100      | 4        | user=repmgr password=VEJ6bHuPYv host=postgres-ha-postgresql-ha-postgresql-1.postgres-ha-postgresql-ha-postgresql-headless.postgres-ha.svc.cluster.local dbname=repmgr port=5432 connect_timeout=5
 1002 | postgres-ha-postgresql-ha-postgresql-2 | standby |   running | postgres-ha-postgresql-ha-postgresql-1 | default  | 100      | 4        | user=repmgr password=VEJ6bHuPYv host=postgres-ha-postgresql-ha-postgresql-2.postgres-ha-postgresql-ha-postgresql-headless.postgres-ha.svc.cluster.local dbname=repmgr port=5432 connect_timeout=5
```