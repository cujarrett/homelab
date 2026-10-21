#!/usr/bin/env bash
# Rotates the Launchpad API's GitHub PAT, checks the pasted value is the right
# token before writing it anywhere, then tests it where it lands.
#
# GitHub has no API to regenerate a fine-grained PAT, so that step stays in the browser.
set -euo pipefail

owner="cujarrett"
api_ns="launchpad"
api_secret="launchpad-github-token"
api_secret_id="platform/${api_ns}/${api_secret}"
api_deploy="launchpad-api"
name="homelab-workspaces-launchpad"

# Show what breaks before anything is regenerated, since regenerating kills the old value at once.
echo "Affected: ${api_deploy} in namespace ${api_ns}"
echo "  Launchpad's workspace list, sandbox creation and guest cleanup"

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

echo
echo "Checking the token..."
can_push homelab-workspaces || { echo "FAIL: cannot push to homelab-workspaces. Wrong or expired token."; exit 1; }
if can_open_pr homelab-workspaces; then
  echo "WARN: this token can open pull requests. The Launchpad token should not."
  read -rp "Use it anyway? [y/N] " yn
  [ "$yn" = y ] || exit 1
fi
echo "ok"

echo
want=$(printf %s "$token" | shasum -a 256 | cut -d' ' -f1)
printf %s "$token" | jq -Rc '{GITHUB_TOKEN: .}' \
  | aws secretsmanager put-secret-value --secret-id "$api_secret_id" --secret-string file:///dev/stdin >/dev/null
unset token

# The sidecar re-reads Secrets Manager within 15 minutes.
# Read through the sidecar, since the api image is distroless and has no cat.
echo "Waiting for the pod to see the new value (up to 16 minutes)..."
for _ in $(seq 1 96); do
  got=$(kubectl exec -n "$api_ns" "deploy/${api_deploy}" -c workload-identity-sidecar -- cat "/secrets/${api_secret}/GITHUB_TOKEN" | shasum -a 256 | cut -d' ' -f1)
  [ "$got" = "$want" ] && break
  sleep 10
done
[ "$got" = "$want" ] || { echo "FAIL: the pod still has the old value"; exit 1; }

# Guest cleanup calls GitHub every minute.
echo "Watching 65s of logs for a 401..."
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 65
fails=$(kubectl logs -n "$api_ns" "deploy/${api_deploy}" --since-time="$since" | grep -c "status 401" || true)
if [ "$fails" = 0 ]; then
  echo "PASS: no GitHub 401 from ${api_deploy} since ${since}"
else
  echo "FAIL: ${fails} GitHub 401s from ${api_deploy} since ${since}"
  exit 1
fi
