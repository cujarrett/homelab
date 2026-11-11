# rotate-secret

Every cluster credential has one paste block below. Run each from the homelab repo root.

The script writes the new value and checks the cluster has it. It reads the value from a pipe, or prompts with echo off, so the value never lands in shell history or the process list.

- `/homelab/...` values are in Parameter Store. The script waits until every Secret rendered from it holds the new value.
- `platform/...` values are in Secrets Manager. Pods read them within 15 minutes, or at once when the block restarts them.
- A last argument such as `blog/deployment/ghost` restarts that workload after the write.

GitHub Actions secrets and App keys are in [GitHub Tokens](../../docs/github-tokens.md). The Launchpad token has its own checked script, [GitHub Token Rotate](../github-token-rotate/).

## Pasted from a vendor page

Regenerate the value on the page named, then run the block and paste it at the prompt.

| Credential | Regenerate at |
|---|---|
| Blog backup PAT (`blog-backups`) | [GitHub fine-grained tokens](https://github.com/settings/personal-access-tokens) |
| Ghost Content API key | Ghost admin, Settings → Integrations → the backup integration |
| Ghost SMTP password | [Google app passwords](https://myaccount.google.com/apppasswords) for cujarrett@gmail.com |
| cert-manager Cloudflare token | [Cloudflare API tokens](https://dash.cloudflare.com/profile/api-tokens), Roll |
| Cloudflare tunnel token | Cloudflare Zero Trust, Networks → Tunnels → the tunnel → Refresh token |
| Alertmanager Discord webhook | Discord channel settings, Integrations → Webhooks |
| Apollo operator keys | Apollo Studio, `storefront-homelab` → Settings → API keys, one per lane |
| Temporal Cloud keys | Temporal Cloud, Settings → API keys |
| github-exporter PAT | [GitHub fine-grained tokens](https://github.com/settings/personal-access-tokens) |
| Discogs token | [Discogs developer settings](https://www.discogs.com/settings/developers) |

```bash
scripts/rotate-secret/rotate-secret.sh /homelab/blog/backup-github-token
scripts/rotate-secret/rotate-secret.sh /homelab/blog/content-api-key
scripts/rotate-secret/rotate-secret.sh /homelab/blog/smtp-password blog/deployment/ghost
scripts/rotate-secret/rotate-secret.sh /homelab/cert-manager/cloudflare-api-token
scripts/rotate-secret/rotate-secret.sh /homelab/cloudflare/tunnel-token cloudflare/deployment/cloudflared
scripts/rotate-secret/rotate-secret.sh /homelab/monitoring/discord-webhook-url
scripts/rotate-secret/rotate-secret.sh /homelab/apollo-operator-test/apollo-api-key apollo-operator-test/deployment/apollo-operator
scripts/rotate-secret/rotate-secret.sh /homelab/apollo-operator-prod/apollo-api-key apollo-operator-prod/deployment/apollo-operator
scripts/rotate-secret/rotate-secret.sh /homelab/temporal-cloud/api-key temporal-controller/deployment/temporal-controller
scripts/rotate-secret/rotate-secret.sh /homelab/monitoring/temporal-cloud-metrics-api-key
scripts/rotate-secret/rotate-secret.sh platform/github-exporter/github-exporter-token github-exporter/deployment/github-exporter
scripts/rotate-secret/rotate-secret.sh platform/my-vinyl/discogs-credentials my-vinyl/deployment/my-vinyl-api
```

To test the blog backup token right away:

```bash
JOB=ghost-backup-manual-$(date +%s)
kubectl create job --from=cronjob/ghost-backup $JOB -n blog
kubectl wait --for=condition=Ready pod -l job-name=$JOB -n blog --timeout=60s
kubectl logs -n blog -l job-name=$JOB -f
```

## Basic auth passwords

`htpasswd` prompts for the new password. The user stays `admin`.

```bash
htpasswd -nB admin | scripts/rotate-secret/rotate-secret.sh /homelab/longhorn-system/basic-auth-htpasswd
htpasswd -nB admin | scripts/rotate-secret/rotate-secret.sh /homelab/monitoring/prometheus-basic-auth-htpasswd
```

## Grafana admin password

Grafana keeps its own copy, so the second command sets it there too.

```bash
scripts/rotate-secret/rotate-secret.sh /homelab/monitoring/grafana-admin-password
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d \
  | kubectl exec -i -n monitoring deploy/monitoring-grafana -c grafana -- grafana cli admin reset-admin-password --password-from-stdin
```

## ArgoCD webhook secret

GitHub signs each push with this value, so both GitHub webhooks get the new one too.

```bash
SECRET=$(openssl rand -hex 32)
printf %s "$SECRET" | scripts/rotate-secret/rotate-secret.sh /homelab/argocd/webhook-github-secret
for hook in $(gh api repos/cujarrett/homelab-workspaces/hooks --jq '.[] | select(.config.url | contains("argocd-webhook")) | .id'); do
  jq -n --arg s "$SECRET" '{secret: $s}' | gh api -X PATCH "repos/cujarrett/homelab-workspaces/hooks/$hook/config" --input - >/dev/null
done
unset SECRET
kubectl rollout restart -n argocd deployment/argocd-server deployment/argocd-applicationset-controller
```

## Visitor salt

Every visitor hashes to a new ID afterwards, so returning visitors count as new once.

```bash
openssl rand -hex 32 | scripts/rotate-secret/rotate-secret.sh /homelab/monitoring/visitor-salt monitoring/daemonset/alloy
```

## Temporal Postgres password

Postgres keeps its own copy, so the first command changes it there. Open connections stay up until the restart.

```bash
PW=$(openssl rand -hex 24)
printf "ALTER USER temporal PASSWORD '%s';" "$PW" | kubectl exec -i -n temporal temporal-postgres-0 -- psql -q -U temporal -d postgres
printf %s "$PW" | scripts/rotate-secret/rotate-secret.sh /homelab/temporal/postgres-password && unset PW
kubectl rollout restart deployment -n temporal
```

## AWS access keys

Each block makes a new key, writes it, then deletes the old one. IAM allows two keys per user, so a leftover second key makes `create-access-key` fail.

```bash
OLD=$(aws iam list-access-keys --user-name crossplane-user --query 'AccessKeyMetadata[].AccessKeyId' --output text)
aws iam create-access-key --user-name crossplane-user --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
  | awk '{printf "[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n", $1, $2}' \
  | scripts/rotate-secret/rotate-secret.sh /homelab/crossplane-system/aws-credentials \
  && aws iam delete-access-key --user-name crossplane-user --access-key-id "$OLD"
```

```bash
OLD=$(aws iam list-access-keys --user-name aws-orphan-scanner --query 'AccessKeyMetadata[].AccessKeyId' --output text)
aws iam create-access-key --user-name aws-orphan-scanner --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
  | awk '{printf "[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n", $1, $2}' \
  | scripts/rotate-secret/rotate-secret.sh /homelab/crossplane-system/aws-orphan-scanner-credentials \
  && aws iam delete-access-key --user-name aws-orphan-scanner --access-key-id "$OLD"
```

`eso-reader` is the key External Secrets itself signs in with, so it goes straight into its Secret. A forced sync of one ExternalSecret proves the new key works before the old one is deleted.

```bash
OLD=$(aws iam list-access-keys --user-name eso-reader --query 'AccessKeyMetadata[].AccessKeyId' --output text)
aws iam create-access-key --user-name eso-reader --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
  | { read -r id key; kubectl create secret generic aws-eso-creds -n external-secrets \
      --from-file=access-key-id=<(printf %s "$id") --from-file=secret-access-key=<(printf %s "$key") \
      --dry-run=client -o yaml | kubectl apply -f -; } \
  && sleep 15 \
  && kubectl annotate externalsecret ghost-smtp -n blog force-sync=$(date +%s) --overwrite \
  && sleep 10 && kubectl wait --for=condition=Ready externalsecret/ghost-smtp -n blog --timeout=30s \
  && aws iam delete-access-key --user-name eso-reader --access-key-id "$OLD"
```

## Entra client secret

The client and tenant IDs come from the current value. `credential reset` revokes the old secret at once.

```bash
CUR=$(aws ssm get-parameter --region us-east-1 --name /homelab/crossplane-system/azuread-credentials --with-decryption --query Parameter.Value --output text)
APP=$(jq -r .clientId <<<"$CUR"); TENANT=$(jq -r .tenantId <<<"$CUR"); unset CUR
az ad app credential reset --id "$APP" --display-name crossplane --years 1 --query password -o tsv \
  | jq -Rc --arg c "$APP" --arg t "$TENANT" '{clientId: $c, clientSecret: ., tenantId: $t}' \
  | scripts/rotate-secret/rotate-secret.sh /homelab/crossplane-system/azuread-credentials
```
