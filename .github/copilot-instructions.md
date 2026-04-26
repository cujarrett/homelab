# Homelab Cluster Context

## Copilot Rules
- **Never run `git commit`, `git push`, or any git command that writes to or modifies repository history or remotes.** If a task requires committing or pushing, stop and tell the user to run the git command manually.
- **Always use `k` instead of `kubectl` in commands shown to the user.**
- **When debugging, always list every command used** — show the command, what it does, and why — so the user can learn the debugging workflow. Do this inline as you debug, not as a summary at the end.

### Pre-commit safety check

Whenever files are ready to be committed (after a set of changes is complete, or when the user asks), automatically perform this check on every changed file **before** telling the user to commit. Report the results inline — do not wait to be asked.

Check for:
1. **Hardcoded secrets** — passwords, API keys, tokens, private keys, connection strings with credentials
2. **Sensitive identifiers** — AWS account IDs, Cloudflare account/tunnel IDs, internal IPs beyond those documented in `copilot-instructions.md`, UUIDs that are runtime secrets
3. **Personal data** — email addresses, names, or other PII not already public
4. **Credentials in templates** — go-template or Helm values that embed literal secrets instead of referencing a Secret/external store
5. **Cluster safety** — no `kubectl delete` or destructive operations baked into manifests; no `hostNetwork: true` or `privileged: true` without justification

If all checks pass, state "All files safe to commit." If any issue is found, describe it and suggest a fix before the user commits.

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
| GitOps | ArgoCD | App-of-apps pattern via `apps/argocd/bootstrap.yaml`, recurses `apps/` |
| Ingress | Traefik | Deployed as DaemonSet via k3s HelmChartConfig; binds hostPorts 80/443 |
| TLS | cert-manager | Local CA issuer (`local-lab-ca-issuer`) for `.local.lab` hosts; Let's Encrypt (staging + prod) for public hosts via HTTP-01/Traefik |
| Storage | Longhorn | Three StorageClasses: `longhorn` (default, Delete), `longhorn-retain` (Retain — use for stateful platform XRs), `longhorn-delete` (explicit Delete) |
| DNS | AdGuard Home | Runs in `adguard` namespace, pinned to node `ctrl-1` via nodeSelector, hostPort 53 UDP |
| External Access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in `cloudflare` namespace; token from secret `cloudflare-tunnel-token` |
| Platform Abstraction | Crossplane | Three XR types: `XWordPressPlatform`, `XSpa`, `XApi` — all use `function-patch-and-transform` + `function-go-templating` |

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
| `crossplane-system` | Crossplane | Platform compositions, XRDs, providers |
| `mattjarrett-com` | WordPress (XWordPressPlatform) | `mattjarrett.com` via Cloudflare Tunnel; 10Gi wp-content, 1Gi MariaDB |
| `mattjarrett-dev` | Angular SPA (XSpa) | `mattjarrett.dev` via Cloudflare Tunnel; nginx serving pre-built Angular dist |

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
- `my-vinyl-api.mattjarrett.dev` — vinyl collection API, routed via Cloudflare Tunnel
- `myvinyl.mattjarrett.dev` — vinyl collection SPA, routed via Cloudflare Tunnel

## Cloudflare Tunnel Operations

Tunnel ID: `REDACTED` — retrieve with:
```bash
kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.tunnelID}' | base64 -d
```

Account ID: `REDACTED` — visible in the Cloudflare dashboard URL (`dash.cloudflare.com/<account-id>/`) or retrieve with:
```bash
kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.accountID}' | base64 -d
```

All hostnames route to: `https://192.168.10.101:443` with `noTLSVerify: true`

**Every new public hostname requires a tunnel config update.** The API is a full replace — always fetch first, append, then PUT back.

Adding a new public hostname:
```bash
# 0. Get IDs from cluster
export ACCOUNT_ID=$(kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.accountID}' | base64 -d)
export TUNNEL_ID=$(kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.tunnelID}' | base64 -d)
export CF_TOKEN=<token>

# 1. Fetch current config
curl -s -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer $CF_TOKEN" | python3 -m json.tool

# 2. PUT the full ingress array back with the new entry added before the catch-all:
curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "ingress": [
        ...existing entries...,
        {"hostname":"<new-hostname>","service":"https://192.168.10.101:443","originRequest":{"noTLSVerify":true}},
        {"service":"http_status:404"}
      ],
      "warp-routing":{"enabled":false}
    }
  }'
```

**Required for Let's Encrypt cert issuance:** the tunnel hostname must be added *before* the cert request is created, otherwise the HTTP-01 challenge self-check fails. If the cert is already stuck pending, delete the CertificateRequest to force a retry:
```bash
kubectl delete certificaterequest -n <namespace> --all
```

**API token permissions needed:** Cloudflare Zero Trust → Argo Tunnel (Legacy) → Edit

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
| `homelab-mbp` | `grafana-dashboard-homelab-mbp.yaml` | Homelab MacBook Pro view |
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
- `mattjarrett.dev` → `mattjarrett-dev-mattjarrett-dev.*@kubernetes` or `web-mattjarrett-dev.*@kubernetes` (both exist; use alternation `|`)
- `mattjarrett.com` → `mattjarrett-com-mattjarrett-com-wordpress.*@kubernetes`

## 1U Display (work-1)
`work-1` runs a kiosk browser on the attached display. It is **not** managed by systemd — it's a bare background process under the `pi` user.

- Script: `~/kiosk.sh` on `work-1`
- Current URL: `https://grafana.local.lab/playlists/play/admt9pc?kiosk`

### X server config (manual — not in Git)
The Pi 5 has two DRM devices (`card0` = v3d, `card1` = display). Without explicit config, Xorg fails with "Cannot run in framebuffer mode". A config file must exist at `/etc/X11/xorg.conf.d/99-pi5.conf` on work-1:
```
Section "Device"
    Identifier "Modesetting"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card1"
EndSection

Section "Monitor"
    Identifier "HDMI-1"
    DisplaySize 172 34
EndSection
```
If work-1 is ever rebuilt, create this file before attempting to start the kiosk:
```bash
sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/99-pi5.conf << 'EOF'
Section "Device"
    Identifier "Modesetting"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card1"
EndSection

Section "Monitor"
    Identifier "HDMI-1"
    DisplaySize 172 34
EndSection
EOF
```

To update the URL without rebooting work-1:
```bash
# 1. Edit the URL
ssh pi@192.168.10.101 "sed -i 's|OLD_URL|NEW_URL|' ~/kiosk.sh"

# 2. Restart the tty1 session — triggers autologin → startx → kiosk.sh (k3s is unaffected)
ssh pi@192.168.10.101 "sudo systemctl restart getty@tty1.service"
```

**Do not** just `pkill chromium` — the `while true` loop in kiosk.sh will relaunch chromium with the URL already loaded in memory, ignoring the file change. Restarting getty re-runs `.bashrc` which re-sources the updated script.

## Crossplane Platform

Three platform types are defined under `platform/`:

| XRD | Kind | Namespace | Notes |
|---|---|---|---|
| `xwordpressplatforms.platform.local.lab` | `XWordPressPlatform` | `mattjarrett-com` | MariaDB StatefulSet + WordPress Deployment; credentials from XR UID |
| `xspas.platform.local.lab` | `XSpa` | `mattjarrett-dev` | nginx + Angular SPA; nginx config generated via go-templating function |
| `xapis.platform.local.lab` | `XApi` | — | Generic REST API (no active instance) |

### GitOps flow for XR instances
1. Commit an XR file to `platform/xrs/<type>/<name>.yaml`
2. `xrs` ApplicationSet (`apps/argocd/xrs-appset.yaml`) detects the file and creates an ArgoCD Application
3. ArgoCD applies the XR to the cluster
4. Crossplane reconciles and creates all composed resources

XR instance files live under `platform/xrs/`:
- `platform/xrs/wordpress/mattjarrett-com.yaml`
- `platform/xrs/spa/mattjarrett-dev.yaml`

### Deleting an XR instance (correct order — prevents data loss)
```bash
# 1. Delete the XR — Crossplane cascade-deletes all composed resources
kubectl delete xspa <name> -n <namespace>
# or: kubectl delete xwordpressplatform <name> -n <namespace>

# 2. Remove the file from git and push — ArgoCD prunes the Application
git rm platform/xrs/<type>/<name>.yaml && git commit -m "..." && git push
```
DO NOT remove the file first — that orphans resources.

### Storage classes for XR PVCs
- `longhorn-retain` — use for `dataRetention: retain` (PV survives XR deletion, data recoverable)
- `longhorn-delete` — use for `dataRetention: delete` (PV wiped on XR deletion)
- The `dataRetention` field in the WordPress XR controls which is used

### WordPress restore
Backup location: `REDACTED`
```bash
bash scripts/restore-wordpress.sh \
  --backup-dir "REDACTED" \
  --namespace mattjarrett-com \
  --instance mattjarrett-com \
  --old-url http://127.0.0.1 \
  --new-url https://mattjarrett.com
```

## ArgoCD AppProjects
Four projects scope workloads by concern:
| Project | Allowed source repos | Contents |
|---|---|---|
| `platform` | homelab git + `argoproj.github.io/argo-helm` | ArgoCD, Crossplane, compositions, bootstrap |
| `infrastructure` | homelab git | Longhorn, Traefik, cert-manager, AdGuard, Cloudflare |
| `observability` | homelab git + `prometheus-community.github.io/helm-charts` + `grafana.github.io/helm-charts` | kube-prometheus-stack, Loki, Promtail |
| `workloads` | homelab git | All XR instances (mattjarrett-com, mattjarrett-dev, blog); `sourceNamespaces: ["*"]` for app-in-any-namespace |

Applications from the `workloads` project can live in any namespace (`sourceNamespaces: ["*"]`).

## Key Conventions
- ArgoCD `automated: { prune: true, selfHeal: true }` on all apps — cluster converges to repo state automatically
- `ServerSideApply: true` used on most apps
- Secrets (tunnel tokens, Grafana admin creds, etc.) are pre-created manually in the cluster — never stored in Git
- Traefik annotations on all Ingresses: `traefik.ingress.kubernetes.io/router.entrypoints: websecure` and `traefik.ingress.kubernetes.io/router.tls: "true"`
- cert-manager annotation on all Ingresses: `cert-manager.io/cluster-issuer: local-lab-ca-issuer` (internal) or `letsencrypt-prod` (public)
- XSpa compositions use `gotemplating.fn.crossplane.io/ready: "True"` on go-templating resources to avoid false `Ready=False` on the XR

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
