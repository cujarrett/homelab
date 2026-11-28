# NoSql

A key-value and document store. It lives on its own, apart from any one Api. Bind it to an `Api` with `nosqlRef.name`.

## What it provisions

- `public-cloud`: an **AWS DynamoDB table**. It is ready about 10 to 30 seconds after creation.
- `private-cloud`: *(in-cluster ExtendDB planned)*.

NoSql owns only the table. The referencing `Api` creates the access role and binding when it declares `nosqlRef`.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `partitionKey` | no | `id` | Partition key attribute name. |
| `partitionKeyType` | no | `S` | Partition key type: `S`=string, `N`=number, `B`=binary. |
| `dataRetention` | no | `delete` | What happens to the table when the XR is deleted: `delete`=table is deleted (data unrecoverable); `retain`=table stays in AWS (data recoverable). |

## Binding secret

The referencing `Api` writes the Secret, named `{api-name}-nosql`, in the Api's namespace. It mounts at `/bindings/nosql/`.

| Key | Value |
|---|---|
| `type` | `dynamodb` |
| `provider` | `aws` |
| `table-name` | Table name |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this table, created by Api) |

The app reads `AWS_PROFILE_NOSQL_<REF>` and uses the standard AWS SDK. The SDK finds DynamoDB from `region`, so no custom endpoint is needed.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: NoSql
metadata:
  name: foo-events
  namespace: foo
spec:
  parameters:
    partitionKey: userId
    partitionKeyType: S
    dataRetention: retain
```

Every parameter is optional. An empty `parameters: {}` gives partition key `id` of type `S`.

Then reference it from an `Api`:

```yaml
spec:
  parameters:
    nosqlRef:
      name: foo-events
```

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).

## Per-workload auth

Only the bound Api's pod can use the table. Full design: [Platform Workload Identity](../docs/workload-identity.md).

- **Reach:** this table and its indexes. No other table.
- **Actions:** GetItem, PutItem, UpdateItem, DeleteItem, Query, Scan, BatchGetItem, BatchWriteItem.

## Operations

```bash
# XR status. SYNCED=composition ran, READY=all children healthy
kubectl get nosqls foo-events -n foo

# Detailed conditions, showing why something is not ready
kubectl get nosql foo-events -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret, to confirm every key is present (written by Api, not NoSql)
# Secret is named {api-name}-nosql, e.g. foo-nosql for an Api named "foo"
kubectl get secret foo-nosql -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Verify table exists in AWS
aws dynamodb describe-table --table-name platform-foo-foo-events --region us-east-1
```
