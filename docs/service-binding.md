# Service Binding

Kubernetes gave us CRDs to describe custom resources, and tools like [Crossplane](https://crossplane.io) turned them into a powerful way to provision infrastructure through APIs. You can declare what you want like S3 or RDS and the platform takes care of the rest.

But there’s still a gap in the experience: getting those provisioned credentials into the application without turning every team into accidental infrastructure plumbers.

[Service Binding](https://servicebinding.io) closes that gap by standardizing how credentials are delivered to workloads—consistently, predictably, as files mounted into the container where the app already lives.

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

The app reads `os.ReadFile("/bindings/object-storage/bucket")` instead of `os.Getenv("S3_BUCKET")`. This is the invariant: regardless of what provisions the resource or where it runs, the app always reads files from the same path. Everything below is about how a Kubernetes Secret gets into the app namespace — from the app's perspective it doesn't matter.

## Two Deployment Models

The difference between models is how the Secret gets into the workload namespace. The binding files the app reads are identical in both.

### Model 1: Same cluster

Crossplane and the workload share the same cluster. Crossplane provisions the cloud resource and writes credentials directly into a Kubernetes Secret in the app namespace. The pod mounts it.

```
Crossplane (same cluster)
  └─ provisions cloud resource
  └─ writes credentials → Secret in app namespace
                                    ↓
                            Pod volume mount
```

Simpler, but constrains you: the workload must run on the same cluster that Crossplane manages cloud resources on.

The composition creates the binding Secret directly as a native Kubernetes composed resource using `function-go-templating`. The MR writes an intermediate Secret with the raw credentials; the go-templating step reads them from `.desired.composite.connectionDetails` and creates the final binding Secret in the app namespace.

The pod mounts the Secret as a service binding volume:

```yaml
volumes:
  - name: object-storage-binding
    secret:
      secretName: my-object-storage
      optional: true
volumeMounts:
  - name: object-storage-binding
    mountPath: /bindings/object-storage
```

No extra tooling required — the composition creates the Secret in the app namespace and it's immediately available.

### Model 2: Cross-cluster (platform cluster + workload cluster)

Crossplane runs on a dedicated platform cluster. Credentials are written to a Secret on the platform cluster, then synced to a shared store (e.g. AWS Secrets Manager) and pulled down into the workload cluster's app namespace by [External Secrets Operator](https://external-secrets.io) (ESO).

```
Platform cluster (Crossplane)
  └─ provisions cloud resource
  └─ writes credentials → Secret in crossplane-system
       └─ ESO PushSecret → AWS Secrets Manager
                                    ↓
Workload cluster (ESO)
  └─ ExternalSecret → Secret in app namespace
                             ↓
                       Pod volume mount
```

No direct Kubernetes API access between clusters. Secrets Manager is the neutral handoff point. The pod still reads the same binding files — the delivery mechanism is the only thing that changes.

Configure the MR to write credentials to `crossplane-system` on the platform cluster, then use a `PushSecret` to sync to Secrets Manager:

**MR writes to `crossplane-system`:**
```yaml
# AccessKey MR — writes to crossplane-system for cross-cluster use
writeConnectionSecretToRef:
  name: my-object-storage-raw
  namespace: crossplane-system
```

**ESO on the platform cluster pushes to Secrets Manager:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: PushSecret
metadata:
  name: my-object-storage
  namespace: crossplane-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  selector:
    secret:
      name: my-object-storage-raw
```

On the workload cluster, an `ExternalSecret` mirrors the secret into the app namespace:
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
        key: my-object-storage
```

The composition (init containers + volume mounts) requires no changes — the Secret still lands in the app namespace under the same name.

**Alternative — ESO Kubernetes provider:** Point a `SecretStore` at the platform cluster's k8s API directly instead of going through Secrets Manager. Simpler, but creates a direct k8s API dependency between clusters.

## Why Init Containers and `optional: true`

The binding Secret doesn't exist until the cloud resource is fully provisioned. Without an init container the app would start immediately and crash or silently fail before credentials are available.

The init container polls until the binding file exists:

```yaml
- name: wait-for-object-storage-binding
  image: busybox:1.36
  command: [sh, -c, "until [ -f /bindings/object-storage/type ]; do echo waiting; sleep 5; done"]
```

The first deploy takes as long as cloud provisioning (~10–30s for S3/IAM). Subsequent pod restarts are immediate — the Secret already exists.

The volume definition uses `optional: true`:

```yaml
volumes:
  - name: object-storage-binding
    secret:
      secretName: {name}-object-storage
      optional: true
```

This lets the pod schedule before the Secret exists. The init container is what actually enforces readiness — `optional: true` just prevents a scheduling deadlock.

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

## Environment-Aware Bindings (Test vs. Prod)

The composition is the only layer that knows what backs a binding. The consumer app see identical binding files regardless of whether the Secret came from ElastiCache or an in-cluster Redis pod.

The `XApi` XRD example has an `environment` field (`test` or `prod`, default `test`). The composition forks on it:

```go
{{- if and $cacheEnabled (eq $xr.spec.environment "prod") }}
# renders XCache sub-XR → provisions ElastiCache → writes connection Secret to app namespace
{{- end }}
{{- if and $cacheEnabled (eq $xr.spec.environment "test") }}
# renders in-cluster Redis Deployment + Service + a plain Secret with identical keys
{{- end }}
```

For test, the composition writes the Secret directly (no MR, no cloud provisioning) with the in-cluster Service DNS name as `host`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}-cache
  namespace: {{ $ns }}
stringData:
  type: redis
  provider: in-cluster
  host: {{ $name }}-redis.{{ $ns }}.svc.cluster.local
  port: "6379"
```

The init container (`until [ -f /bindings/cache/type ]`) works identically for both paths — the test Secret appears immediately (no cloud wait), so the init container exits fast.

The XApi consumer sets `cache.enabled: true` and `environment: test`. The app reads the same `/bindings/cache/` files. No compromise to the binding contract.

## Manual Wiring vs. the ServiceBinding Operator

There is a formal [servicebinding.io operator](https://github.com/servicebinding/runtime) that defines a `ServiceBinding` CRD. You point it at a Kubernetes Secret and a Deployment and it injects the volume mount automatically — no composition changes needed.

With manual wiring, the wiring lives in the Crossplane composition — one place of truth, no extra operator to install or manage.

The init container readiness pattern (block the app until the Secret exists) is not something the ServiceBinding operator handles.

The ServiceBinding operator is worth adopting when workloads are not managed by a Crossplane composition (plain Deployments deployed outside of platform abstractions).
