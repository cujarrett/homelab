#!/usr/bin/env bash
# Render every workspace XR against the current compositions and check the result is
# sane. Runs from anywhere; needs Docker running.
#
# Usage:
#   just render-check                      # from platform/
#   ./platform/test/render-check.sh        # from anywhere
#
# Five gates, each catching a class of bug that reached the cluster at least once:
#   1. schema  - server-side dry-run catches invalid CRD schemas Kubernetes would
#                otherwise silently refuse, leaving the CRD at its old generation.
#   2. render  - crossplane render exits 0.
#   3. parse   - output is valid YAML and every list is a list; render can exit 0
#                even when whitespace trimming collapsed a block sequence to a string.
#   4. diff    - compares against HEAD for both the XR and the composition, so a
#                shared-composition edit and a lone XR edit are each caught.
#   5. rbac    - every composed kind is granted in cluster/crossplane/rbac.yaml, or
#                it renders fine but the API server refuses it - XR stays READY=True
#                while SYNCED=False, so nothing looks wrong.
#   6. xr      - every XR field exists in its XRD. crossplane render ignores an
#                undeclared field and the API server then refuses the same file.
#   7. namespace - every workspace directory carries a namespace.yaml with the mesh
#                and Pod Security labels. Without one, CreateNamespace=true makes a
#                bare namespace and pods there run unmeshed.
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
    ManagedSecret) echo managed-secret ;;
    *) echo "" ;;
  esac
}

# --- 1. XRD schemas -----------------------------------------------------------
# A server-side dry-run accepts the XRD even when Crossplane's later CRD
# generation from it fails silently, so check the invariants directly.
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

# Skips groups Crossplane grants itself elsewhere - composite roles for XRs, each
# provider's own edit role otherwise. Matching the whole upbound.io suffix covers
# both cluster-scoped and namespaced .m. groups, so a new provider needs no edit here.
def skip(group):
    return group == 'platform.local.lab' or group.endswith('upbound.io')

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

# --- 6. XR fields against the XRD ---------------------------------------------
# crossplane render passes an undeclared field straight through, so a typo renders
# clean and the API server then refuses it with "field not declared in schema".
echo "── xr"
if out=$(python3 - "$WORKSPACES" <<'PY'
import sys, pathlib, yaml

KIND_DIR = {"Api": "api", "Spa": "spa", "Cache": "cache", "Sql": "sql", "NoSql": "nosql",
            "ObjectStorage": "object-storage", "Subscription": "subscription",
            "Topic": "topic", "Wordpress": "wordpress"}

def params_schema(xrd_path):
    v = yaml.safe_load(open(xrd_path))["spec"]["versions"][0]
    props = v["schema"]["openAPIV3Schema"]["properties"]
    return props["spec"]["properties"]["parameters"]

def check(value, schema, path, bad):
    if not isinstance(value, dict) or schema.get("type") not in (None, "object"):
        return
    props = schema.get("properties", {})
    if not props:
        return
    for k, v in value.items():
        if k not in props:
            bad.append(f"{path}.{k}")
            continue
        sub = props[k]
        if sub.get("type") == "array" and isinstance(v, list):
            for i, item in enumerate(v):
                check(item, sub.get("items", {}), f"{path}.{k}[{i}]", bad)
        else:
            check(v, sub, f"{path}.{k}", bad)

bad = []
for xr in sorted(pathlib.Path(sys.argv[1]).glob("*/*.yaml")):
    try:
        doc = yaml.safe_load(open(xr))
    except Exception:
        continue
    if not isinstance(doc, dict) or doc.get("kind") not in KIND_DIR:
        continue
    schema = params_schema(f"platform/{KIND_DIR[doc['kind']]}/xrd.yaml")
    local = []
    check((doc.get("spec") or {}).get("parameters") or {}, schema, "spec.parameters", local)
    for b in local:
        bad.append(f"{xr.parent.name}/{xr.stem}: {b} is not declared in the {doc['kind']} XRD")

if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
); then
  grn "   ok  every XR field is declared"
else
  red "   FAIL an XR sets a field its XRD does not declare"
  echo "$out" | sed 's/^/        /'
  echo "        crossplane render ignores these; the API server refuses them."
  fail=1
fi

# --- 7. workspace namespaces --------------------------------------------------
# CreateNamespace=true makes a namespace with no labels, so a directory without a
# namespace.yaml gets pods with no sidecar and no Pod Security enforcement.
echo "── namespace"
ns_fail=0
for d in "$WORKSPACES"/*/; do
  wsname=$(basename "$d")
  [ "$wsname" = ".github" ] && continue
  ls "$d"*.yaml >/dev/null 2>&1 || continue
  if ! out=$(python3 - "$d" "$wsname" <<'PY'
import sys, pathlib, yaml
d, name = pathlib.Path(sys.argv[1]), sys.argv[2]
# enforce may be baseline where an image cannot meet restricted, but warn and audit
# stay restricted so the gap is visible rather than forgotten.
required = {"pod-security.kubernetes.io/warn": "restricted",
            "pod-security.kubernetes.io/audit": "restricted",
            "platform.local.lab/workloads": "true"}
for f in sorted(d.glob("*.yaml")):
    try:
        docs = [x for x in yaml.safe_load_all(open(f)) if isinstance(x, dict)]
    except Exception:
        continue
    for doc in docs:
        if doc.get("kind") != "Namespace":
            continue
        labels = (doc.get("metadata") or {}).get("labels") or {}
        missing = [k for k, v in required.items() if labels.get(k) != v]
        if labels.get("pod-security.kubernetes.io/enforce") not in ("restricted", "baseline"):
            missing.append("pod-security.kubernetes.io/enforce (restricted or baseline)")
        if labels.get("istio-injection") not in ("enabled", "disabled"):
            missing.append("istio-injection (enabled, or disabled to declare the exception)")
        if missing:
            print(f"{f.name}: missing " + ", ".join(missing))
            sys.exit(1)
        sys.exit(0)
print(f"no namespace.yaml - CreateNamespace=true will make a bare {name} namespace")
sys.exit(1)
PY
  ); then
    red "   FAIL $wsname"; echo "$out" | sed 's/^/        /'; ns_fail=1; fail=1
  fi
done
[ "$ns_fail" -eq 0 ] && grn "   ok  every workspace namespace is labelled"

echo
[ "$fail" -eq 0 ] && grn "render-check passed" || red "render-check FAILED"
exit $fail
