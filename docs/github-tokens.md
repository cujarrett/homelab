# GitHub Tokens

Three fine-grained PATs keep GitOps moving, all hand-created outside Git. A fourth, `blog-backups`,
is documented in the [blog-backups](https://github.com/cujarrett/blog-backups) repo instead.

| Token | Grants | Lives as |
|---|---|---|
| `homelab-workspaces-deploy` | Push to `homelab-workspaces` | `HOMELAB_PAT` Actions secret in workspaces app repos |
| `homelab-deploy` | Push to `homelab` | `HOMELAB_PAT` Actions secret in `platform-exporter`, `secret-mirror-controller` |
| `homelab-argocd` | Read `homelab` | `repository`-type Secret in `argocd` namespace |

Split in two rather than one shared token: `homelab` is the cluster's GitOps source, so the 10
repos that only ever touch `homelab-workspaces` don't hold a credential that could also rewrite
cluster manifests.

## `homelab-workspaces-deploy` and `homelab-deploy`

Each app repo's CI job bumps an image tag - most in `homelab-workspaces`, `platform-exporter` and
`secret-mirror-controller` directly in `homelab`. Both are Actions secrets named `HOMELAB_PAT`;
which token value a repo holds depends on which group it's in, not the secret name.

Rotate with [scripts/homelab-workspaces-deploy-token-rotate/](../scripts/homelab-workspaces-deploy-token-rotate/)
and [scripts/homelab-deploy-token-rotate/](../scripts/homelab-deploy-token-rotate/). Each script's
README has the exact steps.

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
