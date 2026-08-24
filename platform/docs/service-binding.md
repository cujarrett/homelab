# Platform Binding

Kubernetes gave us CRDs to describe custom resources, and tools like [Crossplane](https://crossplane.io) turned them into a powerful way to provision infrastructure through APIs. You can declare what you want like S3 or RDS and the platform takes care of the rest.

But there's still a gap in the experience: getting those provisioned credentials into the application without turning every team into accidental infrastructure plumbers.

[Platform Binding](https://servicebinding.io) closes that gap by standardizing how credentials are delivered to workloads - consistently, predictably, as files mounted into the container where the app already lives.

[Fortune 100 Internal Developer Platform patterns, learned on a homelab. Nothing novel.](../../docs/nothing-novel.md)

## The servicebinding.io convention

A "binding" is a directory mounted into the container at `$SERVICE_BINDING_ROOT/<binding-name>/`. Each file in that directory contains one value. What actually lands there depends on the resource:

```
/bindings/
  sql/              type  host  port  database  username  password  (private-cloud)
  sql/              type  host  port  database  username  role-arn  (public-cloud)
  cache/            type  host  port
  nosql/            type  table-name  region  role-arn
  object-storage/   type  bucket  region  role-arn
```

The app reads `os.ReadFile("/bindings/sql/host")` instead of `os.Getenv("DB_HOST")`. This is the invariant: regardless of which backend provisions the resource, the app always reads files from the same path. Whether the value behind `role-arn` came from an AWS-backed resource or `password` from an in-cluster one is a platform concern, not the app's.

## How the Secret gets there

Crossplane and every workload share this cluster - there is no separate platform cluster and no cross-cluster sync. The composition creates the binding Secret directly as a native Kubernetes composed resource using `function-go-templating`. For a resource with its own connection Secret (an RDS `Instance`, an ElastiCache `ReplicationGroup`), the go-templating step reads `.desired.composite.connectionDetails` and writes the final binding Secret in the app namespace, shaped to the table above. For an in-cluster resource with no upstream Secret (`private-cloud` Redis, `private-cloud` Postgres), the composition writes the binding Secret's values itself.

The pod mounts it as a service binding volume:

```yaml
volumes:
  - name: sql-binding
    secret:
      secretName: my-sql
      optional: true
volumeMounts:
  - name: sql-binding
    mountPath: /bindings/sql
```

No extra tooling required - the composition creates the Secret in the app namespace and it's immediately available.

## What `role-arn` means instead of a password

`ObjectStorage`, `NoSql`, and any `Sql` or `Cache` on `backend: public-cloud` never put a static AWS credential in the binding Secret at all - only an IAM Role ARN and resource metadata. The pod's [`workload-identity-sidecar`](https://github.com/cujarrett/workload-identity-sidecar) exchanges the pod's SPIFFE identity for real, hourly STS credentials at runtime and writes those to a separate volume, which the app reads through a named `AWS_PROFILE_*` environment variable. The binding Secret and the credential exchange are two different mechanisms - see [AWS credential binding](../README.md#aws-credential-binding) for the full flow.

## Why init containers and `optional: true`

The binding Secret doesn't exist until the cloud resource is fully provisioned. Without an init container the app would start immediately and crash or silently fail before credentials are available.

The init container polls until the binding file exists:

```yaml
- name: wait-for-sql-binding
  image: busybox:1.36
  command: [sh, -c, "until [ -f /bindings/sql/type ]; do echo waiting; sleep 5; done"]
```

The first deploy takes as long as cloud provisioning. Subsequent pod restarts are immediate - the Secret already exists.

The volume definition uses `optional: true`:

```yaml
volumes:
  - name: sql-binding
    secret:
      secretName: {name}-sql
      optional: true
```

This lets the pod schedule before the Secret exists. The init container is what actually enforces readiness - `optional: true` just prevents a scheduling deadlock.

## Credential rotation

Kubernetes keeps Secret volume mounts (non-`subPath`) in sync automatically. When a Secret is updated, the kubelet propagates the new file contents to running pods within about a minute - no pod restart required. This covers `password` on a `private-cloud` binding.

**The app is responsible for acting on the change.** If it reads binding files once at startup and holds the values in memory, it will keep using stale credentials until the pod restarts. To benefit from live rotation, read binding files on every use, not once at startup. Treat them like a config file, not a constructor argument.

```go
// Good - re-reads on every call
func getSQLConn() string {
    host, _ := os.ReadFile("/bindings/sql/host")
    pass, _ := os.ReadFile("/bindings/sql/password")
    ...
}

// Bad - cached at startup, misses rotations
var conn = buildConn(os.ReadFile("/bindings/sql/host"))
```

**Init containers don't help with rotation.** They only run at pod start. They gate initial credential availability but play no role after the pod is up.

**`role-arn` bindings don't rotate this way at all.** The ARN itself never changes, so there is nothing in the binding Secret to sync. The credentials behind it rotate on their own schedule inside the sidecar - see [AWS credential binding](../README.md#aws-credential-binding).

## `backend: private-cloud` vs `public-cloud`

The composition is the only layer that knows what backs a binding. The app sees identical binding files regardless of whether `password` came from an in-cluster Postgres pod or `role-arn` from RDS.

`Sql` and `Cache` both take a `backend` parameter:

```yaml
spec:
  parameters:
    backend: private-cloud   # or public-cloud
```

`private-cloud` renders an in-cluster Deployment (Postgres or Redis) and writes the binding Secret directly, with the in-cluster Service DNS name as `host`. `public-cloud` renders the AWS resource and derives the binding Secret from its connection details. The init container pattern is identical either way - the `private-cloud` Secret just appears immediately, since there's no cloud provisioning to wait on.

## Manual wiring vs. the ServiceBinding operator

There is a formal [servicebinding.io operator](https://github.com/servicebinding/runtime) that defines a `ServiceBinding` CRD. You point it at a Kubernetes Secret and a Deployment and it injects the volume mount automatically - no composition changes needed.

With manual wiring, the wiring lives in the Crossplane composition - one place of truth, no extra operator to install or manage. The init container readiness pattern (block the app until the Secret exists) is not something the ServiceBinding operator handles either way.

The ServiceBinding operator is worth adopting when workloads are not managed by a Crossplane composition at all (plain Deployments deployed outside of platform abstractions).
