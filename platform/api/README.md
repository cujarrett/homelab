# XApi

Crossplane composition that deploys an API server (Go, Node, GraphQL, etc.) with optional object storage and cache resources.

## What it provisions
- **Deployment** — runs the API server with conditional init containers that block startup until bindings are ready
- **Service** — ClusterIP on port 80 → container port (default 8080)
- **XObjectStorage** *(optional)* — platform primitive that provisions object storage and injects credentials at `/bindings/object-storage`
- **XCache** *(optional)* — platform primitive that provisions a cache cluster and injects credentials at `/bindings/cache`

The namespace is owned by the tenant — created by `namespace.yaml` in the tenant directory, not by this composition.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Tenant namespace to deploy into. Must already exist. |
| `image` | yes | — | Container image (`ghcr.io/owner/api:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `port` | no | `8080` | Port the container listens on. Service always exposes port 80 → this targetPort. |
| `host` | no | — | Hostname for the Ingress. If omitted, no Ingress is created. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer for TLS. |
| `environment` | no | `test` | `prod` or `test`. Controls whether optional integrations use cloud-managed or in-cluster resources. |
| `objectStorage.enabled` | no | `false` | Provision an object storage bucket and inject credentials |
| `cache.enabled` | no | `false` | Provision a cache cluster and inject credentials |
| `secretRef.name` | no | — | Name of a pre-existing Secret to inject via `envFrom`. |

The namespace is always `metadata.name` — no input required.

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
    environment: test
    objectStorage:
      enabled: true
# Deploys into namespace: foo
```

Instance files live in [`tenants/`](../../tenants/).

## Binding secrets

When optional integrations are enabled, the platform writes a servicebinding.io-compliant Secret into the namespace and mounts it at `$SERVICE_BINDING_ROOT/<binding>/`. Each file in that directory is one key. The app reads file contents at runtime — no env vars required.

### `/bindings/object-storage/`

| File | Value |
|---|---|
| `type` | `s3` |
| `provider` | implementation identifier |
| `bucket` | Bucket name |
| `region` | Region string |
| `username` | Access key ID |
| `password` | Secret access key |

### `/bindings/cache/`

| File | Value |
|---|---|
| `type` | `redis` |
| `provider` | implementation identifier |
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
kubectl get secret foo-cache -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Hit the Ingress
curl https://foo.local.lab/health
```
