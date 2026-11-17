---
description: Triage every firing and pending alert, find each one's cause, and offer options with a recommendation. Use for a Discord alert, a red Alerts panel, or one named alert.
---

Triage every alert that is firing or about to fire. Done means each one has a cause read from the live system, or one named check that would settle it, plus options.

With an alert name as the argument, run the same steps but keep only that alert.

## 1. List

Alertmanager and Prometheus need auth on their hostnames, so query them through the API server proxy.

```bash
S='/api/v1/namespaces/monitoring/services'
k get --raw "$S/monitoring-kube-prometheus-alertmanager:9093/proxy/api/v2/alerts?active=true&silenced=false&inhibited=false" | jq -r '
  .[] | select(.labels.alertname != "Watchdog")
  | [.labels.severity, .labels.alertname, .startsAt[:16], (.annotations.summary // .annotations.description), (.labels | del(.alertname, .severity, .prometheus) | tostring)]
  | @tsv' | sort | column -t -s $'\t'
k get --raw "$S/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/alerts" | jq -r '
  .data.alerts[] | select(.state == "pending") | [.labels.alertname, .activeAt[:16], (.labels | tostring)] | @tsv'
k get --raw "$S/monitoring-kube-prometheus-alertmanager:9093/proxy/api/v2/silences" | jq -r '
  .[] | select(.status.state == "active") | [.endsAt[:16], .comment, (.matchers | map(.name + "=" + .value) | join(","))] | @tsv'
```

- `Watchdog`: fires always, by design. Its absence is the finding.
- Pending: the rule is true but its `for` wait has not passed. Triage it like a firing alert.
- Silences: report one that ends within 3 days, because its alert comes back then.

## 2. Triage each alert

Work through every alert, critical first, then oldest first.

1. **Read the rule.** Find it with `grep -rn "alert: <name>" cluster/ platform/`. Homelab rules live in `cluster/monitoring/prometheusrule-*.yaml`. A rule with no match ships in the kube-prometheus-stack chart, and its `runbook_url` annotation explains it.
2. **Run its expression now.** An empty result means the cause has passed and the alert will clear by itself.

   ```bash
   P='/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query'
   k get --raw "$P?query=$(jq -rn --arg q '<expr>' '$q|@uri')" | jq -c '.data.result[] | [.metric, .value[1]]'
   ```

3. **Go to the thing the labels name.** Read its state, events and logs until one fact explains the alert.
   - A pod or workload: `k describe`, `k get events -n <namespace> --sort-by=.lastTimestamp`, `k logs --previous`.
   - An ArgoCD app: `k get applications.argoproj.io <app> -n argocd -o json | jq '.status.resources[] | select(.health.status != "Healthy")'`.
   - A GitHub repo or workflow: `gh run list --repo cujarrett/<repo> --branch main --limit 5`, then `gh run view <id> --log-failed`.
   - A node: [Cluster](../../docs/cluster.md) names each node and how to reach it.
4. **Check memory** for the alert name or the workload. A known cause or an accepted risk settles it.
5. **Name the verdict.**
   - `real`: the system is broken or about to be.
   - `clearing`: the cause is gone and the alert resolves by itself.
   - `noisy`: the system is fine and the rule's threshold or `for` wait is wrong.

Group alerts that share one cause. One down node often fires five alerts.

## 3. Report

**No alerts: one line.** `No alerts firing or pending.`

Otherwise, one line per group, critical first: the alert names, how long they have fired, the verdict and the cause in plain words.

Then, for each `real` or `noisy` group, use the decision format.

- one or two sentences on the situation
- **Options** lettered A, B, C, one line each, drawn from this ladder
  - fix the cause, with the file or command
  - change the rule, for a `noisy` alert
  - silence it with an end date and a comment, when the fix waits on someone else
  - accept it, and say what keeps firing
- **Recommendation** naming the letter

`clearing` groups get one line each, with no options.

Make no change until the user picks an option. A silence is a change too.

A silence goes through `amtool` in the Alertmanager pod, always with an end date.

```bash
k exec -n monitoring alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager -- \
  amtool silence add --alertmanager.url=http://localhost:9093 \
  alertname=<name> <label>=<value> --duration=<hours>h --comment="<why, and what ends it>"
```
