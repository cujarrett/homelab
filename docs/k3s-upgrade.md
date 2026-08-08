# Upgrading k3s

Re-running the k3s install script with a pinned version upgrades a node in place. The server
(`ctrl-1`) goes first, then agents one at a time, draining before each.

The upgrade is routine; what has caused outages is everything around it — lost flags, a bundled
Traefik chart that cannot adopt its own CRDs, and probe failures that never show up as a crashed
pod. Each of those cost real downtime, so they are covered below.

| Chapter | What it covers |
|---|---|
| [Pre-flight](#pre-flight) | Checks, and recovering the real install flags |
| [Upgrading a node](#upgrading-a-node) | Order, drain, install, uncordon |
| [Verification](#verification) | Including the checks that catch silent breakage |
| [Known traps](#known-traps) | Failures seen before, and how to spot them fast |
| [Rollback](#rollback) | Re-pinning a node to the previous version |

---

## Pre-flight

**Never copy install flags from a document, including this one.** The installer rewrites the
systemd unit from the flags you pass it, so anything omitted is silently dropped. Read them off
the running unit and reuse exactly those:

```bash
ssh pi@192.168.10.100 "sudo grep -A20 'ExecStart=/usr/local/bin/k3s' /etc/systemd/system/k3s.service"
ssh pi@192.168.10.101 "sudo grep -A12 'ExecStart=/usr/local/bin/k3s' /etc/systemd/system/k3s-agent.service"
```

`--flannel-backend none` matters most: Cilium is the CNI, and a re-enabled flannel leaves a
stale `flannel.1` device that collides with Cilium's VXLAN port and crash-loops the server.
Agents run only `--node-name <node>`.

Some settings live in a config file the installer never sees and must survive:

```bash
ssh pi@192.168.10.100 "sudo cat /etc/rancher/k3s/config.yaml"   # expect: disable-network-policy: true
```

That stops k3s's kube-router fighting Cilium over NetworkPolicy. Losing it silently breaks every
kubelet probe to a policy-selected pod — see [Kubelet Probe Outage](./postmortem-kubelet-probe-outage.md).

Then confirm the cluster can afford to lose a node, and pin the version:

```bash
kubectl get nodes -o wide
kubectl get volumes.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,ROBUSTNESS:.status.robustness
kubectl get applications -n argocd
export K3S_VERSION=v1.36.3+k3s1
```

Every Longhorn volume must read `healthy` before draining — a degraded volume has no replica to
fall back on. Read the release notes too; the bundled-component bumps bite, not the Kubernetes
version.

---

## Upgrading a node

`ctrl-1` is the only control-plane node, so the API server is briefly unavailable while it
restarts; running pods and public sites are unaffected. Upgrade `ctrl-1` first — agents newer
than the server is unsupported skew — then `work-1`, `work-2`, `work-3` one at a time. Longhorn
keeps 3 replicas across 4 nodes, so draining a second node mid-rebuild can leave one copy.

**1. Cordon and drain.**

```bash
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=180s
```

`--ignore-daemonsets` is required for Cilium, Istio's CNI agent, Traefik and Promtail.
Longhorn's `instance-manager` refuses eviction for a minute or two on its disruption budget then
succeeds — normal, not a stuck drain.

**2. Re-run the installer with the flags recovered above.**

```bash
# server
ssh pi@192.168.10.100 "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - server \
  --write-kubeconfig-mode 644 --disable servicelb --disable local-storage \
  --flannel-backend none --tls-san 192.168.10.100 --tls-san ctrl-1.local.lab --node-name ctrl-1"

# agent — swap IP and node name
TOKEN=$(ssh pi@192.168.10.100 "sudo cat /var/lib/rancher/k3s/server/node-token")
ssh pi@192.168.10.101 "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION \
  K3S_URL=https://192.168.10.100:6443 K3S_TOKEN=$TOKEN sh -s - agent --node-name work-1"
```

**3. Wait for `Ready` at the new version, confirm the service is stable, uncordon.**

```bash
kubectl get node <node> -w        # Ctrl-C at Ready + new VERSION
ssh pi@<node-ip> "sudo systemctl show k3s -p NRestarts"   # k3s-agent on agents
kubectl uncordon <node>
```

A climbing `NRestarts` means the service is crash-looping even though the node reports Ready —
`journalctl -u k3s` will have a `Shutdown request received` line naming the cause.

**4. Let Longhorn finish rebuilding before the next node.**

```bash
kubectl get volumes.longhorn.io -n longhorn-system --no-headers -o custom-columns=R:.status.robustness | sort | uniq -c
```

---

## Verification

```bash
kubectl get nodes -o wide

# Running but NOT ready — a 0/1 Running pod passes a plain "grep -v Running"
kubectl get pods -A --no-headers | awk '{split($3,a,"/"); if ($4=="Running" && a[1]!=a[2]) print}'

kubectl get pods -A --no-headers | grep -vE "Running|Completed"
kubectl get applications -n argocd
kubectl get volumes.longhorn.io -n longhorn-system --no-headers -o custom-columns=R:.status.robustness | sort | uniq -c

for u in https://mattjarrett.com https://kentjarrett.com https://grafana.local.lab; do
  echo "$u $(curl -sk -o /dev/null -w '%{http_code}' $u --max-time 10)"
done
```

Then run [`/cilium-pre-merge-check`](../.claude/commands/cilium-pre-merge-check.md) — it probes a
NetworkPolicy-selected pod from its own node, the only way to catch the host-identity failure.

---

## Known traps

**Traefik CRDs fail to adopt.** k3s bundles Traefik and bumps the chart across releases. If the
existing CRDs lack Helm ownership metadata the install job fails, the DaemonSet is removed, and
*all* ingress goes down. Symptom: `helm-install-traefik*` jobs in `CrashLoopBackOff` and no
`traefik` DaemonSet.

```bash
kubectl get crd -o name | grep 'traefik\.io' | xargs -I{} kubectl label {} app.kubernetes.io/managed-by=Helm --overwrite
kubectl get crd -o name | grep 'traefik\.io' | xargs -I{} kubectl annotate {} meta.helm.sh/release-name=traefik-crd meta.helm.sh/release-namespace=kube-system --overwrite
kubectl delete job -n kube-system helm-install-traefik helm-install-traefik-crd
```

**Pods Running but never Ready.** Check `disable-network-policy` survived and no kube-router
jump rules returned:

```bash
kubectl exec -n kube-system <cilium-pod> -- iptables -t filter -L OUTPUT -n | grep -c KUBE-ROUTER   # must be 0
```

**Cilium config that never took effect.** Agents read `cilium-config` only at startup; a
values-only change does not restart the DaemonSet, and `4/4 ready` does not mean restarted.
Verify from the agent, not the ConfigMap:

```bash
kubectl logs -n kube-system <cilium-pod> -c cilium-agent | grep enable-bpf-masquerade
```

---

## Rollback

Cordon and drain as above, then re-run the same install command with `INSTALL_K3S_VERSION` set
to the prior version — the script downgrades the binary and restarts the service the same way it
upgrades. Node data, labels and `/etc/rancher/k3s/` are untouched.

---

## Related Docs

- [Cluster](./cluster.md) — current stack and hardware
- [Kubelet Probe Outage](./postmortem-kubelet-probe-outage.md) — why several checks above exist
