---
agent: agent
description: Scaffold a new Go API app for the homelab platform
---

Scaffold a new Go HTTP API that follows the homelab app conventions. Ask the user for:

1. **App name** — kebab-case, becomes the repo name, binary name, and image name (e.g. `my-app`)
2. **Workspace** — which homelab-workspaces namespace to deploy to (e.g. `my-vinyl`)
3. **Port** — default `8080`
4. **Has tests?** — yes/no (adds `main_test.go` scaffold if yes)

Then create the following files in a new directory `./<app-name>/`:

---

### `go.mod`
```
module github.com/cujarrett/<app-name>

go 1.26
```

---

### `main.go`
Minimal HTTP server following the existing app pattern:
- `func main()` — reads `PORT` env var (default `8080`), sets up `slog`, creates mux, registers routes, graceful shutdown via `signal.NotifyContext`
- `healthHandler` — returns `{"status":"ok","version":"<app-name>"}` at `GET /healthz`
- `notFoundHandler` — logs + returns 404 for unknown routes
- `writeJSONError` helper

---

### `Dockerfile`
Multi-stage ARM64 build:
```dockerfile
FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o <app-name> .

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app/<app-name> /
ENTRYPOINT ["/<app-name>"]
```

---

### `justfile`
```just
default:
    @just --list

ci: lint test build

lint:
    go mod tidy -diff
    golangci-lint run

test:
    go test -race ./...

build:
    go build -o <app-name> .

run:
    go run .
```

---

### `.github/workflows/ci.yml`
Copy the pattern from `sump-pump-bridge/.github/workflows/ci.yml` exactly, substituting:
- Image tag: `ghcr.io/cujarrett/<app-name>`
- Deploy job `namespace:` → the workspace the user specified

---

### `.github/copilot-instructions.md`
```markdown
# <App Name>

Go HTTP API. Single binary, no frameworks.

## Commands
| Command | What it does |
|---|---|
| `just ci` | Lint + test + build (run before pushing) |
| `just run` | Start the server locally on port 8080 |
| `just test` | Run tests with race detector |
| `just lint` | go mod tidy -diff + golangci-lint |

## Routes
| Method | Path | Description |
|---|---|---|
| GET | `/healthz` | Liveness probe |

## Conventions
- No frameworks — stdlib `net/http` only
- `slog` for structured logging
- Graceful shutdown via `signal.NotifyContext`
- Errors returned as `{"error":"..."}` JSON
- Binary name matches repo name
```

---

### `homelab-workspaces/<workspace>/<app-name>.yaml`
XApi composite resource following the pattern in `homelab-workspaces/my-vinyl/my-vinyl-api.yaml`. This is a cluster-scoped XR — no `namespace` in `metadata`, and no `claimRef`. Minimum fields:

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XApi
metadata:
  name: <app-name>
spec:
  parameters:
    namespace: <workspace>
    image: ghcr.io/cujarrett/<app-name>:main
    port: <port>
```

---

After creating all files, remind the user to:
1. `cd <app-name> && go mod tidy`
2. Create the GitHub repo and push
3. Add `HOMELAB_PAT` secret to the new repo
4. Run `argocd app sync xrs --grpc-web` after the first ArgoCD sync
