#!/usr/bin/env bash
# Render every workspace XR against the current compositions and check the result is
# sane. Runs from anywhere; needs Docker running.
#
# Usage:
#   just render-check                      # from platform/
#   ./platform/test/render-check.sh        # from anywhere
#
# Five gates, each catching a class of bug that reached the cluster at least once:
#   1. schema    - XRDs pass a server-side dry-run. Catches invalid CRD schemas that
#                  Kubernetes silently refuses, leaving the CRD at its old generation.
#   2. render    - crossplane render exits 0.
#   3. parse     - the output is valid YAML and every list is a list. crossplane render
#                  exits 0 on a template whose whitespace trimming collapsed a block
#                  sequence into one string, so exit code alone proves nothing.
#   4. diff      - two comparisons against HEAD, one per repo. Holding the XR still
#                  shows what a composition edit does to every app, since a shared
#                  composition means one edit reaches all of them. Holding the
#                  composition still shows what your own XR edit did, which catches an
#                  edit the XRD silently dropped.
#   5. rbac      - every composed kind is granted in cluster/crossplane/rbac.yaml.
#                  Crossplane composes with its own ServiceAccount, so a kind the
#                  platform has never composed before renders perfectly and is then
#                  refused by the API server. The XR goes SYNCED=False while staying
#                  READY=True, so the app keeps serving and nothing looks wrong.
set -uo pipefail

# Every path below is repo-root-relative, so anchor to the repo root rather than cwd.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

WORKSPACES=${WORKSPACES:-../homelab-workspaces}
ENVCFG=platform/test/fixtures/aws-platform-config.yaml
FUNCS=platform/test/fixtures/render-functions.yaml
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
red() { printf '\033[31m%s\033[0m\n' "$1"; }
grn() { printf '\033[32m%s\033[0m\n' "$1"; }

# --- prerequisites ------------------------------------------------------------
command -v crossplane >/dev/null || { red "crossplane CLI not found"; exit 1; }
docker info >/dev/null 2>&1 || { red "Docker is not running - render pulls function containers"; exit 1; }
[ -f "$ENVCFG" ] || { red "missing $ENVCFG - render needs a local EnvironmentConfig fixture"; exit 1; }
[ -d "$WORKSPACES" ] || { red "workspaces not found at $WORKSPACES"; exit 1; }
git -C "$WORKSPACES" rev-parse --git-dir >/dev/null 2>&1 && WS_GIT=1 || WS_GIT=0
[ "$WS_GIT" -eq 1 ] || echo "   note: $WORKSPACES is not a git checkout - skipping the XR-edit comparison"

# kind -> platform directory
comp_for() {
  case "$1" in
    Api) echo api ;; Spa) echo spa ;; Cache) echo cache ;; Sql) echo sql ;;
    NoSql) echo nosql ;; ObjectStorage) echo object-storage ;;
    Subscription) echo subscription ;; Topic) echo topic ;; Wordpress) echo wordpress ;;
    *) echo "" ;;
  esac
}

# --- 1. XRD schemas -----------------------------------------------------------
# A server-side dry-run does NOT catch this class of bug: the XRD is accepted, and
# only Crossplane's later attempt to generate a CRD from it fails - silently, leaving
# the CRD at its previous generation. So check the invariants directly.
echo "── schema"
for xrd in platform/*/xrd.yaml; do
  if out=$(python3 - "$xrd" <<'PY'
import sys, yaml
errs = []
def walk(node, path):
    if not isinstance(node, dict):
        return
    enum, typ, dflt = node.get('enum'), node.get('type'), node.get('default')
    if enum is not None:
        # Unquoted off/on/yes/no in YAML become booleans. A string field then carries a
        # bool in its enum, the CRD is rejected, and nothing surfaces the reason.
        wrong = [v for v in enum if typ == 'string' and not isinstance(v, str)]
        if wrong:
            errs.append(f"{path}: type string but enum holds {wrong!r} - quote them")
        if dflt is not None and dflt not in enum:
            errs.append(f"{path}: default {dflt!r} is not one of enum {enum!r}")
    for key in ('properties', 'items'):
        sub = node.get(key)
        if isinstance(sub, dict):
            if key == 'properties':
                for k, v in sub.items(): walk(v, f"{path}.{k}")
            else:
                walk(sub, f"{path}[]")
d = yaml.safe_load(open(sys.argv[1]))
for v in d.get('spec', {}).get('versions', []):
    walk(v.get('schema', {}).get('openAPIV3Schema', {}), v.get('name', '?'))
if errs:
    print("\n".join(errs)); sys.exit(1)
PY
  ); then
    grn "   ok  $xrd"
  else
    red "   FAIL $xrd"; echo "$out" | sed 's/^/        /'; fail=1
  fi
done

# --- 2/3/4. render, parse, compare -------------------------------------------
echo "── render"
for xr in "$WORKSPACES"/*/*.yaml; do
  kind=$(grep -m1 '^kind:' "$xr" 2>/dev/null | awk '{print $2}')
  dir=$(comp_for "$kind")
  [ -z "$dir" ] && continue
  comp="platform/$dir/composition.yaml"
  name="$(basename "$(dirname "$xr")")/$(basename "$xr" .yaml)"

  # stderr goes to its own file. Merging it corrupts the YAML this gate then parses, and
  # Docker Desktop warns on stderr for reasons that have nothing to do with the render.
  if ! crossplane render "$xr" "$comp" "$FUNCS" -e "$ENVCFG" > "$TMP/out.yaml" 2>"$TMP/err.txt"; then
    red "   FAIL $name - render error"; sed 's/^/        /' "$TMP/err.txt" | head -5; fail=1; continue
  fi

  # parse: valid YAML, and no list that collapsed into a string
  if ! python3 - "$TMP/out.yaml" <<'PY'
import sys, yaml
bad = []
def walk(node, path):
    if isinstance(node, dict):
        for k, v in node.items(): walk(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node): walk(v, f"{path}[{i}]")
    elif isinstance(node, str) and ('\n- ' in node or node.lstrip().startswith('- ')):
        bad.append(path)          # a block sequence that got flattened into one string
try:
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
except Exception as e:
    print(f"invalid YAML: {e}"); sys.exit(1)
for d in docs:
    walk(d, d.get('kind', '?'))
if bad:
    print("collapsed list at: " + ", ".join(bad)); sys.exit(1)
PY
  then
    red "   FAIL $name - output did not parse cleanly"; fail=1; continue
  fi

  # keep every rendered doc for the rbac gate; the leading --- keeps the last doc of
  # one workspace from merging into the first doc of the next
  { echo '---'; cat "$TMP/out.yaml"; } >> "$TMP/all-rendered.yaml"

  # Hold the composition at HEAD and the XR at its working copy - isolates what a
  # composition edit does to an app, including apps you did not mean to touch.
  if git show "HEAD:$comp" > "$TMP/head-comp.yaml" 2>/dev/null \
     && crossplane render "$xr" "$TMP/head-comp.yaml" "$FUNCS" -e "$ENVCFG" > "$TMP/head-out.yaml" 2>/dev/null; then
    if diff -q "$TMP/head-out.yaml" "$TMP/out.yaml" >/dev/null; then
      grn "   ok  $name (composition change does not affect it)"
    else
      printf '\033[33m   ok  %s (CHANGED vs HEAD - review below)\033[0m\n' "$name"
      diff "$TMP/head-out.yaml" "$TMP/out.yaml" | sed 's/^/        /' | head -40
    fi
  else
    grn "   ok  $name (new)"
  fi

  # Now the mirror image - hold the composition at the working copy and the XR at
  # HEAD, which isolates your own XR edit. Skipped unless you actually edited this
  # XR, so on a normal composition-only run it costs nothing.
  [ "$WS_GIT" -eq 1 ] || continue
  xr_rel="${xr#"$WORKSPACES"/}"
  # HEAD first - an untracked XR shows no diff against HEAD, so asking about the diff
  # ahead of existence would classify a brand-new file as unchanged.
  if ! git -C "$WORKSPACES" show "HEAD:$xr_rel" > "$TMP/head-xr.yaml" 2>/dev/null; then
    grn "       xr is new - nothing at HEAD to compare against"
    continue
  fi
  git -C "$WORKSPACES" diff --quiet HEAD -- "$xr_rel" 2>/dev/null && continue
  if ! crossplane render "$TMP/head-xr.yaml" "$comp" "$FUNCS" -e "$ENVCFG" > "$TMP/head-xr-out.yaml" 2>/dev/null; then
    printf '\033[33m       xr edited - HEAD version no longer renders, so no comparison\033[0m\n'
    continue
  fi
  if diff -q "$TMP/head-xr-out.yaml" "$TMP/out.yaml" >/dev/null; then
    # A field the XRD does not declare is dropped in silence, so an edit that renders
    # to nothing is the signal that you misspelled one.
    printf '\033[33m       xr edited but the output is identical - did the edit take effect?\033[0m\n'
  else
    printf '\033[33m       xr edit renders as - review below\033[0m\n'
    diff "$TMP/head-xr-out.yaml" "$TMP/out.yaml" | sed 's/^/        /' | head -40
  fi
done

# --- 5. RBAC coverage ---------------------------------------------------------
echo "── rbac"
if [ -s "$TMP/all-rendered.yaml" ]; then
  if out=$(python3 - "$TMP/all-rendered.yaml" cluster/crossplane/rbac.yaml <<'PY'
import sys, yaml

# Groups Crossplane grants itself elsewhere: the XRs are covered by the generated
# composite roles, and provider-managed resources (AWS, Azure AD) by each
# provider's own edit role.
def skip(group):
    return group == 'platform.local.lab' or group.endswith('aws.upbound.io') or group.endswith('azuread.upbound.io')

def plural(kind):
    k = kind.lower()
    if k.endswith('y'):  return k[:-1] + 'ies'
    if k.endswith('s'):  return k + 'es'
    return k + 's'

granted = set()
for doc in yaml.safe_load_all(open(sys.argv[2])):
    if not doc or doc.get('kind') != 'ClusterRole':
        continue
    for rule in doc.get('rules') or []:
        for g in rule.get('apiGroups') or []:
            for r in rule.get('resources') or []:
                granted.add((g, r))

missing = {}
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc or 'kind' not in doc:
        continue
    av = doc.get('apiVersion', '')
    group = av.split('/')[0] if '/' in av else ''
    if skip(group):
        continue
    res = plural(doc['kind'])
    if (group, res) in granted or ('*', res) in granted or (group, '*') in granted:
        continue
    missing[(group, res)] = doc['kind']

if missing:
    for (g, r), kind in sorted(missing.items()):
        print(f"{kind} ({g or 'core'}/{r}) is composed but not granted")
    sys.exit(1)
PY
  ); then
    grn "   ok  every composed kind is granted"
  else
    red "   FAIL cluster/crossplane/rbac.yaml is missing grants"
    echo "$out" | sed 's/^/        /'
    echo "        Crossplane will render these fine and the API server will refuse them."
    fail=1
  fi
else
  red "   FAIL nothing rendered - cannot check rbac coverage"; fail=1
fi

echo
[ "$fail" -eq 0 ] && grn "render-check passed" || red "render-check FAILED"
exit $fail
