# FederatedGraph

Crossplane composition that provisions one environment of a federated GraphQL graph. It composes every subgraph in its namespace that names it into one schema, and runs the router clients call. The design is in [Platform Graph](../docs/graph.md).

One per environment, written by the platform team. It lists no subgraphs, so a team joins by merging its own file, never by editing this one.

## What it provisions
- **Composed schema** - selects every subgraph in this namespace carrying this graph's label and composes them against the named variant. A subgraph that breaks composition is refused and the router keeps serving the last good schema.
- **Router** - a Deployment and a ClusterIP Service named `<name>-router` on port 80. Introspection is off and requests are rate limited.
- **Ingress** *(optional)* - Traefik `websecure` with TLS; only created when `host` is set. cert-manager issues the certificate via `tlsIssuer`.
- **Connection policy** - always. Inbound calls need a mesh identity, except ingress traffic when `host` is set. Outbound is limited to the subgraphs in this namespace and the schema registry.

The namespace is owned by the tenant, created by `namespace.yaml` in the tenant directory. Deleting a FederatedGraph removes the router and its policy. The variant and its schema history stay in the registry.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `graphRef` | yes | - | The graph and variant this environment serves, as `graph@variant`. |
| `host` | no | - | Hostname clients call. If omitted, the router is reachable only inside the cluster. |
| `tlsIssuer` | no | `local-lab-ca-issuer` | cert-manager ClusterIssuer. `local-lab-ca-issuer` for internal `.local.lab` hostnames; `letsencrypt-prod` for public internet hosts. Ignored without `host`. |
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

A subgraph joins by carrying the graph's name and its namespace as labels. `GraphApi` sets both.

## Operations

```bash
# XR status - SYNCED=composition ran, READY=router is serving
kubectl get federatedgraph -n <namespace>

# Which subgraphs were found, and whether they composed
kubectl get supergraphschema <name> -n <namespace> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'

# Query the router from the LAN
curl -sk https://<host>/ -H 'content-type: application/json' -d '{"query":"{ __typename }"}'
```
