# GitHub Tokens

Two fine-grained PATs let CI push image tag bumps.

| Token | Grants | Lives as |
|---|---|---|
| `homelab-workspaces-deploy` | Push to `homelab-workspaces` and open its promote pull requests (Contents and Pull requests, read and write) | `HOMELAB_WORKSPACES_PAT` Actions secret in workspaces app repos |
| `homelab-deploy` | Push to `homelab` | `HOMELAB_DEPLOY_PAT` Actions secret in `platform-exporter`, `secret-mirror-controller` |

The deploy tokens are split so repos that only touch `homelab-workspaces` can't rewrite cluster
manifests.

## Deploy tokens

Rotate with [GitHub Token Rotate](../scripts/github-token-rotate/). It only finds repos that already
hold the secret, and a token can't be read back out of GitHub. A new repo gets a placeholder, then a
rotation writes the real token there along with every other repo:

```bash
gh secret set HOMELAB_WORKSPACES_PAT -R cujarrett/<new-repo> --body placeholder
./scripts/github-token-rotate/github-token-rotate.sh
```

The rotation also reruns the new repo's failed deploy, so commit its workspace file first.

An expired or missing token shows as green test and build with a failed `deploy`.
