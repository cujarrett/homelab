# XSubscription

Provisions a durable message cursor on an XTopic. Tracks delivery position across restarts so no messages are missed or replayed.

This is infrastructure only — it does not deploy any compute. Use an XApi instance with `subscriptionRef` to deploy the workload that reads from this cursor.

## What it provisions

- **Message cursor** — durable, named, position tracked across pod restarts

## Parameters

| Field | Required | Default | Description |
|---|---|---|---|
| `topicRef.name` | yes | — | `metadata.name` of the XTopic to consume from. |
| `filterSubject` | no | `>` | Subject filter. `*` = one token, `>` = one or more. e.g. `foo.event.snapshot` |
| `deliverPolicy` | no | `all` | `all` = replay from start. `new` = only new messages. `last` = most recent only. `lastPerSubject` = most recent per subject. |
| `ackPolicy` | no | `explicit` | `explicit` = app must ack per message (at-least-once). `all` = cumulative ack. `none` = fire-and-forget. |
| `ackWait` | no | `30s` | Go duration. Unacked messages are redelivered after this timeout. |

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
```

Paired with an XApi instance to deploy the workload:

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XApi
metadata:
  name: foo-consumer
spec:
  parameters:
    image: ghcr.io/example/foo-consumer:latest
    subscriptionRef:
      name: foo-consumer
```

## Operations

```bash
# Check readiness
kubectl get xsubscription foo-consumer

# Check pod (deployed by the paired XApi)
kubectl get pods -n foo-consumer
```

