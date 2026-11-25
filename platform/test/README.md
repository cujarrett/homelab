# Platform Tests

The render check is fast and offline. Run it on every composition change. The e2e is slow and live. Run it before merging anything that touches AWS or workload identity.

Run the `just` commands from `platform/`, where the `justfile` lives.

## Render check

It renders every workspace XR against the current compositions. No cluster, no AWS, no cost.

```bash
just render-check       # ~1 min, needs Docker for the function containers
```

Docker must be running, since `crossplane render` pulls the functions as containers. Each gate below caught a bug that once reached the cluster.

| Gate | Catches |
|---|---|
| **schema** | An XRD enum with an unquoted YAML boolean (`off`, `on`, `yes`, `no`), or a `default` outside its enum. Crossplane silently keeps the old CRD. A server-side dry-run misses it. |
| **render** | `crossplane render` exits non-zero. |
| **parse** | The output is valid YAML and no list collapsed into a string. Whitespace trimming (`{{- … -}}`) can flatten a list while render exits 0. |
| **diff** | Compares against `HEAD`. A composition edit shows every workspace it reaches, and `Api` and `Spa` reach all of them. An XR edit that renders the same usually has a field name the XRD lacks. |
| **crd** | A rendered AWS managed resource that its provider's CRD rejects. Skipped when no cluster is reachable. |
| **rbac** | A composed kind that [rbac.yaml](../../cluster/crossplane/rbac.yaml) does not grant. The API server refuses it, and the XR shows `SYNCED=False` while staying `READY=True`. XR kinds and provider managed resources are skipped. |
| **xr** | A workspace XR field its XRD does not declare. Render ignores it, and the API server refuses it. |
| **namespace** | A workspace directory without a `namespace.yaml` carrying the mesh and Pod Security labels. |

Reading the output:

| Output | Meaning |
|---|---|
| `ok … (composition change does not affect it)` | Every workspace you did not mean to touch says this. |
| `ok … (CHANGED vs HEAD - review below)` | Your composition edit reaches this app. Check the diff. |
| `ok … (new)` | Not at `HEAD`, so nothing to compare. |
| `xr edit renders as - review below` | The indented line showing what your XR edit did. |
| `xr edited but the output is identical - did the edit take effect?` | Check the field name against the XRD. |
| `FAIL` | Fix it before pushing. |

More facts:

| Topic | Detail |
|---|---|
| XR comparison | Runs only for XRs you edited. |
| Baseline | Local `HEAD`, not `origin/main`. Pull `../homelab-workspaces` first if the remote moved. |
| Discovery | Every `../homelab-workspaces/*/*.yaml`, by `kind`. New apps need no setup. |
| Fixtures | [fixtures/](./fixtures/) holds a stand-in `aws-platform-config` EnvironmentConfig. |
| Functions | The same versions the cluster runs, read from [providers.yaml](../../cluster/crossplane/providers.yaml). |

### A FAIL from the rbac gate has two causes

Kubernetes kinds (`Secret`, `Deployment`, `Ingress`) each need a grant in [rbac.yaml](../../cluster/crossplane/rbac.yaml). Provider kinds bring their own grants. `skip()` in [render-check.sh](./render-check.sh) treats any group ending in `upbound.io` as covered, so other providers fail even when granted. Ask the cluster.

```bash
kubectl auth can-i create applications.applications.azuread.m.upbound.io \
  --as=system:serviceaccount:crossplane-system:crossplane
```

- `yes`: the gate is wrong. Fix `skip()`.
- `no`: the gate is right. Fix `rbac.yaml`.

## End-to-end test

The e2e builds an Api with every integration, on both backends where they exist. It checks each one from inside the pod, tears everything down, then checks nothing is left in the cluster or AWS.

```bash
just test-e2e                  # full run (~11-15 min, a few cents of AWS)
just test-e2e --private-only   # in-cluster only (~2 min, free)
just test-e2e --keep           # skip teardown, leave resources for debugging
just test-e2e --abort          # stop a running e2e and remove what it left
just test-e2e-workflow         # WorkflowSpace only, a WorkflowSpace plus an Api using it (~2 min, free)
just test-e2e-workflow-cloud   # public-cloud WorkflowSpace with a real Temporal Cloud namespace and one order (~10 min, spends money)
```

| Mode | Run it |
|---|---|
| `--private-only` | After changing `platform/api/composition.yaml` or the NATS compositions. |
| Full run | Before merging changes to AWS bindings, workload identity, or the sql, cache, nosql or object-storage compositions. |
| `test-e2e-workflow` | After changing the workflow-space composition, `workflowSpaceRef`, or Temporal's cluster setup. The full run includes it. |

## Credentials the e2e uses

| Credential | Used for | Source |
|---|---|---|
| kubeconfig | Every cluster step. | Your local `~/.kube/config`, over Tailscale. |
| AWS CLI | Read-only teardown checks on RDS, DynamoDB, S3, Secrets Manager, IAM and ElastiCache in `us-east-1`. | Your AWS CLI credentials. `aws sts get-caller-identity` must work. |

Your CLI credentials never create anything. Crossplane provisions with the `aws-creds` secret in `crossplane-system`. Pods reach AWS through workload identity (SPIFFE → OIDC → STS), which the test also covers.

## What the e2e inflates

These manifests go into the `platform-e2e` namespace through `kubectl`. ArgoCD never sees it, because `platform-definitions` excludes `test/**` (see `cluster/argocd/platform-xrs.yaml`).

| Manifest | XRs |
|---|---|
| `manifests/private.yaml` | `Sql e2e-sql-private`, `Topic e2e-topic`, `Subscription e2e-sub`, and `Api e2e-api-private` using all of them plus a cache. |
| `manifests/public.yaml` | `Sql e2e-sql-public` (RDS, xs), `NoSql e2e-nosql`, `ObjectStorage e2e-assets`, `ManagedSecret e2e-secret`, and `Api e2e-api-public` using all of them plus a cache. |

The Api runs `ghcr.io/cujarrett/demo-api:latest`. It round-trips every binding and reports each at `GET /`.

## E2E phases

1. **Preflight:** cluster, Crossplane, NATS, SPIRE and AWS CLI work. `platform-e2e` is free. The last run's ElastiCache group has finished its ~5-10 min delete.
2. **Inflate:** apply the manifests. Wait for every XR `Ready=True`, the cache binding secret (~12 min) and both pods.
3. **Contract checks:** binding keys match the docs. Public sql has `role-arn` and no `password`, private the reverse. The AWS sidecar is on the public Api only, NATS env vars on the private only. RBAC roles are per Api.
4. **Data plane:** port-forward and poll `GET /` until every integration says `ok`. Postgres, Redis, NATS durable consumer, DynamoDB and S3 all round-trip.
5. **Teardown:** delete the Apis, which removes their Cache. Then delete the standalone XRs and wait.
6. **Verify teardown:** the namespace, NATS stream and consumer are gone. The AWS CLI confirms RDS, DynamoDB, S3, the Secrets Manager secret and IAM roles are gone. ElastiCache may report `PASS (deleting)`. Any orphan is a FAIL that names it.

## The identity-only exception

Public-cloud RDS and ElastiCache have no network path from this cluster. See `platform/sql/README.md` and `platform/cache/README.md`. For those two, the probe checks the SPIFFE → OIDC → STS chain and makes a real RDS IAM auth token. It reports `PASS (identity-only)`, and switches to a full round-trip once a path exists.

## E2E cost

A full run costs a few cents. RDS `db.t4g.micro` and ElastiCache `cache.t4g.micro` run for ~20 minutes. DynamoDB and S3 stay in the free tier. `--private-only` is free.
