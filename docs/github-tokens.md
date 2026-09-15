# GitHub Tokens

Two fine-grained PATs let CI push image tag bumps.

| Token | Grants | Lives as |
|---|---|---|
| `homelab-workspaces-deploy` | Push to `homelab-workspaces` | `HOMELAB_WORKSPACES_PAT` Actions secret in workspaces app repos |
| `homelab-deploy` | Push to `homelab` | `HOMELAB_DEPLOY_PAT` Actions secret in `platform-exporter`, `secret-mirror-controller` |

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
