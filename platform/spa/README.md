# Spa

Crossplane composition that hosts an Angular (or any static) SPA on nginx.

Server-side and incremental static regeneration are not supported, those run a real process at request time, which nginx serving pre-built files cannot host, so Next.js and Nuxt in those modes have no offering here yet.

## What it provisions
- **ConfigMap** - nginx config with SPA routing (`try_files` → `index.html`), security headers, asset caching, probe path, and extensive scanner/credential-probe blocking rules
- **Deployment** - nginx container running the pre-built SPA image
- **Service** - ClusterIP on port 80
- **Middleware** - Traefik rate limiter: 60 requests/min average, burst of 20, keyed per client IP (`CF-Connecting-IP` header)
- **Ingress** - Traefik `websecure` entrypoint with cert-manager TLS; rate limit middleware applied
- **Connection policy** - always. Refuses any call this app makes to a destination it has not declared, and any inbound call that does not carry a workload identity the platform issued. See [Platform Connections](../docs/connections.md).

The namespace is owned by the tenant - created by `namespace.yaml` in the tenant directory, not by this composition.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `image` | yes | - | Container image (`ghcr.io/owner/app:sha-abc123`). CI builds on merge to main and commits the new tag back to trigger sync. |
| `host` | yes | - | Ingress hostname (e.g. `myapp.local.lab` or `myapp.example.com`) |
| `repo` | no | - | GitHub repository URL for this app's source code. |
| `size` | no | `sm` | Compute tier for the nginx container: `xs=25m/100m CPU, 32Mi/64Mi mem` · `sm=50m/200m CPU, 64Mi/128Mi mem` · `md=100m/500m CPU, 128Mi/256Mi mem` · `lg=250m/1000m CPU, 256Mi/512Mi mem`. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer. `local-lab-ca-issuer` for internal `.local.lab` hostnames; `letsencrypt-prod` for public internet hosts. Ignored when `tlsSecret` is set. |
| `tlsSecret` | no | - | Name of a pre-existing TLS Secret in the app namespace. When set, the Ingress references it directly and cert-manager issuance is skipped. Used by sandbox slots to reuse long-lived demo certs. |
| `contentSecurityPolicy` | no | `default-src 'self'; frame-ancestors 'none'; base-uri 'self';` | CSP header value. Override with app-specific origins (Google Fonts, external APIs, etc.). |
| `replicas` | no | `1` | Number of nginx replicas. Stateless - safe to scale freely. |
| `apiProxies` | no | - | Array of path prefixes to proxy to a backend, keeping on-platform APIs off the public internet. Each entry requires `path` and exactly one of `app` (on-platform, address derived) or `host` (off-platform, verbatim). `namespace` defaults to this SPA's own. The prefix is stripped before proxying, so set `upstreamPath` when the backend registered its routes under one. |
| `userAuth` | no | - | Sign-in for this SPA. `client` names the proxied app that completes the code exchange and holds the tokens, and there can be only one because only one backend owns the session. `scopes` lists what the signed-in user needs. `extraRedirectUris` adds a localhost callback for local development or a second domain during a migration. Tokens never reach the browser. |
| `consumes` | no | - | Every destination this app calls that `apiProxies` does not already name. Each entry sets exactly one of `host`, `address` (a bare IPv4), or `app` plus `namespace`. |

`apiProxies` doubles as a connection declaration - the composition allows those backends without you restating them in `consumes`. Nothing else is automatic: an app in the same namespace still needs a `consumes` entry, and is still gated by whatever the callee itself declares.

What this means for the API on the other end - stripped prefixes, forwarded client headers, and why it needs no hostname of its own - is in [Api → Being called through a Spa](../api/README.md#being-called-through-a-spa).

The health check endpoint is always `/healthz` - not configurable.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Spa
metadata:
  name: foo
  namespace: foo
spec:
  parameters:
    image: ghcr.io/owner/foo:sha-abc123
    host: foo.local.lab
    apiProxies:
      - path: /api/
        app: bar
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
# XR status - SYNCED=composition ran, READY=all children healthy
kubectl get spa foo -n foo

# Detailed conditions
kubectl get spa foo -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status
kubectl get pods -n foo

# Hit the Ingress
curl https://foo.local.lab/healthz
```
