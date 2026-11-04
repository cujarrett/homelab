# Kill switches

A bill is climbing. Kill the platform's key for that service first, then find the cause. Nothing new gets created or changed until the key works again.

## AWS

Kill every key Crossplane signs in with:

```bash
for k in $(aws iam list-access-keys --user-name crossplane-user --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam update-access-key --user-name crossplane-user --access-key-id "$k" --status Inactive
done
```

Undo: the same loop with `--status Active`.

Killing the key stops new spend only. Running RDS and ElastiCache still bill. List the XRs that own them, as `namespace/name`:

```bash
kubectl get sqls.platform.local.lab -A -o jsonpath='{range .items[?(@.spec.parameters.backend=="public-cloud")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
kubectl get apis.platform.local.lab -A -o jsonpath='{range .items[?(@.spec.parameters.cache.backend=="public-cloud")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

Delete each one, such as `kubectl delete sql foo -n bar`. Then remove its file from Git, or ArgoCD puts it back.

With the key killed, Crossplane can't delete the AWS side either. Turn the key back on until the XRs are gone, or delete the instances in the AWS console.

In the AWS console, names start `crossplane-<namespace>-<name>`, so they point to the same XR. [Cost Explorer](https://console.aws.amazon.com/cost-management/home#/cost-explorer) shows which service is spending.

AWS also kills itself: at 100% of the `Primary Budget`, it attaches `KillSwitchDenyAll` to `crossplane-user`. Undo with `aws iam detach-user-policy --user-name crossplane-user --policy-arn arn:aws:iam::550429969116:policy/KillSwitchDenyAll`.

## Apollo GraphOS

[Apollo Studio](https://studio.apollographql.com/) → the graph → Settings → API Keys → revoke. Test and prod each have their own key, so one lane can stop alone.

Undo: create a new key and put it in `/homelab/apollo-operator-<lane>/apollo-api-key`.

## Temporal Cloud

[Temporal Cloud](https://cloud.temporal.io/) → Settings → Service Accounts → `homelab-platform` → revoke its API key.

Undo: create a new key and put it in `/homelab/temporal-cloud/api-key`.

Killing the key stops new namespaces only. Running workers still spend. Cut them off too:

```bash
kubectl patch environmentconfig aws-platform-config --type=merge -p '{"data":{"temporalCloudEnabled":"false"}}'
```

Every WorkflowSpace drops its route out, so no worker can reach Temporal Cloud. Undo: the same command with `"true"`.

List the XRs that still own a Temporal Cloud namespace, as `namespace/name`:

```bash
kubectl get workflowspaces.platform.local.lab -A -o jsonpath='{range .items[?(@.spec.parameters.backend=="public-cloud")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

Delete each one, such as `kubectl delete workflowspace foo -n bar`. With the key killed, temporal-controller can't delete the Temporal Cloud side, so delete it in the console too.

## Public-cloud Sql, cache and workflow spaces

Already off outside the e2e suite, by [public-cloud-backends.yaml](../../cluster/kyverno/public-cloud-backends.yaml). A public-cloud workflow space is also deleted after 2 hours, by [public-cloud-time-limit.yaml](../../cluster/kyverno/public-cloud-time-limit.yaml).
