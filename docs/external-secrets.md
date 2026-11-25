# External Secrets

Cluster-setup credentials live in AWS SSM Parameter Store as `/homelab/<namespace>/<name>`. External Secrets Operator (ESO) renders each one into a Secret.

- Mapping: [cluster/external-secrets/](../cluster/external-secrets/).
- Left out: workload credentials and controller-generated TLS.
- Hand edits to a rendered Secret are reverted within the hour.

## Rotating a credential

[Rotate Secret](../scripts/rotate-secret/) has one paste block per credential.

## Adding a credential

Write the parameter with the rotate script, then add an `ExternalSecret`. A new namespace also goes in the store's `conditions`.

```bash
scripts/rotate-secret/rotate-secret.sh /homelab/<ns>/<name>
```

The script still writes the value, but reports a failure until the `ExternalSecret` exists. Nothing reads the value before then.

## aws-eso-creds

This is the one hand-created Secret, because ESO needs it to reach AWS. It can read every parameter, so it is the most sensitive key in the cluster. Rotate it with [Rotate Secret → AWS access keys](../scripts/rotate-secret/README.md#aws-access-keys).

Seed it on a rebuild.

```bash
umask 077 && mkdir -p local-only/eso
aws iam create-access-key --user-name eso-reader \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > local-only/eso/key.txt \
&& kubectl create secret generic aws-eso-creds -n external-secrets \
  --from-literal=access-key-id="$(cut -f1 local-only/eso/key.txt)" \
  --from-literal=secret-access-key="$(cut -f2 local-only/eso/key.txt)" \
&& rm -P local-only/eso/key.txt
```

The `eso-reader` policy follows. `kms:ViaService` limits the wildcard to decrypts made through SSM.

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

A failed fetch leaves the existing Secret in place. On a fresh cluster, ESO must be healthy before Crossplane can sign in.

```bash
kubectl get clustersecretstore aws-parameter-store   # Valid
kubectl get externalsecret -A                        # SecretSynced
```
