# CI Writeback for Auto-Deploy on Merge to Main

Currently repos point at `:main` or `:latest` — new images require a manual `kubectl rollout restart` to deploy.

The fix: each repo's CI writes the new SHA tag back to the homelab repo after pushing the image, triggering an ArgoCD sync and rollout automatically.

## Repos to wire up

- [ ] `cujarrett/mattjarrett.dev` → updates `platform/xrs/spa/mattjarrett-dev.yaml`
- [ ] `cujarrett/platform-api-starter` → updates `platform/xrs/api/platform-api-starter.yaml`

**Deferred** (blocked until XR files are moved out of `local-only/` into `platform/xrs/`):
- `cujarrett/my-vinyl-api` — XR at `local-only/xrs/api/my-vinyl.yaml` is gitignored; no secrets in the file, only a `secretRef` name
- `cujarrett/my-vinyl-spa` — same issue, `local-only/xrs/spa/my-vinyl.yaml`

## How it works

1. CI builds and pushes `ghcr.io/cujarrett/<repo>:sha-<full-sha>`
2. CI updates the image tag in the homelab repo via the GitHub API (no clone)
3. ArgoCD detects the commit and syncs — Crossplane updates the Deployment, Kubernetes rolls out

## Security requirements

**Use a fine-grained PAT, not a classic PAT.**

Classic PATs are scoped to the user and grant broad access. A fine-grained PAT is scoped to one repo and one permission:
- Repository: `cujarrett/homelab` only
- Permission: `Contents: Read and write` only
- Set an expiry (1 year max)

Store it as `HOMELAB_PAT` in each source repo's Actions secrets.

**Use the GitHub API, not clone+push.**

`git clone https://x-access-token:${TOKEN}@github.com/...` puts the token in the git remote URL, which is visible in the process list and may appear in runner logs. The `gh` CLI's API approach is atomic and never embeds the token in a URL.

## Workflow step (add after image push)

```yaml
- name: Update homelab image tag
  env:
    GH_TOKEN: ${{ secrets.HOMELAB_PAT }}
  run: |
    FILE=platform/xrs/spa/mattjarrett-dev.yaml   # change per repo
    REPO=cujarrett/homelab
    IMAGE=ghcr.io/cujarrett/mattjarrett.dev       # change per repo
    SHA_TAG=sha-${{ github.sha }}

    # Fetch current file content and its blob SHA (required for PUT)
    FILE_SHA=$(gh api /repos/$REPO/contents/$FILE --jq '.sha')
    CONTENT=$(gh api /repos/$REPO/contents/$FILE --jq '.content' | tr -d '\n' | base64 -d)

    # Patch the image tag in-place
    UPDATED=$(echo "$CONTENT" | sed "s|image: ${IMAGE}:.*|image: ${IMAGE}:${SHA_TAG}|")

    # Write back atomically — fails if file was modified concurrently (safe)
    gh api --method PUT /repos/$REPO/contents/$FILE \
      -f message="chore: deploy ${IMAGE##*/} ${SHA_TAG}" \
      -f content="$(echo "$UPDATED" | base64 -w 0)" \
      -f sha="$FILE_SHA"
```

## PAT setup (one time)

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. New token:
   - Resource owner: `cujarrett`
   - Repository access: **Only select repositories** → `cujarrett/homelab`
   - Permissions → Repository permissions → Contents: **Read and write**
3. Copy the token and add it as an Actions secret named `HOMELAB_PAT` in each source repo
