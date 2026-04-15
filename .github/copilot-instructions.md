# Homelab Cluster Context

## Overview
A 4-node k3s Kubernetes homelab managed entirely via GitOps with ArgoCD.
All workloads are defined as manifests in this repo under `apps/`, `platform/`, and `scripts/`.
GitHub repo: `https://github.com/cujarrett/homelab.git` (branch: `main`)

## Hardware & Network
- **All nodes**: Raspberry Pi 5, NVMe SSD boot, ARM64 architecture — always use ARM64-compatible images
- **Network**: VLAN 10 (`192.168.10.0/24`) is the k3s subnet; gateway is Ubiquiti UDR7 at `192.168.1.1`

| Node | Hostname | IP | Role |
|---|---|---|---|
| Raspberry Pi 5 #1 | `ctrl-1` | `192.168.10.100` | k3s server (control plane) |
| Raspberry Pi 5 #2 | `work-1` | `192.168.10.101` | k3s agent |
| Raspberry Pi 5 #3 | `work-2` | `192.168.10.102` | k3s agent |
| Raspberry Pi 5 #4 | `work-3` | `192.168.10.103` | k3s agent |

SSH access: `ssh pi@192.168.10.10x`

## Remote Access (Tailscale)
- Tailscale subnet router on `ctrl-1`, advertises `192.168.10.0/24`
- Split DNS configured in Tailscale admin: `local.lab` → `192.168.10.100` (AdGuard)
- Allows `kubectl`, SSH, and `*.local.lab` to work from any network

## Cluster Stack
| Layer | Tool | Notes |
|---|---|---|
| Kubernetes | k3s | Lightweight distro |
| GitOps | ArgoCD | App-of-apps pattern via `apps/argocd/k3s-lab.yaml`, recurses `apps/` |
| Ingress | Traefik | Deployed as DaemonSet via k3s HelmChartConfig; binds hostPorts 80/443 |
| TLS | cert-manager | Local CA issuer (`local-lab-ca-issuer`) for `.local.lab` hosts; Let's Encrypt (staging + prod) for public hosts via HTTP-01/Traefik |
| Storage | Longhorn | Default StorageClass; `longhorn-delete` variant wipes PV on release |
| DNS | AdGuard Home | Runs in `adguard` namespace, pinned to node `ctrl-1` via nodeSelector, hostPort 53 UDP |
| External Access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in `cloudflare` namespace; token from secret `cloudflare-tunnel-token` |
| Platform Abstraction | Crossplane | WordPress platform composition (`XWordPressPlatform`) using `function-patch-and-transform` and `function-go-templating` |

## Namespaces & Applications
| Namespace | App | Notes |
|---|---|---|
| `argocd` | ArgoCD | Ingress at `argocd.local.lab` |
| `monitoring` | kube-prometheus-stack | Prometheus (30d retention, 20Gi), Grafana (5Gi), Alertmanager (5Gi) |
| `monitoring` | Loki | SingleBinary mode, filesystem storage, 10Gi PVC, 30d retention |
| `monitoring` | Promtail | DaemonSet log shipper → Loki at `http://loki.monitoring.svc.cluster.local:3100` |
| `longhorn-system` | Longhorn | Ingress at `longhorn.local.lab` |
| `adguard` | AdGuard Home | DNS ad-blocking/resolver |
| `cloudflare` | cloudflared | Cloudflare Tunnel for public ingress |
| `cert-manager` | cert-manager | TLS issuers |
| `crossplane-system` | Crossplane | Platform compositions |
| `mattjarrett-com` | WordPress (XWordPressPlatform) | `mattjarrett.com` via Cloudflare Tunnel; 10Gi wp-content, 1Gi MariaDB |

## Internal Hostnames (`.local.lab`)
All use `local-lab-ca-issuer` (self-signed CA), TLS via Traefik `websecure` entrypoint.
DNS served by AdGuard Home: `*.local.lab → 192.168.10.100` (wildcard rewrite).
UniFi DHCP DNS: primary `192.168.10.100`, fallback `1.1.1.1`.
- `argocd.local.lab`
- `grafana.local.lab`
- `prometheus.local.lab`
- `longhorn.local.lab`

## Public Hostnames
- `mattjarrett.com` — WordPress, routed via Cloudflare Tunnel
- `mattjarrett.dev` — static site, routed via Cloudflare Tunnel
- `blog.mattjarrett.dev` — Ghost blog, routed via Cloudflare Tunnel

## Monitoring Stack Details
- **Prometheus**: `monitoring-kube-prometheus-prometheus`, port 9090, 30d retention, 20Gi PVC
- **Grafana**: `monitoring-grafana`, anonymous viewer access enabled, Loki datasource configured, dashboards loaded via sidecar from all namespaces
- **Loki**: StatefulSet `loki`, SingleBinary, filesystem, 10Gi PVC (`storage-loki-0`), 30d retention, compactor enabled
- **Promtail**: DaemonSet, ships logs to Loki
- **Alertmanager**: 5Gi PVC

### Grafana Dashboards
Dashboards are ConfigMaps with label `grafana_dashboard: "1"` in any namespace. Apply locally to test before committing:
```bash
kubectl apply -f apps/monitoring/<dashboard>.yaml
```

| UID | File | Purpose |
|---|---|---|
| `homelab-kiosk` | `grafana-dashboard-homelab-display.yaml` | Homelab kiosk — 5 grid units tall |
| `web-traffic` | `grafana-dashboard-web-traffic.yaml` | Web traffic MacBook view — defaults 24h |
| `web-traffic-kiosk` | `grafana-dashboard-web-traffic-kiosk.yaml` | Web traffic kiosk — 5 grid units tall, sparklines |

**Adding a new dashboard to the kiosk playlist:**
1. Create the dashboard ConfigMap in `apps/monitoring/` with `grafana_dashboard: "1"` label
2. Keep height at exactly 5 grid units (`"h": 5`) so it fits the 1U display
3. Use `"instant": true` on all stat panel targets — avoids heavy range queries that crash the Pi
4. Apply locally to test: `kubectl apply -f apps/monitoring/<dashboard>.yaml`
5. In Grafana UI → Dashboards → Playlists → edit playlist `admt9pc` → add the new dashboard
6. No restart needed — the playlist picks it up immediately

### Traefik Prometheus label quirk
Prometheus renames the `service` label from Traefik metrics to `exported_service` to avoid collision. Always use `exported_service=~"..."` in Traefik queries.

Service label format: `{namespace}-{servicename}-{port}@kubernetes`
- `blog.mattjarrett.dev` → `blog-ghost.*@kubernetes`
- `mattjarrett.dev` → `web-mattjarrett-dev.*@kubernetes`
- `mattjarrett.com` → `mattjarrett-com-mattjarrett-com-wordpress.*@kubernetes`

## 1U Display (ctrl-1)
`ctrl-1` runs a kiosk browser on the attached display. It is **not** managed by systemd — it's a bare background process under the `pi` user.

- Script: `~/kiosk.sh` on `ctrl-1`
- Current URL: `https://grafana.local.lab/playlists/play/admt9pc?kiosk`

To update the URL without rebooting ctrl-1:
```bash
# 1. Edit the URL
ssh pi@192.168.10.100 "sed -i 's|OLD_URL|NEW_URL|' ~/kiosk.sh"

# 2. Restart the tty1 session — triggers autologin → startx → kiosk.sh (k3s is unaffected)
ssh pi@192.168.10.100 "sudo systemctl restart getty@tty1.service"
```

**Do not** just `pkill chromium` — the `while true` loop in kiosk.sh will relaunch chromium with the URL already loaded in memory, ignoring the file change. Restarting getty re-runs `.bashrc` which re-sources the updated script.

## WordPress Platform (Crossplane)
- XRD: `XWordPressPlatform` (`platform.local.lab/v1alpha1`)
- Composition: MariaDB StatefulSet + WordPress Deployment, DB credentials derived from XR UID (no secrets in Git)
- Active instance: `mattjarrett-com` in namespace `mattjarrett-com`
- StorageClass `longhorn` = retain data on delete; `longhorn-delete` = wipe on delete

## Key Conventions
- ArgoCD `automated: { prune: true, selfHeal: true }` on all apps — cluster converges to repo state automatically
- `ServerSideApply: true` used on most apps
- Secrets (tunnel tokens, Grafana admin creds, etc.) are pre-created manually in the cluster — never stored in Git
- Traefik annotations on all Ingresses: `traefik.ingress.kubernetes.io/router.entrypoints: websecure` and `traefik.ingress.kubernetes.io/router.tls: "true"`
- cert-manager annotation on all Ingresses: `cert-manager.io/cluster-issuer: local-lab-ca-issuer` (internal) or `letsencrypt-prod` (public)

## Common Commands
```bash
# Check all PVCs
kubectl get pvc -A

# Watch pods in monitoring
kubectl get pods -n monitoring -w

# Scale down a StatefulSet (e.g. before PVC resize)
kubectl scale statefulset <name> -n <namespace> --replicas=0

# ArgoCD login (local)
argocd login argocd.local.lab --username admin --insecure

# Force ArgoCD sync
argocd app sync <app-name>

# Get ArgoCD admin password (if initial secret exists)
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```
