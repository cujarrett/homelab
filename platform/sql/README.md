# XSql

Crossplane platform primitive that provisions a Postgres relational database and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Standalone resource with a lifecycle independent of any one API. Bind to an `XApi` via `sqlRef.name`.

## What it provisions
- `backend: private-cloud` — **in-cluster Postgres** (Deployment + PVC on Longhorn) + binding Secret; no cloud resources
- `backend: public-cloud` — **AWS RDS Postgres** instance + binding Secret (**Phase 7 testing only** — see [Deployability](#deployability) below)

## Deployability

**Important:** The `public-cloud` backend (AWS RDS) is **for Phase 7 workload identity testing only**. After confirming that workload-identity works with XSql, XCache, and XNoSql together, XSql will not be deployed to AWS in production. Long-term, only `XApi`, `XCache`, and `XNoSql` use AWS backends; databases will remain in-cluster (cheaper, simpler, `private-cloud` backend).

The `public-cloud` backend is fully functional for testing. Master password is deterministic (derived from XR UID) and acceptable for homelab because:
1. Apps use IAM DB auth (SVID→RolesAnywhere→STS tokens) as the primary auth method
2. Master password is fallback-only (emergencies, direct CLI access)
3. Data is ephemeral (testing only, deleted after Phase 7 validation)

## Binding secret

Secret name equals the XR name; namespace comes from the `namespace` parameter passed by the parent `XApi`. Mounted at `/bindings/sql/` inside the container.

| Key | Value |
|---|---|
| `type` | `postgresql` |
| `provider` | `aws` (public-cloud) or `in-cluster` (private-cloud) |
| `host` | Database endpoint hostname |
| `port` | `5432` |
| `database` | Database name |
| `username` | Username |
| `password` | Password (or role-arn/profile-arn for IAM auth — see `iamDatabaseAuthenticationEnabled` in composition) |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace to write the binding Secret into. |
| `backend` | no | `private-cloud` | `public-cloud` provisions AWS RDS Postgres; `private-cloud` provisions in-cluster Postgres. |
| `region` | no | `us-east-1` | Cloud region for the RDS instance (public-cloud only). |
| `size` | no | `sm` | T-shirt size for the RDS instance (public-cloud only): `xs=db.t4g.micro`, `sm=db.t4g.small`, `md=db.t4g.medium`, `lg=db.t4g.large` |
| `dataRetention` | no | `delete` | Longhorn PVC reclaim: `retain` (survives XR deletion) or `delete` (wiped on deletion). |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSql
metadata:
  name: foo-db
spec:
  parameters:
    backend: private-cloud   # in-cluster Postgres — no AWS resources provisioned
    namespace: foo
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSql
metadata:
  name: foo-db
spec:
  parameters:
    backend: public-cloud   # provisions AWS RDS Postgres (Phase 7 testing only)
    region: us-east-1
    size: sm   # xs=db.t4g.micro | sm=db.t4g.small | md=db.t4g.medium | lg=db.t4g.large
    namespace: foo
```

Then reference from an `XApi`:

```yaml
spec:
  parameters:
    sqlRef:
      name: foo-db
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
k get xsqls foo-db

# Detailed conditions — shows exactly WHY something is not ready
k get xsql foo-db -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all 7 keys are present
k get secret foo-db -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Connect to in-cluster Postgres directly
k exec -it -n foo deploy/foo-db-postgres -- psql -U app -d foo-db

# RDS instance status (public-cloud backend)
aws rds describe-db-instances --db-instance-identifier foo-db
```
