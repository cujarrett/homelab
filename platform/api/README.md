# XApi

Crossplane composition that deploys an API server (Go, Node, GraphQL, etc.) with optional object storage and cache resources.

## What it provisions
- **Namespace** — isolated per app
- **Deployment** — runs the API server, scales horizontally
- **Service** — ClusterIP on port 80 → container port (default 8080)
- **Object Storage** *(optional)* — connection details injected at `/bindings/object-storage`
- **Cache** *(optional)* — connection details injected at `/bindings/cache`
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
