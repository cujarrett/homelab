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
LCD display on `ctrl-1`.

---

## Kiosk Display

The 1U LCD on `ctrl-1` runs a Chromium kiosk displaying the Grafana playlist. It autostarts via `getty@tty1` → autologin → `startx` → `/home/pi/kiosk.sh`.

Playlist URL: `https://grafana.local.lab/playlists/play/adc6g24?kiosk`

**Restart the display** (if black or hung):

```bash
ssh pi@192.168.10.100 "sudo systemctl restart getty@tty1.service"
```

Do not `pkill chromium` — the `while` loop in `kiosk.sh` relaunches it with a stale URL.

**Take a remote screenshot** (`scrot` is installed on `ctrl-1`):

```bash
ssh pi@192.168.10.100 "DISPLAY=:0 scrot /tmp/kiosk.png" && scp pi@192.168.10.100:/tmp/kiosk.png /tmp/kiosk.png && open /tmp/kiosk.png
```

Suggested shell alias:

```bash
alias kiosk-shot='ssh pi@192.168.10.100 "DISPLAY=:0 scrot /tmp/kiosk.png" && scp pi@192.168.10.100:/tmp/kiosk.png /tmp/kiosk.png && open /tmp/kiosk.png'
```

**Check status**:

```bash
ssh pi@192.168.10.100 "journalctl -u getty@tty1 -n 30 --no-pager && ps aux | grep -E 'chromium|kiosk|Xorg' | grep -v grep"
```

---

## Stack

| Layer | Tool | Notes |
|---|---|---|
| Kubernetes | k3s | Lightweight distro |
| GitOps | ArgoCD | App-of-apps pattern; recurses `cluster/` |
| Ingress | Traefik | DaemonSet via k3s `HelmChartConfig`; binds hostPorts 80/443 |
| TLS | cert-manager | Local CA (`local-lab-ca-issuer`) for `.local.lab`; Let's Encrypt for public hosts. Workload mTLS is Istio's own CA, not cert-manager |
| Storage | Longhorn | StorageClasses: `longhorn` (default, Delete), `longhorn-retain` (Retain), `longhorn-delete` (explicit Delete) |
| DNS | AdGuard Home | Pinned to `ctrl-1`; wildcard `*.local.lab → 192.168.10.100` for all cluster hosts |
| External access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in `cloudflare` namespace; zero-trust public ingress, no exposed firewall ports |
| Remote access | Tailscale | Subnet router on `ctrl-1`; advertises `192.168.10.0/24`; split DNS for `local.lab` |
| Platform | Crossplane | XRDs + Compositions in `platform/`; see [Platform](../platform/README.md) |
| CNI | Cilium | Pod networking, WireGuard node encryption, kube-proxy replacement, Hubble observability, NetworkPolicy. Sole policy enforcer — k3s's kube-router is disabled, see [Kubelet Probe Outage](./postmortems/postmortem-kubelet-probe-outage.md). Its own mutual auth is disabled; mesh concerns belong to Istio |
| Service mesh | Istio | Sidecar mesh chained onto Cilium; workload mTLS and platform-rendered connection policy. See [Platform Connections](./platform-connections.md) |
| Secrets | External Secrets Operator | Syncs `grafana-admin-secret` from AWS Secrets Manager. See [External Secrets](./external-secrets.md) |
| Workload identity | SPIRE | SPIFFE SVIDs backing AWS IAM Roles Anywhere. See [Platform Workload Identity](./platform-workload-identity.md) |
| Observability | kube-prometheus-stack | Prometheus (30d retention), Grafana, Alertmanager |
| Logs | Loki + Promtail | Loki SingleBinary, 30d retention; Promtail DaemonSet ships logs |
| Messaging | NATS JetStream | 3-replica cluster in `nats`; NACK controller manages Stream and Consumer CRDs |

---

## Namespaces

| Namespace | App | Notes |
|---|---|---|
| `argocd` | ArgoCD | `argocd.local.lab` |
| `monitoring` | kube-prometheus-stack | Prometheus, Grafana (`grafana.local.lab`), Alertmanager |
| `monitoring` | Loki + Promtail | Log aggregation |
| `monitoring` | prometheus-sump-pump | Long-term IoT Prometheus; ~50yr retention on `longhorn-retain` |
| `longhorn-system` | Longhorn | `longhorn.local.lab` |
| `adguard` | AdGuard Home | Pinned to `ctrl-1` via hostPort 53 |
| `cloudflare` | cloudflared | Cloudflare Tunnel; public ingress entry point |
| `cert-manager` | cert-manager | TLS issuers for internal and public hosts |
| `demo-certs` | cert-manager `Certificate` objects only | Long-lived certs for the five demo sandbox slots; no workloads |
| `external-secrets` | External Secrets Operator | Writes `grafana-admin-secret` from AWS Secrets Manager |
| `spire-server`, `spire-system` | SPIRE | Workload identity; agent DaemonSet on all nodes |
| `istio-system` | Istio | Control plane for the sidecar mesh |
| `kube-system` | Cilium | CNI, Hubble relay (`hubble.local.lab`) |
| `crossplane-system` | Crossplane | Platform compositions, XRDs, AWS provider |
| `platform-exporter` | platform-exporter | Prometheus exporter for platform state |
| `nats` | NATS + NACK | JetStream cluster (3 replicas) |

This table is cluster infrastructure only. Application namespaces (`mattjarrett-com`,
`my-vinyl`, etc.) are owned by tenant `namespace.yaml` files, not by the cluster
bootstrap, and are listed in [CLAUDE.md](../CLAUDE.md).

---

## Networking

External traffic enters through Cloudflare Tunnel to Traefik on `work-1`. Traefik
terminates TLS and routes to in-cluster Services. Node-to-node traffic is encrypted by
Cilium with WireGuard; pod-to-pod mTLS is Istio's, via a sidecar on each meshed pod.

```
Internet → Cloudflare → cloudflared (cloudflare ns)
         → Traefik (kube-system) ──mTLS (Istio sidecar)──► Pod
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
| `adguard.local.lab` | AdGuard Home |
| `argocd.local.lab` | ArgoCD |
| `grafana.local.lab` | Grafana |
| `prometheus.local.lab` | Prometheus |
| `longhorn.local.lab` | Longhorn |
| `hubble.local.lab` | Hubble UI (Cilium flow observability) |

### Public

TLS from `letsencrypt-prod`. Traffic via Cloudflare Tunnel.

Adding a new hostname requires updating the Cloudflare Tunnel ingress config before
the cert-manager HTTP-01 challenge can succeed. See the "Cloudflare Tunnel Operations"
section of [`CLAUDE.md`](../CLAUDE.md) for the API workflow.

| Hostname | Namespace | Stack |
|---|---|---|
| `mattjarrett.com` | `mattjarrett-com` | WordPress (`Wordpress`) |
| `kentjarrett.com` | `kentjarrett-com` | WordPress (`Wordpress`) |
| `mattjarrett.dev` | `mattjarrett-dev` | Angular SPA (`Spa`) |
| `blog.mattjarrett.dev` | `blog` | Ghost (raw Deployment) |
| `myvinyl.mattjarrett.dev` | `my-vinyl` | `Spa` + `Api` + `Cache` |
| `jspollock.mattjarrett.dev` | `js-pollock` | `Spa` |
| `launchpad.mattjarrett.dev` | `launchpad` | `Spa` + `Api` (API cluster-internal, reached via nginx `/api/` proxy) |
| `connections.mattjarrett.dev` | `platform-connections-demo` | `Spa` + `Api` ×3 — service mesh walkthrough |

Guest sandbox slots (`demo1`–`demo5` and `demo1-api`–`demo5-api` under `mattjarrett.dev`)
are pre-registered in the tunnel and reuse long-lived certs from the `demo-certs` namespace.

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

- [How it was built](./how-it-was-built.md) — step-by-step build history from bare Pi to this state
- [Platform](../platform/README.md) — Crossplane-based internal developer platform
- [Nothing Novel](./nothing-novel.md) — the public prior art behind every mechanism here
