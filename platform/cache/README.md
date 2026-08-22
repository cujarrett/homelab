# Cache

Crossplane platform primitive that provisions a Redis-compatible cache cluster and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Owned by `Api` - created and deleted with it when `cache.enabled: true`. Not intended for standalone use.

## What it provisions
- `backend: private-cloud` - **in-cluster Redis** + binding Secret; no cloud resources
- `backend: public-cloud` - **AWS ElastiCache** (IAM auth) + IAM Role + binding Secret; no static credentials

> **Known limitation: `public-cloud` is not currently reachable from this cluster.** ElastiCache clusters are always VPC-internal - there is no public-access option at all, for any AWS account. There is no network path (VPN, peering, or otherwise) between this homelab cluster and the VPC the ReplicationGroup lands in, so pods cannot connect - verified: connection attempts fail with a raw TCP `i/o timeout`. Everything up to that point works correctly: the ReplicationGroup provisions, the IAM Role is created, and the sidecar successfully exchanges the pod's SVID for real STS credentials. The gap is purely network reachability, not identity or credentials. No current workload uses `public-cloud` for Cache. Unlike Sql, there's no "make it internet-reachable" option here at all - the only way to close this gap is bridging into the VPC (e.g. a Tailscale subnet router running inside it, the same pattern already used for the homelab's own LAN) - worth doing only when a real workload needs it.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | - | Namespace to write the binding Secret into. Passed automatically by `Api`. |
| `backend` | no | `private-cloud` | `private-cloud` uses in-cluster Redis; `public-cloud` uses AWS ElastiCache with IAM auth. |
| `size` | no | `sm` | T-shirt size for the cache cluster (public-cloud only): `xs=cache.t4g.micro`, `sm=cache.t4g.small`, `md=cache.t4g.medium`, `lg=cache.t4g.medium`. |
| `consumerServiceAccount` | set by Api | - | Name of the Api service account. Used to scope the IAM trust policy to the pod's exact SPIFFE ID. Set automatically by the Api composition - not a tenant concern. |

## Binding secret

Secret name equals the Cache's `metadata.name`; namespace comes from the `namespace` parameter.

**For `private-cloud`:** Written automatically by the composition once the Redis Deployment is ready.

**For `public-cloud`:** Written automatically by the composition once the ReplicationGroup is ready. The role ARN is computed from the deterministic naming convention and does not need to be observed first. No manual steps required.

| Key | Value | Backend |
|---|---|---|
| `type` | `redis` | all |
| `provider` | `in-cluster` or `aws` | all |
| `host` | Cache endpoint hostname | all |
| `port` | Cache port (`6379`) | all |
| `role-arn` | IAM role ARN (scoped to this cache) | `public-cloud` only |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Cache
metadata:
  name: foo-cache
spec:
  parameters:
    namespace: foo
    backend: private-cloud   # in-cluster Redis - no AWS resources provisioned
```

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Cache
metadata:
  name: foo-cache
spec:
  parameters:
    namespace: foo
    backend: public-cloud   # AWS ElastiCache with IAM auth
    size: sm
```

## Public-cloud provisioning

The `public-cloud` backend runs a two-pass chain. The second step is deferred until the
first step's output is available in observed state.

```
Pass 1: ElastiCache IAM User + UserGroup created
        IAM Role created (trust policy locked to pod's SPIFFE ID; inline policy grants elasticache:Connect to this cluster and user)
Pass 2: ReplicationGroup created (deferred until UserGroup is ready - AWS requirement)
        Binding Secret written (deferred until ReplicationGroup is ready)
```

The ElastiCache cluster uses IAM authentication with TLS required. The IAM Role's inline policy grants only `elasticache:Connect` scoped to this specific ReplicationGroup and User ARN - no other cluster is reachable. The trust policy is locked to the Api pod's exact SPIFFE ID:

```json
"oidc.mattjarrett.dev:sub": "spiffe://homelab.local/ns/{namespace}/sa/{service-account}"
```

The `workload-identity-sidecar` exchanges the pod's SVID for short-lived STS credentials every 50 minutes. The app reads `AWS_PROFILE_CACHE` and uses those credentials when connecting to ElastiCache - no password, no static keys. For the full design: [Platform Workload Identity](../docs/workload-identity.md)

## Operations

```bash
# XR status (XRs are cluster-scoped - no -n flag)
kubectl get cache foo-cache

# Binding secret - confirm all keys are present
kubectl get secret foo-cache -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'

# ReplicationGroup status (public-cloud - managed resources are cluster-scoped)
kubectl get replicationgroup -o jsonpath='{.items[*].status.atProvider | {engine, status, primaryEndpoint}}'

# Detailed conditions - shows exactly WHY something is not ready
kubectl get cache foo-cache -o jsonpath='{.status.conditions}' | python3 -m json.tool
```
