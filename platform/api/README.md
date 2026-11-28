# Api

Runs an API server, such as Go, Node or GraphQL. It binds to data resources and declares who it calls and who may call it.

## What it provisions

| Resource | When | What |
|---|---|---|
| Workload | always | The API server, under its own service account. Startup waits for every binding. The container runs as user 65532 on a read-only filesystem, and only `/tmp` is writable. |
| Service | always | Port 80 to the container `port`. Metrics on `metricsPort`, scraped by Prometheus. |
| Route | `host` is set | HTTPS on `host`. A public host allows 60 requests a minute on average, burst of 20, per client IP. Every response carries `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` and `X-Frame-Options: DENY`, so a browser renders no page from this host. |
| Cache | `cache.enabled` is true | Created and deleted with this Api. |
| Connection policy | always | Lets through only declared traffic. See [Platform Connections](../docs/connections.md). |
| Entra identity | an interface sets `auth: workload` or `auth: user`, this API consumes another app, or it sets a `private-cloud` `workflowSpaceRef` | An Entra identity for this Api. See [App Configuration](../docs/app-configuration.md). |

The connection policy works like this.

- **Outbound:** only destinations in `consumes`.
- **Inbound:** only workloads named in `provides`.
- **Metrics scraping and ingress on `host`:** stay open, since they carry no workload identity.

`ObjectStorage`, `Sql` and `NoSql` live on their own and bind by ref. A `public-cloud` `Sql` must also list each consuming Api in its `consumerServiceAccounts`. The tenant's `namespace.yaml` creates the namespace.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `image` | yes | - | Container image, such as `ghcr.io/cujarrett/api:sha-abc123`. CI commits a new tag on each merge to main. |
| `repo` | no | - | GitHub URL of the app's source. |
| `port` | no | `8080` | Port the container listens on. The Service exposes it on 80. |
| `metricsPort` | no | `9090` | Prometheus metrics port. Set it to `port` if one port serves both. |
| `scrapeInterval` | no | `60s` | Metrics scrape interval. Lower it for short-lived state changes. |
| `replicas` | no | `1` | Number of replicas. |
| `size` | no | `sm` | Compute tier: `xs=25m/100m CPU, 32Mi/64Mi mem` · `sm=50m/200m CPU, 64Mi/128Mi mem` · `md=100m/500m CPU, 128Mi/256Mi mem` · `lg=250m/1000m CPU, 256Mi/512Mi mem`. |
| `host` | no | - | Hostname clients call, under `local.lab` (homelab network) or `mattjarrett.dev` (internet). No route without it. A new public name needs the platform team to add it before it resolves. |
| `callsClusterApi` | no | `false` | Set when this API calls the cluster's own control API, such as to watch platform resources. Keeps those long-lived connections direct. |
| `readinessCheckPath` | no | `/healthz` | Readiness probe path. Use `/readyz` if readiness depends on outside services. |
| `cache.enabled` | no | `false` | Create a cache owned by this Api. |
| `cache.backend` | no | `private-cloud` | `private-cloud`=in-cluster Redis, `public-cloud`=AWS ElastiCache. |
| `objectStorageRefs` | no | - | List of `ObjectStorage` instances to bind. |
| `sqlRef.name` | no | - | `Sql` instance to bind. |
| `sqlRef.backend` | no | `private-cloud` | Must match the `Sql` backend. `public-cloud` signs in to the database with AWS credentials. |
| `nosqlRef.name` | no | - | `NoSql` instance to bind. |
| `configFrom` | no | - | ConfigMaps in this namespace, loaded as env vars in order. Later entries win. |
| `managedSecretRefs` | no | - | List of `ManagedSecret` instances. Each lands at `/secrets/<ref-name>/<key>`. |
| `topicRef.name` | no | - | `Topic` this API publishes to. Injects `NATS_URL` and `NATS_STREAM`. |
| `topicRef.streamName` | no | - | The Topic's `streamName`. Defaults to `topicRef.name` uppercased. Set it when they differ. |
| `subscriptionRef.name` | no | - | `Subscription` this API consumes from. Injects `NATS_URL` and `NATS_CONSUMER`. |
| `workflowSpaceRef.name` | no | - | `WorkflowSpace` in this namespace. Grants access and injects `TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE` and `TEMPORAL_TOKEN_SCOPE`. See [WorkflowSpace](../workflow-space/README.md). |
| `workflowSpaceRef.backend` | no | `private-cloud` | Must match the `WorkflowSpace` backend. `public-cloud` injects `TEMPORAL_TLS_CERT` and `TEMPORAL_TLS_KEY` instead of `TEMPORAL_TOKEN_SCOPE`. See [WorkflowSpace → public-cloud](../workflow-space/README.md#public-cloud). |
| `provides` | no | - | Interfaces this API exposes and who may call each. Without it, no call gets in. Each entry needs `name`, `auth` and `allowedCallers`. Each caller needs `namespace` and `app`. |
| `provides[].auth` | yes | - | What a caller must prove. `mesh`: workload identity alone, no token. `workload`: an Entra app role in the `roles` claim. `user`: a delegated scope in `scp`, as on-behalf-of produces. |
| `consumes` | no | - | Every destination this API calls, including its own namespace. Its own `Cache` is allowed automatically. Each entry sets exactly one of `host` (off-platform DNS name), `address` (bare IPv4, such as a LAN device), `app` plus `namespace` (on-platform), or `entraApp` (an outside registration, with `appIdUri`, `role` and `host`). `port` and `protocol` apply to `host` and `address`. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Api
metadata:
  name: foo
  namespace: foo
spec:
  parameters:
    image: ghcr.io/cujarrett/foo:main
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
        auth: mesh
        allowedCallers:
          - { namespace: foo, app: baz }
    consumes:
      - { host: api.example.com }
```

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).

## Being called through a Spa

A [`Spa`](../spa/) can forward a path prefix to this API with `apiProxies`. The browser then only talks to the SPA's hostname. Nothing is set here.

- **No `host` needed.** The API stays inside the cluster. A `host` lets ingress in regardless of `provides`.
- **The prefix is stripped.** `/api/baz` arrives as `/baz`.
- **Still gated.** `provides.allowedCallers` must name the Spa, or the call gets a 403.
- **Client details are in headers.** `X-Forwarded-For` is the client address, `X-Forwarded-Host` the browser's hostname, `X-Forwarded-Proto` the scheme.
- **Server-Sent Events work.** Buffering is off and the read timeout is long.

## Configuration

Pick by whether the value changes while the pod runs.

- **`configFrom`:** for values that never rotate. Each ConfigMap key becomes an env var. List a shared base first and overrides after.
- **`managedSecretRefs`:** for values that rotate. Files at `/secrets/<name>/<key>` update without a restart. Read the file on each use, or the value goes stale.

```yaml
configFrom: [foo-base, foo-overrides]   # foo-overrides wins on any shared key
```

### What the platform injects

| Variable | Value |
|---|---|
| `AWS_PROFILE_<KIND>_<REF>` | One per AWS binding. See [Workload identity credential injection](#workload-identity-credential-injection). |
| `ENTRA_SCOPE_<APP>` | The token scope for each `app` in `consumes`. An `entraApp` entry uses `ENTRA_SCOPE_<ROLE>`. |

Names are uppercased, with `-` and `.` becoming `_`.

The running pod spec lists every variable and mounted path.

```bash
kubectl get deploy <app> -n <namespace> -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}'
kubectl get deploy <app> -n <namespace> -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.mountPath}{"\n"}{end}'
```

## Binding secrets

Each binding mounts at `/bindings/<binding>/`, one file per key. A ref named `foo-assets` mounts at `/bindings/object-storage-foo-assets/`.

| File | `object-storage-<ref>/` | `sql/` | `nosql/` | `cache/` |
|---|---|---|---|---|
| `type` | `s3` | `postgresql` | `dynamodb` | `redis` |
| `provider` | `aws` | `in-cluster` or `aws` | `aws` | `in-cluster` or `aws` |
| `host` | - | Postgres hostname | - | Cache endpoint hostname |
| `port` | - | `5432` | - | `6379` |
| `database` | - | The Sql name. On `public-cloud`, dashes become underscores. | - | - |
| `username` | - | `app` | - | - |
| `password` | - | `private-cloud` only | - | - |
| `bucket` | `platform-{namespace}-{ref-name}` | - | - | - |
| `table-name` | - | - | DynamoDB table name | - |
| `region` | `us-east-1` | - | `us-east-1` | - |
| `role-arn` | IAM role ARN for this bucket and pod | `public-cloud` only | IAM role ARN for this table and pod | `public-cloud` only |

A `role-arn` binding gives the app an AWS profile instead of a password.

| Binding | How the app signs in |
|---|---|
| ObjectStorage, NoSql | Use the profile with the standard AWS SDK. |
| Sql | Call `rds:GenerateDBAuthToken` with the profile. The short-lived token is the database password. |
| Cache | Sign in to ElastiCache with IAM auth. |

## Workload identity credential injection

The [`workload-identity-sidecar`](https://github.com/cujarrett/workload-identity-sidecar) joins the pod when this Api has an AWS binding or needs an Entra identity. It reads the SPIRE agent socket through the `spiffe-bundle` volume.

**AWS**, for `objectStorageRefs`, `nosqlRef`, `managedSecretRefs`, or a `public-cloud` `sqlRef` or cache:

| Item | Detail |
|---|---|
| Exchange | The sidecar trades the pod's SVID for STS credentials per binding, every 50 minutes. |
| `AWS_SHARED_CREDENTIALS_FILE` | `/aws-credentials/credentials`, shared with the app. |
| `AWS_PROFILE_<KIND>_<REF>` | One per binding, uppercased with `-` becoming `_`. Cache uses `AWS_PROFILE_CACHE`. |
| `managedSecretRefs` | No profile. The sidecar writes the value to `/secrets/<ref-name>/<key>`. |

**Entra**, when an interface sets `auth: workload` or `auth: user`, this Api consumes another app, or it sets a `private-cloud` `workflowSpaceRef`:

| Item | Detail |
|---|---|
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE=/entra-identity/token` | The Azure SDK's `WorkloadIdentityCredential` reads these and exchanges on demand, as on AKS. The sidecar keeps the token file fresh. |
| Egress | `login.microsoftonline.com` opens automatically. Never list it in `consumes`. |
| Audience | `api://<tenant-id>/platform-<namespace>-<name>`, so callers need no client ID lookup. A v2 token still carries `AZURE_CLIENT_ID` as its audience. |
| Issuer | `login.microsoftonline.com/<tenant>/v2.0`. |

`auth: workload` creates an app role per interface, assigned to each allowed caller. `auth: user` creates a delegated scope and grant. The app validates the token and the claim. See [App Configuration → Entra](../docs/app-configuration.md#entra).

Full design: [Platform Workload Identity](../docs/workload-identity.md).

## Operations

```bash
# XR status. SYNCED=composition ran, READY=all children healthy
kubectl get apis.platform.local.lab foo -n foo

# Detailed conditions, showing why something is not ready
kubectl get apis.platform.local.lab foo -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status. Init containers block startup until each binding Secret is ready
kubectl get pods -n foo

# Binding secret, to confirm every key is present
# Object storage secrets are named <api-name>-<ref-name>; nosql is <api-name>-nosql
kubectl get secret foo-foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Hit the route
curl https://foo.local.lab/healthz
```
