# Platform Tests

Two tests live here. Render check is the fast offline one, run on every composition change. The e2e is the slow live one, run before merging anything that touches AWS or workload identity.

Start with [Render check](#render-check) - it is the one you run most.

| Chapter | What it covers |
|---|---|
| [Render check](#render-check) | The offline check - what it catches and how to run it |
| [End-to-end test](#end-to-end-test) | The live test and its three modes |
| [Credentials the e2e uses](#credentials-the-e2e-uses) | Which credentials the e2e needs and what each one does |
| [What the e2e inflates](#what-the-e2e-inflates) | The namespace, manifests, and XRs it creates |
| [E2E phases](#e2e-phases) | The six phases of a run, in order |
| [The identity-only exception](#the-identity-only-exception) | Why RDS and ElastiCache verify identity instead of a round-trip |
| [E2E cost](#e2e-cost) | What a full run costs in AWS |
| [When to run the e2e](#when-to-run-the-e2e) | Which mode to reach for after which change |

## Render check

Renders every workspace XR against the current compositions offline - no cluster, no AWS, no cost.

```bash
just render-check       # ~1 min, needs Docker for the function containers
```

Docker must be running - `crossplane render` pulls the composition functions as containers.

Five gates run. Each exists because that class of bug reached the cluster at least once.

| Gate | Catches |
|---|---|
| **schema** | An XRD whose enum holds a YAML boolean (`off`, `on`, `yes`, `no` unquoted), or a `default` outside its own enum. Kubernetes rejects the generated CRD, Crossplane leaves it at the old generation, and nothing logs why. A server-side dry-run does **not** catch this - the XRD is valid, only CRD generation fails. |
| **render** | `crossplane render` exits non-zero. |
| **parse** | Output is valid YAML and no block sequence collapsed into a single string. `crossplane render` exits 0 even when whitespace trimming (`{{- … -}}`) flattens a list, so exit code alone proves nothing. |
| **diff** | Two comparisons against `HEAD`, one per repo. Holding the XR still and moving the composition shows the blast radius of a composition edit - `Api` and `Spa` are shared by every workspace, so one edit reaches all of them. Holding the composition still and moving the XR shows what your own XR edit did; an XR that renders identically after an edit usually means a field name the XRD does not declare, which Crossplane drops in silence. |
| **rbac** | A composed resource kind that [rbac.yaml](../../cluster/crossplane/rbac.yaml) does not grant. Crossplane composes with its own ServiceAccount, so a kind the platform has never composed before renders perfectly and is then refused by the API server. The XR lands on `SYNCED=False` while staying `READY=True` - the app keeps serving and nothing looks broken. XR kinds and AWS managed resources are skipped; Crossplane grants those through its generated composite and provider roles. |

Reading the output:

- `ok … (composition change does not affect it)` - what every workspace you did not intend to touch must say.
- `ok … (CHANGED vs HEAD - review below)` - your composition edit reaches this app. Read the diff and confirm you meant it.
- `ok … (new)` - not present at `HEAD`, so there is nothing to compare against.
- `xr edit renders as - review below` - the indented second line under a workspace. Your XR edit did this. Read it and confirm it is what you meant.
- `xr edited but the output is identical - did the edit take effect?` - the edit changed nothing downstream. Check the field name against the XRD.
- `FAIL` - fix before pushing.

The XR-side comparison only runs for XRs you actually edited, so a composition-only run costs nothing extra. Both sides compare against local `HEAD`, not `origin/main` - pull `../homelab-workspaces` before trusting the diff if the remote has moved.

Workspaces are discovered from `../homelab-workspaces/*/*.yaml` by their `kind`, so new apps and new XR types are picked up automatically - nothing to keep in sync here.

Fixtures the check feeds to `crossplane render` live in [fixtures/](./fixtures/) - the composition functions to pull, and a placeholder stand-in for the `aws-platform-config` EnvironmentConfig.

## End-to-end test

One command that proves the platform still works end to end after big composition changes. It inflates an Api with **every** integration - both backends where they exist - verifies each one actually works from inside the pod, tears everything down, and verifies nothing was left behind in the cluster or AWS.

```bash
just test-e2e           # full run (~11-15 min, a few cents of AWS)
just test-e2e-private   # in-cluster only (~2 min, free)
just test-e2e-keep      # skip teardown, leave resources for debugging
```

## Credentials the e2e uses

| Credential | Used for | Source |
|---|---|---|
| kubeconfig | All cluster operations (apply XRs, wait, port-forward, teardown) | Your local `~/.kube/config`, reachable via Tailscale |
| AWS CLI credentials | **Teardown verification only** - read-only `describe`/`list`/`head` calls confirming RDS, DynamoDB, S3, IAM, and ElastiCache are clean | Default AWS CLI credential chain (`aws sts get-caller-identity` must work); needs read access to those services in `us-east-1` |

The test itself never creates AWS resources with your CLI credentials. All provisioning happens through Crossplane (the `aws-creds` secret in `crossplane-system`), and all in-pod AWS access uses workload identity (SPIFFE → IAM Roles Anywhere → STS) - the same path production workloads use. That identity chain is part of what's being tested.

## What the e2e inflates

Everything goes into the ephemeral `platform-e2e` namespace, applied directly with `kubectl`. ArgoCD never sees it - `platform-definitions` excludes `test/**` (see `cluster/argocd/platform-xrs.yaml`).

| Manifest | XRs |
|---|---|
| `manifests/private.yaml` | `Sql e2e-sql-private` (in-cluster Postgres), `Topic e2e-topic`, `Subscription e2e-sub`, `Api e2e-api-private` (sql + cache + topic + subscription, all private-cloud) |
| `manifests/public.yaml` | `Sql e2e-sql-public` (RDS, xs), `NoSql e2e-nosql` (DynamoDB), `ObjectStorage e2e-assets` (S3), `Api e2e-api-public` (sql + cache + nosql + object storage, all public-cloud) |

The Api image is `ghcr.io/cujarrett/hello-world-api:latest` - the Launchpad demo app, whose probes do real round-trips against every binding and report per-integration JSON at `GET /`.

## E2E phases

1. **Preflight** - cluster reachable, Crossplane/NATS/SPIRE running, AWS CLI credentialed, `platform-e2e` namespace free, and the previous run's ElastiCache replication group finished deleting (AWS deletes it asynchronously for ~5-10 min after a run ends; back-to-back runs wait here instead of stalling mid-inflate).
2. **Inflate** - apply the manifests, wait for every XR to reach `Ready=True`, then wait for the cache binding secret (written only after the ElastiCache replication group is ready, ~12 min) and for both pods to be Available.
3. **Contract checks** - binding secrets have exactly the documented keys (public sql has `role-arn` and no `password`, private has `password` and no ARNs), the AWS sidecar exists only on the public Api, NATS env vars exist only on the private one, RBAC roles are scoped per Api.
4. **Data plane** - port-forward to each Api and poll the probe's `GET /` until every integration reports `ok`: Postgres insert/count, Redis INCR, NATS publish + durable-consumer fetch, DynamoDB put/get/delete, S3 put/get/delete.
5. **Teardown** - delete Apis first (cascades the owned Cache), then the standalone XRs, and wait for every object to disappear.
6. **Verify teardown** - namespace empty and terminated, NATS stream/consumer gone, and via AWS CLI: RDS instance, DynamoDB table, S3 bucket, and IAM roles all gone. The ElastiCache replication group reports `PASS (deleting)` if AWS is still finishing its async deletion. Any orphan is a FAIL naming the orphan.

## The identity-only exception

Public-cloud RDS and ElastiCache land in the AWS default VPC with no network path from this cluster (ElastiCache has no public option at all - see `platform/sql/README.md` and `platform/cache/README.md`). For those two, the probe verifies the full SPIFFE → OIDC → STS chain and generates a real RDS IAM auth token, then reports `PASS (identity-only)`. If a network path ever exists, the probe automatically upgrades to a full SQL round-trip.

## E2E cost

RDS `db.t4g.micro` + ElastiCache `cache.t4g.micro` for ~20 minutes ≈ a few cents per full run. DynamoDB and S3 stay in the free tier. `--private-only` costs nothing.

## When to run the e2e

- `just test-e2e-private` after any change to `platform/api/composition.yaml` or the NATS-related compositions - fast, free
- `just test-e2e` before merging changes that touch AWS bindings, workload identity, or the sql/cache/nosql/object-storage compositions
