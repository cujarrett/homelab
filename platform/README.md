# Platform

Crossplane-based internal developer platform. Declare what your app needs. The platform provisions it, wires it, and delivers credentials directly to the pod — no Terraform, no tickets, no credential management in application code.

## Philosophy

- **Declare resources, not steps.** An `XApi` with a `sqlRef` is a statement of intent. The composition figures out IAM roles, init containers, volume mounts, credential rotation — none of that is the app's problem.
- **Credentials reach the pod as files, not env vars.** The [servicebinding.io](https://servicebinding.io) convention makes bindings portable and predictable. The app reads `/bindings/sql/host`. It doesn't care whether that's in-cluster Postgres or RDS.
- **Choose your backend, keep your app the same.** Some resources offer both in-cluster and cloud-managed variants: Postgres or RDS, Redis or ElastiCache. The `sqlRef` works for both. The app reads `/bindings/sql/host`. It doesn't care where the database lives.
- **Data resources outlive APIs.** `XSql`, `XNoSql`, `XObjectStorage` have lifecycles independent of any one `XApi`. Create them once, reference them by name.
- **No static credentials for AWS.** Every AWS binding uses workload identity: a short-lived X.509 certificate exchanged for temporary STS credentials via IAM Roles Anywhere. No access keys in Secrets or config files.

---

## Offerings

| XR | What it provisions | `private-cloud` | `public-cloud` |
|---|---|---|---|
| [`XApi`](api/README.md) | Deployment · Service · Ingress · TLS | — | — |
| [`XSpa`](spa/README.md) | Static frontend via nginx | — | — |
| [`XSql`](sql/README.md) | Relational database | Postgres on Longhorn | AWS RDS Postgres |
| [`XCache`](cache/README.md) | Cache cluster (owned by XApi) | Redis | AWS ElastiCache |
| [`XNoSql`](nosql/README.md) | Key-value / document store | ExtendDB *(planned)* | AWS DynamoDB |
| [`XObjectStorage`](object-storage/README.md) | Object store | MinIO *(planned)* | AWS S3 |
| [`XTopic`](topic/README.md) | Durable message stream | NATS JetStream | — |
| [`XSubscription`](subscription/README.md) | Durable consumer cursor | NATS JetStream | — |
| [`XConnection`](connection/README.md) | Grants a workload→workload or workload→external network connection, enforced by workload identity | — | — |
---

## How resources connect

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 40, 'rankSpacing': 60}}}%%
flowchart TD
    xapi["XApi\nDeployment + Service + Ingress"]
    xspa["XSpa\nnginx frontend"]
    xcache["XCache\nowned by XApi"]
    xsql["XSql\nstandalone lifecycle"]
    xnosql["XNoSql\nstandalone lifecycle"]
    xos["XObjectStorage\nstandalone lifecycle"]
    xtopic["XTopic\nNATS stream"]
    xsub["XSubscription\nconsumer cursor"]

    xapi -->|"cache.enabled"| xcache
    xapi -->|"sqlRef"| xsql
    xapi -->|"nosqlRef"| xnosql
    xapi -->|"objectStorageRefs"| xos
    xapi -->|"topicRef"| xtopic
    xapi -->|"subscriptionRef"| xsub
    xspa -.->|"companion API"| xapi
```

`XCache` is created and destroyed with its `XApi`. Everything else is independent — delete an `XApi` without touching its database.

The refs above are **data** dependencies — what an app is wired to. [`XConnection`](connection/README.md) governs the **network** layer separately: once a workload is locked down (`enforce: true` on its `XApi`), it accepts nothing until you declare who may reach it. A `ref` provisions and binds a resource; an `XConnection` grants permission for traffic to flow — workload→workload, or workload→external host.

---

## Service binding

Credentials reach the pod via `/bindings/`, following the [servicebinding.io](https://servicebinding.io) spec. The composition provisions the resource and writes a Kubernetes Secret in the app namespace; the pod mounts it at `/bindings/`.

```
/bindings/
  sql/              type  host  port  database  username  password  (private-cloud)
  sql/              type  host  port  database  username  role-arn  profile-arn  (public-cloud)
  cache/            type  host  port
  nosql/            type  table-name  region  role-arn  profile-arn
  object-storage/   type  bucket  region  role-arn  profile-arn
```

For non-AWS resources (private-cloud SQL, in-cluster cache, NATS), the app reads credential files directly:

```go
host, _ := os.ReadFile("/bindings/sql/host")
port, _ := os.ReadFile("/bindings/sql/port")
```

For AWS-backed resources (those with `role-arn`/`profile-arn`), the binding Secret contains ARNs — not credentials. The [`aws-spiffe-helper`](https://github.com/cujarrett/aws-spiffe-helper) sidecar reads those and writes actual STS credentials to a separate volume; the app uses `AWS_PROFILE_*` env vars instead. See [AWS credential binding](#aws-credential-binding) below.

An init container blocks the app from starting until each binding's Secret is fully synced to the volume. Once it exits, every file is there — no retry logic needed in the app.

Reference an existing resource from an `XApi` by name:

```yaml
spec:
  parameters:
    sqlRef:
      name: foo-db          # existing XSql
    objectStorageRefs:
      - name: foo-assets    # existing XObjectStorage
```

---

## AWS credential binding

AWS-backed offerings (`XObjectStorage`, `XNoSql`, `XSql` with `backend: public-cloud`, `XCache` with `backend: public-cloud`) use workload identity instead of static keys. The binding Secret contains ARNs and resource metadata — no access key, no secret.

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 45, 'rankSpacing': 60}}}%%
flowchart LR
    subgraph cluster["Cluster"]
        spire["SPIRE\nissues X.509 SVID\nper pod identity"]
        sidecar["aws-credentials-sidecar\nexchanges SVID for STS creds\nrefreshes every 50 min"]
        app["api container\nreads AWS named profile\nfrom shared volume"]
        spire -->|"cert + key"| sidecar
        sidecar -->|"writes credentials"| app
    end

    subgraph aws["AWS"]
        ra["IAM Roles Anywhere\nvalidates cert chain\nchecks SPIFFE ID condition"]
        sts["STS\n1h temp credentials"]
        ra --> sts
    end

    sidecar -->|"SVID + role ARN"| ra
    sts -->|"access key + session token"| sidecar
```

Each binding gets its own IAM Role scoped to the pod's exact SPIFFE ID — wrong namespace, wrong service account, different cluster: rejected.

The app uses named AWS profiles injected by the composition. Profile env var names are derived from the binding: `AWS_PROFILE_{REF_NAME_UPPER_SNAKE_CASE}` for object storage refs, `AWS_PROFILE_NOSQL` for nosql, `AWS_PROFILE_SQL` for public-cloud sql, and `AWS_PROFILE_CACHE` for public-cloud cache.

```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_FOO_ASSETS")))
s3 := s3.NewFromConfig(cfg)
```

For the full design: [`docs/workload-identity.md`](../docs/workload-identity.md)

---

## Environments and feature branches

**The namespace is the environment boundary.** Every AWS resource name embeds both namespace and XR name — `crossplane-{ns}-{name}-*` for IAM roles, `platform-{ns}-{name}` for S3 buckets. Within a namespace, XApi names must be unique (standard Kubernetes). Across namespaces, names are independent — `foo-api` in `ns-alice` and `foo-api` in `ns-bob` produce completely separate IAM roles, secrets, and buckets.

### Feature branch pattern

Each engineer or branch gets its own namespace.

```
namespace: foo-alice          namespace: foo-bob
────────────────────          ─────────────────────
XSql    foo-db                XSql    foo-db
XNoSql  foo-events            XNoSql  foo-events
XApi    foo-api               XApi    foo-api
```

IAM roles: `crossplane-foo-alice-foo-api-nosql` vs `crossplane-foo-bob-foo-api-nosql`. S3 buckets: `platform-foo-alice-foo-assets` vs `platform-foo-bob-foo-assets`.

### Test / QA / Prod tiers

Use `private-cloud` backends for feature branches and test to avoid AWS cost. Promote to `public-cloud` at QA and above. The `XApi` binding is identical — only `backend:` changes in the resource YAML.

| Tier | Namespace pattern | Backend | Notes |
|---|---|---|---|
| Feature branch | `{app}-{branch}` or `{app}-{engineer}` | `private-cloud` | Short-lived; cheap; spun up per-branch |
| Test | `{app}-test` | `private-cloud` | Persistent; no AWS cost |
| QA | `{app}-qa` | `public-cloud` | Real AWS; shared QA dataset |
| Prod | `{app}-prod` | `public-cloud` | Real AWS; production data |

### XSql and shared databases

`XSql` creates the underlying RDS instance. Multiple XApis can share one RDS instance by listing themselves in `consumerServiceAccounts` — each gets its own IAM role and binding secret scoped to its SA, identical to how XNoSql and XObjectStorage work.

For feature branches and test, use `backend: private-cloud`. Each branch gets its own in-cluster Postgres at near-zero cost and full isolation. Reserve `public-cloud` XSql for QA and prod.
