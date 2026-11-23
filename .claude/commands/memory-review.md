---
description: Weekly review of cluster memory. Finds requests above their 30-day peak, idle replicas and heavy pods, then offers options for the top five.
---

Find memory the cluster can get back. Done means every finding has a size in Mi,
the file that sets it, and options. Change nothing until the owner picks.

Two kinds of memory matter.
- Requests: the scheduler reserves them. Workers near 90% requested cannot start new sandboxes.
- Real use: what the node actually spends. Pods with no request still fill the node.

## 1. Node headroom

```bash
k top nodes
k describe nodes | grep -A6 "Allocated resources" | grep memory
```

Report each node as used % and requested %. A worker over 85% requested is the headline.

## 2. Requests above the 30-day peak

The query groups by namespace and container, so a pod restart keeps its history.

```bash
q='sort_desc(max by (namespace,container) (kube_pod_container_resource_requests{resource="memory"}) - on(namespace,container) max_over_time(max by (namespace,container) (container_memory_working_set_bytes{container!="",container!="POD"})[30d:10m]))'
k get --raw "/api/v1/namespaces/monitoring/services/prometheus-operated:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$q" '$q|@uri')" \
  | jq -r '.data.result[:15][] | "\(.value[1]|tonumber/1048576|floor)Mi \(.metric.namespace)/\(.metric.container)"'
```

- Gap over 100Mi: a finding. Propose a request of peak plus 25%.
- Find the file that sets it with `grep -rn` across `cluster/`, `platform/` and `homelab-workspaces`.
- XR sizes (`size: sm|md|lg`) set requests in the composition. A smaller size is the one-line fix.

## 3. Heavy pods and idle replicas

```bash
k top pods -A --sort-by=memory | head -25
k top pods -A --no-headers | awk '{gsub("Mi","",$4); s[$1]+=$4} END {for (n in s) print s[n], n}' | sort -rn | head -15
k get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,R:.spec.replicas | awk '$3>1'
```

- Replicas over 1: a homelab rarely needs them. Give the memory each extra replica costs.
- Pods with no request over 100Mi: say so. They hide from the scheduler.
- Longhorn `instance-manager` memory grows with volume replicas. List volumes on 3 replicas that hold rebuildable data.

```bash
k -n longhorn-system get volumes.longhorn.io -o custom-columns=PVC:.status.kubernetesStatus.pvcName,NS:.status.kubernetesStatus.namespace,REPL:.spec.numberOfReplicas
```

## 4. Host processes

`k3s-server` on `ctrl-1` is the biggest single process. Its RSS tracks CRD count.

```bash
ssh pi@192.168.10.100 'ps -eo rss,comm --sort=-rss | head -5'
k get crd --no-headers | wc -l
k get mrd --no-headers | awk '{print $2}' | sort | uniq -c
```

Report the RSS and the CRD count. Flag any active MRD that no composition uses.

## Decided
Never re-raise these. Raise one only if the reason no longer holds, and say what changed.
- AWS and Azure providers stay up: live managed resources use them, and sandboxes need them warm.
- RDS and ElastiCache providers sit at 0 replicas on `worker-nodes-idle`: already scaled down.
- Prometheus retention: memory tracks series count, not retention.

## Then
Report in about 100 words: node headroom, then the top five by Mi saved.
Work through them one at a time with Options A, B, C and a Recommendation.
When the owner keeps something on purpose, add one line to "Decided" with the reason.
