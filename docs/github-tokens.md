# GitHub Tokens

Three fine-grained PATs keep GitOps moving, all hand-created outside Git. A fourth, `blog-backups`,
is documented in the [blog-backups](https://github.com/cujarrett/blog-backups) repo instead.

| Token | Grants | Lives as |
|---|---|---|
| `homelab-workspaces-deploy` | Push to `homelab-workspaces` | `HOMELAB_WORKSPACES_PAT` Actions secret in workspaces app repos |
| `homelab-deploy` | Push to `homelab` | `HOMELAB_DEPLOY_PAT` Actions secret in `platform-exporter`, `secret-mirror-controller` |
| `homelab-argocd` | Read `homelab` | `repository`-type Secret in `argocd` namespace |

Split in two rather than one shared token: `homelab` is the cluster's GitOps source, so the 10
repos that only ever touch `homelab-workspaces` don't hold a credential that could also rewrite
cluster manifests.

## `homelab-workspaces-deploy` and `homelab-deploy`

Each app repo's CI job bumps an image tag - most in `homelab-workspaces`, `platform-exporter` and
`secret-mirror-controller` directly in `homelab`. The two are separate Actions secrets, named
after the token they carry, so a repo's secret name says which grant it holds.

A new app repo has to be seeded by hand once, because the rotate scripts discover consumers by
checking which repos already hold the secret. A repo that never had it set is invisible to them,
and its deploy job fails with an empty `GH_TOKEN` while test and build both pass.

```bash
gh secret set HOMELAB_WORKSPACES_PAT -R cujarrett/<new-repo> --body "<token>"
```

Rotate with [scripts/homelab-workspaces-deploy-token-rotate/](../scripts/homelab-workspaces-deploy-token-rotate/)
and [scripts/homelab-deploy-token-rotate/](../scripts/homelab-deploy-token-rotate/). Each script's
README has the exact steps.

Regenerating one token does nothing to the other group, and a repo left on an old value keeps
passing test and build while its deploy job 401s. Each script ends by printing the other group's
secret dates and warning when any predate today.

## `homelab-argocd`

Authenticates ArgoCD's read access to `homelab`, which its `Application` sources pull from.

**Rotate:**
```bash
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository -o name
kubectl patch secret <repo-secret-name> -n argocd --type merge \
  -p '{"stringData":{"password":"<new-token>"}}'
argocd repo list --grpc-web   # confirm it's still connected
```
GitHub's "Never used" indicator on this token doesn't track ArgoCD's fetches - ignore it.
