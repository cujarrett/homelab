# Cache

A Redis-compatible cache for one `Api`. Set `cache.enabled: true` on the `Api`, and the cache is created and deleted with it. It is not meant for standalone use.

Only the owning `Api` can connect to a `private-cloud` cache. Every other caller is refused.

## What it provisions

- `backend: private-cloud`: **in-cluster Redis**. No cloud resources.
- `backend: public-cloud`: **AWS ElastiCache** with IAM auth and TLS. No password or static keys.

> **`public-cloud` cannot be reached from this cluster.** ElastiCache only lives inside an AWS VPC, and no network path links the cluster to it. Connections fail with a TCP `i/o timeout`. Provisioning and credentials both work. No workload uses `public-cloud` Cache. A bridge into the VPC, such as a Tailscale subnet router inside it, would open the path.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `backend` | no | `private-cloud` | `private-cloud` uses in-cluster Redis; `public-cloud` uses AWS ElastiCache with IAM auth. |
| `size` | no | `sm` | Cache size, `public-cloud` only: `sm=cache.t4g.micro`, `md=cache.t4g.small`, `lg=cache.t4g.medium`. |
| `consumerServiceAccount` | set by Api | - | The owning Api's service account. Only that pod can connect. The Api sets it, so tenants never do. |

## Binding secret

The Secret has the Cache's `metadata.name`, in the Cache's namespace. The platform writes it, on `public-cloud` once the cache is ready. No manual steps.

| Key | Value | Backend |
|---|---|---|
| `type` | `redis` | all |
| `provider` | `in-cluster` or `aws` | all |
| `host` | Cache endpoint hostname | all |
| `port` | Cache port (`6379`) | all |
| `role-arn` | IAM role ARN (scoped to this cache) | `public-cloud` only |

On `public-cloud`, the app reads `AWS_PROFILE_CACHE` and connects with those short-lived credentials. They refresh every 50 minutes. Full design: [Platform Workload Identity](../docs/workload-identity.md).

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Cache
metadata:
  name: foo-cache
  namespace: foo
spec:
  parameters:
    backend: public-cloud   # AWS ElastiCache with IAM auth
    size: sm
```

For in-cluster Redis, set `backend: private-cloud` and leave out `size`.

## Operations

```bash
# XR status
kubectl get cache foo-cache -n foo

# Binding secret, to confirm every key is present
kubectl get secret foo-cache -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# ReplicationGroup status (public-cloud, in the Cache's namespace)
kubectl get replicationgroup foo-cache -n foo

# Detailed conditions, showing why something is not ready
kubectl get cache foo-cache -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool
```
