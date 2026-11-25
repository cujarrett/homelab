# GitHub Tokens

CI pushes image tag bumps as a GitHub App, so GitHub credits and signs each deploy commit. Kargo pushes storefront promotions the same way. Each deploy job mints a one-hour token from the App's private key.

| App | Grants | Installed on | Key lives as |
|---|---|---|---|
| [`homelab-workspaces-deployer`](https://github.com/settings/apps/homelab-workspaces-deployer) | Contents and Pull requests, read and write | `homelab-workspaces` | `HOMELAB_WORKSPACES_APP_KEY` Actions secret in each workload repo that deploys, and `/homelab/kargo/homelab-workspaces-app-key` in Parameter Store for Kargo |
| [`cujarrett-homelab-deployer`](https://github.com/settings/apps/cujarrett-homelab-deployer) | Contents, read and write | `homelab` | `HOMELAB_APP_KEY` Actions secret in `platform-exporter` and `temporal-controller` |

- Two Apps: repos that only touch `homelab-workspaces` can't rewrite cluster manifests.
- Client IDs: written into the workflows, because they are not secret.

## New repo

Generate a private key on the App's settings page. Set it as the repo's secret, then delete the downloaded file.

```bash
gh secret set HOMELAB_WORKSPACES_APP_KEY -R cujarrett/<new-repo> < ~/Downloads/homelab-workspaces-deployer.*.private-key.pem
```

Commit the repo's workspace file first, because `deploy` edits it.

## Rotating an App key

Each App keeps exactly one private key. Add the new key everywhere, then delete the old one.

1. Open the App's page from the table above. Go to **Credentials → Key pairs → New key**. The `.pem` file downloads.
2. Run this with `APP` and `SECRET` from the table. It sets the new key in every repo holding the secret, and in Parameter Store for Kargo.

   ```bash
   APP=homelab-workspaces-deployer SECRET=HOMELAB_WORKSPACES_APP_KEY
   PEM=$(ls -t ~/Downloads/$APP.*.private-key.pem ~/Desktop/$APP.*.private-key.pem 2>/dev/null | head -1)
   for repo in $(gh repo list cujarrett --no-archived --limit 200 --json name --jq '.[].name'); do
     gh secret list -R "cujarrett/$repo" 2>/dev/null | grep -q "^${SECRET}[[:space:]]" \
       && gh secret set "$SECRET" -R "cujarrett/$repo" < "$PEM" && echo "set $repo"
   done
   [ "$APP" = homelab-workspaces-deployer ] && aws ssm put-parameter --overwrite \
     --name /homelab/kargo/homelab-workspaces-app-key --type SecureString --value "$(cat "$PEM")"
   rm -P "$PEM"
   ```

3. Back on **Key pairs**, delete every key except the new one.

## Revoking a key

Delete it under **Credentials → Key pairs** on the App's settings page. Tokens minted from it stop working within an hour. A missing or revoked key shows as a green test and build with a failed `deploy`.

## Cluster tokens

ArgoCD reads these from Parameter Store to build and report PR environments.

| Token | Used by | Grants | Lives as |
|---|---|---|---|
| `graph-pr-github` | the `graph-pr` ApplicationSet, to list open subgraph PRs | [Fine-grained token](https://github.com/settings/personal-access-tokens), `storefront-records` and `storefront-reviews`, Pull requests read | `/homelab/argocd/graph-pr-github-token` |
| `homelab-argocd-notifier` | Argo notifications, to post each PR environment as a GitHub deployment | [GitHub App](https://github.com/settings/apps/homelab-argocd-notifier) on `storefront-records` and `storefront-reviews`, Deployments read and write | `/homelab/argocd/notifications-github-app-id`, `-installation-id` and `-app-key` |

```bash
aws ssm put-parameter --overwrite --name /homelab/argocd/graph-pr-github-token --type SecureString --value "$(read -rs t && echo "$t")"
aws ssm put-parameter --overwrite --name /homelab/argocd/notifications-github-app-id --type String --value <app id>
aws ssm put-parameter --overwrite --name /homelab/argocd/notifications-github-installation-id --type String --value <installation id>
aws ssm put-parameter --overwrite --name /homelab/argocd/notifications-github-app-key --type SecureString --value "$(cat ~/Downloads/homelab-argocd-notifier.*.private-key.pem)"
```

## Repo Actions secrets

Each command prompts for the value, so it stays out of shell history.

| Secret | Repo | Regenerate at |
|---|---|---|
| `BLOG_STATS_GIST_TOKEN` | `github-exporter` | [GitHub fine-grained tokens](https://github.com/settings/personal-access-tokens), `blog-stats-gist` |
| `APOLLO_KEY` | `storefront-records`, `storefront-reviews` | Apollo Studio, `storefront-homelab` → Settings → API keys |
| `VSCE_PAT` | `between-stars` | [Azure DevOps tokens](https://dev.azure.com/_usersSettings/tokens), scope Marketplace → Manage |

```bash
gh secret set BLOG_STATS_GIST_TOKEN -R cujarrett/github-exporter
gh secret set APOLLO_KEY -R cujarrett/storefront-records
gh secret set APOLLO_KEY -R cujarrett/storefront-reviews
gh secret set VSCE_PAT -R cujarrett/between-stars
```

## Launchpad token

`launchpad-api` writes guest sandbox directories with the `homelab-workspaces-launchpad` fine-grained PAT, kept in AWS Secrets Manager. Rotate it with [GitHub Token Rotate](../scripts/github-token-rotate/). Cluster credentials rotate with [Rotate Secret](../scripts/rotate-secret/).
