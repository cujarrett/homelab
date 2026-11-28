# Subscription

A Subscription is a durable cursor on a Topic. It remembers its place across restarts, so no message is missed or replayed. It runs no code. Pair it with an `Api` that sets `subscriptionRef`.

## Parameters

| Field | Required | Default | Description |
|---|---|---|---|
| `topicRef.name` | yes | - | `metadata.name` of the Topic to read. |
| `topicRef.streamName` | no | `topicRef.name` uppercased | The Topic's `streamName`. Set it when that differs from the uppercased Topic name. |
| `filterSubject` | no | `>` | Subject filter, such as `foo.event.snapshot`. `*` matches one token. `>` matches one or more. |
| `deliverPolicy` | no | `all` | `all` replays from the start. `new` sends only new messages. `last` sends the most recent. `lastPerSubject` sends the most recent per subject. |
| `ackPolicy` | no | `explicit` | `explicit` means the app acks each message (at-least-once). `all` acks everything up to a message. `none` sends without acks. |

Unacked messages come back after 30 seconds. That wait is fixed.

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

The paired Api runs the reader. It gets `NATS_URL` and `NATS_CONSUMER`. The app supplies the stream name itself, such as through `configFrom`.

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Api
metadata:
  name: foo-consumer
  namespace: foo
spec:
  parameters:
    image: ghcr.io/cujarrett/foo-consumer:sha-abc123
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
