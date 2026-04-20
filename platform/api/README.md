# XApi

Crossplane composition that deploys an API server (Go, Node, GraphQL, etc.) with optional object storage and cache resources.

## What it provisions
- **Namespace** — isolated per app
- **Deployment** — runs the API server with conditional init containers that block startup until bindings are ready
- **Service** — ClusterIP on port 80 → container port (default 8080)
- **XObjectStorage** *(optional)* — platform primitive that provisions object storage and injects credentials at `/bindings/object-storage`
- **XCache** *(optional)* — platform primitive that provisions a cache cluster and injects credentials at `/bindings/cache`
- **ArgoCD Application** — self-managing ArgoCD app that syncs the XR instance file from Git

Secrets are mounted via the [servicebinding.io](https://servicebinding.io) convention — each binding is a directory under `$SERVICE_BINDING_ROOT` with files for each key/value pair.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace to deploy into |
| `image` | yes | — | Container image (`ghcr.io/owner/api:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `port` | no | `8080` | Port the container listens on. Service always exposes port 80 → this targetPort. |
| `objectStorage.enabled` | no | `false` | Provision an object storage bucket and inject credentials |
| `cache.enabled` | no | `false` | Provision a cache cluster and inject credentials |
| `argocd.repoURL` | yes | — | Git repository URL (e.g. `https://github.com/owner/repo.git`) |
| `argocd.targetRevision` | no | `main` | Git branch, tag, or commit SHA to sync from |
| `argocd.xrsPath` | no | `platform/xrs/api` | Path in the repo to the XR instance files directory |

## Example app

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XApi
metadata:
  name: my-api
  namespace: my-api
spec:
  namespace: my-api
  image: ghcr.io/owner/my-api:sha-abc123
  port: 8080
  objectStorage:
    enabled: false
  cache:
    enabled: false
  argocd:
    repoURL: https://github.com/owner/homelab.git
    targetRevision: main
    xrsPath: platform/xrs/api
```

Instance files live in [`platform/xrs/api/`](../xrs/api/).

## Service binding keys

When optional integrations are enabled, Crossplane creates a Secret and mounts it into the container at `$SERVICE_BINDING_ROOT/<binding>/`. Each file in that directory is one key. The app reads the file contents at runtime.

Per the [servicebinding.io spec](https://servicebinding.io/spec/core/1.1.0/), each binding MUST contain a `type` file that identifies the **abstract protocol classification** (what client to use), and SHOULD contain a `provider` file that identifies the implementation. Well-known key names (`host`, `port`, `uri`, `username`, `password`) have spec-defined meanings and MUST be used when the value matches.

### `/bindings/object-storage/`

| File | Spec status | Value |
|---|---|---|
| `type` | MUST | `s3` — signals an S3-compatible client |
| `provider` | SHOULD | Implementation-defined (e.g., `aws`) |
| `uri` | well-known | Storage endpoint URL |
| `region` | non-standard | Region string |
| `bucket` | non-standard | Bucket name |
| `username` | well-known | Access key ID |
| `password` | well-known | Secret access key |

### `/bindings/cache/`

| File | Spec status | Value |
|---|---|---|
| `type` | MUST | `redis` — signals a Redis-compatible client |
| `provider` | SHOULD | Implementation-defined (e.g., `aws`) |
| `host` | well-known | Cache endpoint hostname |
| `port` | well-known | Cache port (default `6379`) |
| `username` | well-known | Auth username (if enabled) |
| `password` | well-known | Auth password (if enabled) |

> The exact keys written depend on what the backing provider includes in the connection Secret. Verify with `kubectl get secret <xr-name>-cache -n <namespace> -o yaml` after provisioning.

## Prerequisites

The underlying cloud providers must be installed and credentials must be available in the cluster before any XApi XR with `objectStorage.enabled: true` or `cache.enabled: true` will reconcile successfully.

