# External Secrets

Cluster-setup credentials live in AWS SSM Parameter Store under `/homelab/<namespace>/<name>`. ESO
renders each into a Kubernetes Secret. Every mapping is in
[cluster/external-secrets/](../cluster/external-secrets/), one file per app. Cost is $0.

Workload credentials, controller-generated TLS, and anything a composition derives stay out.

## Adding a credential

1. Write the parameter as a `SecureString`. Stage the value in a file under `local-only/`, never on
   the command line.
2. Add an `ExternalSecret` to that app's file.
3. If the namespace is new, add it to the store's `conditions`, or ESO refuses the fetch.

```bash
aws ssm put-parameter --name /homelab/<ns>/<name> --type SecureString --overwrite \
  --region us-east-1 --value "$(cat local-only/eso/value.txt)" && rm -P local-only/eso/value.txt
```

Editing a rendered Secret in the cluster is reverted within the hour. Change the parameter instead.

## aws-eso-creds

The one hand-created Secret, because ESO needs it to reach AWS. It can read every parameter, including
`aws-creds`, so treat it as the most sensitive key in the cluster.

Seed it on a rebuild. A secret access key is shown once, so the file is shredded only after the
Secret exists.

```bash
umask 077 && mkdir -p local-only/eso
aws iam create-access-key --user-name eso-reader \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > local-only/eso/key.txt \
&& kubectl create secret generic aws-eso-creds -n external-secrets \
  --from-literal=access-key-id="$(cut -f1 local-only/eso/key.txt)" \
  --from-literal=secret-access-key="$(cut -f2 local-only/eso/key.txt)" \
&& rm -P local-only/eso/key.txt
```

`eso-reader` policy. The `kms:ViaService` condition limits the wildcard to decrypts made through SSM.

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

A failed fetch leaves the existing Secret in place. On a never-synced cluster, ESO must be healthy
before Crossplane can authenticate.
