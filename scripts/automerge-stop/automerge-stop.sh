#!/usr/bin/env bash
# Emergency stop for Renovate automerge across every repo.
#
# Suspend runs first, so Renovate can't open or arm a PR after the sweep.
# Disarming still matters, since GitHub merges an armed PR without Renovate.
set -euo pipefail

owner="cujarrett"

echo "Suspend Renovate on the page that opens: Renovate > Configure > Suspend."
open "https://github.com/settings/installations" 2>/dev/null || true
read -rp "Press Enter once it says suspended. "

echo
echo "Disarming auto-merge on open Renovate PRs..."
prs=$(gh search prs --owner "$owner" --author app/renovate --state open --limit 200 \
  --json repository,number --jq '.[] | "\(.repository.nameWithOwner) \(.number)"')

if [ -z "$prs" ]; then
  echo "  none open"
  exit 0
fi
while read -r repo number; do
  # Fails on a PR that was never armed, which is the same end state.
  if gh pr merge "$number" -R "$repo" --disable-auto >/dev/null 2>&1; then
    echo "  ${repo}#${number}: disarmed"
  else
    echo "  ${repo}#${number}: not armed"
  fi
done <<< "$prs"
