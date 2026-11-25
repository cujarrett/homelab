# ManagedSecret

A value someone sets by hand in a cloud console, such as an API token or a webhook signing secret. The pod gets it as files. The value never lands in git or in a Kubernetes Secret.

It lives on its own in one namespace. Bind it to an `Api` with `managedSecretRefs`.

## What it provisions

An empty cloud secret. The owner sets the value, with one property per declared key. The referencing `Api` gets read access.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `keys` | yes | - | Property names the value must carry. Each becomes one file in the pod. Nothing rejects a value missing one, so the app should check what it needs at startup. |
| `dataRetention` | no | `retain` | `retain` keeps the value recoverable for 7 days after the XR is deleted. `delete` purges it at once and frees the name for reuse. |

## How the value reaches a pod

Each key lands at `/secrets/<name>/<key>`. The pod's short-lived identity unlocks this one secret, so nothing long-lived is stored. Full design: [Platform Workload Identity](../docs/workload-identity.md).

## Waiting for a value

A `ManagedSecret` starts empty until the owner sets it. The app container waits to start until every `ManagedSecret` it references has a value.

| Case | What happens |
|---|---|
| While waiting | The pod shows not ready. Any earlier pod keeps serving. |
| After an hour | The sidecar restarts and the wait begins again. |
| Why it waits | The sidecar's logs say. |

```bash
kubectl logs <pod> -n <namespace> -c workload-identity-sidecar | grep waiting
```

## Setting and rotating the value

The owner sets it in the cloud console. A rotated value reaches the files within 15 minutes, with no pod restart. Read the file each time you use it rather than caching it at startup.

To set a value from a terminal, see [Rotate Secret](../../scripts/rotate-secret/). A secret passed as a command-line argument lands in shell history and shows in `ps`.

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

Then reference it from an `Api`:

```yaml
spec:
  parameters:
    managedSecretRefs:
      - name: orders-credentials
# The app reads /secrets/orders-credentials/API_TOKEN
```

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).

## Operations

```bash
# XR status. SYNCED=composition ran, READY=all children healthy
kubectl get managedsecrets.platform.local.lab orders-credentials -n foo

# Detailed conditions, showing why something is not ready
kubectl get managedsecrets.platform.local.lab orders-credentials -n foo \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Confirm the pod received every declared key, by name and size. Never print a value
kubectl exec <pod> -n foo -- ls -l /secrets/orders-credentials
```
