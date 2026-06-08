# Cluster

Four Raspberry Pi 5 nodes running k3s. All state is in this repo; ArgoCD drives the
cluster to match it.

---

## Hardware

| Node | Hostname | IP | Role |
|---|---|---|---|
| Raspberry Pi 5 #1 | `ctrl-1` | `192.168.10.100` | k3s server (control plane) |
| Raspberry Pi 5 #2 | `work-1` | `192.168.10.101` | k3s agent |
| Raspberry Pi 5 #3 | `work-2` | `192.168.10.102` | k3s agent |
| Raspberry Pi 5 #4 | `work-3` | `192.168.10.103` | k3s agent |

ARM64 architecture. NVMe SSD on each node. PoE+ power. All nodes on VLAN 10
(`192.168.10.0/24`). Physical rack: GeeekPi DeskPi RackMate T0 Plus 10" 4U with a 1U
LCD display on `work-1`.

---

## Stack

| Layer | Tool | Notes |
|---|---|---|
| Kubernetes | k3s | Lightweight distro |
| GitOps | ArgoCD | App-of-apps pattern; recurses `cluster/` |
| Ingress | Traefik | DaemonSet via k3s `HelmChartConfig`; binds hostPorts 80/443 |
| TLS | cert-manager | Local CA (`local-lab-ca-issuer`) for `.local.lab`; Let's Encrypt for public hosts |
| Storage | Longhorn | StorageClasses: `longhorn` (default, Delete), `longhorn-retain` (Retain), `longhorn-delete` (explicit Delete) |
| DNS | AdGuard Home | Pinned to `ctrl-1`; wildcard `*.local.lab → 192.168.10.100` for all cluster hosts |
| External access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in `cloudflare` namespace; zero-trust public ingress, no exposed firewall ports |
| Remote access | Tailscale | Subnet router on `ctrl-1`; advertises `192.168.10.0/24`; split DNS for `local.lab` |
| Platform | Crossplane | XRDs + Compositions in `platform/`; see [Platform](platform.md) |
| Observability | kube-prometheus-stack | Prometheus (365d retention), Grafana, Alertmanager |
| Logs | Loki + Promtail | Loki SingleBinary, 30d retention; Promtail DaemonSet ships logs |
| Messaging | NATS JetStream | 3-replica cluster in `nats`; NACK controller manages Stream and Consumer CRDs |

---

## Namespaces

| Namespace | App | Notes |
|---|---|---|
| `argocd` | ArgoCD | `argocd.local.lab` |
| `monitoring` | kube-prometheus-stack | Prometheus, Grafana (`grafana.local.lab`), Alertmanager |
| `monitoring` | Loki + Promtail | Log aggregation |
| `monitoring` | prometheus-sump-pump | Long-term IoT Prometheus; ~50yr retention; pinned to `work-1` |
| `longhorn-system` | Longhorn | `longhorn.local.lab` |
| `adguard` | AdGuard Home | Pinned to `ctrl-1` via hostPort 53 |
| `cloudflare` | cloudflared | Cloudflare Tunnel; public ingress entry point |
| `cert-manager` | cert-manager | TLS issuers for internal and public hosts |
| `crossplane-system` | Crossplane | Platform compositions, XRDs, AWS provider |
| `nats` | NATS + NACK | JetStream cluster (3 replicas) |

Application namespaces (`mattjarrett-com`, `my-vinyl`, etc.) are owned by tenant
`namespace.yaml` files, not by the cluster bootstrap.

---

## Networking

External traffic enters through Cloudflare Tunnel to Traefik on `work-1`. Traefik
terminates TLS and routes to in-cluster Services.

```
Internet → Cloudflare → cloudflared (cloudflare ns)
         → Traefik (kube-system, hostPort 443) → Service → Pod
```

Internal traffic (`*.local.lab`) routes via AdGuard's wildcard DNS entry → Traefik on
`192.168.10.100`.

Off-network: Tailscale subnet router on `ctrl-1` exposes `192.168.10.0/24`. Split DNS in
the Tailscale admin console resolves `*.local.lab` via AdGuard from any network.

---

## Hostnames

### Internal (`.local.lab`)

TLS from `local-lab-ca-issuer`. DNS via AdGuard wildcard `*.local.lab → 192.168.10.100`.

| Host | App |
|---|---|
| `argocd.local.lab` | ArgoCD |
| `grafana.local.lab` | Grafana |
| `prometheus.local.lab` | Prometheus |
| `longhorn.local.lab` | Longhorn |

### Public

TLS from `letsencrypt-prod`. Traffic via Cloudflare Tunnel.

Adding a new hostname requires updating the Cloudflare Tunnel ingress config before
the cert-manager HTTP-01 challenge can succeed. See `.github/copilot-instructions.md`
for the API workflow.

| Hostname | Namespace | Stack |
|---|---|---|
| `mattjarrett.com` | `mattjarrett-com` | WordPress (`XWordpress`) |
| `mattjarrett.dev` | `mattjarrett-dev` | Angular SPA (`XSpa`) |
| `blog.mattjarrett.dev` | `blog` | Ghost (raw Deployment) |
| `myvinyl.mattjarrett.dev` | `my-vinyl` | `XSpa` + `XApi` + `XCache` |
| `jspollock.mattjarrett.dev` | `js-pollock` | `XSpa` |

---

## GitOps

ArgoCD uses an app-of-apps pattern. `cluster/argocd/bootstrap.yaml` is the root
Application — it recurses `cluster/` and creates Applications for everything defined
there.

All apps use `automated: { prune: true, selfHeal: true }`. The cluster converges to
repo state automatically on every push. `ServerSideApply: true` on most apps.

Secrets (tunnel tokens, admin credentials) are pre-created in the cluster and never
stored in Git.

---

## Related Docs

- [How it was built](how-it-was-built.md) — step-by-step build history from bare Pi to this state
- [Cluster upgrade](cluster-upgrade.md) — k3s upgrade procedure
- [Service mesh](service-mesh.md) — Linkerd installation roadmap and Istio translation guide
- [Platform](platform.md) — Crossplane-based internal developer platform
