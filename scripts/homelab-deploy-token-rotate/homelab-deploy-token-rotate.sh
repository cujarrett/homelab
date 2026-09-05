#!/usr/bin/env bash
# Distributes a regenerated homelab-deploy PAT to the two repos that push
# straight to `homelab` instead of `homelab-workspaces`. Fixed list, not
# discovered - not worth the complexity at this size.
set -euo pipefail

owner="cujarrett"
secret="HOMELAB_DEPLOY_PAT"
repos=(platform-exporter secret-mirror-controller)

read -rsp "New ${secret} value (homelab-deploy token): " token
echo

for repo in "${repos[@]}"; do
  echo -n "${owner}/${repo}: "
  gh secret set "$secret" -R "${owner}/${repo}" --body "$token" && echo ok
done
