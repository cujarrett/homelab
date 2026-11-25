# Platform Binding

Crossplane provisions databases, caches and buckets. [Service binding](https://servicebinding.io) is how their connection details reach the app: as files mounted into the container. Every team reads them the same way, whatever backs the resource.

[Fortune 100 Internal Developer Platform patterns, learned on a homelab. Nothing novel.](../../docs/nothing-novel.md)

## The servicebinding.io convention

A binding is a directory mounted at `$SERVICE_BINDING_ROOT/<binding-name>/`. Each file holds one value. The mount path and files for each kind are in [Platform → Service binding](../README.md#service-binding).

The app reads `os.ReadFile("/bindings/sql/host")`, not `os.Getenv("DB_HOST")`. The path stays the same whichever backend provisions the resource.

## How the Secret gets there

Crossplane and every workload share one cluster. The composition writes the binding Secret into the app namespace with `function-go-templating`.

- **Resource with its own connection Secret** (an RDS `Instance`, an ElastiCache `ReplicationGroup`): the composition reads that resource's observed `connectionDetails` and reshapes it.
- **In-cluster resource** (`private-cloud` Redis or Postgres): the composition writes the values itself.

The pod mounts it as a volume. `optional: true` lets the pod schedule before the Secret exists.

```yaml
volumes:
  - name: sql-binding
    secret:
      secretName: {name}-sql
      optional: true
volumeMounts:
  - name: sql-binding
    mountPath: /bindings/sql
```

## What `role-arn` means instead of a password

`ObjectStorage`, `NoSql`, and any `Sql` or `Cache` on `backend: public-cloud` never put an AWS credential in the binding. The Secret holds only an IAM role ARN and resource metadata.

| Who | Does |
|---|---|
| The sidecar | [`workload-identity-sidecar`](https://github.com/cujarrett/workload-identity-sidecar) trades the pod's SPIFFE identity for hourly STS credentials |
| The app | Reads them through a named `AWS_PROFILE_*` env var |

The full flow is in [AWS credential binding](../README.md#aws-credential-binding).

## Why init containers and `optional: true`

The binding Secret exists only once the resource is provisioned. An init container holds the app until the binding file appears.

```yaml
- name: wait-for-sql-binding
  image: busybox:1.38
  command: [sh, -c, "until [ -f /bindings/sql/type ]; do echo waiting; sleep 5; done"]
```

| Item | Detail |
|---|---|
| `optional: true` | Lets the pod schedule. Without it the pod and Secret deadlock |
| Init container | Enforces readiness |
| First deploy | Takes as long as provisioning. Later restarts are immediate |

## Credential rotation

The kubelet syncs Secret volume mounts (not `subPath`) to running pods within about a minute, with no restart. This covers `password` on a `private-cloud` binding.

**Read binding files on every use, not once at startup.** An app that caches them keeps stale credentials until the pod restarts.

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

- **Init containers:** run only at pod start. They play no part in rotation.
- **`role-arn` bindings:** the ARN never changes. The sidecar rotates the credentials behind it. See [AWS credential binding](../README.md#aws-credential-binding).

## `backend: private-cloud` vs `public-cloud`

`Sql` and `Cache` take a `backend` parameter. The app sees the same binding files either way.

```yaml
spec:
  parameters:
    backend: private-cloud   # or public-cloud
```

- **`private-cloud`:** an in-cluster Postgres or Redis Deployment. The binding Secret appears at once, with the Service DNS name as `host`.
- **`public-cloud`:** the AWS resource. The binding Secret comes from its connection details once provisioning finishes.

## Manual wiring vs. the ServiceBinding operator

The [servicebinding.io operator](https://github.com/servicebinding/runtime) has a `ServiceBinding` CRD that injects the volume mount for you. Here the composition does the wiring, so there is one source of truth and no extra operator. The operator also does not hold the app until the Secret exists.

The operator fits workloads that no Crossplane composition manages, such as plain Deployments.
