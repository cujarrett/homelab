# GitHub Tokens

Three fine-grained PATs keep GitOps moving.

| Token | Grants | Lives as |
|---|---|---|
| `homelab-workspaces-deploy` | Push to `homelab-workspaces` | `HOMELAB_WORKSPACES_PAT` Actions secret in workspaces app repos |
| `homelab-deploy` | Push to `homelab` | `HOMELAB_DEPLOY_PAT` Actions secret in `platform-exporter`, `secret-mirror-controller` |
| `homelab-argocd` | Read `homelab` | Parameter `/homelab/argocd/homelab-repo-token` |

The deploy tokens are split so repos that only touch `homelab-workspaces` can't rewrite cluster
manifests.

## Deploy tokens

Rotate with [scripts/homelab-workspaces-deploy-token-rotate/](../scripts/homelab-workspaces-deploy-token-rotate/)
and [scripts/homelab-deploy-token-rotate/](../scripts/homelab-deploy-token-rotate/). The scripts only
find repos that already hold the secret, so seed a new repo once:

```bash
gh secret set HOMELAB_WORKSPACES_PAT -R cujarrett/<new-repo> --body "<token>"
```

An expired or missing token shows as green test and build with a failed `deploy`.

## homelab-argocd

Rotate it like any [External Secrets](./external-secrets.md) credential (ExternalSecret `homelab-repo`
in `argocd`), then check `argocd repo list --grpc-web`. GitHub's "Never used" label ignores ArgoCD's
fetches.
