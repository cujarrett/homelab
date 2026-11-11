# GitHub Tokens

CI pushes image tag bumps as one of two GitHub Apps, so deploy commits and promote pull requests are credited to the App and signed by GitHub. Each deploy job mints a one-hour token from the App's private key.

| App | Grants | Installed on | Key lives as |
|---|---|---|---|
| `homelab-workspaces-deployer` | Contents and Pull requests, read and write | `homelab-workspaces` | `HOMELAB_WORKSPACES_APP_KEY` Actions secret in workspaces app repos |
| `cujarrett-homelab-deployer` | Contents, read and write | `homelab` | `HOMELAB_APP_KEY` Actions secret in `platform-exporter` and `temporal-controller` |

The Apps are split so repos that only touch `homelab-workspaces` can't rewrite cluster manifests. Client IDs are written into the workflows, since they are not secret.

## New repo

Generate a private key on the App's settings page and set it as the repo's secret, then delete the downloaded file:

```bash
gh secret set HOMELAB_WORKSPACES_APP_KEY -R cujarrett/<new-repo> < ~/Downloads/homelab-workspaces-deployer.*.private-key.pem
```

Commit the repo's workspace file first, because `deploy` edits it.

## Rotating an App key

Every repo holding the key gets the new one in one pass. Set `APP` and `SECRET` from the table above.

```bash
APP=homelab-workspaces-deployer SECRET=HOMELAB_WORKSPACES_APP_KEY
open https://github.com/settings/apps   # pick $APP, then Private keys → Generate a private key
PEM=$(ls -t ~/Downloads/$APP.*.private-key.pem | head -1)
for repo in $(gh repo list cujarrett --no-archived --limit 200 --json name --jq '.[].name'); do
  gh secret list -R "cujarrett/$repo" 2>/dev/null | grep -q "^$SECRET[[:space:]]" \
    && gh secret set "$SECRET" -R "cujarrett/$repo" < "$PEM" && echo "set $repo"
done
rm -P "$PEM"
```

Then delete the old key under **Private keys** on the App's page. For `cujarrett-homelab-deployer`, run it again with `APP=cujarrett-homelab-deployer SECRET=HOMELAB_APP_KEY`.

## Repo Actions secrets

Each command prompts for the value, so it stays out of shell history.

| Secret | Repo | Regenerate at |
|---|---|---|
| `BLOG_STATS_GIST_TOKEN` | `github-exporter` | [GitHub fine-grained tokens](https://github.com/settings/personal-access-tokens), `blog-stats-gist` |
| `APOLLO_KEY` | `storefront-records`, `storefront-reviews` | Apollo Studio, `storefront-homelab` → Settings → API keys |
| `VSCE_PAT` | `between-stars`, `gotemplate-yaml` | [Azure DevOps tokens](https://dev.azure.com/_usersSettings/tokens), scope Marketplace → Manage |

```bash
gh secret set BLOG_STATS_GIST_TOKEN -R cujarrett/github-exporter
gh secret set APOLLO_KEY -R cujarrett/storefront-records
gh secret set APOLLO_KEY -R cujarrett/storefront-reviews
gh secret set VSCE_PAT -R cujarrett/between-stars
gh secret set VSCE_PAT -R cujarrett/gotemplate-yaml
```

## Revoking a key

Delete it under **Private keys** on the App's settings page. Tokens minted from it stop working within an hour. A missing or revoked key shows as green test and build with a failed `deploy`.

## Launchpad token

`launchpad-api` writes guest sandbox directories with the `homelab-workspaces-launchpad` fine-grained PAT, held in AWS Secrets Manager. Rotate it with [GitHub Token Rotate](../scripts/github-token-rotate/). Cluster credentials are in [Rotate Secret](../scripts/rotate-secret/).
