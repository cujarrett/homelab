#!/usr/bin/env bash
# Rotates one of the three GitHub PATs, checks the pasted value is the right
# token before writing it anywhere, then tests it where it lands.
#
# GitHub has no API to regenerate a fine-grained PAT, so that step stays in the browser.
set -euo pipefail

owner="cujarrett"
api_ns="launchpad"
api_secret="launchpad-github-token"
api_deploy="launchpad-api"

echo "Which token?"
echo "  1) Launchpad API at runtime          GitHub name: homelab-workspaces-launchpad"
echo "  2) CI deploys to homelab-workspaces  GitHub name: homelab-workspaces-deploy"
echo "  3) CI deploys to homelab             GitHub name: homelab-deploy"
read -rp "> " choice

case "$choice" in
  1) name="homelab-workspaces-launchpad" ;;
  2) name="homelab-workspaces-deploy"; secret="HOMELAB_WORKSPACES_PAT" ;;
  3) name="homelab-deploy"; secret="HOMELAB_DEPLOY_PAT" ;;
  *) echo "pick 1, 2 or 3"; exit 1 ;;
esac

# Show what breaks before anything is regenerated, since regenerating kills the old value at once.
echo
repos=()
if [ "$choice" = 1 ]; then
  echo "Affected: ${api_deploy} in namespace ${api_ns}"
  echo "  Launchpad's workspace list, sandbox creation and guest cleanup"
else
  echo "Finding repos that hold ${secret}..."
  while IFS= read -r repo; do
    if gh secret list -R "${owner}/${repo}" --json name --jq '.[].name' 2>/dev/null | grep -qx "$secret"; then
      repos+=("$repo")
    fi
  done < <(gh repo list "$owner" --limit 200 --no-archived --json name --jq '.[].name')
  echo "Affected: the deploy job in ${#repos[@]} repos"
  printf '  %s\n' "${repos[@]}"
fi

echo
echo "Regenerate >>> ${name} <<< on the page that opens, then paste it here."
open "https://github.com/settings/personal-access-tokens" 2>/dev/null || true
read -rsp "New ${name} value: " token
echo

# The repos are public, so any valid token can read them. Both probes test write access and change nothing.
#   can_push: writes the empty blob, which every repo already has
#   can_open_pr: a PR from a missing branch gets 422 when allowed, 403 when not
post_status() {
  printf %s "$2" | GH_TOKEN="$token" gh api -X POST "$1" --input - -i 2>/dev/null | head -1 | awk '{print $2}'
}
can_push() { [ "$(post_status "repos/${owner}/$1/git/blobs" '{"content":"","encoding":"utf-8"}')" = 201 ]; }
can_open_pr() { [ "$(post_status "repos/${owner}/$1/pulls" '{"title":"probe","head":"no-such-branch","base":"main"}')" = 422 ]; }
hash_of() { printf %s "$1" | shasum -a 256 | cut -d' ' -f1; }

echo
echo "Checking the token..."
case "$choice" in
  1|2)
    can_push homelab-workspaces || { echo "FAIL: cannot push to homelab-workspaces. Wrong or expired token."; exit 1; }
    ;;
  3)
    can_push homelab || { echo "FAIL: cannot push to homelab. Wrong or expired token."; exit 1; }
    ;;
esac

# Pull request access is what tells the two homelab-workspaces tokens apart.
case "$choice" in
  1)
    if can_open_pr homelab-workspaces; then
      echo "WARN: this token can open pull requests. homelab-workspaces-deploy can, the Launchpad token should not."
      read -rp "Use it anyway? [y/N] " yn
      [ "$yn" = y ] || exit 1
    fi
    ;;
  2)
    can_open_pr homelab-workspaces || { echo "FAIL: cannot open pull requests. This is not homelab-workspaces-deploy."; exit 1; }
    current=$(kubectl get secret "$api_secret" -n "$api_ns" -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)
    if [ "$(hash_of "$token")" = "$(hash_of "$current")" ]; then
      echo "FAIL: this is the value Launchpad API uses. Pick option 1 for it."
      exit 1
    fi
    ;;
esac
echo "ok"

echo
if [ "$choice" = 1 ]; then
  patched_at=$(date -u +%s)
  printf '{"data":{"GITHUB_TOKEN":"%s"}}' "$(printf %s "$token" | base64)" \
    | kubectl patch secret "$api_secret" -n "$api_ns" --type merge --patch-file /dev/stdin
  unset token

  # kubelet refreshes the mounted file within about a minute, and guest cleanup calls GitHub every minute.
  echo "Waiting 90s for the pod to see the new file, then watching 65s of logs for a 401..."
  sleep 155
  since=$(date -u -r $((patched_at + 90)) +%Y-%m-%dT%H:%M:%SZ)
  fails=$(kubectl logs -n "$api_ns" "deploy/${api_deploy}" --since-time="$since" | grep -c "status 401" || true)
  if [ "$fails" = 0 ]; then
    echo "PASS: no GitHub 401 from ${api_deploy} since ${since}"
  else
    echo "FAIL: ${fails} GitHub 401s from ${api_deploy} since ${since}"
    exit 1
  fi
  exit 0
fi

failed=()
for repo in "${repos[@]}"; do
  echo -n "${owner}/${repo}: "
  # stdin keeps the token out of the process list.
  if printf %s "$token" | gh secret set "$secret" -R "${owner}/${repo}" >/dev/null; then
    echo ok
  else
    echo "FAILED, rerun this script to retry"
    failed+=("$repo")
  fi
done
unset token
[ "${#failed[@]}" = 0 ] || exit 1

# A rerun of a deploy that failed on the old token is the real test.
echo
echo "Rerunning the latest main run in repos where it failed..."
reran=()
for repo in "${repos[@]}"; do
  run=$(gh run list -R "${owner}/${repo}" --branch main --limit 1 --json databaseId,conclusion \
    --jq '.[] | select(.conclusion == "failure") | .databaseId')
  if [ -n "$run" ]; then
    gh run rerun "$run" --failed -R "${owner}/${repo}" >/dev/null
    reran+=("${repo}:${run}")
    echo "  ${repo}: rerunning ${run}"
  fi
done

if [ "${#reran[@]}" = 0 ]; then
  echo "None failed. The next push to main in any repo above is the test."
  exit 0
fi

result=0
for item in "${reran[@]}"; do
  repo=${item%%:*}
  run=${item##*:}
  if gh run watch "$run" -R "${owner}/${repo}" --exit-status >/dev/null 2>&1; then
    echo "PASS: ${repo}"
  else
    echo "FAIL: ${repo} https://github.com/${owner}/${repo}/actions/runs/${run}"
    result=1
  fi
done
exit "$result"
