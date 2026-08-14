# External Secrets Operator

Grafana's admin login lives in AWS Secrets Manager, not in the cluster. ESO reads it and writes the
`grafana-admin-secret` Secret in `monitoring`. Git holds the wiring, never the value.

Every other credential is still created by hand with `kubectl create secret` - see
[Why only one secret](#why-only-one-secret).

## How it works

The secret `homelab/cluster` in `us-east-1` holds values as JSON properties. The manifests in
[cluster/monitoring/](../cluster/monitoring/) - one `ClusterSecretStore`, one `ExternalSecret` -
map two of them onto Secret keys.

| Secret | Namespace | Key | AWS property |
|---|---|---|---|
| `grafana-admin-secret` | `monitoring` | `admin-user` | `grafana_admin_user` |
| `grafana-admin-secret` | `monitoring` | `admin-password` | `grafana_admin_password` |

ESO authenticates as the `eso-reader` IAM user. Its credential, `aws-eso-creds`, cannot itself come
from ESO, so it is hand-seeded - the same bootstrap problem as `aws-creds` in `crossplane-system`.
Cost is $0.40/month.

## Why only one secret

Grafana's admin password is a value you chose. Nothing outside the cluster rotates it, it never
expires, and if ESO breaks you lose the admin login while anonymous viewer access keeps every
dashboard up. The operator failing costs nothing.

Credentials issued by someone else are a worse fit. A GitHub PAT, a Discogs token or the Cloudflare
tunnel token can be revoked or expire at the provider, and AWS cannot know - ESO would keep writing
a dead value into the cluster. Those stay hand-created, where the thing you edit is the thing that
is used. The tunnel token especially: every public hostname depends on it, so an extra moving part
buys nothing.

## Operating it

Never pass a value as a command-line argument - it lands in shell history and is visible to `ps`.
Stage through a file under `local-only/` (gitignored) and verify by property name and length rather
than printing anything.

**Rotate** - ESO applies the change within the refresh interval; Grafana reads it only at startup.
```bash
umask 077 && mkdir -p local-only/eso
aws secretsmanager get-secret-value --secret-id homelab/cluster --region us-east-1 \
  --query SecretString --output text > local-only/eso/homelab-cluster.json
# edit the file, then
aws secretsmanager put-secret-value --secret-id homelab/cluster \
  --secret-string file://local-only/eso/homelab-cluster.json --region us-east-1 \
&& rm -P local-only/eso/homelab-cluster.json

kubectl rollout restart deployment monitoring-grafana -n monitoring
```

**Seed `aws-eso-creds`** - needed on a rebuilt cluster or a lost key. A secret access key is shown
exactly once, so the staging file is only shredded after the Secret exists. If the chain stops
early the file still holds the key; re-run from `kubectl create secret`. A truly lost key is
unrecoverable - `aws iam delete-access-key`, then mint another. `eso-reader` is capped at two keys.
```bash
umask 077 && mkdir -p local-only/eso
aws iam create-access-key --user-name eso-reader \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text \
  > local-only/eso/eso-key.txt \
&& kubectl create secret generic aws-eso-creds -n external-secrets \
  --from-literal=access-key-id="$(cut -f1 local-only/eso/eso-key.txt)" \
  --from-literal=secret-access-key="$(cut -f2 local-only/eso/eso-key.txt)" \
&& rm -P local-only/eso/eso-key.txt
```

**Recreate `eso-reader`** - read-only on `homelab/*` and nothing else in the account. Idempotent.
```bash
aws iam create-user --user-name eso-reader
ACCT=$(aws sts get-caller-identity --query Account --output text)

aws iam put-user-policy --user-name eso-reader --policy-name ESOReadHomelab \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"ReadHomelabSecrets\",
      \"Effect\": \"Allow\",
      \"Action\": [\"secretsmanager:GetSecretValue\", \"secretsmanager:DescribeSecret\"],
      \"Resource\": \"arn:aws:secretsmanager:us-east-1:${ACCT}:secret:homelab/*\"
    }]
  }"
```

**Verify** - a store that is not `Valid` means ESO cannot reach AWS; fix that before anything else.
```bash
kubectl get clustersecretstore aws-secrets-manager    # STATUS Valid
kubectl get externalsecret -n monitoring              # SecretSynced
```

Losing `aws-eso-creds` stops refreshes but leaves the Secret alive - `creationPolicy: Owner` does
not delete on auth failure. Deleting the `external-secrets` Application does take it, so restore
from AWS first.
