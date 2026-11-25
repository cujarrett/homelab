# Topic

A Topic is a durable message stream. Apps publish events to its subjects, and each [Subscription](../subscription/) reads them at its own pace. Wildcards let one stream catch many subjects, so `foo.events.>` catches `foo.events.created` and `foo.events.updated`.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `streamName` | yes | - | Stream name, such as `FOO-TOPIC`. No spaces, dots or wildcards. Uppercase is the convention. |
| `subjects` | yes | - | Subjects this stream catches. `*` matches one token. `>` matches all the rest. `foo.events.*` matches `foo.events.created` but not `foo.events.user.created`. `foo.events.>` matches both. |
| `retention` | no | `limits` | `limits` drops the oldest messages at the size or age limit. `interest` drops a message once every consumer has read it. `workqueue` drops it once any one consumer acks it. |
| `maxAge` | no | `720h` | Go duration. `720h` is 30 days. An empty string means no limit. |

Every stream keeps 3 copies and has no size limit. Neither is configurable.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Topic
metadata:
  name: foo-topic
  namespace: foo
spec:
  parameters:
    streamName: FOO-TOPIC
    subjects:
      - "foo.events.>"
    retention: limits
    maxAge: "720h"   # 30 days
```

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).

## Kafka and AWS equivalents

| Topic parameter | Kafka | AWS |
|---|---|---|
| `streamName` | Topic | Kinesis stream name |
| `subjects` | Topic partitions filter | Kinesis shard filter |
| `retention: limits` | `log.retention.ms` / `log.retention.bytes` | Kinesis retention period |
| `retention: interest` | - | SNS (fan-out, remove when all consumers read) |
| `retention: workqueue` | - | SQS (remove on acknowledgement) |
| `maxAge` | `log.retention.ms` | Kinesis retention hours |

## Operations

```bash
# Check XR status and readiness
kubectl get topics

# Describe a specific topic XR
kubectl describe topic foo-topic -n foo
```
