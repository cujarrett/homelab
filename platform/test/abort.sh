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

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1

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
echo "── waiting for the namespace (up to 5 min before forcing)"
DEADLINE=$(( $(date +%s) + 300 ))
kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
while kubectl get ns "$NS" >/dev/null 2>&1 && [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 10
done

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  grn "   namespace terminated cleanly"
else
  ylw "   still terminating - checking for the ElastiCache latch"
  STUCK=$(kubectl get usergroups.elasticache.aws.m.upbound.io,users.elasticache.aws.m.upbound.io \
    -n "$NS" -o name 2>/dev/null)
  for r in $STUCK; do
    # Only safe because the AWS side is verified gone below. A finalizer removed
    # while the real resource lives would orphan it and bill silently.
    EXT=$(kubectl get "$r" -n "$NS" -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}' 2>/dev/null)
    case "$r" in
      *usergroup*) LIVE=$(aws elasticache describe-user-groups --user-group-id "$EXT" --region "$REGION" \
                      --query 'UserGroups[].Status' --output text 2>/dev/null) ;;
      *)           LIVE=$(aws elasticache describe-users --user-id "$EXT" --region "$REGION" \
                      --query 'Users[].Status' --output text 2>/dev/null) ;;
    esac
    if [ -n "$LIVE" ]; then
      ylw "   $EXT still exists in AWS (status $LIVE) - deleting there first"
      case "$r" in
        *usergroup*) aws elasticache delete-user-group --user-group-id "$EXT" --region "$REGION" >/dev/null 2>&1 ;;
        *)           aws elasticache delete-user --user-id "$EXT" --region "$REGION" >/dev/null 2>&1 ;;
      esac
      sleep 20
    fi
    kubectl patch "$r" -n "$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 \
      && grn "   released finalizer on $r"
  done
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
