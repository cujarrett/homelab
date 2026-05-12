# Platform

Crossplane-based internal developer platform. Declare what your app needs; the platform provisions it and delivers credentials directly to the pod.

## Offerings

| XR | What it is |
|---|---|
| [`XApi`](api/README.md) | API server deployment with optional resource bindings |
| [`XSpa`](spa/README.md) | Static frontend served via in-cluster nginx |
| [`XObjectStorage`](object-storage/README.md) | S3 bucket with scoped IAM credentials |
| [`XSql`](sql/README.md) | Postgres — in-cluster or AWS RDS |
| [`XNoSql`](nosql/README.md) | DynamoDB table with scoped IAM credentials |
| [`XCache`](cache/README.md) | Redis — in-cluster or AWS ElastiCache; owned by `XApi` |
| [`XTopic`](topic/README.md) | NATS JetStream stream (durable, replicated) |
| [`XSubscription`](subscription/README.md) | Durable NATS consumer cursor |
| [`XWordpress`](wordpress/README.md) | Full WordPress stack |

Data resources (`XObjectStorage`, `XSql`, `XNoSql`) have lifecycles independent of any one `XApi`. Create them once, reference them by name.

## Service Binding

Credentials reach the pod as files, not env vars — following the [servicebinding.io](https://servicebinding.io) convention.

```
/bindings/
  object-storage/   ← files: type, provider, bucket, region, username, password
  sql/              ← files: type, provider, host, port, database, username, password
  nosql/            ← files: type, provider, table-name, region, access-key-id, secret-access-key
  cache/            ← files: type, provider, host, port
```

The app reads `os.ReadFile("/bindings/object-storage/bucket")`. The composition handles everything else: provisioning the cloud resource, writing credentials into a Kubernetes Secret, and mounting it at the right path.

Reference a resource from an `XApi` by name:

```yaml
spec:
  parameters:
    objectStorageRef:
      name: foo-assets   # existing XObjectStorage
    sqlRef:
      name: foo-db       # existing XSql
```

An init container blocks the app from starting until each binding Secret exists. `optional: true` on the volume prevents a scheduling deadlock while provisioning completes.

For a deeper dive: [`docs/service-binding.md`](../docs/service-binding.md)
