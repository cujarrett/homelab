# Topic

Crossplane composition that provisions a durable, persistent message stream.

## What it provisions
- **Message stream** - a named, durable channel that captures published events. Supports wildcards so a single stream can receive events from multiple subjects (e.g. `foo.events.>` captures `foo.events.created`, `foo.events.updated`, etc.).

The `Subscription` type (see [`platform/subscription/`](../subscription/)) deploys consumer applications that subscribe to streams created by this XRD.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `streamName` | yes | - | Stream name (e.g. `FOO-TOPIC`). No spaces, dots, or wildcards. Uppercase is conventional. |
| `subjects` | yes | - | List of subjects this stream captures. `*` matches one token, `>` matches all remaining tokens. e.g. `foo.events.*` matches `foo.events.created` but not `foo.events.user.created`; `foo.events.>` matches both. |
| `retention` | no | `limits` | `limits` - remove oldest messages when size/age limits hit (~Kafka log retention). `interest` - remove when all consumers have read (~SNS fan-out). `workqueue` - remove when any one consumer acknowledges (~SQS). |
| `maxAge` | no | `720h` | Go duration string. `720h` = 30 days. Empty string = unlimited. |

Replicas and max bytes are not configurable - the composition hardcodes 3 replicas (Raft across the NATS cluster) and unlimited max bytes.

## Example instance

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

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Kafka / AWS equivalent concepts

| Topic parameter | NATS term | Kafka comparable | AWS comparable |
|---|---|---|---|
| `streamName` | Stream | Topic | Kinesis stream name |
| `subjects` | Subjects (with wildcards) | Topic partitions filter | Kinesis shard filter |
| `retention: limits` | Limits retention | `log.retention.ms` / `log.retention.bytes` | Kinesis retention period |
| `retention: interest` | Interest retention | - | SNS (fan-out, remove when all consumers read) |
| `retention: workqueue` | Workqueue retention | Compacted topic | SQS (remove on acknowledgement) |
| `maxAge` | `max_age` (Go duration) | `log.retention.ms` | Kinesis retention hours |

## Operations

```bash
# Check XR status and readiness
kubectl get topics

# Describe a specific topic XR
kubectl describe topic foo-topic -n foo
```
