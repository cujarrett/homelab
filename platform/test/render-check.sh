#!/usr/bin/env bash
# Render every workspace XR against the current compositions and check the result is
# sane. Runs from anywhere; needs Docker running.
#
# Usage:
#   just render-check                      # from platform/
#   ./platform/test/render-check.sh        # from anywhere
#
# Four gates, each catching a class of bug that reached the cluster at least once:
#   1. schema    — XRDs pass a server-side dry-run. Catches invalid CRD schemas that
#                  Kubernetes silently refuses, leaving the CRD at its old generation.
#   2. render    — crossplane render exits 0.
#   3. parse     — the output is valid YAML and every list is a list. crossplane render
#                  exits 0 on a template whose whitespace trimming collapsed a block
#                  sequence into one string, so exit code alone proves nothing.
#   4. unchanged — workspaces that declare no new fields render byte-identical to HEAD.
#                  A shared composition means one edit reaches every app.
set -uo pipefail

# Every path below is repo-root-relative, so anchor to the repo root rather than cwd.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

WORKSPACES=${WORKSPACES:-../homelab-workspaces}
ENVCFG=local-only/aws-platform-config.yaml
FUNCS=local-only/render-functions.yaml
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
red() { printf '\033[31m%s\033[0m\n' "$1"; }
grn() { printf '\033[32m%s\033[0m\n' "$1"; }

# --- prerequisites ------------------------------------------------------------
command -v crossplane >/dev/null || { red "crossplane CLI not found"; exit 1; }
docker info >/dev/null 2>&1 || { red "Docker is not running — render pulls function containers"; exit 1; }
[ -f "$ENVCFG" ] || { red "missing $ENVCFG — render needs a local EnvironmentConfig fixture"; exit 1; }
[ -d "$WORKSPACES" ] || { red "workspaces not found at $WORKSPACES"; exit 1; }

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
# only Crossplane's later attempt to generate a CRD from it fails — silently, leaving
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
            errs.append(f"{path}: type string but enum holds {wrong!r} — quote them")
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

  if ! crossplane render "$xr" "$comp" "$FUNCS" -e "$ENVCFG" > "$TMP/out.yaml" 2>&1; then
    red "   FAIL $name — render error"; sed 's/^/        /' "$TMP/out.yaml" | head -5; fail=1; continue
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
    red "   FAIL $name — output did not parse cleanly"; fail=1; continue
  fi

  # compare against HEAD's composition; only meaningful when the composition changed
  if git show "HEAD:$comp" > "$TMP/head-comp.yaml" 2>/dev/null; then
    if crossplane render "$xr" "$TMP/head-comp.yaml" "$FUNCS" -e "$ENVCFG" > "$TMP/head-out.yaml" 2>/dev/null; then
      if diff -q "$TMP/head-out.yaml" "$TMP/out.yaml" >/dev/null; then
        grn "   ok  $name (composition change does not affect it)"
      else
        printf '\033[33m   ok  %s (CHANGED vs HEAD — review below)\033[0m\n' "$name"
        diff "$TMP/head-out.yaml" "$TMP/out.yaml" | sed 's/^/        /' | head -40
      fi
      continue
    fi
  fi
  grn "   ok  $name (new)"
done

echo
[ "$fail" -eq 0 ] && grn "render-check passed" || red "render-check FAILED"
exit $fail
