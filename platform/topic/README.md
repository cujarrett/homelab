# XTopic

Crossplane composition that provisions a durable, persistent message stream.

## What it provisions
- **Message stream** — a named, durable channel that captures published events. Supports wildcards so a single stream can receive events from multiple subjects (e.g. `foo.events.>` captures `foo.events.created`, `foo.events.updated`, etc.).

The `XSubscription` type (see [`platform/subscription/`](../subscription/)) deploys consumer applications that subscribe to streams created by this XRD.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `streamName` | yes | — | Stream name (e.g. `FOO-TOPIC`). No spaces, dots, or wildcards. |
| `subjects` | yes | — | List of subjects this stream captures. `*` matches one token, `>` matches all remaining tokens. e.g. `foo.events.*` matches `foo.events.created` but not `foo.events.user.created`; `foo.events.>` matches both. |
| `retention` | no | `limits` | `limits` — remove oldest messages when size/age limits hit (~Kinesis retention). `interest` — remove when all consumers have read (~SNS fan-out). `workqueue` — remove when any one consumer acknowledges (~SQS). |
| `maxAge` | no | `720h` | Go duration string. `720h` = 30 days. Empty = unlimited. |
| `maxBytes` | no | `-1` | Max stream size in bytes. `-1` = unlimited. |
| `replicas` | no | `3` | Number of NATS nodes that store each message. Must be ≤ NATS cluster size. |

## Example instance

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XTopic
metadata:
  name: foo-topic
spec:
  parameters:
    streamName: FOO-TOPIC
    subjects:
      - "foo.events.>"
    retention: limits
    maxAge: "720h"        # 30 days
    replicas: 3
```

Instance files live in [`platform/xrs/topic/`](../xrs/topic/).

## Kafka / AWS equivalent concepts

| XTopic parameter | NATS term | Kafka comparable | AWS comparable |
|---|---|---|---|
| `streamName` | Stream | Topic | Kinesis stream name |
| `subjects` | Subjects (with wildcards) | Topic partitions filter | Kinesis shard filter |
| `retention: limits` | Limits retention | `log.retention.ms` / `log.retention.bytes` | Kinesis retention period |
| `retention: interest` | Interest retention | — | SNS (fan-out, remove when all consumers read) |
| `retention: workqueue` | Workqueue retention | Compacted topic | SQS (remove on acknowledgement) |
| `maxAge` | `max_age` (Go duration) | `log.retention.ms` | Kinesis retention hours |
| `maxBytes` | `max_bytes` | `log.retention.bytes` | — |
| `replicas` | Stream replicas (Raft) | `replication.factor` | Kinesis (managed) |

## Operations

```bash
# Check XR status and readiness
kubectl get xtopics

# Describe a specific topic XR
kubectl describe xtopic foo-topic
```
