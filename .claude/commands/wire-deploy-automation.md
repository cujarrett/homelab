---
description: Wire a repo's CI so a merge to main auto-bumps the image tag in homelab-workspaces. Use when a repo builds images but you still hand-edit SHAs, or after adding a second image to an existing repo.
---

# Wire deploy automation

A repo is wired when a merge to `main` builds the image *and* commits the new tag to
`homelab-workspaces` on its own. Without the second half you hand-edit SHAs forever, and
the cluster quietly runs stale images.

The commit is done by [update-image-tag.yml](https://github.com/cujarrett/homelab-workspaces/blob/main/.github/workflows/update-image-tag.yml)
in `homelab-workspaces` - a reusable workflow that reads the XR file over the GitHub
contents API, `sed`s `image: <IMAGE>:.*` to `sha-${GITHUB_SHA}`, and PUTs it back as a
commit. ArgoCD takes it from there.

Take the repo path as the argument. If none is given, ask which repo.

## 1. Find what's missing

```bash
cd <repo>
ls .github/workflows/
grep -n "ghcr.io/cujarrett\|deploy:\|uses: cujarrett/homelab-workspaces" .github/workflows/*.yml
```

Every workflow that pushes an image needs a `deploy` job. A workflow with
`build-and-push` but no `deploy` is the gap. Note the exact image names - a monorepo
builds several from one tree.

Then map each image to the XR file(s) it feeds:

```bash
grep -rn "image:" /Users/matt-jarrett/Developer/homelab-workspaces/*/
```

One image can feed more than one XR - the same binary deployed twice under different
names is a normal pattern, and both files need bumping.

## 2. Add the deploy job

Append to each image-building workflow:

```yaml
  deploy:
    needs: build-and-push
    if: github.ref == 'refs/heads/main'
    uses: cujarrett/homelab-workspaces/.github/workflows/update-image-tag.yml@main
    with:
      file: <workspace-dir>/<xr-file>.yaml
    secrets:
      homelab_pat: ${{ secrets.HOMELAB_WORKSPACES_PAT }}
```

Two things the defaults get wrong outside the simple case:

**Image name.** The workflow defaults to `ghcr.io/cujarrett/<repo-name>`. That is only
right when the repo builds one image named after itself. A monorepo building
`foo-api` and `foo-spa` out of repo `foo` must pass `image:` explicitly, or the `sed`
matches nothing and the job succeeds having changed nothing - the worst failure mode,
because it looks green.

```yaml
    with:
      image: ghcr.io/cujarrett/<image-name>
      file: <workspace-dir>/<xr-file>.yaml
```

**One image, several XR files.** `file` takes a single path, so fan out with a matrix.
Keep `max-parallel: 1` - the commits go to the same branch and will race otherwise.

```yaml
    strategy:
      max-parallel: 1
      matrix:
        file:
          - <workspace-dir>/<foo>.yaml
          - <workspace-dir>/<bar>.yaml
    with:
      image: ghcr.io/cujarrett/<image-name>
      file: ${{ matrix.file }}
```

The `namespace` input only feeds the default for `file`. Once `file` is explicit, drop
`namespace` - it does nothing.

## 3. Check the secret

`cujarrett` is a personal account, not an org, so secrets cannot be shared between
repos. Every deploying repo needs its own copy.

```bash
gh secret list -R cujarrett/<repo>
```

Empty output means it must be created. Secrets are write-only, so a token set on
another repo cannot be read back - unless the user saved it, a new one is needed.
Walk them through it:

1. Open **https://github.com/settings/personal-access-tokens/new**
2. Resource owner `cujarrett`; Repository access **Only select repositories** → `homelab-workspaces`
3. Repository permissions → **Contents: Read and write** - that is the entire requirement, the workflow does one GET and one PUT
4. Generate, copy, then `gh secret set HOMELAB_WORKSPACES_PAT -R cujarrett/<repo>`

`gh secret set` has no `-` stdin convention - `--body` takes a literal string and
stdin is read only when the flag is absent. Piping into `--body -` stores a
one-character secret and discards the token, and the command still prints its
success line. The result is a `deploy` job failing on `Bad credentials (HTTP 401)`
that survives any number of token regenerations, because the token was never the
problem. Pass `--body "$VAR"` or omit the flag entirely.

The token needs no access to the repo the workflow runs *in*, only to the repo it
writes *to*. Flag that fine-grained PATs expire, and that when this one does the
`deploy` job fails while `build-and-push` stays green - images keep building and the
cluster keeps running the old SHA.

**The cluster-manifest exception.** A service whose manifests live in `homelab` under
`cluster/` rather than as an XR in `homelab-workspaces` - `platform-exporter` is the
only one - cannot use the reusable workflow, which is hardcoded to its own repo. It
carries an inline GET/`sed`/PUT `deploy` step instead, and its token is scoped to
`cujarrett/homelab`. Same secret name, different target repo: scope that one to
`homelab-workspaces` by mistake and the API returns 404 rather than 401, so it fails
looking like a missing file instead of a bad token.

## 4. Document the rotation in the repo

Expiry is the failure this pattern actually hits, and it lands in a repo whose README
may say nothing about deploys at all. Every wired repo gets a `## Deployment` section
with a `### Rotating HOMELAB_WORKSPACES_PAT` subsection covering four things - which repo the
token is scoped to, that each repo holds its own token because `cujarrett` is a
personal account, that expiry shows up as a green build with a failed `deploy`, and
the `gh secret set` command with this repo's name already filled in. Copy the section
from a wired repo and change the names; do not replace it with a link to another
repo's copy, since the person rotating a token is usually reading only that repo.

## 5. Verify

Validate the YAML parses and the reusable workflow is reachable before pushing:

```bash
python3 -c "
import yaml, glob
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f))
    print(f, '->', list(d['jobs']))
"
gh api "/repos/cujarrett/homelab-workspaces/contents/.github/workflows/update-image-tag.yml?ref=main" --jq '.sha'
```

After the change lands and the secret is set, trigger a build without touching code
(all these workflows should carry `workflow_dispatch`):

```bash
gh workflow run <workflow>.yml -R cujarrett/<repo> --ref main
gh run watch -R cujarrett/<repo>
```

A green `deploy` is not proof on its own - a wrong `image:` still passes. Confirm the
commit actually landed:

```bash
cd /Users/matt-jarrett/Developer/homelab-workspaces && git pull
grep -n "image:" <workspace-dir>/*.yaml
```

The tag should match the SHA of the commit that just built.

## Before committing

Run `/security-review`, then give the user the `git add` and a suggested commit
message as separate steps. Never run git write commands yourself.
