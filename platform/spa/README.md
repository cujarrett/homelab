# XSpa

Crossplane composition that hosts an Angular (or any static) SPA on nginx.

## What it provisions
- **Namespace** — isolated per app
- **ConfigMap** — nginx config with SPA routing (`try_files` → `index.html`), security headers, asset caching, and a health check endpoint
- **Deployment** — nginx container running the pre-built SPA image
- **Service** — ClusterIP on port 80
- **Ingress** — Traefik `websecure` entrypoint with cert-manager TLS
- **ArgoCD Application** — self-managing ArgoCD app that syncs the XR instance file from Git

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace to deploy into |
| `image` | yes | — | Container image (`ghcr.io/owner/app:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `host` | yes | — | Ingress hostname (e.g. `myapp.local.lab` or `myapp.example.com`) |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer. Use `letsencrypt-prod` for public hosts. |
| `imagePullSecret` | no | — | Registry pull secret name (e.g. `ghcr-pull-secret`). Omit for public images. |
| `contentSecurityPolicy` | no | `default-src 'self'; frame-ancestors 'none'; base-uri 'self';` | CSP header value. Override with app-specific origins (Google Fonts, external APIs, etc.). |
| `healthCheckPath` | no | `/healthz` | Path nginx serves for readiness probes. Returns HTTP 200. |
| `replicas` | no | `1` | Number of nginx replicas. Stateless — safe to scale freely. |
| `cpuRequest` | no | `50m` | CPU request |
| `cpuLimit` | no | `200m` | CPU limit |
| `memoryRequest` | no | `32Mi` | Memory request |
| `memoryLimit` | no | `64Mi` | Memory limit |
| `argocd.repoURL` | yes | — | Git repository URL (e.g. `https://github.com/owner/repo.git`) |
| `argocd.targetRevision` | no | `main` | Git branch, tag, or commit SHA to sync from |
| `argocd.xrsPath` | no | `platform/xrs/spa` | Path in the repo to the XR instance files directory |

## Example instance

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSpa
metadata:
  name: foo
  namespace: foo
spec:
  parameters:
    namespace: foo
    image: ghcr.io/owner/foo:sha-abc123
    host: foo.local.lab
    tlsIssuer: local-lab-ca-issuer
    argocd:
      repoURL: https://github.com/owner/homelab.git
      targetRevision: main
      xrsPath: platform/xrs/spa
```

Instance files live in [`platform/xrs/spa/`](../xrs/spa/).
