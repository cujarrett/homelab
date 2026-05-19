# XSpa

Crossplane composition that hosts an Angular (or any static) SPA on nginx.

## What it provisions
- **ConfigMap** — nginx config with SPA routing (`try_files` → `index.html`), security headers, asset caching, and a health check endpoint
- **Deployment** — nginx container running the pre-built SPA image
- **Service** — ClusterIP on port 80
- **Ingress** — Traefik `websecure` entrypoint with cert-manager TLS

The namespace is owned by the tenant — created by `namespace.yaml` in the tenant directory, not by this composition.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Tenant namespace to deploy into. Must already exist. |
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
| `apiProxy.enabled` | no | `false` | Proxy `/api/` to an in-cluster service (keeps API off the public internet). |
| `apiProxy.upstream` | no | — | FQDN of the upstream service (e.g. `my-api.my-tenant.svc.cluster.local`). |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSpa
metadata:
  name: foo
spec:
  parameters:
    namespace: foo
    image: ghcr.io/owner/foo:sha-abc123
    host: foo.local.lab
```

Instance files live in [`workspaces/`](../../homelab-workspaces/).

## App repo contract

App repos ship a static build into `nginx:alpine`. **Do not add an `nginx.conf` to the app repo or `COPY` one in the Dockerfile.** The composition mounts its ConfigMap directly over `/etc/nginx/conf.d/default.conf` at runtime, overwriting anything baked into the image. Security headers, probe blocking, caching rules, and the API proxy are all owned here.

A correct app Dockerfile looks like:

```dockerfile
FROM node:24-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist/foo/browser /usr/share/nginx/html
EXPOSE 80
```

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xspa foo

# Detailed conditions
kubectl get xspa foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status
kubectl get pods -n foo

# Hit the Ingress
curl https://foo.local.lab/healthz
```
