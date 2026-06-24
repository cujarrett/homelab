---
description: 'Scaffold a new Go HTTP API for the homelab platform. Use when creating a new Go API service, new go app, new go service, new backend.'
argument: '<app-name>'
---

# New Go API

Scaffold a new homelab Go HTTP API from the canonical templates in [.claude/assets/new-go-api/](.claude/assets/new-go-api/).

## Inputs

Ask the user for:
1. **App name** — kebab-case; becomes the repo name, binary name, and image name (e.g. `my-app`)
2. **Workspace** — homelab-workspaces namespace to deploy to (e.g. `my-vinyl`)
3. **Port** — default `8080`

## Procedure

Create a new directory `./<app-name>/` containing the following files. In every asset, replace:
- `APP_NAME` → the kebab-case app name
- `APP_PORT` → the port number
- `APP_WORKSPACE` → the workspace namespace

### Files to create

| Destination | Source |
|---|---|
| `./<app-name>/main.go` | [.claude/assets/new-go-api/main.go](.claude/assets/new-go-api/main.go) |
| `./<app-name>/Dockerfile` | [.claude/assets/new-go-api/Dockerfile](.claude/assets/new-go-api/Dockerfile) |
| `./<app-name>/justfile` | [.claude/assets/new-go-api/justfile](.claude/assets/new-go-api/justfile) |
| `./<app-name>/.github/workflows/ci.yml` | [.claude/assets/new-go-api/ci.yml](.claude/assets/new-go-api/ci.yml) |
| `./<app-name>/.github/dependabot.yml` | [.claude/assets/new-go-api/dependabot.yml](.claude/assets/new-go-api/dependabot.yml) |
| `homelab-workspaces/<workspace>/<app-name>.yaml` | [.claude/assets/new-go-api/xapi.yaml](.claude/assets/new-go-api/xapi.yaml) |

Also create:

**`./<app-name>/README.md`**
```markdown
# <app-name>

One sentence description of what the app does.

## Commands

| Command | What it does |
|---|---|
| `just ci` | Lint + test + build (run before pushing) |
| `just run` | Start the server locally on port <port> |
| `just test` | Run tests with race detector |
| `just lint` | go mod tidy -diff + golangci-lint |

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/healthz` | Liveness probe |

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|

## Deployment

Runs on the homelab cluster via the `XApi` Crossplane composition. Image: `ghcr.io/cujarrett/<app-name>`. ARM64.
```

**`./<app-name>/go.mod`**
```
module github.com/cujarrett/<app-name>

go 1.26
```

**`./<app-name>/CLAUDE.md`**
```markdown
# <App Name>

Go HTTP API. Single binary, no frameworks.

## Commands
| Command | What it does |
|---|---|
| `just ci` | Lint + test + build (run before pushing) |
| `just run` | Start the server locally on port <port> |
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

## After scaffolding

Remind the user to:
1. `cd <app-name> && go mod tidy`
2. Create the GitHub repo and push
3. Add `HOMELAB_PAT` secret to the new repo (Settings → Secrets → Actions)
4. Run `argocd app sync xrs --grpc-web` after the first image is pushed and ArgoCD detects the XApi
