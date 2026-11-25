# FederatedGraph

One environment of a federated GraphQL graph. It joins every subgraph in its namespace that names it into one schema, and runs the router clients call. The design is in [Platform Graph](../docs/graph.md).

The platform team writes one per environment. It lists no subgraphs. A team joins by merging its own `GraphApi` file, never by editing this one.

## What it provisions

| Resource | When | What |
|---|---|---|
| Composed schema | always | Every subgraph in this namespace with this graph's label, composed against the named variant. A subgraph that breaks composition is refused. The router keeps serving the last good schema. |
| Router | always | A ClusterIP Service named `<name>-router` on port 80. Introspection is off and requests are rate limited. |
| Route | `host` is set | HTTPS on `host`. |
| Connection policy | always | Lets through only the traffic listed below. |

The connection policy works like this.

- **Inbound:** any workload with a mesh identity may call the router, since it is the graph's front door. Ingress traffic also reaches it when `host` is set.
- **Subgraphs:** accept calls only from the router.
- **Outbound:** only the subgraphs in this namespace and the schema registry.

The tenant's `namespace.yaml` creates the namespace. Deleting a FederatedGraph removes the router and its policy. The variant and its schema history stay in the registry.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `graphRef` | yes | - | The graph and variant this environment serves, as `graph@variant`. |
| `host` | no | - | Hostname clients call. If omitted, the router is reachable only inside the cluster. |
| `replicas` | no | `1` | Number of router replicas. |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: FederatedGraph
metadata:
  name: foo
  namespace: foo-test
spec:
  parameters:
    graphRef: foo-homelab@test
    host: foo-test.local.lab
```

## Operations

```bash
# XR status. SYNCED=composition ran, READY=its resources were created
kubectl get federatedgraph -n <namespace>

# Which subgraphs were found, and whether they composed
kubectl get supergraphschema <name> -n <namespace> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'

# Query the router from the LAN
curl -sk https://<host>/ -H 'content-type: application/json' -d '{"query":"{ __typename }"}'
```
