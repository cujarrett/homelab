# GitHub Tokens

CI pushes image tag bumps as one of two GitHub Apps, so deploy commits and promote pull requests are credited to the App and signed by GitHub. Each deploy job mints a one-hour token from the App's private key.

| App | Grants | Installed on | Key lives as |
|---|---|---|---|
| `homelab-workspaces-deployer` | Contents and Pull requests, read and write | `homelab-workspaces` | `HOMELAB_WORKSPACES_APP_KEY` Actions secret in workspaces app repos |
| `cujarrett-homelab-deployer` | Contents, read and write | `homelab` | `HOMELAB_APP_KEY` Actions secret in `platform-exporter`, `secret-mirror-controller` |

The Apps are split so repos that only touch `homelab-workspaces` can't rewrite cluster manifests. Client IDs are written into the workflows, since they are not secret.

## New repo

Generate a private key on the App's settings page and set it as the repo's secret, then delete the downloaded file:

```bash
gh secret set HOMELAB_WORKSPACES_APP_KEY -R cujarrett/<new-repo> < ~/Downloads/homelab-workspaces-deployer.*.private-key.pem
```

Commit the repo's workspace file first, because `deploy` edits it.

## Revoking a key

Delete it under **Private keys** on the App's settings page. Tokens minted from it stop working within an hour. A missing or revoked key shows as green test and build with a failed `deploy`.

## Launchpad token

`launchpad-api` writes guest sandbox directories with the `homelab-workspaces-launchpad` fine-grained PAT, held in AWS Secrets Manager. Rotate it with [GitHub Token Rotate](../scripts/github-token-rotate/).
