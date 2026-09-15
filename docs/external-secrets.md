# External Secrets

Cluster-setup credentials live in AWS SSM Parameter Store under `/homelab/<namespace>/<name>`. ESO
renders each into a Secret, mapped in [cluster/external-secrets/](../cluster/external-secrets/).
Workload credentials and controller-generated TLS stay out.

## Adding or rotating a credential

Stage the value under `local-only/` so it never lands in shell history. A new credential also needs
an `ExternalSecret`, and a new namespace needs adding to the store's `conditions`.

```bash
aws ssm put-parameter --name /homelab/<ns>/<name> --type SecureString --overwrite \
  --region us-east-1 --value "$(cat local-only/eso/value.txt)" && rm -P local-only/eso/value.txt
kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite
```

Editing a rendered Secret is reverted within the hour. `cloudflared` and `ghost` read theirs as env
vars, so restart them. Grafana ignores a changed admin password; use `grafana cli admin reset-admin-password`.

## aws-eso-creds

The one hand-created Secret, since ESO needs it to reach AWS. It can read every parameter, so it is
the most sensitive key in the cluster. Seed it on a rebuild:

```bash
umask 077 && mkdir -p local-only/eso
aws iam create-access-key --user-name eso-reader \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > local-only/eso/key.txt \
&& kubectl create secret generic aws-eso-creds -n external-secrets \
  --from-literal=access-key-id="$(cut -f1 local-only/eso/key.txt)" \
  --from-literal=secret-access-key="$(cut -f2 local-only/eso/key.txt)" \
&& rm -P local-only/eso/key.txt
```

`eso-reader` policy. `kms:ViaService` limits the wildcard to decrypts made through SSM.

```bash
aws iam put-user-policy --user-name eso-reader --policy-name ESOReadHomelab --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["ssm:GetParameter", "ssm:GetParameters"],
     "Resource": "arn:aws:ssm:us-east-1:550429969116:parameter/homelab/*"},
    {"Effect": "Allow", "Action": "kms:Decrypt", "Resource": "*",
     "Condition": {"StringEquals": {"kms:ViaService": "ssm.us-east-1.amazonaws.com"}}}
  ]
}'
```

## Not syncing

```bash
kubectl get clustersecretstore aws-parameter-store   # Valid
kubectl get externalsecret -A                        # SecretSynced
```

A failed fetch leaves the existing Secret in place. On a fresh cluster, ESO must be healthy before
Crossplane can authenticate.
