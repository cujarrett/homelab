# Service Binding

## What This Is

A pattern for automatically wiring infrastructure credentials into Kubernetes applications — no manual `kubectl create secret` or hand-written volume mounts. When an API declares `objectStorage.enabled: true`, Crossplane provisions the resource, writes credentials into a Kubernetes Secret, and the Deployment picks them up via a volume mount. The app just reads files.

The convention used is [servicebinding.io](https://servicebinding.io): credentials are mounted as a directory of plain text files rather than environment variables. Each file is named after its key.

## Two Deployment Models

From the app's perspective both models are identical — the pod reads files from `$SERVICE_BINDING_ROOT`. The difference is how the Secret gets into the workload cluster.

### Model 1: Same cluster

Crossplane and the workload share the same cluster. Crossplane writes the connection Secret directly into the app namespace via `writeConnectionSecretToRef`.

```
XObjectStorage composition
  └─ writeConnectionSecretToRef → Secret in app namespace (same cluster)
                                        ↓
                                  Pod volume mount
```

Simpler, but constrains you: the workload must run on the same cluster that Crossplane manages cloud resources on.

### Model 2: Cross-cluster (platform cluster + workload cluster)

Crossplane runs on a dedicated platform cluster and publishes connection details to an external store (e.g. AWS Secrets Manager). A workload cluster runs External Secrets Operator (ESO) to pull the secret down into the workload namespace.

```
Platform cluster (Crossplane)
  └─ publishConnectionDetailsTo → StoreConfig → AWS Secrets Manager
                                                        ↓
Workload cluster (ESO)
  └─ ClusterSecretStore → Secrets Manager
  └─ ExternalSecret → Secret in workload app namespace
                             ↓
                       Pod volume mount (same binding files as Model 1)
```

No direct Kubernetes API access between clusters. Secrets Manager is the neutral handoff point. The `XObjectStorage` and `XCache` compositions swap `writeConnectionSecretToRef` for `publishConnectionDetailsTo`; the `XApi` composition (init containers + volume mounts) is unchanged because the Secret still lands in the app namespace — ESO just puts it there instead of Crossplane directly.

## The servicebinding.io Convention

A "binding" is a directory mounted into the container at `$SERVICE_BINDING_ROOT/<binding-name>/`. Each file in that directory contains one value.

```
/bindings/
  object-storage/
    type        → "s3"
    provider    → "aws"
    bucket      → "my-bucket-name"
    region      → "us-east-1"
    username    → "REDACTED"
    password    → "REDACTED"
  cache/
    type        → "redis"
    provider    → "aws"
    host        → "my-cluster.abc123.cache.amazonaws.com"
    port        → "6379"
```

The app reads `os.ReadFile("/bindings/object-storage/bucket")` instead of `os.Getenv("S3_BUCKET")`. This keeps the app decoupled from how or where the credentials come from.

## Architecture

```
XApi (Composite Resource)
│
│  spec.objectStorage.enabled: true
│
├── XObjectStorage (Composed sub-XR)          ← platform/object-storage/
│   │
│   ├── Bucket (MR)                           ← s3.aws.upbound.io
│   ├── User (MR)                             ← iam.aws.upbound.io
│   ├── AccessKey (MR)                        ← iam.aws.upbound.io
│   ├── Policy (MR)                           ← iam.aws.upbound.io
│   └── UserPolicyAttachment (MR)             ← iam.aws.upbound.io
│       │
│       └── connectionDetails bubble up →
│           writes Secret "{name}-object-storage" in app namespace
│           keys: type, provider, bucket, region, username, password
│
└── Deployment (composed resource)
    ├── initContainer: waits until /bindings/object-storage/type exists
    └── volume: mounts Secret "{name}-object-storage" at /bindings/object-storage/
```

**MR** = Managed Resource (the actual AWS resource, owned by a provider).
**Composed XR** = an XR embedded inside another XR's composition. `XObjectStorage` is both a standalone primitive and a composed resource inside `XApi`.

## Key Files

| File | Purpose |
|||
| `/object-storage/xrd.yaml` | Defines the `XObjectStorage` CRD. Fields: `region`. Connection secret keys: `type`, `provider`, `bucket`, `region`, `username`, `password`. |
| `/object-storage/composition.yaml` | Creates the S3 Bucket + IAM User/AccessKey/Policy. Writes credentials to `writeConnectionSecretToRef`. |
| `/api/xrd.yaml` | Defines the `XApi` CRD. Fields: `namespace`, `image`, `port`, `host`, `tlsIssuer`, `secretRef`, `objectStorage.enabled`, `cache.enabled`. |
| `/api/composition.yaml` | Single go-templating pipeline step. Conditionally renders `XObjectStorage` and `XCache` sub-XRs, init containers, and volume mounts based on the `enabled` flags. |
| `/cache/xrd.yaml` | Defines the `XCache` CRD. |
| `/cache/composition.yaml` | Creates an ElastiCache ReplicationGroup. Writes credentials to `writeConnectionSecretToRef`. |

## How Connection Details Flow

Crossplane MRs write connection details (e.g. the IAM access key ID and secret access key, which together authenticate S3 requests) into a Secret in `crossplane-system` by default. To get them into the app namespace, the composition uses `writeConnectionSecretToRef` on the XR with `namespace` patched to the app namespace and `name` patched to a deterministic value (e.g. `{xr-name}-object-storage`).

```
MR (AccessKey)
  └─ connectionDetails: [username, password, ...]
       │
       ↓ bubbles up through composed XR
XObjectStorage
  └─ writeConnectionSecretToRef:
       name: {xapi-name}-object-storage
       namespace: {app-namespace}
       │
       ↓ Crossplane writes
Secret "{xapi-name}-object-storage" in app namespace
  └─ data: { type, provider, bucket, region, username, password }
       │
       ↓ Kubernetes volume mount
Pod /bindings/object-storage/
  ├── type
  ├── provider
  ├── bucket
  ├── region
  ├── username
  └── password
```

## Why Init Containers

The binding Secret doesn't exist until the cloud resource is fully provisioned. Without an init container, the app container would start immediately and either crash (if the app requires credentials at startup) or silently fail (if it reads lazily).

The init container polls until the file exists:

```yaml
- name: wait-for-object-storage-binding
  image: busybox:1.36
  command:
    - sh
    - -c
    - "until [ -f /bindings/object-storage/type ]; do echo waiting; sleep 5; done"
```

This means the first deploy of an XApi with `objectStorage.enabled: true` will take as long as S3 bucket + IAM provisioning (~10–30 seconds). Subsequent restarts are immediate because the Secret already exists.

## Why `optional: true` on Volumes

The XApi composition Deployment volume definition uses `optional: true`:

```yaml
volumes:
  - name: object-storage-binding
    secret:
      secretName: {name}-object-storage
      optional: true
```

This allows the pod to schedule even before the Secret exists (or if `objectStorage.enabled: false` and no Secret is ever created). The init container is what actually enforces readiness — not the volume mount itself.

## Credential Rotation

Kubernetes keeps Secret volume mounts (non-`subPath`) in sync automatically. When a Secret is updated, the kubelet propagates the new file contents to running pods within ~1 minute — no pod restart required.

**The app is responsible for acting on the change.** If it reads binding files once at startup and holds the values in memory, it will keep using stale credentials until the pod restarts. To benefit from live rotation, read binding files on every use, not once at startup. Treat them like a config file, not a constructor argument.

```go
// Good — re-reads on every call
func getS3Client() *s3.Client {
    key, _ := os.ReadFile("/bindings/object-storage/username")
    secret, _ := os.ReadFile("/bindings/object-storage/password")
    ...
}

// Bad — cached at startup, misses rotations
var s3Client = buildS3Client(os.ReadFile("/bindings/object-storage/username"))
```

**Init containers don't help with rotation.** They only run at pod start. They gate initial credential availability but play no role after the pod is up.

**Crossplane's side:** If using ESO → Secrets Manager, ESO's `refreshInterval` re-syncs the Kubernetes Secret once the upstream value changes — but the upstream rotation (new key in AWS) still needs to happen separately.

## Manual Wiring vs. the ServiceBinding Operator

There is a formal [servicebinding.io operator](https://github.com/servicebinding/runtime) that defines a `ServiceBinding` CRD. You point it at a Kubernetes Secret and a Deployment and it injects the volume mount automatically — no composition changes needed.

This XApi uses **manual wiring** (volume mounts inside the composition) deliberately:

- The wiring lives in the Crossplane composition — one place of truth, no extra operator to install or manage
- The init container readiness pattern (block the app until the Secret exists) is not something the ServiceBinding operator handles
- Fewer moving parts overall

The ServiceBinding operator is worth adopting when workloads are not managed by a Crossplane composition (plain Deployments deployed outside of platform abstractions). For XApi consumers, the auto-wiring is fully invisible — they set `objectStorage.enabled: true` and never touch a Secret or volume mount.

## Composition Pipeline

`XApi` uses a single `function-go-templating` pipeline step. All resources are rendered inline as a Go template string. Conditional blocks control whether sub-XRs and their corresponding init containers/volumes appear:

```go
{{- $objectStorageEnabled := and $xr.spec.objectStorage $xr.spec.objectStorage.enabled }}
{{- if $objectStorageEnabled }}
# renders: XObjectStorage sub-XR, init container, volume mount
{{- end }}
```

All go-templating resources carry `gotemplating.fn.crossplane.io/ready: "True"` so the XR reaches `Ready=True` without waiting for the go-templating function itself to report readiness (it can't — it just renders YAML).

## IAM and Credential Scope

Credentials delivered via service binding are securely scoped to each app using IAM policies.

## Environment-Aware Bindings (QA vs. Prod)

The composition is the only layer that knows what backs a binding. The XApi consumer and the app see identical binding files regardless of whether the Secret came from ElastiCache or an in-cluster Redis pod.

Add an `environment` field to the `XApi` XRD (`qa` or `prod`, default `prod`). The composition forks on it:

```go
{{- if and $cacheEnabled (eq $xr.spec.environment "prod") }}
# renders XCache sub-XR → provisions ElastiCache → bubbles up connection Secret
{{- end }}
{{- if and $cacheEnabled (eq $xr.spec.environment "qa") }}
# renders in-cluster Redis Deployment + Service + a plain Secret with identical keys
{{- end }}
```

For QA, the composition writes the Secret directly (no MR, no cloud provisioning) with the in-cluster Service DNS name as `host`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}-cache
  namespace: {{ $ns }}
stringData:
  type: redis
  provider: in-cluster
  host: {{ $name }}-cache.{{ $ns }}.svc.cluster.local
  port: "6379"
```

The init container (`until [ -f /bindings/cache/type ]`) works identically for both paths — the QA Secret appears immediately (no cloud wait), so the init container exits fast.

The XApi consumer sets `cache.enabled: true` and `environment: qa`. The app reads the same `/bindings/cache/` files. No compromise to the binding contract.

## ESO + Service Binding (Multi-Cluster)

This pattern extends service binding to a model where Crossplane manages cloud resources on a **platform cluster** and workloads run on one or more separate **workload clusters**. [External Secrets Operator (ESO)](https://external-secrets.io) is the bridge between them.

### How it works

```
┌─────────────────────────────────────┐
│   Platform Cluster                  │
│   (Crossplane)                      │
│                                     │
│ [1] Compose resource (XR)           │
│     └─ publishes connection         │
│        details to AWS               │
│        Secrets Manager              │
│        (publishConnectionDetailsTo) │
└──────────────┬──────────────────────┘
               │
               ▼
        ┌───────────────────────┐
        │   [2] AWS Secrets     │
        │       Manager         │
        └─────────┬─────────────┘
                  │ [3] ESO ClusterSecretStore references same store
                  ▼
        ┌───────────────────────────────────┐
        │   Workload Cluster (ESO)          │
        │                                   │
        │ [4] ExternalSecret resource       │
        │     pulls secret from AWS         │
        │     Secrets Manager into local    │
        │     namespace                     │
        │                                   │
        │ [5] ESO creates Kubernetes        │
        │     Secret in workload namespace  │
        │                                   │
        │ [6] Pod mounts Secret as          │
        │     service binding volume        │
        └───────────────────────────────────┘
```

No cross-cluster Kubernetes API access required. Secrets Manager is the neutral handoff point.

### Composition change: `writeConnectionSecretToRef` → `publishConnectionDetailsTo`

This is the only change needed in `XObjectStorage` and `XCache` compositions to unlock both models.

**Before (same-cluster only):**
```yaml
spec:
  writeConnectionSecretToRef:
    name: my-object-storage
    namespace: my-app
```

**After (works same-cluster and cross-cluster):**
```yaml
spec:
  publishConnectionDetailsTo:
    name: my-object-storage          # path/name in Secrets Manager
    configRef:
      name: aws-secrets-manager      # name of the Crossplane StoreConfig
    metadata:
      labels:
        environment: homelab
```

The `StoreConfig` is a cluster-scoped Crossplane resource that tells Crossplane which external store to use:
```yaml
apiVersion: secrets.crossplane.io/v1alpha1
kind: StoreConfig
metadata:
  name: aws-secrets-manager
spec:
  type: Plugin
  defaultScope: crossplane-system
  plugin:
    endpoint: ess-plugin-aws-sm.crossplane-system:4040  # External Secrets Store controller
```

On the workload cluster, an `ExternalSecret` mirrors the published secret into the app namespace with the same binding-compatible keys:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-object-storage
  namespace: my-app
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: my-object-storage          # Secret name must match volume mount in Deployment
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: my-object-storage       # must match publishConnectionDetailsTo.name
```

The `XApi` composition (init containers + volume mounts) requires no changes — the Secret still lands in the app namespace under the same name.

### Alternative: ESO Kubernetes provider (cross-cluster API)
```
Platform cluster (Crossplane) → writes connection Secret
      ↓
Workload cluster (ESO)
  → SecretStore with provider: kubernetes (kubeconfig pointing at platform cluster)
  → ExternalSecret mirrors Secret into workload namespace
      ↓
  Service binding volume mount
```

Simpler but creates a direct k8s API dependency between clusters. Acceptable for homelab or tightly coupled environments.

## Reference Links
- https://servicebinding.io/
- https://servicebinding.io/application-developer/
- https://servicebinding.io/service-provider/
- https://servicebinding.io/application-operator/
- https://external-secrets.io/
- https://external-secrets.io/latest/provider/aws-secrets-manager/
- https://docs.crossplane.io/latest/concepts/connection-details/
