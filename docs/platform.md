# Platform

A Crossplane-based internal developer platform. Declare what your app needs; the platform
provisions it and delivers credentials directly to the pod.

Everything runs as Crossplane Composite Resources (XRs). You write a small YAML file
describing what you want — a deployment, a database, a message stream. The composition
handles the rest: creating cloud resources, writing credentials into a Secret, mounting
that Secret into the pod at a predictable path.

---

## Offerings

| XR | What it does |
|---|---|
| [`XApi`](../platform/api/README.md) | API server deployment with optional resource bindings |
| [`XSpa`](../platform/spa/README.md) | Static frontend served via in-cluster nginx |
| [`XWordpress`](../platform/wordpress/README.md) | Full WordPress stack (MariaDB + WordPress + Ingress) |
| [`XObjectStorage`](../platform/object-storage/README.md) | S3 bucket with scoped IAM credentials |
| [`XSql`](../platform/sql/README.md) | Postgres — in-cluster or AWS RDS |
| [`XNoSql`](../platform/nosql/README.md) | DynamoDB table with scoped IAM credentials |
| [`XCache`](../platform/cache/README.md) | Redis — in-cluster or AWS ElastiCache; owned by `XApi` |
| [`XTopic`](../platform/topic/README.md) | NATS JetStream stream (durable, replicated) |
| [`XSubscription`](../platform/subscription/README.md) | Durable NATS consumer cursor |

---

## Design

Two principles run through everything.

**Service bindings, not env vars.** Credentials reach pods as files mounted at
`/bindings/<name>/`, not environment variables. The app reads
`os.ReadFile("/bindings/object-storage/bucket")` instead of
`os.Getenv("S3_BUCKET")`. The path is invariant — the app doesn't care what provisioned
the resource or where it runs. See [Service Binding](service-binding.md) for the full
model.

**Lifecycle independence for data resources.** `XObjectStorage`, `XSql`, and `XNoSql`
exist independently of any one `XApi`. Create them once; reference them by name. Deleting
or redeploying the API doesn't touch the underlying data. `XCache` is the exception — it's
owned by an `XApi` and destroyed with it.

---

## GitOps Flow

1. Commit an XR file to `platform/xrs/<type>/<name>.yaml`
2. The `xrs` ApplicationSet (`cluster/argocd/xrs-appset.yaml`) detects the file and creates an ArgoCD Application
3. ArgoCD applies the XR to the cluster
4. Crossplane reconciles and creates all composed resources

---

## Deleting an XR Instance

Order matters. Removing the file first orphans resources — ArgoCD prunes the Application
but Crossplane never receives the delete signal.

```bash
# 1. Delete the XR — Crossplane cascade-deletes all composed resources
kubectl delete xspa <name> -n <namespace>
# or: kubectl delete xwordpress <name> -n <namespace>

# 2. Remove the file from git and push — ArgoCD prunes the Application
git rm platform/xrs/<type>/<name>.yaml
```

---

## ArgoCD Projects

Four AppProjects scope workloads by concern:

| Project | Contents |
|---|---|
| `platform` | ArgoCD, Crossplane, compositions, bootstrap |
| `infrastructure` | Longhorn, Traefik, cert-manager, AdGuard, Cloudflare |
| `observability` | kube-prometheus-stack, Loki, Promtail |
| `workloads` | All XR instances; `sourceNamespaces: ["*"]` for app-in-any-namespace |

---

## After Changing Compositions

After editing an XRD or Composition, sync `platform-definitions` to pick up the changes:

```bash
argocd app sync platform-definitions --grpc-web
```

---

## Related Docs

- [Service Binding](service-binding.md) — the servicebinding.io convention; how credentials reach pods
- [Debugging Crossplane](debugging-crossplane.md) — layered workflow for diagnosing XR sync failures
- [Cluster](cluster.md) — cluster hardware, networking, and stack
