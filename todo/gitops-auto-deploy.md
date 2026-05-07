# CI Writeback for Auto-Deploy on Merge to Main

Currently repos point at `:main` or `:latest` — new images require a manual `kubectl rollout restart` to deploy.

The fix: each repo's CI writes the new SHA tag back to a dedicated repo (`cujarrett/homelab-tenants`) after pushing the image, triggering an ArgoCD sync and rollout automatically. No `kubectl` needed — the tag change in git is the deploy signal.

## Repo structure

| Repo | Purpose | Who writes to it |
|---|---|---|
| `cujarrett/homelab` | cluster infra, platform compositions, ArgoCD bootstrap | humans only |
| `cujarrett/homelab-tenants` | XR instance files for all apps (`tenants/`) | CI (via PAT) + humans |

The `tenants/` directory moves from `homelab` → `homelab-tenants`. The PAT is scoped to `homelab-tenants` only — a leaked token cannot touch `cluster/` or `platform/` in any way.

Each repo's README links to the other so the two are easy to find together.

## Design: convention over configuration

A single **reusable workflow** lives in `cujarrett/homelab-tenants` at `.github/workflows/update-image-tag.yml`.
App teams call it with **zero required inputs** — the workflow derives the file path and image from the calling repo's name by convention. Inputs exist only as escape hatches for non-standard repos.

The platform team can change the entire deploy mechanism (XR structure, registry, path conventions) by updating one file. Every app repo inherits the change automatically on the next run. App teams are insulated from that churn entirely.

```
source repo CI (e.g. cujarrett/my-vinyl-api)
  └── build + push ghcr.io/cujarrett/my-vinyl-api:sha-<sha>
  └── calls cujarrett/homelab-tenants/.github/workflows/update-image-tag.yml@main
            (no inputs required — workflow derives from repo name)
                    │
                    ▼ workflow infers:
                      image  = ghcr.io/cujarrett/my-vinyl-api
                      file   = tenants/my-vinyl/api.yaml
                    │
                    ▼
            GitHub API PUT → homelab-tenants main branch commit
                    │
                    ▼
            ArgoCD detects commit → syncs app
                    │
                    ▼
            Crossplane updates Deployment → Kubernetes rolls out
```

## Convention rules (baked into the workflow)

Given a source repo named `<repo>`:

| Input | Default | Notes |
|---|---|---|
| `image` | `ghcr.io/cujarrett/<repo>` | |
| `namespace` | `<repo>` | Override when repo name ≠ namespace |
| `file` | `tenants/<namespace>/<repo>.yaml` | Override for repos with dots etc. |

File naming: **directory = namespace, filename = `<xr-instance-name>.yaml`**. The `kind` in each file maps it back to the XRD. Supports any number of XRs per tenant.

Non-standard repos (e.g. `mattjarrett.dev` — dot in name) override with `file:` input.

## Reusable workflow (in homelab-tenants)

**`.github/workflows/update-image-tag.yml`**

```yaml
on:
  workflow_call:
    inputs:
      namespace:
        description: "Override: tenant namespace (directory under tenants/). Defaults to the calling repo name."
        required: false
        type: string
      file:
        description: "Override: full path to the XR file. Defaults to tenants/<namespace>/<repo-name>.yaml."
        required: false
        type: string
      image:
        description: "Override: full image name without tag. Defaults to ghcr.io/cujarrett/<repo-name>."
        required: false
        type: string
    secrets:
      homelab_pat:
        required: true

jobs:
  update-tag:
    runs-on: ubuntu-latest
    steps:
      - name: Derive defaults from repo name
        id: defaults
        run: |
          REPO_NAME="${GITHUB_REPOSITORY#*/}"  # strips "cujarrett/" prefix

          IMAGE="${{ inputs.image }}"
          if [[ -z "$IMAGE" ]]; then
            IMAGE="ghcr.io/cujarrett/${REPO_NAME}"
          fi

          NAMESPACE="${{ inputs.namespace }}"
          if [[ -z "$NAMESPACE" ]]; then
            NAMESPACE="${REPO_NAME}"
          fi

          FILE="${{ inputs.file }}"
          if [[ -z "$FILE" ]]; then
            FILE="tenants/${NAMESPACE}/${REPO_NAME}.yaml"
          fi

          echo "image=$IMAGE" >> "$GITHUB_OUTPUT"
          echo "file=$FILE"   >> "$GITHUB_OUTPUT"

      - name: Update image tag
        env:
          GH_TOKEN: ${{ secrets.homelab_pat }}
        run: |
          FILE="${{ steps.defaults.outputs.file }}"
          IMAGE="${{ steps.defaults.outputs.image }}"
          REPO=cujarrett/homelab-tenants
          SHA_TAG=sha-${GITHUB_SHA}

          FILE_SHA=$(gh api /repos/$REPO/contents/$FILE --jq '.sha')
          CONTENT=$(gh api /repos/$REPO/contents/$FILE --jq '.content' | tr -d '\n' | base64 -d)
          UPDATED=$(echo "$CONTENT" | sed "s|image: ${IMAGE}:.*|image: ${IMAGE}:${SHA_TAG}|")

          gh api --method PUT /repos/$REPO/contents/$FILE \
            -f message="chore: deploy ${IMAGE##*/} ${SHA_TAG}" \
            -f content="$(echo "$UPDATED" | base64 -w 0)" \
            -f sha="$FILE_SHA"
```

## Calling the reusable workflow (source repo side)

### Zero-config (works for 90% of apps)

```yaml
deploy:
  needs: build
  uses: cujarrett/homelab-tenants/.github/workflows/update-image-tag.yml@main
  secrets:
    homelab_pat: ${{ secrets.HOMELAB_PAT }}
```

### Namespace override (repo lives in a different namespace)

```yaml
# my-vinyl-api lives in the my-vinyl namespace
deploy:
  needs: build
  uses: cujarrett/homelab-tenants/.github/workflows/update-image-tag.yml@main
  with:
    namespace: my-vinyl
  secrets:
    homelab_pat: ${{ secrets.HOMELAB_PAT }}
```

### Full file override (repo name can't be derived)

```yaml
# mattjarrett.dev — dot in repo name
deploy:
  needs: build
  uses: cujarrett/homelab-tenants/.github/workflows/update-image-tag.yml@main
  with:
    file: tenants/mattjarrett-dev/mattjarrett-dev.yaml
  secrets:
    homelab_pat: ${{ secrets.HOMELAB_PAT }}
```

## All apps to wire up

| Source repo | Needs override? | Override |
|---|---|---|
| `cujarrett/my-vinyl` | no | — |
| `cujarrett/my-vinyl-api` | yes (different namespace) | `namespace: my-vinyl` |
| `cujarrett/js-pollock` | no | — |
| `cujarrett/sump-pump-bridge` | yes (different namespace) | `namespace: sump-pump` |
| `cujarrett/sump-pump-consumer` | yes (different namespace) | `namespace: sump-pump` |
| `cujarrett/mattjarrett.dev` | yes (dot in name) | `file: tenants/mattjarrett-dev/mattjarrett-dev.yaml` |

**Progress:**
- [x] Create `cujarrett/homelab-tenants` repo
- [x] Move `tenants/` from `homelab` → `homelab-tenants`
- [x] Add ArgoCD source for `homelab-tenants` (update `cluster/argocd/bootstrap.yaml` or `xrs-appset.yaml`)
- [x] Add cross-links in each repo's README
- [x] Create `.github/workflows/update-image-tag.yml` in `homelab-tenants`
- [x] `cujarrett/my-vinyl`
- [x] `cujarrett/my-vinyl-api`
- [x] `cujarrett/js-pollock`
- [x] `cujarrett/mattjarrett.dev`
- [ ] `cujarrett/sump-pump-bridge` *(blocked: image not yet published)*
- [ ] `cujarrett/sump-pump-consumer` *(blocked: image not yet published)*

## For future apps

When adding a new app:
1. Create `<namespace>/<xr-instance-name>.yaml` in `homelab-tenants` — the `kind` maps it to the XRD
2. Add the `deploy` job to the source repo's CI (zero-config if repo name = namespace, otherwise add `namespace:` override)
3. Done — no workflow changes needed

If the repo name can't be derived cleanly (e.g. dots), use `file:` override. That's the full cost.

## Security

**Fine-grained PAT scoped to `homelab-tenants` only.**

- Repository: `cujarrett/homelab-tenants` only
- Permission: `Contents: Read and write` only
- Set an expiry (1 year max)

A leaked token can update an image tag in `tenants/`. It cannot touch `cluster/`, `platform/`, or anything else in `homelab`.

**Store the token value in your password manager when you create it.** GitHub shows it once. Adding a new repo later just means retrieving it from there. If you lose it, rotate it — generate a new one and update `HOMELAB_PAT` in each source repo.

## PAT setup (one time, shared across all source repos)

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. New token:
   - Resource owner: `cujarrett`
   - Repository access: **Only select repositories** → `cujarrett/homelab-tenants`
   - Permissions → Repository permissions → Contents: **Read and write**
3. Copy the token — **save it in your password manager now**
4. Add it as `HOMELAB_PAT` in each source repo under Settings → Secrets and variables → Actions

One PAT, one revocation point, zero access to cluster infra.
