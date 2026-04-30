# XSubscription

Deploys a message consumer Deployment that processes events from an XTopic.

## What it provisions

- **Message consumer** — durable, tracks position across restarts so no messages are missed or replayed
- **Deployment** — your consumer app, pre-configured with connection env vars
- **Service** — ClusterIP exposing the metrics port
- **ServiceMonitor** — Prometheus scrape config for `/metrics`

## Parameters

| Field | Required | Default | Description |
|---|---|---|---|
| `topicRef.name` | yes | — | `metadata.name` of the XTopic to consume from. |
| `image` | yes | — | Container image for the consumer Deployment. |
| `filterSubject` | no | `>` | Subject filter. `*` = one token, `>` = one or more. e.g. `foo.event.snapshot` |
| `port` | no | `9090` | Container port for `/metrics`. Used by Service and ServiceMonitor. |
| `deliverPolicy` | no | `all` | `all` = replay from start. `new` = only new messages. `last` = most recent only. `lastPerSubject` = most recent per subject. |
| `ackPolicy` | no | `explicit` | `explicit` = app must ack per message (at-least-once). `all` = cumulative ack. `none` = fire-and-forget. |
| `ackWait` | no | `30s` | Go duration. Unacked messages are redelivered after this timeout. |
| `replicas` | no | `1` | Deployment replicas. Use `1` for ordered processing. |
| `secretRef.name` | no | — | Secret name to inject as env vars into the Deployment. |

## Environment variables injected

The consumer Deployment receives these env vars automatically:

| Var | Value |
|---|---|
| `NATS_URL` | `nats://nats.nats.svc.cluster.local:4222` |
| `NATS_STREAM` | `streamName` parameter |
| `NATS_CONSUMER` | XR `metadata.name` (also the durable consumer name) |
| `NATS_FILTER_SUBJECT` | `filterSubject` parameter |
| `PORT` | `port` parameter |

If `secretRef` is set, the named Secret is also mounted via `envFrom`.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSubscription
metadata:
  name: foo-consumer
spec:
  parameters:
    topicRef:
      name: foo-topic
    filterSubject: "foo.event.>"
    image: ghcr.io/example/foo-consumer:latest
    port: 9090
    deliverPolicy: all
    ackPolicy: explicit
```

## Operations

```bash
# Check readiness
kubectl get xsubscription foo-consumer

# Check pod
kubectl get pods -n foo-consumer

# Check ServiceMonitor is picked up by Prometheus
kubectl get servicemonitor -n foo-consumer
```
