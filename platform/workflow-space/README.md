# WorkflowSpace

A space for durable workflows: steps that keep their progress through crashes, restarts and long waits. An `Api` that references a `WorkflowSpace` can start workflows in it and run them.

## What it provisions

- **Workflow namespace:** named after the `WorkflowSpace`, with the retention you set. Names are shared across the whole platform, so a name another workspace already uses leaves this `WorkflowSpace` not ready.

## Access

- **Same workspace:** an `Api` with `workflowSpaceRef` can start and run workflows here.
- **Other workspaces:** an `Api` elsewhere cannot, even with the same `workflowSpaceRef` name.
- **Tokens:** every call needs a token. Calls without one are refused.
- **Name clash:** access is granted only once the workflow namespace is ready, so a clash grants nothing.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `backend` | no | `private-cloud` | Where the workflow service runs. `private-cloud` runs it in the cluster. `public-cloud` runs it on a managed service. See [public-cloud](#public-cloud). |
| `retention` | no | `72h` | How long the history of finished workflows is kept, as a Go duration. At least `24h`. `public-cloud` always keeps `24h`. |
| `description` | no | - | Shown next to this workflow space in the workflow UI. Not used on `public-cloud`. |

## Example instance

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: WorkflowSpace
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
    workflowSpaceRef:
      name: foo-workflows
```

## Env vars

An `Api` with `workflowSpaceRef` gets these, plus a workload identity whose token carries the permission to use this `WorkflowSpace`. The platform also allows its traffic to the workflow service, so it never goes in `consumes`.

| Env var | Value |
|---|---|
| `TEMPORAL_ADDRESS` | The workflow service, as `host:port`. Pass it to the Temporal SDK client. |
| `TEMPORAL_NAMESPACE` | The `WorkflowSpace`'s name. Workers and clients use it as their namespace. |
| `TEMPORAL_TOKEN_SCOPE` | `api://<tenant>/platform-temporal/.default`. Ask Entra for a token with this scope, using the `AZURE_*` identity the Api already has. The token carries this `WorkflowSpace`'s permission. Send it as `Authorization: Bearer <token>` on every Temporal call. |

In Go, with the Azure SDK and the Temporal SDK:

```go
cred, _ := azidentity.NewWorkloadIdentityCredential(nil) // reads the AZURE_* env vars
c, _ := client.Dial(client.Options{
	HostPort:  os.Getenv("TEMPORAL_ADDRESS"),
	Namespace: os.Getenv("TEMPORAL_NAMESPACE"),
	HeadersProvider: tokenHeader{cred}, // returns "authorization": "Bearer " + a fresh token
})
```

`tokenHeader.GetHeaders` calls `cred.GetToken` with `TEMPORAL_TOKEN_SCOPE`. The Azure SDK caches the token and refreshes it before it expires.

Workflow code, task queue names, retries and timeouts all live in the app.

## public-cloud

A `public-cloud` workflow space runs on a managed service that bills by use. The platform limits it.

- **Approved namespaces only.** Elsewhere the platform refuses it.
- **2 hours at most.** The platform then deletes it.
- **Sign-in:** the pod signs in with a client certificate. No token is involved.

The `Api` names the backend too:

```yaml
    workflowSpaceRef:
      name: foo-workflows
      backend: public-cloud
```

| Env var | Value |
|---|---|
| `TEMPORAL_ADDRESS` | The workflow service, as `host:port`. |
| `TEMPORAL_NAMESPACE` | The namespace to use. It is longer than the `WorkflowSpace`'s name. |
| `TEMPORAL_TLS_CERT` | Path to the client certificate. |
| `TEMPORAL_TLS_KEY` | Path to its private key. |

Pass the address, namespace and certificate to the Temporal SDK client with TLS on. The files appear a moment after the pod starts, so retry the first connection. They are renewed about every hour, so read them again on each new connection.

## Operations

```bash
kubectl get workflowspaces -n foo
kubectl describe workflowspace foo-workflows -n foo
```
