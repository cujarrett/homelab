#!/usr/bin/env bash
# Distributes a regenerated homelab-workspaces-deploy PAT to every repo that
# already holds one. Consumers are discovered via `gh secret list`, not
# hand-maintained.
set -euo pipefail

owner="cujarrett"
secret="HOMELAB_WORKSPACES_PAT"

echo "Listing repos for ${owner}..."
all_repos=()
while IFS= read -r repo; do
  all_repos+=("$repo")
done < <(gh repo list "$owner" --limit 200 --json name --jq '.[].name')
echo "Found ${#all_repos[@]} repos, checking each for ${secret}..."

repos=()
for repo in "${all_repos[@]}"; do
  echo -n "  ${repo}..."
  if gh secret list -R "${owner}/${repo}" --json name --jq '.[].name' 2>/dev/null | grep -qx "$secret"; then
    echo " yes"
    repos+=("$repo")
  else
    echo " no"
  fi
done
echo

echo "Found ${secret} on ${#repos[@]} repos:"
printf '  %s\n' "${repos[@]}"
echo

read -rsp "New ${secret} value: " token
echo

for repo in "${repos[@]}"; do
  echo -n "${owner}/${repo}: "
  gh secret set "$secret" -R "${owner}/${repo}" --body "$token" && echo ok
done
