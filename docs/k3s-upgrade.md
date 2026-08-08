# Upgrading k3s

Re-running the k3s install script with a pinned version upgrades a node in place. The server
(`ctrl-1`) goes first, then agents one at a time, draining before each. The upgrade itself is
routine — everything below exists because of two things that broke it before.

| Chapter | What it covers |
|---|---|
| [Background](#background) | Two settings this cluster needs that a normal k3s install doesn't |
| [Pre-flight](#pre-flight) | Checks before touching any node |
| [Upgrading a node](#upgrading-a-node) | Order, drain, install, uncordon |
| [Verification](#verification) | Including the checks that catch silent breakage |
| [Known traps](#known-traps) | Failures seen before, and how to spot them fast |
| [Rollback](#rollback) | Re-pinning a node to the previous version |

---

## Background

This cluster runs Cilium instead of k3s's default networking. Cilium needs two things that a
default k3s install doesn't set up, and **neither one lives in this Git repo** — they live only
on the physical nodes, as flags and files the upgrade script doesn't manage. If either is ever
lost, the cluster comes back up looking fine and then breaks in a way that gives no error
pointing at the cause. That's why Pre-flight below checks both, every time.

**1. Flannel must stay off.** k3s ships its own CNI (flannel) and starts it by default, even
though Cilium is what actually handles pod networking here. Flannel and Cilium fight over the
same network device, and the server's k3s service crash-loops. Fixed with a startup flag,
`--flannel-backend none`, and flags aren't saved anywhere — you have to keep passing it, or the
next plain reinstall silently drops it and flannel comes back.

**2. k3s's own NetworkPolicy controller must stay off.** k3s also ships a NetworkPolicy
enforcer, kube-router, on by default. Cilium enforces NetworkPolicy too. With both running, a
kubelet health check to any pod that has a NetworkPolicy gets silently dropped by kube-router
before Cilium ever sees it — the pod looks unhealthy forever even though it's serving requests
fine. This actually happened; see [Kubelet Probe Outage](./postmortem-kubelet-probe-outage.md)
for what it looked like from the outside. Fixed with a setting in a file on the server,
`/etc/rancher/k3s/config.yaml`, containing `disable-network-policy: true`. That file already
exists — it was created once, as the fix — and normally never needs to be touched again.

---

## Pre-flight

**Never copy install flags from a document, including this one.** The installer rewrites the
systemd unit from whatever flags you pass it, so anything you forget to include is silently
dropped — that's how fix #1 above gets lost. Read the current flags off the running node
instead of typing them from memory:

```bash
ssh pi@192.168.10.100 "sudo grep -A20 'ExecStart=/usr/local/bin/k3s' /etc/systemd/system/k3s.service"
ssh pi@192.168.10.101 "sudo grep -A12 'ExecStart=/usr/local/bin/k3s' /etc/systemd/system/k3s-agent.service"
```

Confirm `--flannel-backend none` is in there (fix #1). Agents normally run only
`--node-name <node>`.

Now check fix #2 — the file should already exist from a past fix, so this is confirming it
survived, not setting anything up for the first time:

```bash
ssh pi@192.168.10.100 "sudo cat /etc/rancher/k3s/config.yaml"
```

**Expected output:** `disable-network-policy: true`

**If that's missing, something deleted it — recreate it before upgrading:**

```bash
ssh pi@192.168.10.100 "sudo mkdir -p /etc/rancher/k3s && echo 'disable-network-policy: true' | sudo tee /etc/rancher/k3s/config.yaml"
```

Pin the target version, then check its release notes for a bundled-component bump — Traefik,
CoreDNS, containerd. Those are what break things here, not the Kubernetes version itself.
(`v1.36.3+k3s1` bundled Traefik v40.x, whose CRDs the install job couldn't adopt — see
[Known traps](#known-traps).)

```bash
export K3S_VERSION=v1.36.3+k3s1
gh release view $K3S_VERSION --repo k3s-io/k3s | head -40
```

Then confirm the cluster can afford to lose a node:

```bash
kubectl get nodes -o wide
kubectl get volumes.longhorn.io -n longhorn-system -o custom-columns=NAME:.metadata.name,ROBUSTNESS:.status.robustness
kubectl get applications -n argocd
```

Every Longhorn volume must read `healthy` before draining — a degraded volume has no replica to
fall back on.

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

for u in \
  https://mattjarrett.com \
  https://kentjarrett.com \
  https://mattjarrett.dev \
  https://blog.mattjarrett.dev \
  https://myvinyl.mattjarrett.dev \
  https://jspollock.mattjarrett.dev \
  https://launchpad.mattjarrett.dev \
  https://connections.mattjarrett.dev \
  https://argocd.local.lab \
  https://grafana.local.lab \
  https://prometheus.local.lab \
  https://longhorn.local.lab \
  https://adguard.local.lab \
  https://hubble.local.lab
do echo "$u $(curl -sk -o /dev/null -w '%{http_code}' $u --max-time 10 -A 'Mozilla/5.0')"
done
# 200 means up. 302 is fine too — some apps redirect their own root (Prometheus, AdGuard).
# Without -A above, the *.mattjarrett.dev hosts 403 — that's Cloudflare rejecting curl's
# lack of a browser User-Agent, not the site being down.
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

**Cilium config that never took effect.** Agents read `cilium-config` only at startup; a
values-only change does not restart the DaemonSet, and `4/4 ready` does not mean restarted.
Verify from the agent, not the ConfigMap:

```bash
CIL=$(kubectl get pod -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n kube-system $CIL -c cilium-agent | grep enable-bpf-masquerade
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
