# Sql

Crossplane platform primitive that provisions a Postgres relational database and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Standalone resource with a lifecycle independent of any one API. Bind to an `Api` via `sqlRef.name`.

## What it provisions
- `backend: private-cloud` - **in-cluster Postgres** (Deployment + PVC on Longhorn) + binding Secret; no cloud resources
- `backend: public-cloud` - **AWS RDS Postgres** + IAM Role + binding Secret; IAM DB auth; no password in the binding Secret

> **Known limitation: `public-cloud` is not currently reachable from this cluster.** The RDS instance is created with `publiclyAccessible: false` and no explicit `dbSubnetGroupName`/security group, so it lands in the AWS account's default VPC. There is no network path (VPN, peering, or otherwise) between this homelab cluster and that VPC, so pods cannot open a connection to it - verified: the RDS hostname resolves only to a private VPC IP, and a raw TCP connection times out. Everything up to that point works correctly: the instance provisions, the IAM Role is created, and the sidecar successfully exchanges the pod's SVID for real STS credentials. The gap is purely network reachability, not identity or credentials. No current workload uses `public-cloud` for Sql - closing this would mean either making the instance internet-reachable and security-group-restricted (fixes only Sql; Cache's ElastiCache has no public-access option at all), or bridging into the VPC (e.g. a Tailscale subnet router running inside it, the same pattern already used for the homelab's own LAN) - worth doing only when a real workload needs it.

## Binding secret

Secret name:
- `public-cloud` → one secret per consumer: `{consumer}-sql` (e.g. `foo-api-sql`, `bar-api-sql`)
- `private-cloud` → `{sql-name}`

Namespace comes from the `namespace` parameter. Mounted at `/bindings/sql/` inside the container.

Multiple consumers' secrets coexist in the same namespace but each Api's RBAC Role grants `get` only on its own named secrets - `foo-api`'s ServiceAccount cannot read `bar-api-sql`.

| Key | Value | Backend |
|---|---|---|
| `type` | `postgresql` | all |
| `provider` | `in-cluster` or `aws` | all |
| `host` | Database endpoint hostname | all |
| `port` | `5432` | all |
| `database` | Database name - the Sql name as-is (`private-cloud`) or with dashes replaced by underscores (`public-cloud`) | all |
| `username` | Database user (`app`) | all |
| `password` | Database password | `private-cloud` only |
| `role-arn` | IAM role ARN | `public-cloud` only |

**`public-cloud` auth flow:** No password is written to the binding Secret. The `workload-identity-sidecar` exchanges the pod's SVID for short-lived STS credentials. The app then calls `aws rds generate-db-auth-token` using those credentials to produce a short-lived RDS auth token, which it uses as the database password. No static password is stored anywhere accessible to the app.

> **Note: master password exists but is not app-visible.** The RDS instance requires a master password at creation time. The composition generates one deterministically from the XR UID and stores it outside the tenant namespace, where only the platform can read it. This is the RDS admin password - the app never sees it. The app authenticates via IAM DB auth only.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | - | Namespace to deploy the database into and write binding Secrets to. |
| `backend` | no | `private-cloud` | `public-cloud` provisions AWS RDS Postgres; `private-cloud` provisions in-cluster Postgres. |
| `size` | no | `sm` | T-shirt size for the RDS instance (public-cloud only): `xs=db.t4g.micro`, `sm=db.t4g.small`, `md=db.t4g.medium`, `lg=db.t4g.large` |
| `dataRetention` | no | `delete` | Longhorn PVC reclaim (private-cloud only): `retain` (PVC survives XR deletion, data recoverable) or `delete` (PVC wiped on deletion, data unrecoverable). |
| `consumerServiceAccounts` | public-cloud | - | List of Api names that will bind this database. Each entry gets its own IAM role and binding secret scoped to that SA's exact SPIFFE ID. Each entry must match an Api `metadata.name`. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Sql
metadata:
  name: foo-db
spec:
  parameters:
    backend: private-cloud   # in-cluster Postgres - no AWS resources provisioned
    namespace: foo
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Sql
metadata:
  name: foo-db
spec:
  parameters:
    backend: public-cloud   # provisions AWS RDS Postgres
    size: sm   # xs=db.t4g.micro | sm=db.t4g.small | md=db.t4g.medium | lg=db.t4g.large
    namespace: foo
    consumerServiceAccounts:
      - foo-api   # each entry gets its own IAM role and binding secret
```

Then reference from an `Api`:

```yaml
spec:
  parameters:
    sqlRef:
      name: foo-db
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Public-cloud provisioning

The `public-cloud` backend runs a multi-pass chain. The RDS instance and IAM Role are created in parallel on the first pass; subsequent steps wait for their prerequisites to appear in observed state.

```
Pass 1: RDS Instance created (iamDatabaseAuthenticationEnabled: true; master password from the platform-held master secret)
        Per consumer in consumerServiceAccounts:
          IAM Role created (trust policy StringEquals scoped to that SA's SPIFFE ID)
Pass 2: Per consumer: Binding Secret written (deferred until RDS is ready)
```

**Trust policy scope.** Each consumer gets its own IAM role with a `StringEquals` trust policy scoped to `spiffe://homelab.local/ns/{namespace}/sa/{consumer}`. Multiple Apis can share one RDS instance - each declares itself in `consumerServiceAccounts` and gets an independent role and binding secret.

Because Sql is standalone, consumer names must be declared upfront. Each consumer must match an Api `metadata.name` in the same namespace.

The inline policy grants only `rds-db:connect` scoped to the `app` database user on any RDS instance in the account:

```json
"Action": "rds-db:connect",
"Resource": "arn:aws:rds-db:{region}:{account}:dbuser/*/app"
```

For the full workload identity design: [Platform Workload Identity](../../docs/platform-workload-identity.md)

> **`skipFinalSnapshot: true`** The RDS instance is created without a final snapshot. Deleting the XR permanently destroys the data with no recovery path. Intentional for homelab cost management.

## Operations

```bash
# XR status - SYNCED=composition ran, READY=all children healthy
kubectl get sqls foo-db

# Detailed conditions - shows exactly WHY something is not ready
kubectl get sql foo-db -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secrets - one per consumer, named {consumer}-sql
kubectl get secret foo-api-sql -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Connect to in-cluster Postgres directly (database name = Sql name)
kubectl exec -it -n foo deploy/foo-db-postgres -- psql -U app -d foo-db

# RDS instance status (public-cloud backend)
aws rds describe-db-instances --db-instance-identifier foo-db
```
