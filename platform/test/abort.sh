#!/usr/bin/env bash
# Stop a running e2e and leave nothing behind - no namespace, no XRs, no AWS spend.
#
# Usage:
#   just test-abort
#
# The normal teardown inside e2e.sh only runs when the script reaches it. Killing a
# run mid-flight, or a run that dies in inflate, skips it entirely and leaves real
# billable AWS resources up. This is the same teardown, reachable on its own.
#
# The ElastiCache wedge is the reason this needs to exist rather than being a
# `kubectl delete ns`. Crossplane calls DeleteUserGroup while the group is still
# `modifying`, AWS returns 400, and the async delete latches - it never retries.
# Two finalizers then hold the namespace open forever while the AWS resources
# behind them are already gone.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$TEST_DIR/../.." || exit 1

# shellcheck source=lib-unlatch.sh
. "$TEST_DIR/lib-unlatch.sh"

NS="platform-e2e"
REGION="us-east-1"
red() { printf '\033[31m%s\033[0m\n' "$1"; }
grn() { printf '\033[32m%s\033[0m\n' "$1"; }
ylw() { printf '\033[33m%s\033[0m\n' "$1"; }

# --- 1. stop the run ----------------------------------------------------------
echo "── stopping"
if pkill -f 'test/e2e.sh' 2>/dev/null; then
  grn "   killed the running e2e"
  sleep 2
else
  echo "   no e2e process running"
fi

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  grn "   namespace $NS already gone - nothing to clean"
  exit 0
fi

# --- 2. delete the XRs, Apis first --------------------------------------------
# An Api owns its Cache, so deleting it first is what starts the slow ElastiCache
# teardown. Deleting the namespace alone would strand the Cache behind finalizers.
echo "── deleting XRs"
kubectl delete apis.platform.local.lab --all -n "$NS" --ignore-not-found --timeout=60s >/dev/null 2>&1
kubectl delete spas.platform.local.lab,sqls.platform.local.lab,nosqls.platform.local.lab \
  ,objectstorages.platform.local.lab,topics.platform.local.lab,subscriptions.platform.local.lab \
  ,managedsecrets.platform.local.lab,caches.platform.local.lab \
  --all -n "$NS" --ignore-not-found --timeout=120s >/dev/null 2>&1
grn "   XR deletion requested"

# --- 3. wait, then break the ElastiCache latch --------------------------------
# RDS and ElastiCache routinely take 5-10 minutes to delete and the MRs hold the
# namespace until AWS confirms. Waiting less than that reports a healthy teardown
# as a failure, which trains you to ignore this script.
echo "── waiting for the namespace (up to 15 min, AWS deletions are slow)"
DEADLINE=$(( $(date +%s) + 900 ))
kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
LAST=""
while kubectl get ns "$NS" >/dev/null 2>&1 && [ "$(date +%s)" -lt "$DEADLINE" ]; do
  # Name what is still going, so a long wait reads as progress rather than a hang.
  NOW=$(kubectl get managed -n "$NS" --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, - )
  if [ "$NOW" != "$LAST" ] && [ -n "$NOW" ]; then
    echo "   still deleting: $NOW"
    LAST="$NOW"
  fi
  # A latched async failure never retries, so waiting out the clock on one only
  # wastes the wait. Break as soon as everything left has already given up.
  TOTAL=$(kubectl get managed -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  LATCHED=$(kubectl get managed -n "$NS" -o json 2>/dev/null \
    | python3 -c "import json,sys;print(sum(1 for i in json.load(sys.stdin).get('items',[]) if any(c.get('reason','').startswith('Async') and c.get('status')=='False' for c in i.get('status',{}).get('conditions',[]))))" 2>/dev/null)
  if [ -n "$TOTAL" ] && [ "$TOTAL" != "0" ] && [ "$TOTAL" = "$LATCHED" ]; then
    ylw "   every remaining resource has a latched async failure - not waiting it out"
    break
  fi
  sleep 15
done

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  grn "   namespace terminated cleanly"
else
  ylw "   still terminating - looking for latched deletions"
  unlatch_namespace "$NS" "$REGION"
  for _ in $(seq 1 12); do
    kubectl get ns "$NS" >/dev/null 2>&1 || break
    sleep 5
  done
fi

# --- 4. report anything still billing -----------------------------------------
# The point of aborting is to stop spend, so say plainly what is still up rather
# than exiting green on a namespace that happened to disappear.
echo "── AWS leftovers"
LEFT=0
check_gone() { # description command...
  local what=$1; shift
  local out; out=$("$@" 2>/dev/null)
  if [ -n "$out" ]; then red "   STILL UP  $what: $out"; LEFT=1; else grn "   gone      $what"; fi
}
check_gone "RDS instances" bash -c "aws rds describe-db-instances --region $REGION --query 'DBInstances[?contains(DBInstanceIdentifier,\`e2e\`)].DBInstanceIdentifier' --output text"
check_gone "ElastiCache groups" bash -c "aws elasticache describe-replication-groups --region $REGION --query 'ReplicationGroups[?contains(ReplicationGroupId,\`e2e\`)].ReplicationGroupId' --output text"
check_gone "ElastiCache user groups" bash -c "aws elasticache describe-user-groups --region $REGION --query 'UserGroups[?contains(UserGroupId,\`e2e\`)].UserGroupId' --output text"
check_gone "DynamoDB tables" bash -c "aws dynamodb list-tables --region $REGION --query 'TableNames[?contains(@,\`e2e\`)]' --output text"
check_gone "S3 buckets" bash -c "aws s3api list-buckets --query 'Buckets[?contains(Name,\`$NS\`)].Name' --output text"
check_gone "Secrets Manager" bash -c "aws secretsmanager list-secrets --region $REGION --query 'SecretList[?contains(Name,\`$NS\`)].Name' --output text"
check_gone "IAM roles" bash -c "aws iam list-roles --path-prefix /crossplane/ --query 'Roles[?contains(RoleName,\`$NS\`)].RoleName' --output text"

echo
if kubectl get ns "$NS" >/dev/null 2>&1; then
  red "namespace $NS still present - inspect it before starting another run"
  exit 1
elif [ "$LEFT" -eq 1 ]; then
  red "namespace gone but AWS resources remain - they are billing until removed"
  exit 1
else
  grn "aborted clean"
fi
