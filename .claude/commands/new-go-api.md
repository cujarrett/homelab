---
description: 'Scaffold a new Go HTTP API for the homelab platform. Use when creating a new Go API service, new go app, new go service, new backend.'
argument: '<app-name>'
---

# New Go API

Scaffold a new homelab Go HTTP API from the canonical templates in [.claude/assets/new-go-api/](.claude/assets/new-go-api/).

## Inputs

Ask the user for:
1. **App name** - kebab-case; becomes the repo name, binary name, and image name (e.g. `my-app`)
2. **Workspace** - homelab-workspaces namespace to deploy to (e.g. `my-vinyl`)
3. **Port** - default `8080`

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
| `./<app-name>/renovate.json` | [.claude/assets/new-go-api/renovate.json](.claude/assets/new-go-api/renovate.json) |
| `homelab-workspaces/<workspace>/<app-name>.yaml` | [.claude/assets/new-go-api/api.yaml](.claude/assets/new-go-api/api.yaml) |

A new workspace also needs its namespace in the `workloads` project `destinations` in
[cluster/argocd/projects.yaml](cluster/argocd/projects.yaml), synced before the workspace commit.

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

**`./<app-name>/AGENTS.md`** - a standalone repo, so it carries the same git rules, pre-commit safety check, and grug philosophy as the homelab repo (an agent working in this repo won't see homelab's AGENTS.md). Commands and routes stay in the README, so they are written once:
```markdown
# <app-name>

Go HTTP API. Single binary, stdlib only. Commands are in the [README](./README.md) and the `justfile`.

## Rules

- **Never run `git add`, `git commit`, `git push`, or any git command that writes to or modifies the index, repository history, or remotes.** Output the commands for the user to run. Staging is part of their review.
- **Never add a `Co-Authored-By` trailer or a "Generated with Claude Code" line** to commit messages or PR descriptions, including in suggested commit messages. Commits are authored by the user alone.
- **Whenever a task requires a commit, always give a suggested commit message.** Give `git add` and the commit as two separate steps, listing every file explicitly. Never output a `git push` command.
- **Cheapest rung that works.** Before writing code go down the ladder and stop at the first rung that solves it: skip the feature, reuse code already here, standard library, native platform feature, a dependency already installed, one line, then build the minimum.

### Pre-commit safety check

Before telling the user to commit, always run `/security-review`. Once it confirms the changes are safe, offer a suggested commit message.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." - [grugbrain.dev](https://grugbrain.dev/)

- **Say no.** No new feature, no new abstraction, until it earns its place.
- **No abstraction until a pattern repeats three times.**
- **80/20 solutions.** Ugly but working beats elegant but over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it.
- **Boring, obvious code wins.** Intermediate variables with good names beat clever one-liners.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so.

## Conventions

- stdlib `net/http` only, `slog` for logging
- Graceful shutdown via `signal.NotifyContext`
- `/healthz` is the readiness probe
- Errors returned as `{"error":"..."}` JSON
- Binary name matches repo name
```

## After scaffolding

Remind the user to:
1. `cd <app-name> && go mod tidy`
2. Create the GitHub repo and push
3. Add the `HOMELAB_WORKSPACES_PAT` secret to the new repo - `/wire-deploy-automation` covers how to scope the token, and is also what to run if the deploy job ever needs rewiring
4. Run `argocd app sync xrs --grpc-web` after the first image is pushed and ArgoCD detects the Api
