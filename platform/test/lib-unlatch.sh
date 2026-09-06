#!/usr/bin/env bash
# Release finalizers on managed resources whose AWS object is already gone.
#
# Sourced by e2e.sh (end of teardown) and abort.sh. Both need it because the
# provider latches: Crossplane calls DeleteUserGroup while ElastiCache still has the
# group in `modifying`, AWS returns 400, and the async delete never retries. Two
# finalizers then hold the namespace open forever while AWS has nothing left. It has
# happened on every full run.
#
# The rule this enforces: never release a finalizer without first asking AWS whether
# the object is really gone. A finalizer dropped on a live resource orphans it, and
# an orphan bills silently until someone notices.

# unlatch_namespace <namespace> <region>
unlatch_namespace() {
  local ns=$1 region=$2 r ext live unknown released=0

  for r in $(kubectl get managed -n "$ns" -o name 2>/dev/null); do
    ext=$(kubectl get "$r" -n "$ns" -o jsonpath='{.metadata.annotations.crossplane\.io/external-name}' 2>/dev/null)
    [ -n "$ext" ] || continue

    live=""; unknown=0
    case "$r" in
      usergroup.elasticache.*)        live=$(aws elasticache describe-user-groups --user-group-id "$ext" --region "$region" --query 'UserGroups[].Status' --output text 2>/dev/null) ;;
      user.elasticache.*)             live=$(aws elasticache describe-users --user-id "$ext" --region "$region" --query 'Users[].Status' --output text 2>/dev/null) ;;
      replicationgroup.elasticache.*) live=$(aws elasticache describe-replication-groups --replication-group-id "$ext" --region "$region" --query 'ReplicationGroups[].Status' --output text 2>/dev/null) ;;
      instance.rds.*)                 live=$(aws rds describe-db-instances --db-instance-identifier "$ext" --region "$region" --query 'DBInstances[].DBInstanceStatus' --output text 2>/dev/null) ;;
      table.dynamodb.*)               live=$(aws dynamodb describe-table --table-name "$ext" --region "$region" --query 'Table.TableStatus' --output text 2>/dev/null) ;;
      bucket.s3.*)                    live=$(aws s3api head-bucket --bucket "$ext" --region "$region" 2>/dev/null && echo present) ;;
      secret.secretsmanager.*|secretversion.secretsmanager.*) live=$(aws secretsmanager describe-secret --secret-id "$ext" --region "$region" --query 'Name' --output text 2>/dev/null) ;;
      role.iam.*)                     live=$(aws iam get-role --role-name "$ext" --query 'Role.RoleName' --output text 2>/dev/null) ;;
      *)                              unknown=1 ;;
    esac

    # An unrecognised kind is left alone on purpose. Guessing here is how a live
    # database gets orphaned, and a stuck namespace is the cheaper failure.
    if [ "$unknown" -eq 1 ]; then
      echo "   unlatch: no AWS lookup for ${r%%/*}, leaving its finalizer" >&2
      continue
    fi
    if [ -n "$live" ]; then
      # Still in AWS. If Crossplane has latched, nobody is going to delete it - the
      # provider never retries an async failure - so issue the delete here. Without
      # this both sides wait on each other and the namespace hangs indefinitely.
      if ! kubectl get "$r" -n "$ns" \
           -o jsonpath='{.status.conditions[?(@.type=="LastAsyncOperation")].reason}' 2>/dev/null \
           | grep -q 'AsyncDeleteFailure'; then
        continue
      fi
      echo "   unlatch: $ext is latched and still in AWS ($live), deleting it there" >&2
      case "$r" in
        usergroup.elasticache.*)        aws elasticache delete-user-group --user-group-id "$ext" --region "$region" >/dev/null 2>&1 ;;
        user.elasticache.*)             aws elasticache delete-user --user-id "$ext" --region "$region" >/dev/null 2>&1 ;;
        replicationgroup.elasticache.*) aws elasticache delete-replication-group --replication-group-id "$ext" --region "$region" >/dev/null 2>&1 ;;
        *)                              echo "   unlatch: no delete for ${r%%/*}, leaving it" >&2; continue ;;
      esac
      # Wait for AWS to actually let go, then re-check. Falling through on a timeout
      # would drop the finalizer on a resource that still exists, which is the one
      # outcome this function must never produce.
      for _ in $(seq 1 18); do
        sleep 10
        case "$r" in
          usergroup.elasticache.*)        aws elasticache describe-user-groups --user-group-id "$ext" --region "$region" >/dev/null 2>&1 || break ;;
          user.elasticache.*)             aws elasticache describe-users --user-id "$ext" --region "$region" >/dev/null 2>&1 || break ;;
          replicationgroup.elasticache.*) aws elasticache describe-replication-groups --replication-group-id "$ext" --region "$region" >/dev/null 2>&1 || break ;;
        esac
      done
      case "$r" in
        usergroup.elasticache.*)        aws elasticache describe-user-groups --user-group-id "$ext" --region "$region" >/dev/null 2>&1 && still=1 || still=0 ;;
        user.elasticache.*)             aws elasticache describe-users --user-id "$ext" --region "$region" >/dev/null 2>&1 && still=1 || still=0 ;;
        replicationgroup.elasticache.*) aws elasticache describe-replication-groups --replication-group-id "$ext" --region "$region" >/dev/null 2>&1 && still=1 || still=0 ;;
        *)                              still=1 ;;
      esac
      if [ "$still" -eq 1 ]; then
        echo "   unlatch: $ext did not disappear from AWS, keeping its finalizer" >&2
        continue
      fi
    fi

    if kubectl patch "$r" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1; then
      echo "   unlatch: released $r (confirmed gone from AWS)" >&2
      released=$((released + 1))
    fi
  done

  return $(( released > 0 ? 0 : 1 ))
}
