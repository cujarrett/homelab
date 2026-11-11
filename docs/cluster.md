# Cluster

Four Raspberry Pi 5 nodes running k3s. All state is in this repo; ArgoCD drives the
cluster to match it.

---

## Hardware

[Homelab Cluster Context → Hardware & Network](../AGENTS.md#hardware--network)

---

## Kiosk Display

[Kiosk](./kiosk/README.md)

---

## Stack

[Homelab Cluster Context → Cluster Stack](../AGENTS.md#cluster-stack)

---

## Namespaces

[Homelab Cluster Context → Namespaces & Applications](../AGENTS.md#namespaces--applications)

---

## Networking

External traffic enters through Cloudflare Tunnel and reaches Traefik on `work-1`, which
terminates TLS and routes to in-cluster Services. Inside the cluster, pods talk over flannel
VXLAN across the single VLAN the nodes share, unencrypted. Istio adds mTLS on top of that, in
the namespaces that are meshed.

```
Internet → Cloudflare → cloudflared (cloudflare ns)
         → Traefik (kube-system) ──plaintext, PERMISSIVE app port──► Pod
```

Internal traffic (`*.local.lab`) routes via AdGuard's wildcard DNS entry → Traefik on
`192.168.10.100`.

Off-network: Tailscale subnet router on `ctrl-1` exposes `192.168.10.0/24`. Split DNS in
the Tailscale admin console resolves `*.local.lab` via AdGuard from any network.

---

## Hostnames

- Internal: [Homelab Cluster Context → Internal Hostnames](../AGENTS.md#internal-hostnames-locallab)
- Public: [Homelab Cluster Context → Public Hostnames](../AGENTS.md#public-hostnames)

---

## GitOps

ArgoCD uses an app-of-apps pattern. `cluster/argocd/bootstrap.yaml` is the root
Application - it recurses `cluster/` and creates Applications for everything defined
there.

All apps use `automated: { prune: true, selfHeal: true }`. The cluster converges to
repo state automatically on every push. `ServerSideApply: true` on most apps.

Cluster-setup Secrets (tunnel tokens, admin credentials) are rendered from AWS Parameter
Store and never stored in Git. See [External Secrets](./external-secrets.md).

---

## Related Docs

- [How I built it](https://blog.mattjarrett.dev/homelab/) - step-by-step build history from bare Pi to this state
- [Platform](../platform/README.md) - Crossplane-based internal developer platform
- [Nothing Novel](./nothing-novel.md) - the public prior art behind every mechanism here
