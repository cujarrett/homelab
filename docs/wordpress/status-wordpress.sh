#!/usr/bin/env bash
# Reports WordPress version drift across every homelab WordPress instance.
#
# Four versions matter and they drift apart independently:
#   running  what is serving traffic right now
#   pinned   what a pod restart would land on
#   image    newest published image, i.e. what the pin could become
#   release  newest WordPress release, i.e. the security floor
#
# Core lives in the container filesystem, not the wp-content PVC, so a version
# WordPress applied to itself is lost on restart. That is why running and pinned
# are reported separately -- a site can serve the latest release and still be one
# restart away from a vulnerable version.
#
# Usage: ./docs/wordpress/status-wordpress.sh
set -uo pipefail

SITES=(mattjarrett-com kentjarrett-com)

# The composition is the source of truth for the image variant, so read it rather
# than restating it here -- a second copy only ever drifts and then this script
# reports upgrades that do not apply.
COMPOSITION="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/platform/wordpress/composition.yaml"
[ -f "$COMPOSITION" ] || { echo "cannot find $COMPOSITION" >&2; exit 1; }

# The init container and the app container must run the same image. If they ever
# disagree the pin is already broken, and guessing which one is right would hide it.
variants=$(grep -oE 'image: wordpress:[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9.-]+' "$COMPOSITION" \
  | sed 's/.*wordpress:[0-9]*\.[0-9]*\.[0-9]*-//' | sort -u)
case $(printf '%s' "$variants" | grep -c .) in
  1) VARIANT="$variants" ;;
  0) echo "no pinned wordpress image found in $COMPOSITION" >&2; exit 1 ;;
  *) echo "composition pins more than one variant: $(echo "$variants" | tr '\n' ' ')" >&2; exit 1 ;;
esac

for cmd in kubectl curl jq; do
  command -v "$cmd" >/dev/null || { echo "missing required command: $cmd" >&2; exit 1; }
done

release=$(curl -s https://api.wordpress.org/core/version-check/1.7/ | jq -r '.offers[0].current')
image=$(curl -s "https://hub.docker.com/v2/repositories/library/wordpress/tags?page_size=100&name=${VARIANT}&ordering=last_updated" \
  | jq -r --arg v "$VARIANT" \
    '[.results[] | select(.name | endswith("-" + $v)) | select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+-"))][0].name // "none"')
image_ver=${image%%-*}

echo "latest release : $release"
if [ "$image_ver" = "$release" ]; then
  echo "latest image   : $image  ✅ pin can move to $release"
else
  echo "latest image   : $image  ⏳ upstream has not built $release yet"
fi
echo

for ns in "${SITES[@]}"; do
  pod=$(kubectl get pod -n "$ns" -o name 2>/dev/null | grep wordpress | head -1)
  if [ -z "$pod" ]; then printf '%-18s no wordpress pod\n' "$ns"; continue; fi

  running=$(kubectl exec -n "$ns" "$pod" -- sh -c \
    'grep -h "wp_version =" /var/www/html/wp-includes/version.php' 2>/dev/null \
    | sed "s/.*'\(.*\)'.*/\1/")
  pinned=$(kubectl get deploy -n "$ns" \
    -o jsonpath='{.items[?(@.spec.template.spec.containers[0].name=="wordpress")].spec.template.spec.containers[0].image}' 2>/dev/null)
  pinned_ver=${pinned#*:}; pinned_ver=${pinned_ver%%-*}

  [ "$running" = "$release" ] && mark="✅" || mark="⚠️  update available ($release)"
  printf '%-18s running %-8s %s\n' "$ns" "$running" "$mark"

  if [ "$pinned_ver" != "$running" ]; then
    printf '%-18s   ↳ restart would drop to %s (image %s)\n' "" "$pinned_ver" "$pinned"
  fi
done
