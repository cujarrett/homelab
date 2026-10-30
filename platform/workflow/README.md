# Workflow

A space for durable workflows: steps that keep their progress through crashes, restarts and long waits. An `Api` that references a `Workflow` can start workflows in it and run them.

## What it provisions

- **Workflow namespace:** named after the `Workflow`, with the retention you set. Names are shared across the whole platform, so a name another workspace already uses leaves this `Workflow` not ready.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `backend` | no | `private-cloud` | Where the workflow service runs. `private-cloud` runs it in the cluster. |
| `retention` | no | `72h` | How long the history of finished workflows is kept, as a Go duration. At least `24h`. |
| `description` | no | - | Shown next to this workflow space in the workflow UI. |

## Example instance

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Workflow
metadata:
  name: foo-workflows
  namespace: foo
spec:
  parameters:
    retention: 72h
    description: Workflows for foo
---
apiVersion: platform.local.lab/v1alpha1
kind: Api
metadata:
  name: foo-worker
  namespace: foo
spec:
  parameters:
    image: ghcr.io/foo/foo-worker:sha-abc123
    workflowRef:
      name: foo-workflows
```

## Env vars

An `Api` with `workflowRef` gets these. The platform also allows its traffic to the workflow service, so it never goes in `consumes`.

| Env var | Value |
|---|---|
| `TEMPORAL_ADDRESS` | The workflow service, as `host:port`. Pass it to the Temporal SDK client. |
| `TEMPORAL_NAMESPACE` | The `Workflow`'s name. Workers and clients use it as their namespace. |

Workflow code, task queue names, retries and timeouts all live in the app.

## Operations

```bash
kubectl get workflows -n foo
kubectl describe workflow foo-workflows -n foo
```
