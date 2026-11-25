# Sql

A Sql is a Postgres database with its own lifecycle. An `Api` binds to it with `sqlRef.name` and gets its connection details as a [servicebinding.io](https://servicebinding.io) Secret.

## Backends

- **`private-cloud`:** Postgres in the cluster, on a persistent volume. Only an `Api` that names it in `sqlRef` can connect.
- **`public-cloud`:** AWS RDS Postgres with IAM database auth. The binding holds no password.

> **`public-cloud` has no network path from this cluster.** The instance lands in a private AWS VPC. Provisioning and the credential exchange both work, but a pod cannot open a connection. No workload uses it today.

## Binding secret

The Secret lands in the Sql's namespace and mounts at `/bindings/sql/`.

- **`private-cloud` name:** `{sql-name}`.
- **`public-cloud` name:** one per consumer, `{consumer}-sql`, such as `foo-api-sql`. Each Api can read only its own.

| Key | Value | Backend |
|---|---|---|
| `type` | `postgresql` | all |
| `provider` | `in-cluster` or `aws` | all |
| `host` | Database endpoint hostname | all |
| `port` | `5432` | all |
| `database` | The Sql name as-is (`private-cloud`), or with dashes turned to underscores (`public-cloud`) | all |
| `username` | `app` | all |
| `password` | Database password | `private-cloud` only |
| `role-arn` | IAM role ARN | `public-cloud` only |

`public-cloud` sign-in works like this.

1. The `workload-identity-sidecar` trades the pod's identity for short-lived AWS credentials.
2. The app calls `aws rds generate-db-auth-token` with them.
3. The app uses that token as the database password.

RDS also needs an admin password. The platform keeps it in its own Secret, and the app never sees it.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `backend` | no | `private-cloud` | `private-cloud` for in-cluster Postgres. `public-cloud` for AWS RDS Postgres. |
| `size` | no | `sm` | RDS instance size, `public-cloud` only. `xs`: `db.t4g.micro`. `sm`: `db.t4g.small`. `md`: `db.t4g.medium`. `lg`: `db.t4g.large`. |
| `dataRetention` | no | `delete` | `private-cloud` only. `retain` keeps the data after the XR is deleted. `delete` wipes it. |
| `storageSize` | yes | - | `1Gi` to `100Gi`, such as `1Gi`. `public-cloud` needs at least `20Gi`. You can raise it later but never lower it. |
| `consumerServiceAccounts` | `public-cloud` | - | Api names that bind this database. Each must match an Api `metadata.name` in the same namespace. Each gets its own IAM role and binding secret. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Sql
metadata:
  name: foo-db
  namespace: foo
spec:
  parameters:
    backend: private-cloud   # in-cluster Postgres - no AWS resources provisioned
    storageSize: 1Gi
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Sql
metadata:
  name: foo-db
  namespace: foo
spec:
  parameters:
    backend: public-cloud   # provisions AWS RDS Postgres
    size: sm   # xs=db.t4g.micro | sm=db.t4g.small | md=db.t4g.medium | lg=db.t4g.large
    storageSize: 20Gi
    consumerServiceAccounts:
      - foo-api   # each entry gets its own IAM role and binding secret
```

Then reference it from an `Api`.

```yaml
spec:
  parameters:
    sqlRef:
      name: foo-db
      backend: public-cloud   # only for a public-cloud Sql
```

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).

## Public-cloud provisioning

The database and the consumer roles come up first. Each binding secret follows once the database is ready.

| Topic | Detail |
|---|---|
| Roles | One per consumer. Each trusts only `spiffe://homelab.local/ns/{namespace}/sa/{consumer}`. |
| Sharing | Many Apis can share one database. Each lists itself in `consumerServiceAccounts`. |
| Permission | Only `rds-db:connect` as the `app` user. |

```json
"Action": "rds-db:connect",
"Resource": "arn:aws:rds-db:{region}:{account}:dbuser/*/app"
```

See [Platform Workload Identity](../docs/workload-identity.md) for the full identity design.

> **Deleting the XR destroys the data.** RDS takes no final snapshot, so there is no recovery.

## Operations

```bash
# XR status - SYNCED=composition ran, READY=all children healthy
kubectl get sqls foo-db -n foo

# Detailed conditions - shows exactly WHY something is not ready
kubectl get sql foo-db -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secrets - one per consumer, named {consumer}-sql
kubectl get secret foo-api-sql -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Connect to in-cluster Postgres directly (database name = Sql name)
kubectl exec -it -n foo deploy/foo-db-postgres -- psql -U app -d foo-db

# RDS instance status (public-cloud backend)
aws rds describe-db-instances --db-instance-identifier foo-db
```
