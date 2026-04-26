# k3s Cluster Upgrade

## Current State

| Node | Role | Version |
|---|---|---|
| `ctrl-1` | control-plane | `v1.34.6+k3s1` |
| `work-1` | worker | `v1.34.6+k3s1` |
| `work-2` | worker | `v1.34.6+k3s1` |
| `work-3` | worker | `v1.34.6+k3s1` |

Check current stable: `curl -sI https://update.k3s.io/v1-release/channels/stable | grep location`

---

## Two Options

**Option A — Automated (system-upgrade-controller):** GitOps-native, tracks the stable channel automatically. Add it as an ArgoCD app and it handles future upgrades too. More setup, better long-term.

**Option B — Manual (install script over SSH):** Run one command per node. Good for a one-time upgrade to latest stable right now.

---

## Option A — Automated via system-upgrade-controller (recommended)

### Step 1 — Add to ArgoCD

Create `apps/system-upgrade/system-upgrade-controller.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: system-upgrade-controller
  namespace: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/cujarrett/homelab.git
    targetRevision: main
    path: apps/system-upgrade
  destination:
    server: https://kubernetes.default.svc
    namespace: system-upgrade
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

Create `apps/system-upgrade/controller.yaml` (the upstream manifest, pinned):

```yaml
# Source: https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml
# Apply CRD + controller — fetch latest from upstream and commit here
```

> In practice: download the two upstream files and commit them. ArgoCD syncs them into the cluster.
>
> ```bash
> mkdir -p apps/system-upgrade
> curl -sL https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml \
>   -o apps/system-upgrade/crd.yaml
> curl -sL https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml \
>   -o apps/system-upgrade/controller.yaml
> ```

Register in bootstrap: add an entry to `apps/argocd/bootstrap.yaml` for `system-upgrade-controller`.

### Step 2 — Create upgrade Plans

Create `apps/system-upgrade/plans.yaml`:

```yaml
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: server-plan
  namespace: system-upgrade
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: In
        values: ["true"]
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  channel: https://update.k3s.io/v1-release/channels/stable
---
apiVersion: upgrade.cattle.io/v1
kind: Plan
metadata:
  name: agent-plan
  namespace: system-upgrade
spec:
  concurrency: 1
  cordon: true
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  prepare:
    args: [prepare, server-plan]
    image: rancher/k3s-upgrade
  serviceAccountName: system-upgrade
  upgrade:
    image: rancher/k3s-upgrade
  channel: https://update.k3s.io/v1-release/channels/stable
```

The `prepare` step on the agent plan makes workers wait until `ctrl-1` finishes before starting. `concurrency: 1` means one node at a time. With `channel` set to `stable`, future k3s stable releases trigger upgrades automatically on the next poll.

### Step 3 — Monitor

```bash
# Watch plans resolve target version
kubectl get plan -n system-upgrade -o wide

# Watch upgrade jobs run (one job per node per plan)
kubectl get jobs -n system-upgrade -w

# Watch nodes cycle through SchedulingDisabled → Ready
kubectl get nodes -w
```

---

## Option B — Manual (one-time, SSH per node)

Upgrade server first, then workers one at a time. Control plane will be briefly unavailable per restart (~10–30s); workloads on workers continue running.

### ctrl-1 (server)

```bash
ssh pi@192.168.10.100
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -
# k3s restarts automatically; wait for it to come back
sudo systemctl status k3s
exit
```

Verify from your Mac before moving to workers:

```bash
kubectl get nodes
# ctrl-1 should show new version and Ready
```

### work-1

```bash
# Optional: drain first if you want zero disruption to workloads
kubectl drain work-1 --ignore-daemonsets --delete-emptydir-data

ssh pi@192.168.10.101
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable K3S_URL=https://192.168.10.100:6443 K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/token 2>/dev/null || echo "GET_FROM_CTRL1") sh -
sudo systemctl status k3s-agent
exit

kubectl uncordon work-1
kubectl get nodes
```

> Get the token from ctrl-1: `ssh pi@192.168.10.100 'sudo cat /var/lib/rancher/k3s/server/token'`

### work-2 and work-3

Repeat the same pattern, substituting IPs (`192.168.10.102`, `192.168.10.103`) and node names.

---

## Verify

```bash
# All nodes should show the same new version and Ready
kubectl get nodes

# ArgoCD and all apps should be green after a minute
kubectl get applications -n argocd

# Spot-check critical pods
kubectl get pods -n argocd
kubectl get pods -n monitoring
kubectl get pods -n longhorn-system
```

---

## Notes

- **Version skew:** Kubernetes only supports upgrading one minor version at a time (e.g. 1.33 → 1.34 → 1.35). Do not skip minor versions. The stable channel handles this automatically if you upgrade regularly; check the channel's resolved version before applying if you've been behind for a long time.
- **Traefik:** Already on 1.32+, so Traefik v3 is installed. No Traefik migration needed for upgrades within the 1.32+ range.
- **ARM64:** k3s binaries are ARM64-native. No special flags needed for Raspberry Pi 5.
- **kiosk on work-1:** The kiosk process survives the k3s-agent restart (it's not managed by k3s). No special handling needed.
