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
| `./<app-name>/README.md` | [.claude/assets/new-go-api/README.md](.claude/assets/new-go-api/README.md) |
| `./<app-name>/AGENTS.md` | [.claude/assets/new-go-api/AGENTS.md](.claude/assets/new-go-api/AGENTS.md) |
| `./<app-name>/renovate.json` | [.claude/assets/new-go-api/renovate.json](.claude/assets/new-go-api/renovate.json) |
| `homelab-workspaces/<workspace>/<app-name>.yaml` | [.claude/assets/new-go-api/api.yaml](.claude/assets/new-go-api/api.yaml) |

A new workspace also needs its namespace in the `workloads` project `destinations` in
[cluster/argocd/projects.yaml](cluster/argocd/projects.yaml), synced before the workspace commit.

Also create **`./<app-name>/go.mod`**
```
module github.com/cujarrett/<app-name>

go 1.26
```

## After scaffolding

Remind the user to:
1. `cd <app-name> && go mod tidy`
2. Create the GitHub repo and push
3. Add the `HOMELAB_WORKSPACES_PAT` secret to the new repo. [GitHub Tokens](../../docs/github-tokens.md) covers which token to use and how to seed it. Use `--body "$VAR"` or no flag, because `gh secret set --body -` stores a one-character secret
4. Run `argocd app sync xrs --grpc-web` after the first image is pushed and ArgoCD detects the Api
