#!/usr/bin/env bash
#
# Public-cloud WorkflowSpace end-to-end test.
#
# Creates a real Temporal Cloud namespace and runs one order through it with the worker's SVID.
# Proves the spend switches, then deletes everything and turns the egress switch back off.
#
# Temporal Cloud has no spend cap, so nothing else runs this. e2e.sh does not call it.
#
# Usage:
#   ./platform/test/e2e-workflow-cloud.sh               # ~10 min, a real namespace and one order
#   ./platform/test/e2e-workflow-cloud.sh --time-limit  # also waits for the 2 hour policy, ~2h20m

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="platform-e2e"
WF="e2e-cloud-workflows"
API="e2e-cloud-worker"
MANIFEST="$SCRIPT_DIR/manifests/workflow-cloud.yaml"
ENTRY="$WF-workflow-space"
PORT=18080
TIME_LIMIT=false
FORWARD_PID=""

for arg in "$@"; do
  case "$arg" in
    --time-limit) TIME_LIMIT=true ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

REPORT_TITLE="PUBLIC-CLOUD WORKFLOW E2E REPORT"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

check() { # phase name command... -> PASS when the command exits 0
  local phase=$1 name=$2; shift 2
  if "$@" >/dev/null 2>&1; then record "$phase" "$name" PASS ""; else record "$phase" "$name" FAIL ""; fi
}

ready() { # kind name
  [[ "$(kubectl get "$1" "$2" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

gone() { # kind name
  ! kubectl get "$1" "$2" -n "$NS" >/dev/null 2>&1
}

exists() { # kind name
  kubectl get "$1" "$2" -n "$NS" >/dev/null 2>&1
}

set_egress() { # true or false
  kubectl patch environmentconfig aws-platform-config --type=merge -p "{\"data\":{\"temporalCloudEnabled\":\"$1\"}}" >/dev/null
}

egress_value() {
  kubectl get environmentconfig aws-platform-config -o jsonpath='{.data.temporalCloudEnabled}' 2>/dev/null
}

available() {
  [[ "$(kubectl get deployment "$API" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ]]
}

env_has() { # var
  kubectl get deployment "$API" -n "$NS" -o jsonpath='{.spec.template.spec.containers[*].env[*].name}' | tr ' ' '\n' | grep -qx "$1"
}

no_env() { # var
  ! env_has "$1"
}

worker_is_retrying() {
  kubectl logs "deployment/$API" -n "$NS" -c api --tail=50 2>/dev/null | grep -q "cannot reach Temporal yet"
}

order_done() { # order id
  curl -sf "http://localhost:$PORT/orders/$1" | grep -q '"done":true'
}

# Runs on every exit, including Ctrl-C and a failed check.
# Spend stops here first. The Kyverno time limit is the backstop if this never runs.
cleanup() {
  [[ -n "$FORWARD_PID" ]] && kill "$FORWARD_PID" 2>/dev/null
  set_egress false
  kubectl delete -f "$MANIFEST" --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "== Phase 0: preflight"
if [[ -n "$(kubectl get pods -n temporal-controller -l app=temporal-controller --field-selector=status.phase=Running --no-headers 2>/dev/null)" ]]; then
  record preflight "temporal-controller running" PASS ""
else
  record preflight "temporal-controller running" FAIL "no Running pods"
fi
check preflight "platform key synced" kubectl get secret temporal-cloud-api-key -n temporal-controller
if [[ "$(egress_value)" == "true" ]]; then
  record preflight "egress switch starts off" FAIL "temporalCloudEnabled is already true"
else
  record preflight "egress switch starts off" PASS ""
fi
if kubectl get namespace "$NS" >/dev/null 2>&1; then
  record preflight "namespace free" FAIL "$NS already exists - is another e2e running?"
else
  record preflight "namespace free" PASS ""
fi
if (( FAILURES > 0 )); then
  # Nothing here is ours yet, so leave the switch and any other run alone.
  trap - EXIT
  report; exit 1
fi

# ---------------------------------------------------------------------------
echo "== Phase 1: allowlist"
DENIED=$(kubectl apply --dry-run=server -f - 2>&1 <<YAML
apiVersion: platform.local.lab/v1alpha1
kind: WorkflowSpace
metadata:
  name: e2e-denied
  namespace: default
spec:
  parameters:
    backend: public-cloud
YAML
)
if grep -q "turned off" <<< "$DENIED"; then
  record allowlist "refused outside $NS" PASS ""
else
  record allowlist "refused outside $NS" FAIL "$DENIED"
fi

# ---------------------------------------------------------------------------
echo "== Phase 2: egress switch off"
kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" platform.local.lab/workloads=true istio-injection=enabled >/dev/null
kubectl apply -f "$MANIFEST" >/dev/null

if wait_until 600 ready workflowspaces.platform.local.lab "$WF"; then
  record egress-off "Temporal Cloud namespace Ready" PASS ""
else
  record egress-off "Temporal Cloud namespace Ready" FAIL "timeout 600s"
fi
check egress-off "connection ConfigMap written" exists configmap "$ENTRY"
check egress-off "no ServiceEntry" gone serviceentries.networking.istio.io "$ENTRY"
if wait_until 300 worker_is_retrying; then
  record egress-off "worker can't connect" PASS ""
else
  record egress-off "worker can't connect" FAIL "no retry line in the worker log after 300s"
fi
if available; then record egress-off "worker not Available" FAIL ""; else record egress-off "worker not Available" PASS ""; fi

# ---------------------------------------------------------------------------
echo "== Phase 3: egress switch on"
set_egress true
if wait_until 180 exists serviceentries.networking.istio.io "$ENTRY"; then
  record egress-on "ServiceEntry rendered" PASS ""
else
  record egress-on "ServiceEntry rendered" FAIL "timeout 180s"
fi
if wait_until 300 available; then
  record egress-on "worker signed in" PASS ""
else
  record egress-on "worker signed in" FAIL "timeout 300s"
fi

check contract "env TEMPORAL_TLS_CERT injected" env_has TEMPORAL_TLS_CERT
check contract "env TEMPORAL_TLS_KEY injected" env_has TEMPORAL_TLS_KEY
check contract "no Entra token scope" no_env TEMPORAL_TOKEN_SCOPE
check contract "no Entra role grant" gone roleassignments.app.azuread.m.upbound.io "$NS-$API-temporal-grant"
check contract "no Entra app role" gone approles.applications.azuread.m.upbound.io "$NS-$WF-temporal-writer"

kubectl port-forward "deployment/$API" -n "$NS" "$PORT:8080" >/dev/null 2>&1 &
FORWARD_PID=$!
sleep 3
ORDER=$(curl -sf -X POST "http://localhost:$PORT/orders" | sed -E 's/.*"id":"([^"]+)".*/\1/')
if [[ -n "$ORDER" ]] && wait_until 180 order_done "$ORDER"; then
  record contract "order finishes on Temporal Cloud" PASS ""
else
  record contract "order finishes on Temporal Cloud" FAIL "order '${ORDER:-not started}' not done after 180s"
fi
kill "$FORWARD_PID" 2>/dev/null
FORWARD_PID=""

# ---------------------------------------------------------------------------
if $TIME_LIMIT; then
  echo "== Phase 4: time limit (waits up to 2h20m with egress off)"
  set_egress false
  kubectl delete apis.platform.local.lab "$API" -n "$NS" >/dev/null 2>&1
  if wait_until 8400 gone workflowspaces.platform.local.lab "$WF"; then
    record time-limit "policy deleted the WorkflowSpace" PASS ""
  else
    record time-limit "policy deleted the WorkflowSpace" FAIL "still there after 2h20m"
  fi
fi

# ---------------------------------------------------------------------------
echo "== Phase 5: teardown"
set_egress false
kubectl delete -f "$MANIFEST" --ignore-not-found --wait=false >/dev/null 2>&1
if wait_until 300 gone apis.platform.local.lab "$API"; then record teardown "Api deleted" PASS ""; else record teardown "Api deleted" FAIL "timeout 300s"; fi
# temporal-controller's finalizer holds these until Temporal Cloud finishes deleting the namespace.
if wait_until 900 gone workflowspaces.platform.local.lab "$WF" && wait_until 900 gone temporalnamespaces.temporal.local.lab "$WF"; then
  record teardown "Temporal Cloud namespace gone" PASS ""
else
  record teardown "Temporal Cloud namespace gone" FAIL "timeout 900s"
fi
check teardown "ServiceEntry gone" gone serviceentries.networking.istio.io "$ENTRY"
kubectl delete namespace "$NS" >/dev/null 2>&1
if wait_until 300 gone namespace "$NS"; then record teardown "namespace terminated" PASS ""; else record teardown "namespace terminated" FAIL "stuck terminating"; fi
if [[ "$(egress_value)" == "false" ]]; then record teardown "egress switch off" PASS ""; else record teardown "egress switch off" FAIL ""; fi

report
exit $(( FAILURES > 0 ? 1 : 0 ))
