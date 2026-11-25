# Spa

A Spa hosts a static single-page app, such as an Angular build, on nginx. Server-side rendering and incremental static regeneration need a live process, so Next.js and Nuxt in those modes do not fit here.

## What it provisions

| Resource | What it does |
|---|---|
| nginx config | SPA routing to `index.html`, security headers, asset caching, a probe path and scanner blocking. |
| Deployment | nginx serving the pre-built image. |
| Service | Port 80. |
| Rate limit | 300 requests a minute on average, burst of 100, per client IP (`CF-Connecting-IP`). |
| Route | HTTPS on `host`, with the rate limit. |
| Connection policy | Always on. Outbound calls go only to declared backends. Inbound calls reach only the web server. See [Platform Connections](../docs/connections.md). |

Your workspace owns the namespace through its `namespace.yaml`.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `image` | yes | - | Container image, such as `ghcr.io/owner/app:sha-abc123`. CI builds on merge to main and commits the new tag back. |
| `host` | yes | - | Hostname clients call, such as `foo.local.lab`. Use `local.lab` for the homelab network or `mattjarrett.dev` for the internet. |
| `repo` | no | - | GitHub URL of the app's source. |
| `size` | no | `sm` | nginx compute. `xs`: 25m/100m CPU, 32Mi/64Mi memory. `sm`: 50m/200m CPU, 64Mi/128Mi. `md`: 100m/500m CPU, 128Mi/256Mi. `lg`: 250m/1000m CPU, 256Mi/512Mi. |
| `contentSecurityPolicy` | no | `default-src 'self'; frame-ancestors 'none'; base-uri 'self';` | CSP header. Add your app's origins, such as Google Fonts or external APIs. |
| `replicas` | no | `1` | nginx replicas. Stateless, so scale freely. |
| `apiProxies` | no | - | Path prefixes proxied to a backend, so platform APIs stay off the internet. Each entry needs `path` and `app`, the name of a platform Api. `namespace` defaults to this Spa's own. The Api must name this Spa in `allowedCallers`, even in the same namespace. The prefix is stripped, so set `upstreamPath` if the backend expects one. |
| `publicConfig` | no | - | Key/value pairs served as JSON at `/config.json`, so one image works in every environment. Any browser can read it, so never put a secret here. |
| `userAuth` | no | - | Sign-in for this Spa. `client` names the one proxied app that does the code exchange and holds the tokens. `scopes` lists what the user needs. `extraRedirectUris` adds a callback, such as localhost or a second domain. Tokens never reach the browser. |

| Topic | Detail |
|---|---|
| Connection list | `apiProxies` is the list. The Spa may call those backends and nothing else. Each backend still decides whether to admit it. |
| Api side | See [Api → Being called through a Spa](../api/README.md#being-called-through-a-spa) for stripped prefixes and forwarded headers. |
| Health check | Always `/healthz`. |

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

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).

## Workload repo contract

Ship a static build in `nginx:alpine`. **Never add an `nginx.conf` to the repo or `COPY` one in the Dockerfile.** The platform mounts its own config over `/etc/nginx/conf.d/default.conf` and overwrites it.

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

The default CSP blocks inline scripts. A blocked script fails silently, with only a console error. Load every script in `index.html` from a file.

- **Angular:** set `"optimization": { "scripts": true, "styles": { "minify": true, "inlineCritical": false }, "fonts": true }` in the production configuration, or the global stylesheet never applies.
- **Create React App:** build with `INLINE_RUNTIME_CHUNK=false`.

## Operations

```bash
# XR status - SYNCED=composition ran, READY=all children healthy
kubectl get spa foo -n foo

# Detailed conditions
kubectl get spa foo -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Pod status
kubectl get pods -n foo

# Hit the route
curl https://foo.local.lab/healthz
```
