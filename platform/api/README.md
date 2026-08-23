# Api

Crossplane composition that deploys an API server (Go, Node, GraphQL, etc.) with optional bindings to platform data resources.

## What it provisions
- **Deployment** - runs the API server with init containers that block startup until each binding is ready
- **Service** - ClusterIP on port 80 → container port (default 8080); separate metrics port (default 9090)
- **ServiceAccount** - dedicated per-instance SA; pods do not use the namespace default SA
- **Role + RoleBinding** - least-privilege RBAC: `get` only on the exact Secrets this instance mounts
- **ServiceMonitor** - Prometheus scrape target on the metrics port
- **Ingress** *(optional)* - Traefik `websecure` with TLS; only created when `host` is set. cert-manager issues a certificate via `tlsIssuer` unless `tlsSecret` points to a pre-existing Secret, in which case issuance is skipped.
- **Cache** *(optional)* - short-lived cache cluster owned by this Api; created and deleted alongside it
- **Connection policy** - always. Refuses any call this API makes to a destination it has not declared, and any inbound call whose workload identity is not named in `provides`. Metrics scraping and, when `host` is set, ingress traffic stay reachable - neither carries a workload identity to match on. See [Platform Connections](../docs/connections.md).
- **Entra identity** *(optional)* - only when an interface sets `auth: workload` or `auth: user`, or this API consumes another app. See [App Configuration](../docs/app-configuration.md).

`ObjectStorage`, `Sql`, and `NoSql` are created independently and bound via refs. They outlive any one Api. For `ObjectStorage` and `NoSql`, this composition creates the IAM Role and binding Secret when the ref is declared - their binding secrets only contain names, region, and ARNs, which Api can compute. For `Sql`, those are created by the Sql composition itself, because its binding secret contains RDS connection details (host, port, username) that are only known after RDS provisioning. The tenant lists consuming Api names in `consumerServiceAccounts` on the Sql - each gets its own IAM role and binding secret scoped to its SA.

The namespace is owned by the tenant - created by `namespace.yaml` in the tenant directory, not by this composition.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `image` | yes | - | Container image (`ghcr.io/owner/api:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `repo` | no | - | GitHub repository URL for this app's source code. |
| `port` | no | `8080` | Port the container listens on. Service always exposes port 80 → this targetPort. |
| `metricsPort` | no | `9090` | Port the container exposes Prometheus metrics on. Set to match `port` if the app serves metrics and traffic on the same port. |
| `scrapeInterval` | no | `60s` | Prometheus scrape interval. Reduce for apps that emit short-lived state changes. |
| `replicas` | no | `1` | Number of API replicas. |
| `size` | no | `sm` | Compute tier: `xs=25m/100m CPU, 32Mi/64Mi mem` · `sm=50m/200m CPU, 64Mi/128Mi mem` · `md=100m/500m CPU, 128Mi/256Mi mem` · `lg=250m/1000m CPU, 256Mi/512Mi mem`. |
| `host` | no | - | Hostname for the Ingress. If omitted, no Ingress is created. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer. `local-lab-ca-issuer` for internal `.local.lab` hostnames; `letsencrypt-prod` for public internet hosts. Ignored when `tlsSecret` is set. |
| `tlsSecret` | no | - | Name of a pre-existing TLS Secret in the app namespace. When set, the Ingress references it directly and cert-manager issuance is skipped. Used by sandbox slots to reuse long-lived demo certs. |
| `readinessCheckPath` | no | `/healthz` | HTTP path the readiness probe hits. Set to `/readyz` for apps that gate readiness on external dependencies. |
| `cache.enabled` | no | `false` | Provision a cache cluster owned by this Api. |
| `cache.backend` | no | `private-cloud` | `private-cloud`=in-cluster Redis, `public-cloud`=AWS ElastiCache. |
| `objectStorageRefs` | no | - | Array of references to existing `ObjectStorage` instances. Each creates an IAM Role and binding Secret. |
| `sqlRef.name` | no | - | Name of an existing `Sql` instance to bind. |
| `sqlRef.backend` | no | `private-cloud` | Must match the `Sql` instance's backend. When `public-cloud`, the sidecar exchanges the SVID for STS credentials for RDS IAM DB auth. |
| `nosqlRef.name` | no | - | Name of an existing `NoSql` instance to bind. Creates an IAM Role and binding Secret. |
| `configFrom` | no | - | ConfigMaps in this namespace, mounted as environment in order. The team owns each, so changing a value never re-reconciles this Api. |
| `secretsFrom` | no | - | Secrets in this namespace, mounted as environment in order. Hand-create one, or declare a `Secret` XR that fills it. A list, so two vendors' credentials can have separate lifecycles. |
| `topicRef.name` | no | - | Name of an `Topic` this API publishes to. Injects `NATS_URL` and `NATS_STREAM` env vars. |
| `topicRef.streamName` | no | - | NATS stream name from the Topic's `spec.parameters.streamName`. Defaults to `topicRef.name` uppercased. Set explicitly when the Topic's streamName differs from its metadata.name. |
| `subscriptionRef.name` | no | - | Name of an `Subscription` this API consumes from. Injects `NATS_URL` and `NATS_CONSUMER` env vars. |
| `provides` | no | - | Interfaces this API exposes, and which apps may call each one. Required to accept any call at all. Each entry requires `name` and `allowedCallers`; each caller requires `namespace` and `app`. |
| `provides[].auth` | yes | - | What a caller must prove. `mesh` = its workload identity is enough, no token, no Entra object. Required rather than defaulted, so every interface states it. `workload` = it must also carry an Entra app role, read from the `roles` claim. `user` = it must carry a delegated scope, read from `scp`, which is what on-behalf-of produces. |
| `provides[].methods` | no | - | HTTP methods this interface accepts. Omit to accept all. |
| `provides[].paths` | no | - | Path prefixes this interface covers. Omit to cover the whole API. |
| `consumes` | no | - | Every destination this API calls, including apps in its own namespace. A `Cache` this API creates itself is allowed automatically - do not list it. Each entry sets exactly one of `host` (off-platform DNS name), `address` (a bare IPv4 with no DNS name, such as a device on the LAN), `app` plus `namespace` (on-platform), or `entraApp` (a registration the platform does not own, carrying `appIdUri`, `role`, and `host`). `port` and `protocol` apply to `host` and `address`. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Api
metadata:
  name: foo
  namespace: foo
spec:
  parameters:
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
    provides:
      - name: bar
        allowedCallers:
          - { namespace: foo, app: baz }
    consumes:
      - { host: api.example.com }
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Being called through a Spa

A [`Spa`](../spa/) can proxy a path prefix to this API, so the browser only ever talks to the SPA's hostname. The Spa declares it with `apiProxies` - a path and this API's in-cluster address - and nothing is set here. Four things follow for this API:

- **No `host` needed.** Skip it and the API gets no Ingress, no public hostname, and no certificate. It stays reachable only inside the cluster. Setting `host` anyway leaves it reachable from the ingress controller regardless of `provides`.
- **The prefix is stripped.** A browser request to `/api/baz` arrives here as `/baz`. Route on the bare path.
- **Still gated.** Being proxied grants nothing. Under `enforce`, `provides.allowedCallers` must name the Spa or the call is refused with a 403.
- **Client details move to headers.** The connecting peer is the Spa, so read `X-Forwarded-For` for the client address, `X-Forwarded-Host` for the hostname the browser used, and `X-Forwarded-Proto` for the scheme.

Streaming responses work unchanged - the proxy is configured for Server-Sent Events, with buffering off and a long read timeout.

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
| `database` | Database name - the Sql name as-is (`private-cloud`) or with dashes replaced by underscores (`public-cloud`) | all |
| `username` | Database user (`app`) | all |
| `password` | Database password | `private-cloud` only |
| `role-arn` | IAM role ARN | `public-cloud` only |

For `public-cloud`, the sidecar writes a `sql` named profile to the credentials file and the composition injects `AWS_PROFILE_SQL=sql`. The app uses that profile's STS credentials to call `rds:GenerateDBAuthToken` and uses the resulting short-lived token as the database password.

### `/bindings/nosql/`

| File | Value |
|---|---|
| `type` | `dynamodb` |
| `provider` | `aws` |
| `table-name` | DynamoDB table name |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this table, this pod's SPIFFE ID) |

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

For `public-cloud`, the sidecar writes a `cache` named profile to the credentials file and the composition injects `AWS_PROFILE_CACHE=cache`. The app uses those credentials to authenticate to ElastiCache via IAM auth.

## Workload identity credential injection

When any AWS cloud binding is declared, or this Api needs an Entra identity, the composition adds a `workload-identity-sidecar` container running [`workload-identity-sidecar`](https://github.com/cujarrett/workload-identity-sidecar) and a `spiffe-bundle` CSI volume (read-only SPIRE agent socket). What else gets added depends on which is enabled - an Api can declare both, and both run independently in the same sidecar.

**AWS** (any `objectStorageRefs`, `nosqlRef`, or `public-cloud` `sqlRef` cache):
- The sidecar exchanges the pod's SVID for STS credentials, once per binding, every 50 minutes.
- An `aws-credentials` emptyDir volume shared between the sidecar and the app container, mounted at `/aws-credentials/credentials`.
- `AWS_SHARED_CREDENTIALS_FILE=/aws-credentials/credentials` env var in the app container.
- `AWS_PROFILE_*` env vars for every AWS binding: `AWS_PROFILE_{REF_NAME_UPPER_SNAKE_CASE}` per object storage ref, `AWS_PROFILE_NOSQL`, `AWS_PROFILE_SQL` (public-cloud sql), and `AWS_PROFILE_CACHE` (public-cloud cache).

**Entra** (an interface sets `auth: workload` or `auth: user`, or this Api consumes another app):
- The sidecar keeps a raw SPIFFE SVID fresh in an `entra-identity` emptyDir volume, mounted at `/entra-identity/token` - it does not exchange this token itself.
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE=/entra-identity/token` env vars in the app container. The app's own Azure SDK (`WorkloadIdentityCredential`) reads these and does the exchange on demand - the same contract Azure Kubernetes Service (AKS) uses natively.
- Egress to `login.microsoftonline.com`, since that is where the exchange happens. Needing an identity is what registers it, so it never goes in `consumes`.
- A stable identifier, `api://<tenant-id>/platform-<namespace>-<name>`, so a caller can name this Api as an audience without looking up the client ID Entra generated for it. The tenant ID is required by Entra's default tenant policy, not decoration. A v2 token still arrives audienced to the client ID, which the Api already has as `AZURE_CLIENT_ID`.
- Tokens issued at v2, so their issuer is `login.microsoftonline.com/<tenant>/v2.0` rather than the v1 `sts.windows.net`.

For each interface with `auth: workload` the composition creates an app role and one assignment per allowed caller; `auth: user` creates a delegated scope and a permission grant instead. Validating the token and checking the claim are both the app's job - see [App Configuration → Entra](../docs/app-configuration.md#entra).

For the full workload identity design: [Platform Workload Identity](../docs/workload-identity.md)

## Operations

```bash
# XR status - SYNCED=composition ran, READY=all children healthy
kubectl get api foo -n foo

# Detailed conditions - shows exactly WHY something is not ready
kubectl get api foo -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status - init containers block startup until each binding Secret is ready
kubectl get pods -n foo

# Binding secret - confirm all keys are present
# Object storage secrets are named <api-name>-<ref-name>; nosql is <api-name>-nosql
kubectl get secret foo-foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Hit the Ingress
curl https://foo.local.lab/healthz
```
