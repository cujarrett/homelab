# XApi

Crossplane composition that deploys an API server (Go, Node, GraphQL, etc.) with optional bindings to platform data resources.

See also: [`XCache`](../cache/README.md) · [`XObjectStorage`](../object-storage/README.md)

## What it provisions
- **Deployment** — runs the API server with conditional init containers that block startup until bindings are ready
- **Service** — ClusterIP on port 80 → container port (default 8080)
- **XCache** *(optional)* — short-lived cache cluster owned by this XApi; created and deleted alongside it

`XObjectStorage` is created independently in the namespace and bound via a ref. It outlives any one XApi.

The namespace is owned by the tenant — created by `namespace.yaml` in the tenant directory, not by this composition.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Tenant namespace to deploy into. Must already exist. |
| `image` | yes | — | Container image (`ghcr.io/owner/api:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `port` | no | `8080` | Port the container listens on. Service always exposes port 80 → this targetPort. |
| `host` | no | — | Hostname for the Ingress. If omitted, no Ingress is created. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer for TLS. |
| `environment` | no | `cluster` | Controls `XCache` only: `cluster`=in-cluster Redis, `cloud`=AWS ElastiCache. |
| `cache.enabled` | no | `false` | Provision a cache cluster owned by this XApi and inject credentials at `/bindings/cache/`. |
| `objectStorageRef.name` | no | — | Name of an existing `XObjectStorage` instance to bind. Mounts its Secret at `/bindings/object-storage/`. |
| `secretRef.name` | no | — | Name of a pre-existing Secret to inject via `envFrom`. |
| `topicRef.name` | no | — | Name of an `XTopic` this API publishes to. Platform injects `NATS_URL` and `NATS_STREAM` env vars. |
| `subscriptionRef.name` | no | — | Name of an `XSubscription` this API consumes from. Platform injects `NATS_CONSUMER` env var. |

## Example app

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XApi
metadata:
  name: foo
spec:
  parameters:
    namespace: foo
    image: ghcr.io/owner/foo:main
    port: 8080
    host: foo.local.lab
    objectStorageRef:
      name: foo-assets
    environment: cluster   # Controls XCache only: cluster=in-cluster Redis, cloud=AWS ElastiCache
    # Cache is short-lived — owned and managed by this XApi
    cache:
      enabled: true
```

Instance files live in [`homelab-tenants/`](../../../homelab-tenants/).

## Binding secrets

The platform mounts servicebinding.io-compliant Secrets at `$SERVICE_BINDING_ROOT/<binding>/`. Each file in that directory is one key. The app reads file contents at runtime — no env vars required.

### `/bindings/object-storage/`

| File | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name |
| `region` | Region string |
| `username` | Access key ID |
| `password` | Secret access key |

### `/bindings/cache/`

| File | Value |
|---|---|
| `type` | `redis` |
| `provider` | `aws` or `in-cluster` |
| `host` | Cache endpoint hostname |
| `port` | `6379` |

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xapi foo

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xapi foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status — init container blocks startup until binding secret is ready
kubectl get pods -n foo

# Binding secret — confirm all keys are present
kubectl get secret foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Hit the Ingress
curl https://foo.local.lab/health
```
