# XNoSql

Crossplane platform primitive that provisions an AWS DynamoDB table and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Standalone resource with a lifecycle independent of any one API. Bind to an `XApi` via `nosqlRef.name`.

See also: [`XSql`](../sql/README.md) · [`XCache`](../cache/README.md) · [`XObjectStorage`](../object-storage/README.md) · [`XApi`](../api/README.md)

## What it provisions
- **AWS DynamoDB table** — always cloud; no in-cluster equivalent
- **Scoped IAM user + access key** — credentials locked to this table via ABAC policy
- **Binding Secret** — written to the tenant namespace; contains everything the app needs to connect

DynamoDB tables are ready in ~10–30 seconds after Crossplane calls the API, making the commit-to-running loop fast regardless of environment.

## Binding secret

Secret name equals the XR name; namespace comes from the `namespace` parameter passed by the parent `XApi`. Mounted at `/bindings/nosql/` inside the container.

| Key | Value |
|---|---|
| `type` | `dynamodb` |
| `provider` | `aws` |
| `tableName` | Table name |
| `region` | AWS region |
| `accessKeyId` | IAM access key ID (scoped to this table) |
| `secretAccessKey` | IAM secret access key |

Apps configure the AWS SDK from these keys. No custom endpoint required — the SDK resolves the DynamoDB endpoint from `region` automatically.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace to write the binding Secret into. Passed automatically by `XApi`. |
| `region` | no | `us-east-1` | AWS region for the DynamoDB table |
| `partitionKey` | no | `id` | Partition key attribute name |
| `partitionKeyType` | no | `S` | Partition key type: `S`=string, `N`=number, `B`=binary |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XNoSql
metadata:
  name: foo-events
spec:
  parameters:
    namespace: foo
    # region and partitionKey default to us-east-1 and id
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XNoSql
metadata:
  name: foo-events
spec:
  parameters:
    namespace: foo
    region: us-east-1
    partitionKey: userId
    partitionKeyType: S
```

Then reference from an `XApi`:

```yaml
spec:
  parameters:
    nosqlRef:
      name: foo-events
```

Instance files live in [`homelab-tenants/`](../../../homelab-tenants/).

## Per-workload auth

Each `XNoSql` instance creates a dedicated IAM user with credentials scoped to its specific table via ABAC. The policy ARN is stored in the `aws-platform-config` EnvironmentConfig (`dynamoDbPolicyArn`). The ABAC policy grants `dynamodb:*` scoped to `arn:aws:dynamodb:{region}:*:table/${aws:PrincipalTag/Table}` — the IAM user can only access the table it was created for. See `todo/workload-identity.md` for the full roadmap.

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xnosqls foo-nosql

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xnosql foo-nosql -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all 6 keys are present
kubectl get secret foo-nosql -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Verify table exists in AWS
aws dynamodb describe-table --table-name foo-nosql --region us-east-1
```
