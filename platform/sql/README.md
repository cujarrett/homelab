# XSql

Crossplane platform primitive that provisions a Postgres relational database and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Standalone resource with a lifecycle independent of any one API. Bind to an `XApi` via `sqlRef.name`.

## What it provisions
- `backend: private-cloud` — **in-cluster Postgres** (Deployment + PVC on Longhorn) + binding Secret; no cloud resources
- `backend: public-cloud` — **AWS RDS Postgres** instance + binding Secret (see [Deployability](#deployability) for limitations)

## Deployability

**⚠️ Not for scale** The `public-cloud` backend stores master passwords in Kubernetes Secrets. This is acceptable for homelab because apps use IAM DB auth as the primary method and passwords are fallback-only. For production use at scale:

1. Replace Secret-based storage with AWS Secrets Manager + ExternalSecret
2. Generate random passwords at composition time (not deterministic)
3. Enable automatic rotation in Secrets Manager
4. This prevents cluster admins from reading database credentials

Currently, in-cluster databases are the recommended approach for this platform.

## Binding secret

Secret name equals the XR name; namespace comes from the `namespace` parameter. Mounted at `/bindings/sql/` inside the container.

**For `private-cloud`:** Standard username/password auth.

**For `public-cloud`:** IAM DB auth — no password in the Secret. Apps exchange SVID for STS credentials (via sidecar), then call `rds generate-db-auth-token` with those credentials as the password.

| Key | Value | Used by |
|---|---|---|
| `type` | `postgresql` | servicebinding.io spec |
| `provider` | `aws` (public-cloud) or `in-cluster` (private-cloud) | app routing |
| `host` | Database endpoint hostname | all backends |
| `port` | `5432` | all backends |
| `database` | Database name | all backends |
| `username` | Username | private-cloud only; public-cloud uses IAM DB auth |
| `password` | Password (private-cloud) or omitted (public-cloud) | private-cloud only |
| `role-arn` | IAM role ARN | public-cloud only; read by sidecar |
| `profile-arn` | RolesAnywhere profile ARN | public-cloud only; read by sidecar |

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
