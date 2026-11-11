# GraphApi

Crossplane composition that runs one team's subgraph and joins it to a federated graph. The team writes this file, and the schema inside the image is published from the running deployment. Nobody publishes by hand. The design is in [Platform Graph](../docs/graph.md).

## What it provisions
- **Workload** - an `Api` with the same name, no `host`, so the router is the only way in. Sizing, mesh policy, metrics and identity come from `Api` unchanged.
- **Subgraph registration** - the schema at `/schema.graphql` inside the image, read from the same digest the workload runs, published to the named graph's variant.

The graph composes every subgraph in the namespace that names it. A change that breaks composition is refused and the router keeps serving the last good schema.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `graph` | yes | - | Name of the `FederatedGraph` in this namespace to join. |
| `image` | yes | - | Container image, pinned by digest. Managed by CI. |
| `size` | no | `sm` | Compute tier. `xs`, `sm`, `md` or `lg`. |
| `replicas` | no | `1` | Number of subgraph replicas. |

Fixed by convention, never a field:

| Convention | Value |
|---|---|
| Schema location | `/schema.graphql` inside the image |
| Port | `8080` |
| Health | `/healthz` |
| Metrics | `/metrics` on `9090` |
| Endpoint | `/graphql` |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: GraphApi
metadata:
  name: foo
  namespace: bar-test
spec:
  parameters:
    graph: bar
    image: ghcr.io/owner/foo@sha256:4f1c...
```

## Operations

```bash
# XR status - SYNCED=composition ran, READY=workload up and schema loaded
kubectl get graphapi -n <namespace>

# Was the schema read from the image, and which digest
kubectl get subgraph <name> -n <namespace> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```
