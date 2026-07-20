# Platform E2E Test

One command that proves the platform still works end to end after big composition changes. It inflates an Api with **every** integration — both backends where they exist — verifies each one actually works from inside the pod, tears everything down, and verifies nothing was left behind in the cluster or AWS.

```bash
just test-e2e           # full run (~11-15 min, a few cents of AWS)
just test-e2e-private   # in-cluster only (~2 min, free)
just test-e2e-keep      # skip teardown, leave resources for debugging
```

## Credentials it uses

| Credential | Used for | Source |
|---|---|---|
| kubeconfig | All cluster operations (apply XRs, wait, port-forward, teardown) | Your local `~/.kube/config`, reachable via Tailscale |
| AWS CLI credentials | **Teardown verification only** — read-only `describe`/`list`/`head` calls confirming RDS, DynamoDB, S3, IAM, RolesAnywhere, and ElastiCache are clean | Default AWS CLI credential chain (`aws sts get-caller-identity` must work); needs read access to those services in `us-east-1` |

The test itself never creates AWS resources with your CLI credentials. All provisioning happens through Crossplane (the `aws-creds` secret in `crossplane-system`), and all in-pod AWS access uses workload identity (SPIFFE → IAM Roles Anywhere → STS) — the same path production workloads use. That identity chain is part of what's being tested.

## What it inflates

Everything goes into the ephemeral `platform-e2e` namespace, applied directly with `kubectl`. ArgoCD never sees it — `platform-definitions` excludes `test/**` (see `cluster/argocd/platform-xrs.yaml`).

| Manifest | XRs |
|---|---|
| `manifests/private.yaml` | `Sql e2e-sql-private` (in-cluster Postgres), `Topic e2e-topic`, `Subscription e2e-sub`, `Api e2e-api-private` (sql + cache + topic + subscription, all private-cloud) |
| `manifests/public.yaml` | `Sql e2e-sql-public` (RDS, xs), `NoSql e2e-nosql` (DynamoDB), `ObjectStorage e2e-assets` (S3), `Api e2e-api-public` (sql + cache + nosql + object storage, all public-cloud) |

The Api image is `ghcr.io/cujarrett/hello-world-api:latest` — the Launchpad demo app, whose probes do real round-trips against every binding and report per-integration JSON at `GET /`.

## Phases

1. **Preflight** — cluster reachable, Crossplane/NATS/SPIRE running, AWS CLI credentialed, `platform-e2e` namespace free, and the previous run's ElastiCache replication group finished deleting (AWS deletes it asynchronously for ~5-10 min after a run ends; back-to-back runs wait here instead of stalling mid-inflate).
2. **Inflate** — apply the manifests, wait for every XR to reach `Ready=True`, then wait for the cache binding secret (written only after the ElastiCache replication group is ready, ~12 min) and for both pods to be Available.
3. **Contract checks** — binding secrets have exactly the documented keys (public sql has `role-arn` and no `password`, private has `password` and no ARNs), the AWS sidecar exists only on the public Api, NATS env vars exist only on the private one, RBAC roles are scoped per Api.
4. **Data plane** — port-forward to each Api and poll the probe's `GET /` until every integration reports `ok`: Postgres insert/count, Redis INCR, NATS publish + durable-consumer fetch, DynamoDB put/get/delete, S3 put/get/delete.
5. **Teardown** — delete Apis first (cascades the owned Cache), then the standalone XRs, and wait for every object to disappear.
6. **Verify teardown** — namespace empty and terminated, NATS stream/consumer gone, and via AWS CLI: RDS instance, DynamoDB table, S3 bucket, IAM roles, and RolesAnywhere profiles all gone. The ElastiCache replication group reports `PASS (deleting)` if AWS is still finishing its async deletion. Any orphan is a FAIL naming the orphan.

## The identity-only exception

Public-cloud RDS and ElastiCache land in the AWS default VPC with no network path from this cluster (ElastiCache has no public option at all — see `platform/sql/README.md` and `platform/cache/README.md`). For those two, the probe verifies the full SPIFFE → RolesAnywhere → STS chain and generates a real RDS IAM auth token, then reports `PASS (identity-only)`. If a network path ever exists, the probe automatically upgrades to a full SQL round-trip.

## Cost

RDS `db.t4g.micro` + ElastiCache `cache.t4g.micro` for ~20 minutes ≈ a few cents per full run. DynamoDB and S3 stay in the free tier. `--private-only` costs nothing.

## When to run it

- `just test-e2e-private` after any change to `platform/api/composition.yaml` or the NATS-related compositions — fast, free
- `just test-e2e` before merging changes that touch AWS bindings, workload identity, or the sql/cache/nosql/object-storage compositions
