# ManagedSecret

Crossplane platform primitive for a value someone sets by hand in a cloud console - an API token, a webhook signing secret, a third-party credential - delivered to a pod as files. No value is ever committed to git, hand-created in the cluster, or stored as a Kubernetes Secret.

Standalone resource, same-namespace only, like `ObjectStorage` and `NoSql`. Bind to an `Api` via `managedSecretRefs`.

Kind is `ManagedSecret`, not `Secret` - avoids colliding with `kubectl get secret`, without narrowing to "credential" only, since a signing secret or encryption key fits too.

## What it provisions

A cloud secret the owner sets the value of, holding one property per declared key. That is all.

The identity and access to read it belong to the referencing `Api`, which creates them when the ref is declared, the same way it does for `objectStorageRefs`. Trust names the consuming pod, and a `ManagedSecret` does not know which pods those will be.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `keys` | yes | - | Property names the value must carry. Each becomes one file in the pod. Declared so the owner knows what to set; nothing rejects a value missing one, so an app should check what it needs at startup |
| `dataRetention` | no | `retain` | `retain` keeps the value recoverable for 7 days after the XR is deleted; `delete` purges it immediately and frees the name for reuse right away |

## How the value reaches a pod

The pod proves who it is with a short-lived SVID, trades it for credentials scoped to this one secret, and the platform writes each property to a file. Nothing long-lived is stored, and the value never becomes a Kubernetes object. For the full design see [Platform Workload Identity](../docs/workload-identity.md).

Files land at `/secrets/<name>/<key>`, the same shape `secretsFrom` uses, so an app reads a `ManagedSecret` exactly like a hand-created one.

## Waiting for a value

A `ManagedSecret` is created empty, because the owner sets the value out of band. Until then the platform writes no files, and an app reading one gets nothing - so check what you need at startup and fail loudly rather than running half-configured.

The reason is in the sidecar's logs:

```bash
kubectl logs <pod> -n <namespace> -c workload-identity-sidecar | grep waiting
```

## Setting and rotating the value

The owner sets it in the cloud console. A rotated value reaches the files within 15 minutes without a pod restart, so read a file per use rather than caching it at startup.

Setting a value from a terminal instead needs care, since a secret passed as a command-line argument lands in shell history and is visible to `ps` - see [External Secrets](../../docs/external-secrets.md) for the staged-file handling this repo uses.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: ManagedSecret
metadata:
  name: orders-credentials
  namespace: foo
spec:
  parameters:
    keys: [API_TOKEN, API_SECRET]
```

Then reference from an `Api`:

```yaml
spec:
  parameters:
    managedSecretRefs:
      - name: orders-credentials
# The app reads /secrets/orders-credentials/API_TOKEN
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Operations

```bash
# XR status - SYNCED=composition ran, READY=all children healthy
kubectl get managedsecrets.platform.local.lab orders-credentials -n foo

# Detailed conditions - shows exactly WHY something is not ready
kubectl get managedsecrets.platform.local.lab orders-credentials -n foo \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Confirm the pod received every declared key, by name and size - never print a value
kubectl exec <pod> -n foo -- ls -l /secrets/orders-credentials
```
