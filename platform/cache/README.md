# XCache

Crossplane platform primitive that provisions a Redis-compatible cache cluster and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Consumed by `XApi` when `cache.enabled: true`. Can also be used standalone or by other platform compositions.

## What it provisions
- **Cache cluster** — Redis-compatible cache (currently AWS ElastiCache ReplicationGroup)
- **Connection Secret** — written to `spec.secretNamespace/spec.secretName` with servicebinding.io-compliant keys

## Connection secret keys

| File | Spec status | Value |
|---|---|---|
| `type` | MUST | `redis` |
| `provider` | SHOULD | `aws` |
| `host` | well-known | Cache endpoint hostname |
| `port` | well-known | Cache port (default `6379`) |
| `username` | well-known | Auth username (if auth enabled) |
| `password` | well-known | Auth password (if auth enabled) |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `secretNamespace` | yes | — | Namespace to write the connection secret into |
| `secretName` | yes | — | Name for the connection secret |
| `region` | no | `us-east-1` | Cloud region for the cache cluster |
| `nodeType` | no | `cache.t4g.micro` | Cache node instance type |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XCache
metadata:
  name: my-app-cache
spec:
  secretName: my-app-cache
  secretNamespace: my-app
  region: us-east-1
  nodeType: cache.t4g.micro
```
