# XSql

Crossplane platform primitive that provisions a Postgres relational database and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Standalone resource with a lifecycle independent of any one API. Bind to an `XApi` via `sqlRef.name`.

See also: [`XNoSql`](../nosql/README.md) · [`XCache`](../cache/README.md) · [`XObjectStorage`](../object-storage/README.md) · [`XApi`](../api/README.md)

## What it provisions
- `environment: cluster` — **in-cluster Postgres** (Deployment + PVC on Longhorn) + binding Secret; no cloud resources
- `environment: cloud` — **AWS RDS Postgres** instance + binding Secret

## Binding secret

Secret name equals the XR name; namespace comes from the `namespace` parameter passed by the parent `XApi`. Mounted at `/bindings/sql/` inside the container.

| Key | Value |
|---|---|
| `type` | `postgresql` |
| `provider` | `aws` (cloud) or `in-cluster` (cluster) |
| `host` | Database endpoint hostname |
| `port` | `5432` |
| `database` | Database name |
| `username` | Username |
| `password` | Password |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace to write the binding Secret into. Passed automatically by `XApi`. |
| `environment` | no | `cluster` | `cloud` provisions AWS RDS Postgres; `cluster` provisions in-cluster Postgres |
| `region` | no | `us-east-1` | Cloud region for the RDS instance (cloud only) |
| `size` | no | `small` | T-shirt size for the RDS instance (cloud only): `small=db.t4g.micro`, `medium=db.t4g.small`, `large=db.t4g.medium` |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSql
metadata:
  name: foo-db
spec:
  parameters:
    environment: cluster   # in-cluster Postgres — no AWS resources provisioned
    namespace: foo
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSql
metadata:
  name: foo-db
spec:
  parameters:
    environment: cloud   # provisions AWS RDS Postgres
    region: us-east-1
    size: small   # small=db.t4g.micro | medium=db.t4g.small | large=db.t4g.medium
    namespace: foo
```

Then reference from an `XApi`:

```yaml
spec:
  parameters:
    sqlRef:
      name: foo-db
```

Instance files live in [`homelab-tenants/`](../../../homelab-tenants/).

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xsqls foo-db

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xsql foo-db -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all 7 keys are present
kubectl get secret foo-db -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Connect to in-cluster Postgres directly
kubectl exec -it -n foo deploy/foo-db-postgres -- psql -U app -d foo-db
```
