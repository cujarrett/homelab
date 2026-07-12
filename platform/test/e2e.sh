#!/usr/bin/env bash
#
# Platform end-to-end test.
#
# Inflates an XApi with every platform integration — private-cloud (in-cluster
# Postgres, Redis, NATS) and public-cloud (AWS RDS, ElastiCache, DynamoDB, S3)
# — verifies each one actually works from inside the pod, tears everything
# down, and verifies the teardown left nothing behind in the cluster or AWS.
#
# Usage:
#   ./platform/test/e2e.sh                 # full run (~15-25 min, costs a few cents of AWS)
#   ./platform/test/e2e.sh --private-only  # in-cluster only (~5 min, no AWS)
#   ./platform/test/e2e.sh --keep          # skip teardown, leave resources for debugging
#
# XRs are applied directly with kubectl (never via ArgoCD), so GitOps state is
# untouched. Public-cloud RDS/ElastiCache are VPC-internal and unreachable from
# the cluster by design — for those the test verifies provisioning plus the full
# SPIFFE -> RolesAnywhere -> STS identity chain, reported as "identity-only".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="platform-e2e"
REGION="us-east-1"
PRIVATE_ONLY=false
KEEP=false

for arg in "$@"; do
  case "$arg" in
    --private-only) PRIVATE_ONLY=true ;;
    --keep) KEEP=true ;;
    *) echo "unknown flag: $arg"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Result collection
# ---------------------------------------------------------------------------
RESULTS=()
FAILURES=0

record() { # phase check status detail
  RESULTS+=("$1|$2|$3|$4")
  [[ "$3" == FAIL* ]] && FAILURES=$((FAILURES + 1))
  printf '  [%s] %s — %s%s\n' "$3" "$2" "$1" "${4:+ ($4)}"
}

report() {
  echo
  echo "============================ E2E REPORT ============================"
  printf '%s\n' "PHASE|CHECK|RESULT|DETAIL" "${RESULTS[@]}" | column -t -s'|'
  echo "====================================================================="
  if (( FAILURES > 0 )); then
    echo "VERDICT: FAIL ($FAILURES check(s) failed)"
  else
    echo "VERDICT: PASS"
  fi
  echo "Total time: $(( ($(date +%s) - RUN_START) / 60 ))m $(( ($(date +%s) - RUN_START) % 60 ))s"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
wait_ready() { # kind name timeout_seconds -> 0 if Ready=True
  local kind=$1 name=$2 timeout=$3 start
  start=$(date +%s)
  while true; do
    local status
    status=$(kubectl get "$kind" "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$status" == "True" ]] && return 0
    if (( $(date +%s) - start > timeout )); then
      echo "  --- $kind/$name conditions on timeout:"
      kubectl get "$kind" "$name" -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null || true
      return 1
    fi
    sleep 10
  done
}

wait_gone() { # kind name timeout_seconds -> 0 if the object no longer exists
  local kind=$1 name=$2 timeout=$3 start
  start=$(date +%s)
  while kubectl get "$kind" "$name" >/dev/null 2>&1; do
    (( $(date +%s) - start > timeout )) && return 1
    sleep 10
  done
  return 0
}

wait_secret() { # name timeout_seconds -> 0 once the secret exists
  local name=$1 timeout=$2 start
  start=$(date +%s)
  while ! kubectl get secret "$name" -n "$NS" >/dev/null 2>&1; do
    (( $(date +%s) - start > timeout )) && return 1
    sleep 10
  done
  return 0
}

secret_keys() { # secret_name -> space-separated sorted key list ("" if absent)
  kubectl get secret "$1" -n "$NS" -o jsonpath='{.data}' 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))' 2>/dev/null
}

check_secret() { # check_name secret must_have_key must_not_have_key
  local check=$1 secret=$2 want=$3 forbid=$4 keys
  keys=$(secret_keys "$secret")
  if [[ -z "$keys" ]]; then
    record contract "$check" FAIL "secret $secret missing"
  elif [[ "$keys" != *"$want"* ]]; then
    record contract "$check" FAIL "key '$want' missing (has: $keys)"
  elif [[ -n "$forbid" && "$keys" == *"$forbid"* ]]; then
    record contract "$check" FAIL "key '$forbid' must not be present"
  else
    record contract "$check" PASS ""
  fi
}

# probe_statuses <local_port> -> lines of "name|status|detail" from the app's GET /
probe_statuses() {
  curl -s --max-time 5 "http://127.0.0.1:$1/" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for i in d.get("integrations", []):
    print("|".join([i["name"], i["status"], i.get("detail", "")]))
'
}

# check_probes <xapi> <local_port> <expected names, comma-separated>
# Retries until every expected integration reports ok, or the deadline passes.
# The port-forward is restarted if it dies (kubectl drops it on transient
# connection errors); its stderr is kept for the failure report.
check_probes() {
  local xapi=$1 port=$2 expected=$3 deadline=$(( $(date +%s) + 360 )) statuses=""
  local pf_log pf_pid=""
  pf_log=$(mktemp)

  while (( $(date +%s) < deadline )); do
    if [[ -z "$pf_pid" ]] || ! kill -0 "$pf_pid" 2>/dev/null; then
      kubectl port-forward -n "$NS" "svc/$xapi" "$port:80" --address 127.0.0.1 >>"$pf_log" 2>&1 &
      pf_pid=$!
      sleep 3
    fi
    statuses=$(probe_statuses "$port") || statuses=""
    local all_ok=true
    IFS=',' read -ra names <<< "$expected"
    for n in "${names[@]}"; do
      local line
      line=$(grep "^$n|" <<< "$statuses" | head -1)
      [[ "$line" == "$n|ok|"* ]] || all_ok=false
    done
    $all_ok && break
    sleep 10
  done
  kill "$pf_pid" 2>/dev/null
  if [[ -z "$statuses" ]]; then
    echo "  --- port-forward log for $xapi:"
    tail -5 "$pf_log"
  fi
  rm -f "$pf_log"

  IFS=',' read -ra names <<< "$expected"
  for n in "${names[@]}"; do
    local line status detail
    line=$(grep "^$n|" <<< "$statuses" | head -1)
    status=$(cut -d'|' -f2 <<< "$line")
    detail=$(cut -d'|' -f3 <<< "$line")
    if [[ "$status" == "ok" && "$detail" == *"VPC-internal"* ]]; then
      record data-plane "$xapi: $n" "PASS (identity-only)" "$detail"
    elif [[ "$status" == "ok" ]]; then
      record data-plane "$xapi: $n" PASS "$detail"
    else
      record data-plane "$xapi: $n" FAIL "status=${status:-missing} $detail"
    fi
  done
}

# PASS when the command exits non-zero (resource not found / grep found
# nothing). Every command below is written so that "exists" = exit 0.
aws_gone() { # check_name command...
  local check=$1; shift
  local out
  if out=$("$@" 2>&1); then
    record teardown-verify "$check" FAIL "orphan: ${out:-exists}"
  else
    record teardown-verify "$check" PASS ""
  fi
}

# ---------------------------------------------------------------------------
# Phase 0 — preflight
# ---------------------------------------------------------------------------
RUN_START=$(date +%s)
echo "== Phase 0: preflight"

kubectl get nodes >/dev/null 2>&1 \
  && record preflight "kubectl reachable" PASS "" \
  || { record preflight "kubectl reachable" FAIL "cannot reach cluster"; report; exit 1; }

for check in "crossplane:crossplane-system:app=crossplane" "nats:nats:app.kubernetes.io/name=nats" "spire-agent:spire-server:app.kubernetes.io/name=agent"; do
  IFS=':' read -r label ns selector <<< "$check"
  if [[ -n "$(kubectl get pods -n "$ns" -l "$selector" --field-selector=status.phase=Running --no-headers 2>/dev/null)" ]]; then
    record preflight "$label running" PASS ""
  else
    record preflight "$label running" FAIL "no Running pods matching $selector in $ns"
  fi
done

if kubectl get namespace "$NS" >/dev/null 2>&1; then
  record preflight "namespace free" FAIL "$NS already exists — previous run not cleaned up?"
  report; exit 1
fi
record preflight "namespace free" PASS ""

if ! $PRIVATE_ONLY; then
  if aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
    record preflight "aws cli credentials" PASS ""
  else
    record preflight "aws cli credentials" FAIL "needed for teardown verification"
    report; exit 1
  fi

  # The previous run's ElastiCache replication group deletes asynchronously for
  # ~5-10 min after the run ends and the new run reuses the same id — wait it
  # out so back-to-back runs don't stall on the create.
  RG_RAW="crossplane-$NS-e2e-api-public-cache"
  RG_ID="$RG_RAW"
  if (( ${#RG_RAW} > 40 )); then
    RG_ID="xp-$(printf '%s' "$RG_RAW" | shasum -a 256 | cut -c1-37)"
  fi
  RG_WAIT_DEADLINE=$(( $(date +%s) + 900 ))
  while true; do
    RG_STATUS=$(aws elasticache describe-replication-groups --replication-group-id "$RG_ID" --region "$REGION" \
      --query 'ReplicationGroups[].Status' --output text 2>/dev/null)
    if [[ -z "$RG_STATUS" ]]; then
      record preflight "elasticache id free" PASS ""
      break
    elif [[ "$RG_STATUS" == "deleting" ]]; then
      if (( $(date +%s) > RG_WAIT_DEADLINE )); then
        record preflight "elasticache id free" FAIL "still deleting after 900s"
        break
      fi
      echo "  ... waiting for previous replication group to finish deleting"
      sleep 30
    else
      record preflight "elasticache id free" FAIL "exists with status=$RG_STATUS — previous run not cleaned up?"
      break
    fi
  done
fi

(( FAILURES > 0 )) && { report; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1 — inflate
# ---------------------------------------------------------------------------
echo "== Phase 1: inflate (public-cloud resources take ~10-14 min)"
kubectl create namespace "$NS" >/dev/null

kubectl apply -f "$SCRIPT_DIR/manifests/private.yaml" >/dev/null
$PRIVATE_ONLY || kubectl apply -f "$SCRIPT_DIR/manifests/public.yaml" >/dev/null

INFLATE_OK=true
# Quick resources first; the long AWS ones provision concurrently in the
# background, so later waits mostly return immediately.
for spec in "xtopic:e2e-topic:180" "xsubscription:e2e-sub:180" "xsql:e2e-sql-private:300"; do
  IFS=':' read -r kind name timeout <<< "$spec"
  if wait_ready "$kind" "$name" "$timeout"; then
    record inflate "$kind/$name Ready" PASS ""
  else
    record inflate "$kind/$name Ready" FAIL "timeout ${timeout}s"; INFLATE_OK=false
  fi
done

if ! $PRIVATE_ONLY; then
  for spec in "xnosql:e2e-nosql:180" "xobjectstorage:e2e-assets:180" "xsql:e2e-sql-public:960"; do
    IFS=':' read -r kind name timeout <<< "$spec"
    if wait_ready "$kind" "$name" "$timeout"; then
      record inflate "$kind/$name Ready" PASS ""
    else
      record inflate "$kind/$name Ready" FAIL "timeout ${timeout}s"; INFLATE_OK=false
    fi
  done
fi

# XApis last — their readiness gates on bindings (and the owned XCache).
if wait_ready xapi e2e-api-private 600; then
  record inflate "xapi/e2e-api-private Ready" PASS ""
else
  record inflate "xapi/e2e-api-private Ready" FAIL "timeout 600s"; INFLATE_OK=false
fi
if kubectl wait deployment e2e-api-private -n "$NS" --for=condition=Available --timeout=300s >/dev/null 2>&1; then
  record inflate "private pod Available" PASS ""
else
  record inflate "private pod Available" FAIL "timeout 300s"; INFLATE_OK=false
fi

if ! $PRIVATE_ONLY; then
  if wait_ready xapi e2e-api-public 960; then
    record inflate "xapi/e2e-api-public Ready" PASS ""
  else
    record inflate "xapi/e2e-api-public Ready" FAIL "timeout 960s"; INFLATE_OK=false
  fi
  # The cache binding secret is written only after the ElastiCache replication
  # group is ready (~12 min) — the XApi XR reports Ready before that, and the
  # pod stays Pending until this secret exists to mount.
  if wait_secret e2e-api-public-cache 960; then
    record inflate "cache binding secret written" PASS ""
  else
    record inflate "cache binding secret written" FAIL "timeout 960s"; INFLATE_OK=false
  fi
  if kubectl wait deployment e2e-api-public -n "$NS" --for=condition=Available --timeout=300s >/dev/null 2>&1; then
    record inflate "public pod Available" PASS ""
  else
    record inflate "public pod Available" FAIL "timeout 300s"; INFLATE_OK=false
  fi
fi

# ---------------------------------------------------------------------------
# Phase 2 — contract checks (binding secrets, deployment shape, RBAC)
# ---------------------------------------------------------------------------
if $INFLATE_OK; then
  echo "== Phase 2: contract checks"

  check_secret "sql private binding has password, no ARNs" e2e-sql-private password role-arn
  check_secret "cache private binding" e2e-api-private-cache host role-arn

  PRIV_DEPLOY=$(kubectl get deployment e2e-api-private -n "$NS" -o json 2>/dev/null)
  if grep -q '"name": "NATS_STREAM"' <<< "$PRIV_DEPLOY" && grep -q '"name": "NATS_CONSUMER"' <<< "$PRIV_DEPLOY"; then
    record contract "private deploy has NATS env vars" PASS ""
  else
    record contract "private deploy has NATS env vars" FAIL "NATS_STREAM/NATS_CONSUMER missing"
  fi
  if grep -q 'aws-credentials-sidecar' <<< "$PRIV_DEPLOY"; then
    record contract "private deploy has no AWS sidecar" FAIL "sidecar present without AWS bindings"
  else
    record contract "private deploy has no AWS sidecar" PASS ""
  fi

  if ! $PRIVATE_ONLY; then
    check_secret "sql public binding has role-arn, no password" e2e-api-public-sql role-arn password
    check_secret "nosql binding" e2e-api-public-nosql table-name ""
    check_secret "object-storage binding" e2e-api-public-e2e-assets bucket ""
    check_secret "cache public binding has role-arn" e2e-api-public-cache role-arn ""

    PUB_DEPLOY=$(kubectl get deployment e2e-api-public -n "$NS" -o json 2>/dev/null)
    if grep -q 'aws-credentials-sidecar' <<< "$PUB_DEPLOY"; then
      record contract "public deploy has AWS sidecar" PASS ""
    else
      record contract "public deploy has AWS sidecar" FAIL "aws-credentials-sidecar missing"
    fi
    for var in AWS_PROFILE_E2E_ASSETS AWS_PROFILE_NOSQL AWS_PROFILE_SQL AWS_PROFILE_CACHE; do
      if grep -q "\"name\": \"$var\"" <<< "$PUB_DEPLOY"; then
        record contract "public deploy has $var" PASS ""
      else
        record contract "public deploy has $var" FAIL "env var missing"
      fi
    done

    # RBAC isolation: each XApi's Role must not name the other's secrets.
    PRIV_ROLE=$(kubectl get role e2e-api-private -n "$NS" -o json 2>/dev/null)
    if grep -q 'e2e-api-public' <<< "$PRIV_ROLE"; then
      record contract "RBAC scoped per XApi" FAIL "private Role can read public secrets"
    else
      record contract "RBAC scoped per XApi" PASS ""
    fi
  fi

  # -------------------------------------------------------------------------
  # Phase 3 — data plane via the probe app
  # -------------------------------------------------------------------------
  echo "== Phase 3: data plane (probes retried while sidecars warm up)"
  check_probes e2e-api-private 18081 "SQL Database,Cache,Topic,Subscription"
  $PRIVATE_ONLY || check_probes e2e-api-public 18082 "SQL Database,Cache,NoSQL Database,Object Storage"
else
  echo "== Skipping contract + data-plane checks (inflate failed)"
  record contract "skipped" SKIP "inflate failed"
fi

# ---------------------------------------------------------------------------
# Phase 4 — teardown
# ---------------------------------------------------------------------------
if $KEEP; then
  echo "== Phase 4: SKIPPED (--keep). Tear down manually with:"
  echo "   kubectl delete -f $SCRIPT_DIR/manifests/private.yaml"
  $PRIVATE_ONLY || echo "   kubectl delete -f $SCRIPT_DIR/manifests/public.yaml"
  echo "   kubectl delete namespace $NS"
  report
  exit $(( FAILURES > 0 ? 1 : 0 ))
fi

echo "== Phase 4: teardown (RDS/ElastiCache deletion takes several minutes)"
# XApis first — deleting them cascades the owned XCache (and ElastiCache).
kubectl delete xapi e2e-api-private --ignore-not-found >/dev/null 2>&1
kubectl delete xapi e2e-api-public --ignore-not-found >/dev/null 2>&1
wait_gone xapi e2e-api-private 300 || record teardown "xapi/e2e-api-private deleted" FAIL "still present after 300s"
wait_gone xapi e2e-api-public 900 || record teardown "xapi/e2e-api-public deleted" FAIL "still present after 900s"
# The owned XCaches outlive their XApi briefly — the ElastiCache replication
# group takes ~5-10 min to delete in AWS and the XCache XR waits for it.
wait_gone xcache e2e-api-private-cache 300 || record teardown "xcache/e2e-api-private-cache deleted" FAIL "still present after 300s"
wait_gone xcache e2e-api-public-cache 900 || record teardown "xcache/e2e-api-public-cache deleted" FAIL "still present after 900s"

kubectl delete -f "$SCRIPT_DIR/manifests/private.yaml" --ignore-not-found >/dev/null 2>&1
$PRIVATE_ONLY || kubectl delete -f "$SCRIPT_DIR/manifests/public.yaml" --ignore-not-found >/dev/null 2>&1

for spec in "xtopic:e2e-topic:120" "xsubscription:e2e-sub:120" "xsql:e2e-sql-private:300"; do
  IFS=':' read -r kind name timeout <<< "$spec"
  if wait_gone "$kind" "$name" "$timeout"; then
    record teardown "$kind/$name deleted" PASS ""
  else
    record teardown "$kind/$name deleted" FAIL "still present after ${timeout}s"
  fi
done
if ! $PRIVATE_ONLY; then
  for spec in "xnosql:e2e-nosql:180" "xobjectstorage:e2e-assets:180" "xsql:e2e-sql-public:900"; do
    IFS=':' read -r kind name timeout <<< "$spec"
    if wait_gone "$kind" "$name" "$timeout"; then
      record teardown "$kind/$name deleted" PASS ""
    else
      record teardown "$kind/$name deleted" FAIL "still present after ${timeout}s"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Phase 5 — verify teardown
# ---------------------------------------------------------------------------
echo "== Phase 5: verify teardown"

# Composed resources cascade-delete asynchronously after the XR is gone, so
# give the namespace up to 2 min to empty out before calling anything an orphan.
EMPTY_DEADLINE=$(( $(date +%s) + 120 ))
while true; do
  LEFTOVER=$(kubectl get deployments,secrets,pvc -n "$NS" --no-headers 2>/dev/null)
  [[ -z "$LEFTOVER" ]] && break
  (( $(date +%s) > EMPTY_DEADLINE )) && break
  sleep 10
done
if [[ -n "$LEFTOVER" ]]; then
  record teardown-verify "namespace empty" FAIL "left in $NS: $(awk '{print $1}' <<< "$LEFTOVER" | tr '\n' ' ')"
else
  record teardown-verify "namespace empty" PASS ""
fi

if kubectl get streams.jetstream.nats.io e2e-topic -n nats >/dev/null 2>&1 \
   || kubectl get consumers.jetstream.nats.io e2e-sub -n nats >/dev/null 2>&1; then
  record teardown-verify "NATS stream/consumer gone" FAIL "orphaned in nats namespace"
else
  record teardown-verify "NATS stream/consumer gone" PASS ""
fi

kubectl delete namespace "$NS" >/dev/null 2>&1
if wait_gone namespace "$NS" 180; then
  record teardown-verify "namespace terminated" PASS ""
else
  record teardown-verify "namespace terminated" FAIL "stuck terminating"
fi

if ! $PRIVATE_ONLY; then
  aws_gone "RDS instance gone" \
    aws rds describe-db-instances --db-instance-identifier e2e-sql-public --region "$REGION" \
      --query 'DBInstances[].DBInstanceIdentifier' --output text
  aws_gone "DynamoDB table gone" \
    aws dynamodb describe-table --table-name e2e-nosql --region "$REGION" \
      --query 'Table.TableName' --output text
  aws_gone "S3 bucket gone" \
    aws s3api head-bucket --bucket "platform-$NS-e2e-assets" --region "$REGION"
  aws_gone "IAM roles gone" bash -c \
    "aws iam list-roles --path-prefix /crossplane/ --query 'Roles[?contains(RoleName, \`$NS\`)].RoleName' --output text --region $REGION | grep ."
  aws_gone "RolesAnywhere profiles gone" bash -c \
    "aws rolesanywhere list-profiles --region $REGION --query 'profiles[?contains(name, \`$NS\`)].name' --output text | grep ."
  # $RG_ID computed in preflight (mirrors the composition's 40-char naming).
  # AWS deletes replication groups asynchronously for ~5-10 min after the XR
  # is gone — "deleting" means the platform did its job, so count it as done.
  RG_STATUS=$(aws elasticache describe-replication-groups --replication-group-id "$RG_ID" --region "$REGION" \
    --query 'ReplicationGroups[].Status' --output text 2>/dev/null)
  case "$RG_STATUS" in
    "")        record teardown-verify "ElastiCache replication group gone" PASS "" ;;
    deleting)  record teardown-verify "ElastiCache replication group gone" "PASS (deleting)" "AWS async deletion in progress" ;;
    *)         record teardown-verify "ElastiCache replication group gone" FAIL "orphan: $RG_ID status=$RG_STATUS" ;;
  esac
fi

report
exit $(( FAILURES > 0 ? 1 : 0 ))
