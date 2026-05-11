# XCache

Crossplane platform primitive that provisions a Redis-compatible cache cluster and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Consumed by `XApi` when `cache.enabled: true`. Can also be used standalone or by other platform compositions.

## What it provisions
- `environment: cluster` — **in-cluster cache cluster** + binding Secret; no cloud resources
- `environment: cloud` — **cloud-managed cache cluster** + binding Secret

## Binding secret

Secret name equals the XR name; namespace comes from the explicit `namespace` parameter passed by the parent `XApi`.

All keys are automatically wired — no manual credential handling required.

| Key | Value |
|---|---|
| `type` | `redis` |
| `provider` | `aws` (cloud) or `in-cluster` (cluster) |
| `host` | Cache endpoint hostname |
| `port` | Cache port (`6379`) |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `region` | no | `us-east-1` | Cloud region for the cache cluster (cloud only) |
| `size` | no | `small` | T-shirt size for the cache cluster (cloud only): `small`, `medium`, `large` |
| `environment` | no | `cluster` | `cloud` uses AWS ElastiCache; `cluster` uses in-cluster Redis |
| `namespace` | yes | — | Namespace to write the binding Secret into. Passed automatically by `XApi`. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XCache
metadata:
  name: foo-cache
spec:
  parameters:
    environment: cluster   # in-cluster Redis — no AWS resources provisioned
# Secret written to: foo/foo-cache
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XCache
metadata:
  name: foo-cache
spec:
  parameters:
    environment: cloud  # explicit cloud — provisions AWS ElastiCache
    region: us-east-1
    size: small   # small=cache.t4g.micro | medium=cache.t4g.small | large=cache.t4g.medium
# Secret written to: foo/foo-cache
```

## Operations

```bash
# XR status
kubectl get xcaches foo-cache

# Binding secret — confirm all 4 keys are present
kubectl get secret foo-cache -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xcache foo-cache -o jsonpath='{.status.conditions}' | python3 -m json.tool
```
