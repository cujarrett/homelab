# XApi

Crossplane composition that deploys an API server (Go, Node, GraphQL, etc.) with optional object storage and cache resources.

## What it provisions
- **Namespace** — derived from `metadata.name` (name = namespace)
- **Deployment** — runs the API server with conditional init containers that block startup until bindings are ready
- **Service** — ClusterIP on port 80 → container port (default 8080)
- **XObjectStorage** *(optional)* — platform primitive that provisions object storage and injects credentials at `/bindings/object-storage`
- **XCache** *(optional)* — platform primitive that provisions a cache cluster and injects credentials at `/bindings/cache`

When optional integrations are enabled, the platform provisions the resource and writes a servicebinding.io-compliant Secret into the app namespace automatically. Each init container blocks app startup until its binding secret is ready — the app never starts with missing credentials.

The binding secret is mounted at `$SERVICE_BINDING_ROOT/<binding>/`. Each file in that directory is one key.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `image` | yes | — | Container image (`ghcr.io/owner/api:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `port` | no | `8080` | Port the container listens on. Service always exposes port 80 → this targetPort. |
| `host` | no | — | Hostname for the Ingress. If omitted, no Ingress is created. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer for TLS. |
| `environment` | no | `test` | `prod` or `test`. Controls whether cache uses ElastiCache or in-cluster Redis. |
| `objectStorage.enabled` | no | `false` | Provision an object storage bucket and inject credentials |
| `cache.enabled` | no | `false` | Provision a cache cluster and inject credentials |
| `secretRef.name` | no | — | Name of a pre-existing Secret to inject via `envFrom`. |

The namespace is always `metadata.name` — no input required.

## Example app

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XApi
metadata:
  name: platform-api-starter
spec:
  image: ghcr.io/cujarrett/platform-api-starter:main
  port: 8080
  host: platform-api-starter.local.lab
  environment: test
  objectStorage:
    enabled: true
# Deploys into namespace: platform-api-starter
```

## Binding secret

When optional integrations are enabled, Crossplane creates a Secret and mounts it into the container at `$SERVICE_BINDING_ROOT/<binding>/`. Each file in that directory is one key. The app reads the file contents at runtime.

Per the [servicebinding.io spec](https://servicebinding.io/spec/core/1.1.0/), each binding MUST contain a `type` file that identifies the **abstract protocol classification** (what client to use), and SHOULD contain a `provider` file that identifies the implementation. Well-known key names (`host`, `port`, `uri`, `username`, `password`) have spec-defined meanings and MUST be used when the value matches.

### `/bindings/object-storage/`

| File | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name |
| `region` | Region string |
| `username` | IAM access key ID |
| `password` | IAM secret access key |

### `/bindings/cache/`

| File | Value |
|---|---|
| `type` | `redis` |
| `provider` | `aws` (prod) or `in-cluster` (test) |
| `host` | Cache endpoint hostname |
| `port` | `6379` |

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xapi platform-api-starter
kubectl get xobjectstorage platform-api-starter-object-storage

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xapi platform-api-starter -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status — init container blocks startup until binding secret is ready
kubectl get pods -n platform-api-starter

# Binding secret — confirm all 6 keys are present with correct values
kubectl get secret platform-api-starter-object-storage -n platform-api-starter \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Hit the Ingress
curl https://platform-api-starter.local.lab/health
```

## Prerequisites

The underlying cloud providers must be installed and credentials must be available in the cluster before any XApi XR with `objectStorage.enabled: true` or `cache.enabled: true` will reconcile successfully.
