# XCache

Crossplane platform primitive that provisions a Redis-compatible cache cluster and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Owned by `XApi` — created and deleted with it when `cache.enabled: true`. Not intended for standalone use.

**⚠️ Phase 7 testing:** The `public-cloud` backend (AWS ElastiCache) is temporary for workload identity validation only. Long-term, only `XApi` and `XNoSql` use cloud resources; caching remains in-cluster via the `private-cloud` backend.

## What it provisions
- `backend: private-cloud` — **in-cluster Redis** + binding Secret; no cloud resources
- `backend: public-cloud` — **AWS ElastiCache** + binding Secret (Phase 7 testing; manual binding Secret required due to provider limitations)

## Binding secret

Secret name equals the XR name; namespace comes from the explicit `namespace` parameter passed by the parent `XApi`.

**For `private-cloud`:** All keys are automatically written by the composition — no manual steps required.

**For `public-cloud` (Phase 7):** The composition provisions the cache but does not automatically write the binding Secret due to ElastiCache User/UserGroup API provider limitations. **Manual workaround:** After the ReplicationGroup (and IAM role/profile) are `READY=True`, manually create the binding Secret with the keys below. See [Operations](#operations) for the command.

| Key | Value | Source |
|---|---|---|
| `type` | `redis` | literal |
| `provider` | `aws` | literal |
| `host` | Cache endpoint hostname | ReplicationGroup connection details |
| `port` | Cache port (`6379`) | ReplicationGroup connection details |
| `role-arn` | IAM role ARN | Role resource `.status.atProvider.arn` |
| `profile-arn` | RolesAnywhere profile ARN | Profile resource `.status.atProvider.arn` |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace to write the binding Secret into. Passed automatically by `XApi`. |
| `backend` | no | `private-cloud` | `private-cloud` uses in-cluster Redis; `public-cloud` uses AWS ElastiCache (Phase 7 testing only). |
| `region` | no | `us-east-1` | Cloud region for the cache cluster (public-cloud only). |
| `size` | no | `sm` | T-shirt size for the cache cluster (public-cloud only): `xs=cache.t4g.micro`, `sm=cache.t4g.small`, `md=cache.t4g.medium`, `lg=cache.t4g.medium`. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XCache
metadata:
  name: foo-cache
spec:
  parameters:
    namespace: foo
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
    namespace: foo
    environment: cloud  # explicit cloud — provisions AWS ElastiCache
    region: us-east-1
    size: small   # small=cache.t4g.micro | medium=cache.t4g.small | large=cache.t4g.medium
# Secret written to: foo/foo-cache
```

## Operations

```bash
# XR status
kubectl get xcache foo-cache -n foo

# Binding secret (private-cloud) — confirm all keys are present
kubectl get secret foo-cache -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# ReplicationGroup status (public-cloud)
kubectl get replicationgroup foo-cache -n foo -o jsonpath='{.status.atProvider | {engine, status, primaryEndpoint}}'

# Manual binding Secret creation (public-cloud) — required after ReplicationGroup is READY
# Replace ROLE_ARN and PROFILE_ARN with actual values from the Role and Profile resources
kubectl create secret generic foo-cache -n foo \
  --from-literal=type=redis \
  --from-literal=provider=aws \
  --from-literal=host=<replicationgroup-endpoint> \
  --from-literal=port=6379 \
  --from-literal=role-arn=arn:aws:iam::...:role/crossplane/... \
  --from-literal=profile-arn=arn:aws:rolesanywhere:us-east-1:...:profile/... \
  --type=servicebinding.io/redis

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xcache foo-cache -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool
```
