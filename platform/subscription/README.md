# Subscription

Provisions a durable message cursor on a Topic. Tracks delivery position across restarts so no messages are missed or replayed.

This is infrastructure only - it does not deploy any compute. Use an Api instance with `subscriptionRef` to deploy the workload that reads from this cursor.

## What it provisions

- **Message cursor** - durable, named, position tracked across pod restarts

## Parameters

| Field | Required | Default | Description |
|---|---|---|---|
| `topicRef.name` | yes | - | `metadata.name` of the Topic to consume from. |
| `topicRef.streamName` | no | - | NATS stream name from the Topic's `spec.parameters.streamName`. Defaults to `topicRef.name` uppercased. Set explicitly when the Topic's streamName differs from its metadata.name. |
| `filterSubject` | no | `>` | Subject filter. `*` = one token, `>` = one or more. e.g. `foo.event.snapshot` |
| `deliverPolicy` | no | `all` | `all` = replay from start. `new` = only new messages. `last` = most recent only. `lastPerSubject` = most recent per subject. |
| `ackPolicy` | no | `explicit` | `explicit` = app must ack per message (at-least-once). `all` = cumulative ack. `none` = fire-and-forget. |

Ack wait timeout is hardcoded at 30 seconds - unacked messages are redelivered after this interval. It is not configurable per subscription.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Subscription
metadata:
  name: foo-consumer
  namespace: foo
spec:
  parameters:
    topicRef:
      name: foo-topic
    filterSubject: "foo.event.>"
```

Paired with an Api instance to deploy the workload:

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Api
metadata:
  name: foo-consumer
  namespace: foo
spec:
  parameters:
    image: ghcr.io/example/foo-consumer:sha-abc123
    subscriptionRef:
      name: foo-consumer
```

## Operations

```bash
# Check readiness
kubectl get subscription foo-consumer -n foo

# Check pod (deployed by the paired Api)
kubectl get pods -n foo
```
