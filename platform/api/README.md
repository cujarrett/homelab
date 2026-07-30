# Api

Crossplane composition that deploys an API server (Go, Node, GraphQL, etc.) with optional bindings to platform data resources.

## What it provisions
- **Deployment** — runs the API server with init containers that block startup until each binding is ready
- **Service** — ClusterIP on port 80 → container port (default 8080); separate metrics port (default 9090)
- **ServiceAccount** — dedicated per-instance SA; pods do not use the namespace default SA
- **Role + RoleBinding** — least-privilege RBAC: `get` only on the exact Secrets this instance mounts
- **ServiceMonitor** — Prometheus scrape target on the metrics port
- **Ingress** *(optional)* — Traefik `websecure` with TLS; only created when `host` is set. cert-manager issues a certificate via `tlsIssuer` unless `tlsSecret` points to a pre-existing Secret, in which case issuance is skipped.
- **Cache** *(optional)* — short-lived cache cluster owned by this Api; created and deleted alongside it
- **Connection policy** *(optional)* — only when `connectionPosture` is `enforce`. Refuses any call this API makes to a destination it has not declared, and any inbound call whose workload identity is not named in `provides`. Metrics scraping and, when `host` is set, ingress traffic stay reachable — neither carries a workload identity to match on. See [Platform Connections](../../docs/platform-connections.md).

`ObjectStorage`, `Sql`, and `NoSql` are created independently and bound via refs. They outlive any one Api. For `ObjectStorage` and `NoSql`, this composition creates the IAM Role, RolesAnywhere Profile, and binding Secret when the ref is declared — their binding secrets only contain names, region, and ARNs, which Api can compute. For `Sql`, those are created by the Sql composition itself, because its binding secret contains RDS connection details (host, port, username) that are only known after RDS provisioning. The tenant lists consuming Api names in `consumerServiceAccounts` on the Sql — each gets its own IAM role and binding secret scoped to its SA.

The namespace is owned by the tenant — created by `namespace.yaml` in the tenant directory, not by this composition.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Tenant namespace to deploy into. Must already exist. |
| `image` | yes | — | Container image (`ghcr.io/owner/api:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `repo` | no | — | GitHub repository URL for this app's source code. |
| `port` | no | `8080` | Port the container listens on. Service always exposes port 80 → this targetPort. |
| `metricsPort` | no | `9090` | Port the container exposes Prometheus metrics on. Set to match `port` if the app serves metrics and traffic on the same port. |
| `scrapeInterval` | no | `60s` | Prometheus scrape interval. Reduce for apps that emit short-lived state changes. |
| `replicas` | no | `1` | Number of API replicas. |
| `size` | no | `sm` | Compute tier: `xs=25m/100m CPU, 32Mi/64Mi mem` · `sm=50m/200m CPU, 64Mi/128Mi mem` · `md=100m/500m CPU, 128Mi/256Mi mem` · `lg=250m/1000m CPU, 256Mi/512Mi mem`. |
| `host` | no | — | Hostname for the Ingress. If omitted, no Ingress is created. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer. `local-lab-ca-issuer` for internal `.local.lab` hostnames; `letsencrypt-prod` for public internet hosts. Ignored when `tlsSecret` is set. |
| `tlsSecret` | no | — | Name of a pre-existing TLS Secret in the app namespace. When set, the Ingress references it directly and cert-manager issuance is skipped. Used by sandbox slots to reuse long-lived demo certs. |
| `readinessCheckPath` | no | `/healthz` | HTTP path the readiness probe hits. Set to `/readyz` for apps that gate readiness on external dependencies. |
| `cache.enabled` | no | `false` | Provision a cache cluster owned by this Api. |
| `cache.backend` | no | `private-cloud` | `private-cloud`=in-cluster Redis, `public-cloud`=AWS ElastiCache. |
| `objectStorageRefs` | no | — | Array of references to existing `ObjectStorage` instances. Each creates an IAM Role, RolesAnywhere Profile, and binding Secret. |
| `sqlRef.name` | no | — | Name of an existing `Sql` instance to bind. |
| `sqlRef.backend` | no | `private-cloud` | Must match the `Sql` instance's backend. When `public-cloud`, the sidecar exchanges the SVID for STS credentials for RDS IAM DB auth. |
| `nosqlRef.name` | no | — | Name of an existing `NoSql` instance to bind. Creates an IAM Role, RolesAnywhere Profile, and binding Secret. |
| `secretRef.name` | no | — | Name of a pre-existing Secret to inject into the container via `envFrom`. |
| `topicRef.name` | no | — | Name of an `Topic` this API publishes to. Injects `NATS_URL` and `NATS_STREAM` env vars. |
| `topicRef.streamName` | no | — | NATS stream name from the Topic's `spec.parameters.streamName`. Defaults to `topicRef.name` uppercased. Set explicitly when the Topic's streamName differs from its metadata.name. |
| `subscriptionRef.name` | no | — | Name of an `Subscription` this API consumes from. Injects `NATS_URL` and `NATS_CONSUMER` env vars. |
| `connectionPosture` | no | `off` | `off` = this API may call anything it can reach, and anything may call it. `enforce` = only declared calls work — everything else is refused. |
| `provides` | no | — | Interfaces this API exposes, and which apps may call each one. Required to accept any call once `connectionPosture` is `enforce`. Each entry requires `name` and `allowedCallers`; each caller requires `namespace` and `app`. |
| `provides[].methods` | no | — | HTTP methods this interface accepts. Omit to accept all. |
| `provides[].paths` | no | — | Path prefixes this interface covers. Omit to cover the whole API. |
| `consumes` | no | — | Destinations this API calls that nothing else already states: off-platform hostnames, and apps in another namespace. Only read when `connectionPosture` is `enforce`. Entries take `host`, and optionally `port`, `protocol`, `app`, `namespace`. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Api
metadata:
  name: foo
spec:
  parameters:
    namespace: foo
    image: ghcr.io/owner/foo:main
    port: 8080
    host: foo.local.lab
    objectStorageRefs:
      - name: foo-assets
    sqlRef:
      name: foo-db
      backend: private-cloud
    nosqlRef:
      name: foo-nosql
    cache:
      enabled: true
      backend: private-cloud   # private-cloud=in-cluster Redis, public-cloud=AWS ElastiCache
    connectionPosture: enforce
    provides:
      - name: bar
        allowedCallers:
          - { namespace: foo, app: baz }
    consumes:
      - { host: api.example.com }
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Binding secrets

The platform mounts servicebinding.io-compliant Secrets at `/bindings/<binding>/`. Each file in that directory is one key. The app reads file contents at runtime.

### `/bindings/object-storage/` (first ref) · `/bindings/object-storage-1/` (second) · etc.

Multiple `objectStorageRefs` each get their own mount. The first ref mounts at `/bindings/object-storage/`; subsequent refs mount at `/bindings/object-storage-1/`, `/bindings/object-storage-2/`, and so on.

| File | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name (`platform-{namespace}-{ref-name}`) |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this bucket, this pod's SPIFFE ID) |
| `profile-arn` | RolesAnywhere profile ARN |

The composition injects one `AWS_PROFILE_*` env var per object storage ref into the app container, named after the ref: `AWS_PROFILE_{REF_NAME_UPPER_SNAKE_CASE}`. For example, a ref named `foo-assets` gets `AWS_PROFILE_FOO_ASSETS=object-storage`.

```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_FOO_ASSETS")))
s3Client := s3.NewFromConfig(cfg)
```

### `/bindings/sql/`

| File | Value | Backend |
|---|---|---|
| `type` | `postgresql` | all |
| `provider` | `in-cluster` or `aws` | all |
| `host` | Postgres hostname | all |
| `port` | `5432` | all |
| `database` | Database name — the Sql name as-is (`private-cloud`) or with dashes replaced by underscores (`public-cloud`) | all |
| `username` | Database user (`app`) | all |
| `password` | Database password | `private-cloud` only |
| `role-arn` | IAM role ARN | `public-cloud` only |
| `profile-arn` | RolesAnywhere profile ARN | `public-cloud` only |

For `public-cloud`, the sidecar writes a `sql` named profile to the credentials file and the composition injects `AWS_PROFILE_SQL=sql`. The app uses that profile's STS credentials to call `rds:GenerateDBAuthToken` and uses the resulting short-lived token as the database password.

### `/bindings/nosql/`

| File | Value |
|---|---|
| `type` | `dynamodb` |
| `provider` | `aws` |
| `table-name` | DynamoDB table name |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this table, this pod's SPIFFE ID) |
| `profile-arn` | RolesAnywhere profile ARN |

The composition injects `AWS_PROFILE_NOSQL=nosql` into the app container.

```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_NOSQL")))
ddbClient := dynamodb.NewFromConfig(cfg)
```

### `/bindings/cache/`

| File | Value | Backend |
|---|---|---|
| `type` | `redis` | all |
| `provider` | `in-cluster` or `aws` | all |
| `host` | Cache endpoint hostname | all |
| `port` | `6379` | all |
| `role-arn` | IAM role ARN | `public-cloud` only |
| `profile-arn` | RolesAnywhere profile ARN | `public-cloud` only |

For `public-cloud`, the sidecar writes a `cache` named profile to the credentials file and the composition injects `AWS_PROFILE_CACHE=cache`. The app uses those credentials to authenticate to ElastiCache via IAM auth.

## AWS credential injection

When any AWS cloud binding is declared, the composition adds:
- An `aws-credentials-sidecar` container running [`aws-spiffe-helper`](https://github.com/cujarrett/aws-spiffe-helper). It fetches the pod's SVID from the SPIFFE CSI volume and exchanges it for STS credentials (once per binding, every 50 minutes).
- A `spiffe-bundle` CSI volume (read-only SPIRE agent socket).
- An `aws-credentials` emptyDir volume shared between the sidecar and the app container, mounted at `/aws-credentials/credentials`.
- `AWS_SHARED_CREDENTIALS_FILE=/aws-credentials/credentials` env var in the app container.
- `AWS_PROFILE_*` env vars for every AWS binding: `AWS_PROFILE_{REF_NAME_UPPER_SNAKE_CASE}` per object storage ref, `AWS_PROFILE_NOSQL`, `AWS_PROFILE_SQL` (public-cloud sql), and `AWS_PROFILE_CACHE` (public-cloud cache).

The `TRUST_ANCHOR_ARN` is injected into the sidecar from the `aws-platform-config` EnvironmentConfig — it never appears in user-visible binding Secrets.

For the full workload identity design: [Platform Workload Identity](../../docs/platform-workload-identity.md)

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get api foo

# Detailed conditions — shows exactly WHY something is not ready
kubectl get api foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status — init containers block startup until each binding Secret is ready
kubectl get pods -n foo

# Binding secret — confirm all keys are present
# Object storage secrets are named <api-name>-<ref-name>; nosql is <api-name>-nosql
kubectl get secret foo-foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Hit the Ingress
curl https://foo.local.lab/healthz
```
