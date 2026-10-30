#!/usr/bin/env bash
#
# Workflow end-to-end test.
#
# Inflates a Workflow and an Api that references it, checks every piece the platform
# composes for them, tears both down, and checks nothing was left in Temporal or Entra.
#
# Usage:
#   ./platform/test/e2e-workflow.sh         # ~3 min, in-cluster plus Entra, free
#   ./platform/test/e2e-workflow.sh --keep  # skip teardown, leave resources for debugging
#
# e2e.sh runs this too, so the full suite covers it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="platform-e2e-workflow"
WF="e2e-workflows"
API="e2e-worker"
KEEP=false

for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=true ;;
    --private-only) ;; # passed through by e2e.sh. This suite never touches AWS.
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

REPORT_TITLE="WORKFLOW E2E REPORT"
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

# Temporal's own record, read from its database. A deleted namespace is renamed, so
# an exact-name match means it still exists.
in_temporal() {
  [[ "$(kubectl exec -n temporal temporal-postgres-0 -- psql -U temporal -d temporal -tAc \
    "select count(*) from namespaces where name = '$WF'" 2>/dev/null)" == "1" ]]
}
not_in_temporal() { ! in_temporal; }

env_has() { # var
  kubectl get deployment "$API" -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep -qx "$1"
}

# ---------------------------------------------------------------------------
echo "== Phase 0: preflight"
for check in "temporal-controller:temporal-controller:app=temporal-controller" "temporal-frontend:temporal:app.kubernetes.io/component=frontend"; do
  IFS=':' read -r label ns selector <<< "$check"
  if [[ -n "$(kubectl get pods -n "$ns" -l "$selector" --field-selector=status.phase=Running --no-headers 2>/dev/null)" ]]; then
    record preflight "$label running" PASS ""
  else
    record preflight "$label running" FAIL "no Running pods matching $selector in $ns"
  fi
done
SP=$(kubectl get environmentconfig aws-platform-config -o jsonpath='{.data.temporalEntraSpObjectId}' 2>/dev/null)
if [[ -n "$SP" && "$SP" != 00000000-* ]]; then
  record preflight "Temporal Entra IDs configured" PASS ""
else
  record preflight "Temporal Entra IDs configured" FAIL "temporalEntraSpObjectId missing from aws-platform-config"
fi
if kubectl get namespace "$NS" >/dev/null 2>&1; then
  record preflight "namespace free" FAIL "$NS already exists - previous run not cleaned up?"
  report; exit 1
fi
record preflight "namespace free" PASS ""
(( FAILURES > 0 )) && { report; exit 1; }

# ---------------------------------------------------------------------------
echo "== Phase 1: inflate"
# The workloads label is what lets the Api's pods past the temporal NetworkPolicy.
kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" platform.local.lab/workloads=true istio-injection=enabled >/dev/null
kubectl apply -f "$SCRIPT_DIR/manifests/workflow.yaml" >/dev/null

if wait_until 180 ready workflows.platform.local.lab "$WF"; then record inflate "workflow/$WF Ready" PASS ""; else record inflate "workflow/$WF Ready" FAIL "timeout 180s"; fi
if wait_until 600 ready apis.platform.local.lab "$API"; then record inflate "api/$API Ready" PASS ""; else record inflate "api/$API Ready" FAIL "timeout 600s"; fi
if kubectl wait deployment "$API" -n "$NS" --for=condition=Available --timeout=300s >/dev/null 2>&1; then
  record inflate "worker pod Available" PASS ""
else
  record inflate "worker pod Available" FAIL "timeout 300s"
fi

# ---------------------------------------------------------------------------
echo "== Phase 2: contract checks"
check contract "Temporal namespace exists in Temporal" in_temporal
check contract "Entra app role Ready" ready approles.applications.azuread.m.upbound.io "$NS-$WF-temporal-writer"
if wait_until 180 ready roleassignments.app.azuread.m.upbound.io "$NS-$API-temporal-grant"; then
  record contract "Entra role granted to the Api" PASS ""
else
  record contract "Entra role granted to the Api" FAIL "timeout 180s"
fi
for var in TEMPORAL_ADDRESS TEMPORAL_NAMESPACE TEMPORAL_TOKEN_SCOPE; do
  check contract "env $var injected" env_has "$var"
done
check contract "pods labelled uses-workflow" test "$(kubectl get deployment "$API" -n "$NS" -o jsonpath='{.spec.template.metadata.labels.platform\.local\.lab/uses-workflow}')" = true
check contract "egress allows the frontend" bash -c "kubectl get sidecar -n $NS -o yaml | grep -q temporal-frontend.temporal.svc.cluster.local"

# ---------------------------------------------------------------------------
if $KEEP; then
  echo "== Phase 3: SKIPPED (--keep). Tear down manually with:"
  echo "   kubectl delete -f $SCRIPT_DIR/manifests/workflow.yaml && kubectl delete namespace $NS"
  report; exit $(( FAILURES > 0 ? 1 : 0 ))
fi

echo "== Phase 3: teardown"
kubectl delete -f "$SCRIPT_DIR/manifests/workflow.yaml" --wait=false >/dev/null 2>&1
if wait_until 300 gone apis.platform.local.lab "$API" && wait_until 300 gone workflows.platform.local.lab "$WF"; then
  record teardown "XRs deleted" PASS ""
else
  record teardown "XRs deleted" FAIL "timeout 300s"
fi
if wait_until 180 not_in_temporal; then record teardown "Temporal namespace gone" PASS ""; else record teardown "Temporal namespace gone" FAIL "still in Temporal after 180s"; fi
# The provider deletes each object in Entra before it releases the finalizer, so gone here means gone there.
if wait_until 180 gone approles.applications.azuread.m.upbound.io "$NS-$WF-temporal-writer"; then record teardown "Entra app role gone" PASS ""; else record teardown "Entra app role gone" FAIL "timeout 180s"; fi
if wait_until 180 gone roleassignments.app.azuread.m.upbound.io "$NS-$API-temporal-grant"; then record teardown "Entra role grant gone" PASS ""; else record teardown "Entra role grant gone" FAIL "timeout 180s"; fi
kubectl delete namespace "$NS" >/dev/null 2>&1
if wait_until 300 gone namespace "$NS"; then record teardown "namespace terminated" PASS ""; else record teardown "namespace terminated" FAIL "stuck terminating"; fi

report
exit $(( FAILURES > 0 ? 1 : 0 ))
