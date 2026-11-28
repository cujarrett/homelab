# Platform

Declare what your app needs in an XR file. The platform builds it, connects it and hands credentials to the pod. Apps hold no keys and file no tickets.

## Philosophy

- **Declare resources, not steps.** The platform handles roles, startup order, mounts and credential rotation.
- **Credentials arrive as files.** `/bindings/sql/host` reads the same on every backend, so a backend switch never changes the app. This follows [servicebinding.io](https://servicebinding.io).
- **Data outlives apps.** Create `Sql`, `NoSql` and `ObjectStorage` once, then reference them by name.
- **No app holds a static identity credential.** Every AWS and Entra identity comes from the pod's short-lived identity token (SVID). A third-party API key is a value, so it arrives as a file.
- **Every image we build says how it was built.** The cluster blocks any of our images without a signed SLSA Build Level 3 record. See [Image Provenance](./docs/image-provenance.md).
- **Nothing is reachable until declared.** Sharing a cluster or a namespace grants nothing.
- **Apps never see Istio.** No Istio kinds, SPIFFE strings or Envoy appear in a workspace file.
- **Nobody invents an `aud`, `iss`, scope, redirect URI or role GUID.** The platform derives them for registrations it owns. The owner supplies them for any other.

## Offerings

| XR | What it provisions | `private-cloud` | `public-cloud` |
|---|---|---|---|
| [`Api`](api/README.md) | Deployment · Service · Route | - | - |
| [`Spa`](spa/README.md) | Static frontend via nginx | - | - |
| [`Wordpress`](wordpress/README.md) | WordPress site with its own database | - | - |
| [`Sql`](sql/README.md) | Relational database | Postgres on Longhorn | AWS RDS Postgres |
| [`Cache`](cache/README.md) | Cache cluster (owned by Api) | Redis | AWS ElastiCache |
| [`NoSql`](nosql/README.md) | Key-value / document store | ExtendDB *(planned)* | AWS DynamoDB |
| [`ObjectStorage`](object-storage/README.md) | Object store | MinIO *(planned)* | AWS S3 |
| [`Topic`](topic/README.md) | Durable message stream | NATS JetStream | - |
| [`Subscription`](subscription/README.md) | Durable consumer cursor | NATS JetStream | - |
| [`ManagedSecret`](managed-secret/README.md) | A console-set value, delivered as files | - | AWS Secrets Manager |
| [`FederatedGraph`](federated-graph/README.md) | Federated GraphQL router and composed schema | - | - |
| [`GraphApi`](graph-api/README.md) | One team's subgraph, joined to a FederatedGraph | - | - |
| [`WorkflowSpace`](workflow-space/README.md) | Durable workflow space, used by an Api through `workflowSpaceRef` | Temporal in the cluster | Temporal Cloud |

## How resources connect

An `Api` links to other resources by name with `sqlRef`, `nosqlRef`, `objectStorageRefs`, `topicRef`, `subscriptionRef`, `managedSecretRefs` and `workflowSpaceRef`. A `Spa` can sit in front of an `Api` as its companion.

`cache.enabled` gives an `Api` its own `Cache`, created and deleted with it. Everything else lives on its own, so deleting an `Api` leaves its database alone.

## Service binding

Each binding is a directory of files under `/bindings/`, one value per file. The app starts only once every file is there, so it needs no retry logic.

```
/bindings/
  sql/                  type  provider  host  port  database  username  password  (private-cloud)
  sql/                  type  provider  host  port  database  username  role-arn  (public-cloud)
  cache/                type  provider  host  port                                (private-cloud)
  cache/                type  provider  host  port  role-arn                      (public-cloud)
  nosql/                type  provider  table-name  region  role-arn
  object-storage-foo/   type  provider  bucket  region  role-arn
```

Each `objectStorageRefs` entry mounts at `object-storage-<ref-name>/`. Every other kind binds once per `Api`. File values are in [Api → Binding secrets](./api/README.md#binding-secrets).

Bindings without a `role-arn` hold real values. Read them directly.

```go
host, _ := os.ReadFile("/bindings/sql/host")
port, _ := os.ReadFile("/bindings/sql/port")
```

## AWS credential binding

AWS-backed bindings hold a role ARN, never a key. That covers `ObjectStorage`, `NoSql`, and `Sql` or `Cache` on `backend: public-cloud`.

1. The [`workload-identity-sidecar`](https://github.com/cujarrett/workload-identity-sidecar) trades the pod's SVID with AWS STS for 1-hour credentials, every 50 minutes.
2. It writes them to a shared volume as named AWS profiles.
3. The app picks a profile by env var.

Each binding's IAM role accepts only this pod's exact identity. A different namespace, service account or cluster is refused.

| Binding | Profile env var | Example |
|---|---|---|
| Every kind but Cache | `AWS_PROFILE_<KIND>_<REF>`, uppercased, with `-` becoming `_` | `AWS_PROFILE_OBJECT_STORAGE_FOO_ASSETS`, `AWS_PROFILE_NOSQL_FOO` |
| Cache | `AWS_PROFILE_CACHE`, since an Api owns at most one | `AWS_PROFILE_CACHE` |

```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_OBJECT_STORAGE_FOO_ASSETS")))
s3 := s3.NewFromConfig(cfg)
```

Full design: [Platform Workload Identity](./docs/workload-identity.md).

## Environments and feature branches

The namespace is the environment. Give each engineer or branch its own namespace. `foo-api` can then run in `foo-alice` and `foo-bob` at once. AWS names include the namespace, so the two never share anything. A new namespace needs the platform team to allow it before its first sync.

| Resource | Name pattern | Example |
|---|---|---|
| IAM role | `crossplane-{ns}-{name}-*` | `crossplane-foo-alice-foo-api-nosql` |
| S3 bucket | `platform-{ns}-{name}` | `platform-foo-alice-foo-assets` |

### Test / QA / Prod tiers

Use `private-cloud` below QA to avoid AWS cost. Only `backend:` changes between tiers. The `Api` stays the same.

| Tier | Namespace pattern | Backend | Notes |
|---|---|---|---|
| Feature branch | `{app}-{branch}` or `{app}-{engineer}` | `private-cloud` | Short-lived; cheap; spun up per-branch |
| Test | `{app}-test` | `private-cloud` | Persistent; no AWS cost |
| QA | `{app}-qa` | `public-cloud` | Real AWS; shared QA dataset |
| Prod | `{app}-prod` | `public-cloud` | Real AWS; production data |

### Sql and shared databases

Several Apis can share one `Sql`. On `public-cloud`, list each in the Sql's `consumerServiceAccounts`, and each gets its own role and binding secret. On `private-cloud`, each branch gets its own isolated Postgres at near-zero cost.
