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
| `homelab-workspaces/<workspace>/<app-name>.yaml` | [.claude/assets/new-go-api/api.yaml](.claude/assets/new-go-api/api.yaml) |

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

Runs on the homelab cluster via the `Api` Crossplane composition. Image: `ghcr.io/cujarrett/<app-name>`. ARM64.
```

**`./<app-name>/go.mod`**
```
module github.com/cujarrett/<app-name>

go 1.26
```

**`./<app-name>/CLAUDE.md`** — a standalone repo, so it carries the same git rules, pre-commit safety check, and grug philosophy as the homelab repo (Claude working in this repo won't see homelab's CLAUDE.md):
```markdown
## Rules

- **Never run `git commit`, `git push`, or any git command that writes to or modifies repository history or remotes.** If a task requires committing or pushing, stop and tell the user to run the git command manually.
- **Whenever a task requires a commit, always give a suggested commit message** — never leave the user to write it themselves.

### Pre-commit safety check

Before telling the user to commit, always run `/security-review`. It reviews the pending changes on the current branch for security issues. Once it confirms the changes are safe, offer the user a suggested commit message — do not run `git commit` yourself.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." — [grugbrain.dev](https://grugbrain.dev/)

- **Say no.** The best weapon against complexity is the word "no". No new feature, no new abstraction, until it earns its place.
- **No abstraction until a pattern repeats three times.** Let cut points emerge naturally from the code; don't invent them up front.
- **80/20 solutions.** Ship 80% of the value with 20% of the code. Ugly but working beats elegant but over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it. If you don't see the use, go away and think.
- **Boring, obvious code wins.** Intermediate variables with good names beat clever one-liners. Easier to debug.
- **DRY is not a law.** A little copy-paste beats a complex abstraction built for two cases.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so. That's a signal to simplify, not a personal failing.

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
3. Add the `HOMELAB_PAT` secret to the new repo — `/wire-deploy-automation` covers how to scope the token, and is also what to run if the deploy job ever needs rewiring
4. Run `argocd app sync xrs --grpc-web` after the first image is pushed and ArgoCD detects the Api
