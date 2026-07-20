# Spa

Crossplane composition that hosts an Angular (or any static) SPA on nginx.

## What it provisions
- **ConfigMap** — nginx config with SPA routing (`try_files` → `index.html`), security headers, asset caching, probe path, and extensive scanner/credential-probe blocking rules
- **Deployment** — nginx container running the pre-built SPA image
- **Service** — ClusterIP on port 80
- **Middleware** — Traefik rate limiter: 60 requests/min average, burst of 20, keyed per client IP (`CF-Connecting-IP` header)
- **Ingress** — Traefik `websecure` entrypoint with cert-manager TLS; rate limit middleware applied

The namespace is owned by the tenant — created by `namespace.yaml` in the tenant directory, not by this composition.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Tenant namespace to deploy into. Must already exist. |
| `image` | yes | — | Container image (`ghcr.io/owner/app:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `host` | yes | — | Ingress hostname (e.g. `myapp.local.lab` or `myapp.example.com`) |
| `repo` | no | — | GitHub repository URL for this app's source code. |
| `size` | no | `sm` | Compute tier for the nginx container: `xs=25m/100m CPU, 32Mi/64Mi mem` · `sm=50m/200m CPU, 64Mi/128Mi mem` · `md=100m/500m CPU, 128Mi/256Mi mem` · `lg=250m/1000m CPU, 256Mi/512Mi mem`. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer. `local-lab-ca-issuer` for internal `.local.lab` hostnames; `letsencrypt-prod` for public internet hosts. Ignored when `tlsSecret` is set. |
| `tlsSecret` | no | — | Name of a pre-existing TLS Secret in the app namespace. When set, the Ingress references it directly and cert-manager issuance is skipped. Used by sandbox slots to reuse long-lived demo certs. |
| `contentSecurityPolicy` | no | `default-src 'self'; frame-ancestors 'none'; base-uri 'self';` | CSP header value. Override with app-specific origins (Google Fonts, external APIs, etc.). |
| `replicas` | no | `1` | Number of nginx replicas. Stateless — safe to scale freely. |
| `apiProxy.enabled` | no | `false` | Proxy `/api/` to an in-cluster service (keeps the API off the public internet). |
| `apiProxy.upstream` | no | — | FQDN of the upstream service (e.g. `my-api.my-tenant.svc.cluster.local`). nginx proxies `/api/` → `http://<upstream>/`. |

The health check endpoint is always `/healthz` — not configurable. Mesh injection follows the namespace annotation; there is no per-instance mesh parameter on Spa.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Spa
metadata:
  name: foo
spec:
  parameters:
    namespace: foo
    image: ghcr.io/owner/foo:sha-abc123
    host: foo.local.lab
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

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
kubectl get spa foo

# Detailed conditions
kubectl get spa foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status
kubectl get pods -n foo

# Hit the Ingress
curl https://foo.local.lab/healthz
```
