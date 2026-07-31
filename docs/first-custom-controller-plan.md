# First Custom Controller — ConnectionGraph

> **The one idea (grug):** each `Api`/`Spa` composition only ever sees its own XR — it has no way to answer "who actually calls whom" across the whole cluster. That cross-resource correlation is real work a Crossplane composition structurally can't do, and it's the piece [Platform Connections](./platform-connections.md) calls the "four diffs" view but never built.

## The ask

First kubebuilder project. Small enough to finish, real enough to matter, safe enough that a bug doesn't touch anything live — it only reads XRs/CRs and writes its own status, never mutates a workload.

## What it does

1. Every [`Api`](../platform/api/)/ [`Spa`](../platform/spa/) composition emits a small `ConnectionIntent` CR alongside what it already renders (`AuthorizationPolicy`, `PeerAuthentication`, `Sidecar`, `ServiceEntry` — none of that changes), carrying `provides`/`consumes` straight from `spec.parameters`.
2. A new controller watches every `ConnectionIntent` CR cluster-wide and aggregates them into a graph — `status.edges: [{source, target}]` — answering "who calls whom" without anyone reading N different XR specs by hand.

Not built from live Envoy traffic — from declared intent. Unmeshed namespaces ([`sump-pump`, `launchpad`](./platform-connections.md#status)) can still emit a `ConnectionIntent` and appear in the graph; their edges just aren't policy-enforced. Worth labeling those nodes as "declared, unenforced" once visualization exists.

## What kubebuilder produces

`kubebuilder create api --group platform --version v1 --kind ConnectionIntent` scaffolds all three pieces:
- **CRD** — the `ConnectionIntent` schema (Go type + `config/crd/bases/*.yaml`)
- **CR** — instances of it (hand-write a couple for local testing before the composition emits real ones)
- **Controller** — the reconciler stub in `internal/controller/`, filled in with the aggregation logic

## Build plan

**1. Scaffold:**
```bash
kubebuilder init --domain platform.local.lab --repo github.com/cujarrett/connection-graph-controller
kubebuilder create api --group platform --version v1 --kind ConnectionIntent
```
Say yes to both "create resource" and "create controller" — this one owns its CRD, unlike the earlier XR-watching drafts.

**2. `ConnectionIntent` spec:**
```yaml
apiVersion: platform.platform.local.lab/v1
kind: ConnectionIntent
metadata:
  name: my-vinyl-api
  namespace: my-vinyl
spec:
  provides: [my-vinyl-api]
  consumes: [my-vinyl-cache]
```

**3. Reconcile logic:**
- List all `ConnectionIntent` CRs cluster-wide
- Build the edge list: for each CR, each `consumes` entry becomes an edge `{source: metadata.name, target: consumesEntry}`
- Write the aggregate to a singleton `ConnectionGraph` status (or a `ConfigMap`, whichever is simpler to start) — requeue on any `ConnectionIntent` create/update/delete via a watch, not polling

**4. RBAC** — read-only on `ConnectionIntent` across all namespaces, write only to its own aggregate object's status.

**5. Test with `envtest`** — create a handful of fake `ConnectionIntent` CRs, assert the aggregated edges come out correct, including one delete to confirm the graph updates.

**6. Composition wiring** — once the controller works standalone, add the `ConnectionIntent` render to the `Api`/`Spa` compositions and remind to sync `platform-definitions`: `argocd app sync platform-definitions --grpc-web`.

## Deferred: visualization

Grafana's core **Node Graph panel** is the right fit — it needs two data frames (`type: node`, `type: edge`), which no datasource emits for arbitrary custom data, so the practical path is the **Infinity** plugin reading JSON from the controller, same pattern `platform-exporter` already uses. Not part of this build — get the aggregation correct first, wire up the panel once there's real data to point it at. Also worth a quick look at whether Istio's own **Kiali** already shows a live service graph for free before investing in a custom one.

## Other candidates, parked

`Greeting`/uptime-bragging-bot (fun-first, Discord-posting CRDs), a Cloudflare tunnel drift checker, a `ConnectionIntent`-based posture compliance auditor, an XR-aware orphan detector, a demo-sandbox TTL flagger for Launchpad, and the original observe-posture status controller (Envoy shadow-deny counters into XR status) are all real candidates for a second or third project.
