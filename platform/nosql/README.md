# XNoSql

Crossplane platform primitive that provisions a key-value / document store.

Standalone resource with a lifecycle independent of any one API. Bind to an `XApi` via `nosqlRef.name`.

## What it provisions
- `public-cloud` — **AWS DynamoDB table**
- `private-cloud` — *(in-cluster ExtendDB planned)*

The IAM Role, RolesAnywhere Profile, and binding Secret are **not** created by XNoSql. They are created by the `XApi` composition when `nosqlRef` is declared. XNoSql manages only the table's lifecycle.

DynamoDB tables are ready in ~10–30 seconds after Crossplane calls the API, making the commit-to-running loop fast regardless of environment.

## Binding secret

Written by the `XApi` composition (not by XNoSql) once the RolesAnywhere Profile ARN is available. Secret name is `{xapi-name}-nosql`; namespace comes from the `XApi` that references it. Mounted at `/bindings/nosql/` inside the container.

| Key | Value |
|---|---|
| `type` | `dynamodb` |
| `provider` | `aws` |
| `table-name` | Table name |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this table, created by XApi) |
| `profile-arn` | RolesAnywhere profile ARN (created by XApi) |

The `aws-spiffe-helper` sidecar (injected by XApi) exchanges the pod's SVID for short-lived STS credentials and writes them as the `nosql` named profile. The app reads `AWS_PROFILE_NOSQL` and uses the standard AWS SDK — no custom endpoint required, the SDK resolves DynamoDB from `region`.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the owning workload. Used for the Namespace cost-allocation tag; the binding Secret is written by the referencing `XApi`. |
| `partitionKey` | no | `id` | Partition key attribute name. |
| `partitionKeyType` | no | `S` | Partition key type: `S`=string, `N`=number, `B`=binary. |
| `dataRetention` | no | `delete` | AWS resource reclaim on XR deletion: `delete`=table is deleted (data unrecoverable); `retain`=table is orphaned in AWS (data recoverable). |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XNoSql
metadata:
  name: foo-events
spec:
  parameters:
    namespace: foo
    # partitionKey defaults to id; partitionKeyType defaults to S
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XNoSql
metadata:
  name: foo-events
spec:
  parameters:
    namespace: foo
    partitionKey: userId
    partitionKeyType: S
    dataRetention: retain
```

Then reference from an `XApi`:

```yaml
spec:
  parameters:
    nosqlRef:
      name: foo-events
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Per-workload auth

When `XApi` declares `nosqlRef`, it creates an IAM Role whose trust policy is locked to the pod's exact SPIFFE ID (`spiffe://homelab.local/ns/{namespace}/sa/{service-account}`). The inline policy grants specific DynamoDB actions (GetItem, PutItem, UpdateItem, DeleteItem, Query, Scan, BatchGetItem, BatchWriteItem) scoped to this table's ARN and its indexes — no other table is reachable. For the full design: [`docs/workload-identity.md`](../../../docs/workload-identity.md)

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xnosqls foo-events

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xnosql foo-events -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all keys are present (written by XApi, not XNoSql)
# Secret is named {xapi-name}-nosql, e.g. foo-nosql for an XApi named "foo"
kubectl get secret foo-nosql -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Verify table exists in AWS
aws dynamodb describe-table --table-name foo-events --region us-east-1
```
