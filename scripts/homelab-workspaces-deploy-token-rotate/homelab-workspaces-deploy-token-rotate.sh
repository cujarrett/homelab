#!/usr/bin/env bash
# Distributes a regenerated HOMELAB_PAT to every repo that already has one set,
# except the repos that push straight to `homelab` - see homelab-deploy-token-rotate/.
# Consumers are discovered via `gh secret list`, not hand-maintained.
set -euo pipefail

owner="cujarrett"
homelab_repos=(platform-exporter secret-mirror-controller)

echo "Listing repos for ${owner}..."
all_repos=()
while IFS= read -r repo; do
  all_repos+=("$repo")
done < <(gh repo list "$owner" --limit 200 --json name --jq '.[].name')
echo "Found ${#all_repos[@]} repos, checking each for HOMELAB_PAT..."

repos=()
for repo in "${all_repos[@]}"; do
  for skip in "${homelab_repos[@]}"; do
    [[ "$repo" == "$skip" ]] && continue 2
  done
  echo -n "  ${repo}..."
  if gh secret list -R "${owner}/${repo}" 2>/dev/null | grep -q '^HOMELAB_PAT[[:space:]]'; then
    echo " yes"
    repos+=("$repo")
  else
    echo " no"
  fi
done
echo

echo "Found HOMELAB_PAT on ${#repos[@]} repos:"
printf '  %s\n' "${repos[@]}"
echo

read -rsp "New HOMELAB_PAT value: " token
echo

for repo in "${repos[@]}"; do
  echo -n "${owner}/${repo}: "
  gh secret set HOMELAB_PAT -R "${owner}/${repo}" --body "$token" && echo ok
done
