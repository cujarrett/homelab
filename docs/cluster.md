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

Playlist URL: `https://grafana.local.lab/playlists/play/bfkvgx130fncwc?kiosk`

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
| TLS | cert-manager | Local CA (`local-lab-ca-issuer`) for `.local.lab`; Let's Encrypt for public hosts; SPIRE identity certs for mTLS |
| Storage | Longhorn | StorageClasses: `longhorn` (default, Delete), `longhorn-retain` (Retain), `longhorn-delete` (explicit Delete) |
| DNS | AdGuard Home | Pinned to `ctrl-1`; wildcard `*.local.lab → 192.168.10.100` for all cluster hosts |
| External access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in `cloudflare` namespace; zero-trust public ingress, no exposed firewall ports |
| Remote access | Tailscale | Subnet router on `ctrl-1`; advertises `192.168.10.0/24`; split DNS for `local.lab` |
| Platform | Crossplane | XRDs + Compositions in `platform/`; see [Platform](platform.md) |
| Service mesh | Cilium | eBPF CNI + mesh; mTLS via SPIRE Mutual Auth; `toFQDNs` egress enforcement; Hubble observability |
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
| `spire` | SPIRE | Workload identity; backs Cilium Mutual Auth mTLS and AWS IAM Roles Anywhere |
| `kube-system` | Cilium | eBPF CNI, service mesh, Hubble relay (`hubble.local.lab`) |
| `crossplane-system` | Crossplane | Platform compositions, XRDs, AWS provider |
| `nats` | NATS + NACK | JetStream cluster (3 replicas) |

Application namespaces (`mattjarrett-com`, `my-vinyl`, etc.) are owned by tenant
`namespace.yaml` files, not by the cluster bootstrap.

---

## Networking

External traffic enters through Cloudflare Tunnel to Traefik on `work-1`. Traefik
terminates TLS and routes to in-cluster Services. All pod-to-pod traffic uses mTLS via
Cilium Mutual Auth at the kernel level — no sidecar required.

```
Internet → Cloudflare → cloudflared (cloudflare ns)
         → Traefik (kube-system) ──mTLS (eBPF)──► Pod
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
| `hubble.local.lab` | Hubble UI (Cilium flow observability) |

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
- [Platform](platform.md) — Crossplane-based internal developer platform
