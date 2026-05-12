# XSql Platform Offering

`platform/sql/xrd.yaml`, `platform/sql/composition.yaml`, and `platform/sql/README.md` are written. `XSql` is a standalone resource — bound to `XApi` via `sqlRef.name`, not owned by it. The database lifecycle is independent of any one API.

## What it provisions

- `environment: cluster` — in-cluster Postgres (Deployment + PVC on Longhorn) + binding Secret; no cloud resources
- `environment: cloud` — AWS RDS Postgres instance via `provider-aws-rds` + binding Secret

Connection details exposed as a servicebinding.io-compliant Secret in the tenant namespace at `/bindings/sql/`.

| Key | Value |
|---|---|
| `type` | `postgresql` |
| `provider` | `aws` (cloud) or `in-cluster` (cluster) |
| `host` | DB endpoint hostname |
| `port` | `5432` |
| `database` | Database name |
| `username` | Username |
| `password` | Password |

## Remaining work

1. **Test the cluster path** — deploy an `XSql` instance against a real tenant, confirm the Postgres Deployment, PVC, and binding Secret are created and healthy.

2. **Cluster path password** — the in-cluster composition currently uses a static `changeme` password. Replace with a generated Secret (via `function-go-templating` random string or an external Secret manager). See `todo/workload-identity.md`.

3. **Test the cloud path** — requires `provider-aws-rds` to be running (`kubectl get providers`). RDS instance creation takes ~5–10 minutes; watch with `kubectl get xsqls -w`.

4. **Wire at least one tenant** — create a standalone `XSql` in a tenant namespace, then add `sqlRef.name` to an `XApi` (e.g. `my-vinyl-api`) to exercise the full bind path end-to-end.

5. **Update `platform/api/README.md`** — add `sqlRef.name` to the parameters table and binding secrets section.

## Before testing cloud path

- Confirm `provider-aws-rds` is installed and healthy: `kubectl get providers`.
- `provider-aws-rds` was added to `cluster/crossplane/providers.yaml` — sync `platform-definitions` after merging: `argocd app sync platform-definitions --grpc-web`.
