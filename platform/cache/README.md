# XCache

Crossplane platform primitive that provisions a Redis-compatible cache cluster and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Consumed by `XApi` when `cache.enabled: true`. Can also be used standalone or by other platform compositions.

## What it provisions
- `environment: test` — **Redis Deployment + Service** (in-cluster, `redis:7-alpine`) + binding Secret; no AWS resources
- `environment: prod` — **ElastiCache ReplicationGroup** (AWS) + binding Secret

## Binding secret

Secret name equals the XR name; namespace is the XR name with `-cache` stripped (e.g. `my-app-cache` → secret in namespace `my-app`).

All keys are automatically wired — no manual credential handling required.

| Key | Value |
|---|---|
| `type` | `redis` |
| `provider` | `aws` (prod) or `in-cluster` (test) |
| `host` | Cache endpoint hostname |
| `port` | Cache port (`6379`) |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `region` | no | `us-east-1` | Cloud region for the cache cluster (prod only) |
| `size` | no | `small` | T-shirt size for the cache cluster (prod only): `small`, `medium`, `large` |
| `environment` | no | `test` | `prod` uses AWS ElastiCache; `test` uses in-cluster Redis |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XCache
metadata:
  name: my-app-cache
spec:
  environment: test   # in-cluster Redis — no AWS resources provisioned
# Secret written to: my-app/my-app-cache
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XCache
metadata:
  name: my-app-cache
spec:
  environment: prod  # explicit prod — provisions AWS ElastiCache
  region: us-east-1
  size: small   # small=cache.t4g.micro | medium=cache.t4g.small | large=cache.t4g.medium
# Secret written to: my-app/my-app-cache
```

## Operations

```bash
# XR status
kubectl get xcaches my-app-cache

# Binding secret — confirm all 4 keys are present
kubectl get secret my-app-cache -n my-app \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Ping Redis directly (environment: test — in-cluster only)
kubectl run redis-test --rm -it --restart=Never \
  --image=redis:7-alpine \
  -n my-app \
  -- redis-cli -h my-app-cache-redis.my-app.svc.cluster.local ping
# Expected output: PONG
```
