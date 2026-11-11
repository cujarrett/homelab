#!/usr/bin/env bash
# Writes a new credential value, then checks the cluster has it.
#   /homelab/<ns>/<name>: Parameter Store, rendered into a Secret by External Secrets
#   platform/<ns>/<name>: Secrets Manager, read by a ManagedSecret
# The value comes from a pipe, or a prompt with echo off.
# Either way it stays out of shell history and the process list.
set -euo pipefail

usage="usage: $0 /homelab/<ns>/<name>|platform/<ns>/<name> [<ns>/<kind>/<name> to restart]"
id=${1:?$usage}
restart=${2:-}

if [ -t 0 ]; then
  read -rsp "New value for ${id}: " value
  echo
else
  value=$(cat)
fi
[ -n "$value" ] || { echo "FAIL: empty value"; exit 1; }
want=$(printf %s "$value" | shasum -a 256 | cut -d' ' -f1)

case $id in
/homelab/*)
  printf %s "$value" | aws ssm put-parameter --region us-east-1 --name "$id" \
    --type SecureString --overwrite --value file:///dev/stdin >/dev/null
  unset value

  # One line per Secret key fed from this parameter: namespace, ExternalSecret, Secret, key.
  refs=$(kubectl get externalsecret -A -o json | jq -r --arg id "$id" '
    .items[] | . as $es | .spec.data[] | select(.remoteRef.key == $id)
    | "\($es.metadata.namespace) \($es.metadata.name) \($es.spec.target.name // $es.metadata.name) \(.secretKey)"')
  [ -n "$refs" ] || { echo "FAIL: no ExternalSecret reads ${id}"; exit 1; }

  while read -r ns es secret key; do
    kubectl annotate externalsecret "$es" -n "$ns" force-sync="$(date +%s)" --overwrite >/dev/null
    got=""
    for _ in $(seq 30); do
      got=$(kubectl get secret "$secret" -n "$ns" -o json \
        | jq -r --arg k "$key" '.data[$k] // ""' | base64 -d | shasum -a 256 | cut -d' ' -f1)
      [ "$got" = "$want" ] && break
      sleep 2
    done
    [ "$got" = "$want" ] || { echo "FAIL: ${ns}/${secret} still has the old ${key}"; exit 1; }
    echo "ok: ${ns}/${secret} has the new ${key}"
  done <<<"$refs"
  ;;
platform/*)
  ns=$(cut -d/ -f2 <<<"$id")
  name=$(cut -d/ -f3 <<<"$id")
  keys=$(kubectl get managedsecret "$name" -n "$ns" -o json | jq -r '.spec.parameters.keys[]')
  # put-secret-value replaces the whole JSON, so a second key would be wiped.
  [ "$(wc -l <<<"$keys" | tr -d ' ')" = 1 ] || { echo "FAIL: ${id} has more than one key"; exit 1; }

  printf %s "$value" | jq -Rc --arg k "$keys" '{($k): .}' \
    | aws secretsmanager put-secret-value --region us-east-1 --secret-id "$id" \
      --secret-string file:///dev/stdin >/dev/null
  unset value
  echo "ok: ${id} updated. Pods read it within 15 minutes, or at once on restart."
  ;;
*)
  echo "$usage"
  exit 1
  ;;
esac

if [ -n "$restart" ]; then
  kubectl rollout restart -n "${restart%%/*}" "${restart#*/}"
  kubectl rollout status -n "${restart%%/*}" "${restart#*/}" --timeout=5m
fi
