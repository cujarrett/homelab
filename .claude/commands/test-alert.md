---
description: Fire a synthetic alert through Alertmanager and confirm it reaches Discord. Also checks where a named alert would route without sending anything.
---

Verifies the alert pipeline end to end: Prometheus rule → Alertmanager route → Discord.

Argument is optional. With no argument, send a synthetic `AlertPipelineTest`. With an alert name, only report where that alert would route — nothing is sent.

**Never print the contents of `alertmanager-...-generated`.** The operator resolves the webhook secret into that config in cleartext, so any `grep`/`gunzip` of it leaks the credential into the transcript. Compare hashes or redact with `sed 's#https://discord.com/api/webhooks/.*#<REDACTED>#'`.

```bash
POD=alertmanager-monitoring-kube-prometheus-alertmanager-0
```

## Route check (no send)

```bash
kubectl exec -n monitoring $POD -c alertmanager -- \
  amtool config routes test --alertmanager.url=http://localhost:9093 alertname="<AlertName>"
```

`monitoring/discord/discord` means it reaches the channel. `null` means it is silenced — expected only for `Watchdog` and the three `Kube*Down` k3s false positives.

To see the whole tree: `amtool config routes --alertmanager.url=http://localhost:9093`.

## Send a test alert

Take a baseline first — the counter is cumulative and never resets, so only the delta proves delivery.

```bash
kubectl exec -n monitoring $POD -c alertmanager -- sh -c \
  'wget -qO- http://localhost:9093/metrics' | grep '^alertmanager_notifications_total{integration="discord"}'
```

Send it. `--end` matters: an alert with no end time stays active and re-notifies every `repeatInterval` (12h) until manually silenced.

```bash
kubectl exec -n monitoring $POD -c alertmanager -- amtool alert add \
  --alertmanager.url=http://localhost:9093 \
  alertname=AlertPipelineTest severity=warning namespace=monitoring \
  --annotation=summary="Pipeline test, resolves on its own" \
  --end="$(date -u -v+3M +%Y-%m-%dT%H:%M:%SZ)"
```

`amtool` warns about the UTF-8 matcher parser on annotations containing spaces. It falls back to the classic parser and the alert is accepted — not an error.

## Confirm delivery

Wait past `groupWait` (30s), then re-read both counters:

```bash
sleep 45
kubectl exec -n monitoring $POD -c alertmanager -- sh -c \
  'wget -qO- http://localhost:9093/metrics' \
  | grep -E '^alertmanager_notifications(_failed)?_total\{integration="discord"'
```

Sent incremented and failures flat means it worked. A `404 Unknown Webhook` in the failed counter means the secret no longer matches the live webhook — recreate `alertmanager-discord` and let the operator regenerate.

Report the before/after counts and whether a message should now be in `#homelab-alerts`.

## Testing a real rule instead

To check a rule's expression fires without waiting for real conditions, query it with the threshold inverted (`<` for a `>` rule) — a non-empty result proves the metric and label shape are right:

```bash
curl -sk --data-urlencode 'query=<expr with inverted comparison>' -G 'https://prometheus.local.lab/api/v1/query'
```

Rules live on the main Prometheus, not the sump-pump archive — the archive has `alerting: None` and reaches no Alertmanager.
