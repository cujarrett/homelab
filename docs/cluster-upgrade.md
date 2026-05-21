# Cluster Upgrade

How to upgrade k3s when you get a release notification email from GitHub.

---

## Before you start

Confirm the stable channel has resolved to the version in the email:

```bash
curl -sv https://update.k3s.io/v1-release/channels/stable 2>&1 | grep location
```

Check current node versions:

```bash
kubectl get nodes
```

## Upgrade

Upgrade the control plane first. Workers stay up serving traffic the whole time.

### ctrl-1

```bash
ssh pi@192.168.10.100 'curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -'
```

Wait for it to come back, then verify before touching any worker:

```bash
kubectl get nodes
# ctrl-1 should show the new version and Ready
```

### Workers

Upgrade one at a time. Each takes ~30s.

```bash
TOKEN=$(ssh pi@192.168.10.100 'sudo cat /var/lib/rancher/k3s/server/token')

ssh pi@192.168.10.101 "curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable K3S_URL=https://192.168.10.100:6443 K3S_TOKEN=$TOKEN sh -"
kubectl get nodes  # wait for work-1 Ready

ssh pi@192.168.10.102 "curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable K3S_URL=https://192.168.10.100:6443 K3S_TOKEN=$TOKEN sh -"
kubectl get nodes  # wait for work-2 Ready

ssh pi@192.168.10.103 "curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable K3S_URL=https://192.168.10.100:6443 K3S_TOKEN=$TOKEN sh -"
kubectl get nodes  # wait for work-3 Ready
```

## Verify

```bash
kubectl get nodes
kubectl get applications -n argocd
kubectl get pods -n longhorn-system | grep -v Running
```

All nodes same version, all ArgoCD apps green, no non-Running Longhorn pods — done.

## Notes

- Only upgrade one minor version at a time (e.g. 1.33 → 1.34 → 1.35). The stable channel handles this — just don't skip emails.
- The kiosk on work-1 survives the k3s-agent restart. No special handling needed.
