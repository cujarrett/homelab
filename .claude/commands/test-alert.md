---
description: Fire a synthetic alert through Alertmanager and confirm it reaches Discord. Also checks where a named alert would route without sending anything.
---

Verifies the alert pipeline end to end: Prometheus rule → Alertmanager route → Discord.

Argument is optional. With no argument, send one synthetic alert to each Discord channel. With an alert name, only report where that alert would route. Nothing is sent.

| Channel | Receiver | Matches | Test alert |
|---|---|---|---|
| `#homelab-cluster-alerts` | `discord` | everything else | `AlertPipelineTest` |
| `#homelab-workload-alerts` | `discord-workload` | `audience="workload"` | `WorkloadPipelineTest` |

**Never print the contents of `alertmanager-...-generated`.** The operator resolves the webhook secret into that config in cleartext, so any `grep`/`gunzip` of it leaks the credential into the transcript. Compare hashes or redact with `sed 's#https://discord.com/api/webhooks/.*#<REDACTED>#'`.

```bash
POD=alertmanager-monitoring-kube-prometheus-alertmanager-0
```

## Route check (no send)

```bash
kubectl exec -n monitoring $POD -c alertmanager -- \
  amtool config routes test --alertmanager.url=http://localhost:9093 alertname="<AlertName>" <other labels>
```

Pass the rule's own labels too, such as `audience=workload`. The route depends on them, not the name. In zsh, a label list held in one variable stays one argument, so write labels out.

`monitoring/discord/discord` means the cluster channel. `monitoring/discord/discord-workload` means the workload channel. `null` means it is silenced - expected only for `Watchdog` and the three `Kube*Down` k3s false positives.

To see the whole tree: `amtool config routes --alertmanager.url=http://localhost:9093`.

## Send a test alert

Take a baseline first - the counter is cumulative and never resets, so only the delta proves delivery.

```bash
kubectl exec -n monitoring $POD -c alertmanager -- sh -c \
  'wget -qO- http://localhost:9093/metrics' | grep '^alertmanager_notifications_total{integration="discord"}'
```

Send one per channel. `--end` matters: an alert with no end time stays active and re-notifies every `repeatInterval` (720h) until manually silenced.

```bash
END="$(date -u -v+3M +%Y-%m-%dT%H:%M:%SZ)"
kubectl exec -n monitoring $POD -c alertmanager -- amtool alert add \
  --alertmanager.url=http://localhost:9093 \
  alertname=AlertPipelineTest severity=warning namespace=monitoring \
  --annotation=summary="Cluster channel test, resolves on its own" --end="$END"
kubectl exec -n monitoring $POD -c alertmanager -- amtool alert add \
  --alertmanager.url=http://localhost:9093 \
  alertname=WorkloadPipelineTest audience=workload namespace=monitoring \
  --annotation=summary="Workload channel test, resolves on its own" --end="$END"
```

The workload test carries no `severity`. `InfoInhibitor` mutes every `severity="info"` alert.

`amtool` warns about the UTF-8 matcher parser on annotations containing spaces. It falls back to the classic parser and the alert is accepted - not an error.

## Confirm delivery

Wait past `groupWait` (30s), then re-read both counters:

```bash
sleep 45
kubectl exec -n monitoring $POD -c alertmanager -- sh -c \
  'wget -qO- http://localhost:9093/metrics' \
  | grep -E '^alertmanager_notifications(_failed)?_total\{integration="discord"'
```

Sent up by 2 and failures flat means both channels worked. The counter is per integration, not per channel, so it cannot tell the two apart. Ask the user to confirm one message landed in each channel.

A `404 Unknown Webhook` in the failed counter means a secret no longer matches its live webhook. Recreate `alertmanager-discord` or `alertmanager-discord-workload` and let the operator regenerate.

## Testing a real rule instead

To check a rule's expression fires without waiting for real conditions, query it with the threshold inverted (`<` for a `>` rule) - a non-empty result proves the metric and label shape are right:

```bash
curl -sk --netrc-optional --data-urlencode 'query=<expr with inverted comparison>' -G 'https://prometheus.local.lab/api/v1/query'
```

`--netrc-optional` picks the credentials out of `~/.netrc` - Prometheus sits behind
basicAuth. A 401 here means the netrc entry is missing, not that the rule is wrong.

Rules live on the main Prometheus, not the sump-pump archive - the archive has `alerting: None` and reaches no Alertmanager.
