# External Secrets

Cluster-setup credentials live in AWS SSM Parameter Store under `/homelab/<namespace>/<name>`. ESO
renders each into a Secret, mapped in [cluster/external-secrets/](../cluster/external-secrets/).
Workload credentials and controller-generated TLS stay out.

## Rotating a credential

[Rotate Secret](../scripts/rotate-secret/) has one paste block per credential.

## Adding a credential

Write the parameter with the rotate script, then add an `ExternalSecret`. A new namespace also needs adding to the store's `conditions`.

```bash
scripts/rotate-secret/rotate-secret.sh /homelab/<ns>/<name>
```

The script fails until the `ExternalSecret` exists, since nothing reads the value yet.

Editing a rendered Secret by hand is reverted within the hour.

## aws-eso-creds

The one hand-created Secret, since ESO needs it to reach AWS. It can read every parameter, so it is
the most sensitive key in the cluster. [Rotate Secret → AWS access keys](../scripts/rotate-secret/README.md#aws-access-keys) rotates it. Seed it on a rebuild:

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
