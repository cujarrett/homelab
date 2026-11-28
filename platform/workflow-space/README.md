# WorkflowSpace

A WorkflowSpace holds durable workflows. Their steps keep progress through crashes, restarts and long waits. An `Api` that references it can start and run workflows there.

## Access

| Topic | Rule |
|---|---|
| Namespace | Each WorkflowSpace gets a workflow namespace with its own name and retention. |
| Name clash | Names are platform-wide. A name another workspace uses leaves this one not ready, and grants no access. |
| Same workspace | An `Api` with `workflowSpaceRef` can start and run workflows. |
| Other workspaces | Cannot, even with the same name in `workflowSpaceRef`. |
| Tokens | Every call needs one. Calls without one are refused. |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `backend` | no | `private-cloud` | `private-cloud` runs the workflow service in the cluster. `public-cloud` uses a managed service. See [public-cloud](#public-cloud). |
| `retention` | no | `72h` | How long finished workflow history is kept, as a Go duration. At least `24h`. `public-cloud` always keeps `24h`. |
| `description` | no | - | Shown next to the space in the workflow UI. Not used on `public-cloud`. |

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
    image: ghcr.io/cujarrett/foo-worker:sha-abc123
    workflowSpaceRef:
      name: foo-workflows
```

## Env vars

An `Api` with `workflowSpaceRef` gets these env vars and a workload identity. Its token carries permission for this WorkflowSpace. The platform allows traffic to the workflow service, so leave it out of `consumes`.

| Env var | Value |
|---|---|
| `TEMPORAL_ADDRESS` | The workflow service, as `host:port`. Pass it to the Temporal SDK client. |
| `TEMPORAL_NAMESPACE` | The WorkflowSpace's name. Workers and clients use it as their namespace. |
| `TEMPORAL_TOKEN_SCOPE` | `api://<tenant>/platform-temporal/.default`. Ask Entra for a token with this scope, using the Api's `AZURE_*` identity. Send it as `Authorization: Bearer <token>` on every Temporal call. |

In Go, with the Azure SDK and the Temporal SDK:

```go
cred, _ := azidentity.NewWorkloadIdentityCredential(nil) // reads the AZURE_* env vars
c, _ := client.Dial(client.Options{
	HostPort:  os.Getenv("TEMPORAL_ADDRESS"),
	Namespace: os.Getenv("TEMPORAL_NAMESPACE"),
	HeadersProvider: tokenHeader{cred}, // returns "authorization": "Bearer " + a fresh token
})
```

`tokenHeader.GetHeaders` calls `cred.GetToken` with `TEMPORAL_TOKEN_SCOPE`. The Azure SDK caches the token and refreshes it early.

Workflow code, task queues, retries and timeouts all live in the app.

## public-cloud

A `public-cloud` space runs on a managed service that bills by use, so the platform limits it.

| Limit | Rule |
|---|---|
| Namespaces | Approved ones only. Elsewhere the platform refuses it. |
| Lifetime | 2 hours. The platform deletes it within 15 minutes after that. |
| Sign-in | The pod uses a client certificate. No token is involved. |

The `Api` names the backend too.

```yaml
    workflowSpaceRef:
      name: foo-workflows
      backend: public-cloud
```

| Env var | Value |
|---|---|
| `TEMPORAL_ADDRESS` | The workflow service, as `host:port`. |
| `TEMPORAL_NAMESPACE` | The namespace to use. It is longer than the WorkflowSpace's name. |
| `TEMPORAL_TLS_CERT` | Path to the client certificate. |
| `TEMPORAL_TLS_KEY` | Path to its private key. |

| Step | What to do |
|---|---|
| Client | Pass the address, namespace and certificate to the Temporal SDK with TLS on. |
| First connect | The files appear a moment after start, so retry. |
| Renewal | About every 2 hours, so reread them on each new connection. |

## Operations

```bash
kubectl get workflowspaces -n foo
kubectl describe workflowspace foo-workflows -n foo
```
