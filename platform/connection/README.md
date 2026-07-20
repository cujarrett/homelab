# Connection

Crossplane composition that grants and enforces the network connections a workload is allowed to make — to other platform workloads, and to external hosts. On a locked-down workload nothing gets through unless it's declared here; a Connection is a caller's outbound allowlist.

## What it provisions
- **On-platform grants** (`toServices`) — for each entry, permission for the caller to reach that destination workload, over mutual TLS. Optionally narrowed to specific HTTP methods/paths.
- **Off-platform registrations** (`toExternals`) — for each entry, an external host registered as an allowed destination. When a namespace is under egress lockdown, this is the only way a workload reaches outside the platform.

One Connection is a single caller's full connection set: N on-platform destinations and N off-platform destinations. The grant is keyed on the caller's **service account** — its cryptographic workload identity — not on labels or IP, and only works over authenticated (mutually-TLS'd) traffic.

Pairs with [`platform/api/`](../api/): set `enforce: true` on an `Api` to lock it to default-deny, then declare who each locked-down workload may call with an `Connection`.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `from.namespace` | yes | — | Namespace of the calling workload. |
| `from.serviceAccount` | yes | — | Service account of the caller. This is the identity all grants below are keyed to. |
| `toServices[]` | no | `[]` | On-platform destinations (one grant per entry). |
| `toServices[].namespace` | yes | — | Destination workload's namespace. |
| `toServices[].appLabel` | yes | — | Name of the destination instance (its `metadata.name`) — selects only that instance's pods, even if its namespace runs several instances of the same platform type. |
| `toServices[].port` | yes | — | Destination container port. |
| `toServices[].httpPolicy.allowMethods` | no | all | HTTP methods to allow (e.g. `GET`). Omit for any method. |
| `toServices[].httpPolicy.allowPaths` | no | all | HTTP path prefixes to allow (e.g. `/api/v1/*`). Omit for any path. |
| `toExternals[]` | no | `[]` | Off-platform destinations (one egress registration per entry). |
| `toExternals[].fqdn` | yes | — | External hostname (e.g. `api.example.com`). |
| `toExternals[].port` | yes | — | External port (typically `443`). |

Declare at least one of `toServices` or `toExternals`.

## Example

`foo` reaches two platform services and two external hosts:

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Connection
metadata:
  name: foo-connections
spec:
  parameters:
    from:
      namespace: foo
      serviceAccount: foo
    toServices:
      - namespace: bar
        appLabel: bar
        port: 8080
        httpPolicy:            # optional — omit for L4-only (any method/path)
          allowMethods: ["GET"]
          allowPaths: ["/api/v1/*"]
      - namespace: baz
        appLabel: baz
        port: 8080
    toExternals:
      - fqdn: api.example.com
        port: 443
      - fqdn: api.another.com
        port: 443
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Operations

```bash
# List connections and their readiness
kubectl get connections

# Describe a specific connection (see every rendered grant)
kubectl describe connection foo-connections
```
