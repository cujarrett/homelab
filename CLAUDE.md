# Homelab Cluster Context

## Rules

- **Never run `git add`, `git commit`, `git push`, or any git command that writes to or modifies the index, repository history, or remotes.** Output the commands for the user to run — staging is part of their review, and running it for them removes the checkpoint.
- **Whenever a task requires a commit, always give a suggested commit message** — never leave the user to write it themselves.
- **Give `git add` and the commit as two separate steps, listing every file explicitly** — never `git add .`, `git add -A`, or a bare directory. Group related files onto one `git add` line. One `git add` + one commit message per repository, each under its own heading when more than one repo changed.
- **Always precede `git add` with the `cd` to that repo's absolute path**, so the commands can be pasted from anywhere without landing in the wrong repo.
- **Never output a `git push` command.** The user pushes as a deliberate human step.
- **Never include a `:` in YAML comment** Editors highlight the trailing colon as a key and mis-colour the rest of the block. Use an em dash, or reword — `# depends on tlsIssuer — letsencrypt-prod means...`, not `# depends on tlsIssuer:`. Mid-line colons (`# curl: raw curl without browser UA`) are fine.
- **Always use `k` instead of `kubectl` in commands shown to the user in chat. Use kubectl in all doc files.**
- **Never wrap `kubectl`/`k` commands in `ssh pi@...` — the user's local machine has Tailscale and kubeconfig configured. Run `kubectl` commands directly in the terminal.**
- **When debugging, always list every command used** — show the command, what it does, and why — so the user can learn the debugging workflow. Do this inline as you debug, not as a summary at the end.
- **After changing XRDs or Compositions, remind the user to sync `platform-definitions`:** `argocd app sync platform-definitions --grpc-web`
- **Platform README and XRD examples must use `foo`, `bar`, or `baz` as placeholder names** — never use real instance names (e.g. `nms-events`, `mattjarrett-com`) in `platform/*/README.md` or `platform/*/xrd.yaml` description fields.
- **No lazy cross-references in tables or lists.** Never write "Same as above," "Same as XFoo pattern," or "See above." Write it out explicitly — every row must stand on its own.
- **Platform READMEs and XRD descriptions must not leak implementation details.** Rules:
  - No infrastructure technology names in XRD `description` fields (e.g. no "NATS", "Redis", "S3", "NACK") — describe *what* the platform does, not *how*
  - No internal resource names, namespaces, or controller names in README prose (e.g. no "managed by NACK", no `kubectl get consumer -n nats`)
  - No internal derivation conventions in user-facing descriptions (e.g. no "uppercased to become the stream name")
  - Env var names injected into containers are a **necessary exception** — document them in the README since app code must read them
  - Wildcard syntax required to use a parameter is a **necessary exception** — document it since dev teams need it to set the value correctly
  - The composition is the platform team's implementation file — details there are fine

### Pre-commit safety check

Before telling the user to commit, always run `/security-review`. It reviews the pending changes on the current branch for security issues. Once it confirms the changes are safe, offer the user a suggested commit message — do not run `git commit` yourself.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." — [grugbrain.dev](https://grugbrain.dev/)

- **Say no.** The best weapon against complexity is the word "no". No new feature, no new abstraction, until it earns its place.
- **No abstraction until a pattern repeats three times.** Let cut points emerge naturally from the code; don't invent them up front.
- **80/20 solutions.** Ship 80% of the value with 20% of the code. Ugly but working beats elegant but over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it. If you don't see the use, go away and think.
- **Boring, obvious code wins.** Intermediate variables with good names beat clever one-liners. Easier to debug.
- **DRY is not a law.** A little copy-paste beats a complex abstraction built for two cases.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so. That's a signal to simplify, not a personal failing.
- **Comments are grug too.** Two or three lines, not a paragraph. Say why the value is what it is, or what bites you if you change it — never restate what the code does. Cut the percentile tables, the alternatives you rejected, and the history of how you got there.

## Documentation

Applies to every `.md` file in this repo — same grug philosophy, applied to prose.

- **Grug first, then depth.** Every section opens with one or two plain sentences before any table, diagram, or YAML. If a reader stops after the first line, they should still have the idea.
- **Concise > long.** One representation per idea. Never a diagram that repeats the prose, or a table that repeats the diagram.
- **One numbering scheme per doc.** If steps or phases are numbered, nothing else is. Chapters are flat `#` headings with plain titles — never "Part 3".
- **Flat hierarchy.** No wrapper heading whose only content is other headings. If a chapter holds ten things, those ten things are the chapters.
- **Every chapter does one job.** A chapter titled "where we are today" must not contain timeless explanation. Move it.
- **No meta-content.** Never document what changed from an earlier draft, critique a previous plan, or narrate the doc's own history. Same principle as the code-comment rule: state current rationale only.
- **No time-bound content.** No "tonight", "this session", "first night", no timeboxes. Say "Phases 0, 1 and 6 touch no cluster" — not "do this at 10pm". Docs outlive the session that wrote them.
- **Index at the top** for any doc with more than three chapters: one "start here" line, then a table of every chapter. Verify every anchor resolves before finishing.
- **Link to real paths**, don't just code-format them — `[Api](../platform/api/)`, not `` `Api` ``.
- **Cross-doc links use the human title and a `./` relative path** — `[Platform Connections](./platform-connections.md)`, never a bare or backticked filename. A reader should see what the doc *is*, not what it's called on disk. Deep links keep the title too: `[Platform Connections → Known limits](./platform-connections.md#known-limits)`. **Never link to a doc under `local-only/`** — it is gitignored, so the link is dead for every reader but you.

## Overview
A 4-node k3s Kubernetes homelab managed entirely via GitOps with ArgoCD.
All workloads are defined as manifests in this repo under `cluster/`, `platform/`, and `homelab-workspaces/`.
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
| GitOps | ArgoCD | App-of-apps pattern via `cluster/argocd/bootstrap.yaml`, recurses `cluster/` |
| Ingress | Traefik | Deployed as DaemonSet via k3s HelmChartConfig; binds hostPorts 80/443 |
| TLS | cert-manager | Local CA issuer (`local-lab-ca-issuer`) for `.local.lab` hosts; Let's Encrypt (staging + prod) for public hosts via HTTP-01/Traefik |
| Storage | Longhorn | Three StorageClasses: `longhorn` (default, Delete), `longhorn-retain` (Retain — use for stateful platform XRs), `longhorn-delete` (explicit Delete) |
| DNS | AdGuard Home | Runs in `adguard` namespace, pinned to node `ctrl-1` via nodeSelector, hostPort 53 UDP |
| External Access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in `cloudflare` namespace; token from secret `cloudflare-tunnel-token` |
| Platform Abstraction | Crossplane | Nine XR types — see the Crossplane Platform section below |
| CNI | Cilium | DaemonSet in `kube-system` on all 4 nodes; Helm chart from `helm.cilium.io`. Plumbing only — pod networking, WireGuard node encryption, kube-proxy replacement, Hubble. Mesh features (mutual auth, connection policy) belong to Istio; Cilium's SPIRE mutual auth is disabled. |
| Service Mesh | Istio | Sidecar mesh chained onto Cilium CNI; provides workload mTLS. Permissive mode — nothing is denied. Platform-managed connection policy is designed but not built; see [Platform Connections](./docs/platform-connections.md). |
| Workload Identity | SPIRE | `spire-server` + `spire-system` namespaces; Helm chart from `spiffe.github.io/helm-charts-hardened`. Previously backed Cilium mutual auth (now disabled); retained for potential Istio/SPIFFE use. |

## Namespaces & Applications
| Namespace | App | Notes |
|---|---|---|
| `argocd` | ArgoCD | Ingress at `argocd.local.lab` |
| `monitoring` | kube-prometheus-stack | Prometheus (30d retention, 35Gi), Grafana (2Gi), Alertmanager (2Gi) |
| `monitoring` | prometheus-sump-pump | Dedicated long-term Prometheus for sump pump + weather data (18250d retention, 2Gi PVC, `longhorn-retain`, no node pinning); Grafana datasource UID `sump-pump-archive` |
| `monitoring` | Loki | SingleBinary mode, filesystem storage, 5Gi PVC, 30d retention |
| `monitoring` | Promtail | DaemonSet log shipper → Loki at `http://loki.monitoring.svc.cluster.local:3100` |
| `longhorn-system` | Longhorn | Ingress at `longhorn.local.lab` |
| `adguard` | AdGuard Home | DNS ad-blocking/resolver |
| `cloudflare` | cloudflared | Cloudflare Tunnel for public ingress |
| `cert-manager` | cert-manager | TLS issuers |
| `crossplane-system` | Crossplane | Platform compositions, XRDs, providers |
| `nats` | NATS + NACK | JetStream cluster (3 replicas), NACK controller for Stream/Consumer CRDs |
| `mattjarrett-com` | WordPress (Wordpress) | `mattjarrett.com` via Cloudflare Tunnel; 7Gi wp-content, 1Gi MariaDB |
| `kentjarrett-com` | WordPress (Wordpress) | `kentjarrett.com` via Cloudflare Tunnel; 10Gi wp-content, 2Gi MariaDB |
| `mattjarrett-dev` | Angular SPA (Spa) | `mattjarrett.dev` via Cloudflare Tunnel |
| `blog` | Ghost (Deployment) | `blog.mattjarrett.dev` via Cloudflare Tunnel; 2Gi content PVC |
| `my-vinyl` | Spa + Api + Cache | `myvinyl.mattjarrett.dev` via Cloudflare Tunnel |
| `js-pollock` | Spa | `jspollock.mattjarrett.dev` via Cloudflare Tunnel |
| `sump-pump` | Api ×2 + Topic + Subscription | IoT sump pump bridge + consumer + weather-exporter |
| `launchpad` | Api | `launchpad.mattjarrett.dev` via Cloudflare Tunnel; BFF for Launchpad UI, provisions ephemeral demo sandboxes |
| `demo-certs` | cert-manager `Certificate` objects only (no workloads) | 10 long-lived `letsencrypt-prod` certs for the 5 fixed demo sandbox slots (`demo{1-5}.mattjarrett.dev` + `demo{1-5}-api.mattjarrett.dev`); `launchpad-api` copies the resulting secrets into each sandbox namespace at creation time so cert-manager skips issuance there and Let's Encrypt's 5-certs-per-exact-hostname-per-168h limit is never hit |
| `platform-connections-demo` | Api ×3 + Spa | Service mesh walkthrough at `connections.mattjarrett.dev`; two callers run one image and differ only in what they declare |
| `platform-exporter` | platform-exporter | Custom Prometheus exporter for platform metrics; scraped via `platform-exporter-servicemonitor` |
| `spire-server`, `spire-system` | SPIRE | Workload identity (SPIFFE); agent DaemonSet on all nodes |

## Internal Hostnames (`.local.lab`)

All use `local-lab-ca-issuer` (self-signed CA), TLS via Traefik `websecure` entrypoint. AdGuard Home holds the wildcard rewrite `*.local.lab → 192.168.10.100`.

- `argocd.local.lab`
- `grafana.local.lab`
- `prometheus.local.lab`
- `longhorn.local.lab`

### How clients actually resolve

**Clients on VLAN 10 query the UDR7 at `192.168.10.1`, not AdGuard directly** — confirm with `scutil --dns` on a Mac. Three consequences:

- AdGuard filters and logs nothing for those clients. `*.local.lab` still reaches them, but only because Tailscale split-DNS points `local.lab` at AdGuard separately.
- A second resolver is consulted only when the first fails to answer. A *wrong* answer — including a cached `NXDOMAIN` — is still an answer, so listing AdGuard second would never help.
- The UDR7 negative-caches for the full SOA TTL (30 minutes on Cloudflare zones) and cannot be flushed without enabling **Settings → System → Advanced → Device SSH Authentication**. It outlasts AdGuard and CoreDNS, which recover on their own. A new public hostname that anything looked up before its DNS record existed stays unreachable from the LAN until that expires.

To restore filtering without making AdGuard a hard dependency for every device, point the UDR7's own upstream resolver at AdGuard rather than changing what DHCP hands out.

## Public Hostnames
- `mattjarrett.com` — WordPress, routed via Cloudflare Tunnel
- `kentjarrett.com` — WordPress, routed via Cloudflare Tunnel
- `mattjarrett.dev` — static site, routed via Cloudflare Tunnel
- `blog.mattjarrett.dev` — Ghost blog, routed via Cloudflare Tunnel
- `myvinyl.mattjarrett.dev` — my-vinyl SPA, routed via Cloudflare Tunnel
- `jspollock.mattjarrett.dev` — js-pollock SPA, routed via Cloudflare Tunnel
- `launchpad.mattjarrett.dev` — Launchpad BFF, routed via Cloudflare Tunnel
- `connections.mattjarrett.dev` — service mesh walkthrough, routed via Cloudflare Tunnel
- `demo{1-5}.mattjarrett.dev` / `demo{1-5}-api.mattjarrett.dev` — fixed ephemeral demo sandbox slots provisioned by `launchpad-api`, not permanently bound to any one app

## Cloudflare Tunnel Operations

The `cloudflare-tunnel-token` secret has a single key, `tunnel-token` — a double-base64-encoded JSON blob with fields `a` (account ID), `t` (tunnel ID), and `s` (tunnel secret). Retrieve the IDs with:
```bash
kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.tunnel-token}' | base64 -d | base64 -d | python3 -c "import json,sys; d=json.load(sys.stdin); print('account:', d['a'], 'tunnel:', d['t'])"
```
The account ID is also visible in the Cloudflare dashboard URL (`dash.cloudflare.com/<account-id>/`).

All hostnames route to: `https://192.168.10.101:443`. WordPress hosts (`mattjarrett.com`, `kentjarrett.com`) use `noTLSVerify: false` + `originServerName: <hostname>` so cloudflared verifies the Let's Encrypt origin cert; all other hostnames use `noTLSVerify: true`. A hostname can only flip to verified after its `letsencrypt-prod` cert is issued and served by Traefik, otherwise the tunnel 502s — new hostnames must start with `noTLSVerify: true`.

**Every new public hostname requires a tunnel config update.** The API is a full replace — always fetch first, append, then PUT back.

Adding a new public hostname:
```bash
# 0. Get IDs from cluster
CREDS=$(kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.tunnel-token}' | base64 -d | base64 -d)
export ACCOUNT_ID=$(echo "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)['a'])")
export TUNNEL_ID=$(echo "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)['t'])")
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
- **Prometheus (main)**: `monitoring-kube-prometheus-prometheus`, port 9090, 30d retention, 35Gi PVC
- **Prometheus (sump-pump)**: `prometheus-sump-pump`, port 9090, 18250d retention, 2Gi PVC (`longhorn-retain`, no node pinning); scrapes sump-pump-bridge, sump-pump-consumer, weather-exporter; Grafana datasource UID `sump-pump-archive`; **PVC mounts at `prometheus-db/` subdirectory** — migration jobs must write blocks there, not to the PVC root
- **Grafana**: admin secret `grafana-admin-secret`, anonymous viewer access enabled, Loki datasource configured, dashboards loaded via sidecar from all namespaces; the kiosk playlist is managed in the Grafana UI (not provisioned from Git)
- **Loki**: StatefulSet `loki`, SingleBinary, filesystem, 5Gi PVC (`storage-loki-0`), 30d retention, compactor enabled. `argocd` is ~80% of all log volume — check it first if the PVC fills.
- **Promtail**: DaemonSet, ships logs to Loki
- **Alertmanager**: 2Gi PVC

### Resizing a StatefulSet PVC
`volumeClaimTemplates` are immutable — bumping `size:` in Git does nothing to an existing StatefulSet, and ArgoCD retries the sync until it gives up with `updates to statefulset spec ... are forbidden`. The PVC stays at its old size while the repo claims otherwise. Expand the PVC first, then recreate the StatefulSet so its template matches:
```bash
kubectl patch pvc <pvc> -n <namespace> -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'
kubectl delete sts <name> -n <namespace> --cascade=orphan   # keeps the pod and PVC alive
argocd app sync <app> --grpc-web                            # recreates the STS; it adopts the running pod
```
Skipping the recreate leaves the app permanently OutOfSync, and any future pod recreate comes back at the old size.

### Grafana Dashboards
Colors follow [Dashboard Colors](./docs/dashboard-colors.md) — green/yellow/red are reserved for health, every other value uses the blue/purple family. Read it before adding or editing a panel.

Dashboards are ConfigMaps with label `grafana_dashboard: "1"` in any namespace. Apply locally to test before committing:
```bash
kubectl apply -f cluster/monitoring/<dashboard>.yaml
```

| UID | File | Title |
|---|---|---|
| `homelab-alertmanager` | `grafana-dashboard-alertmanager.yaml` | Alertmanager — vendored from kube-prometheus-stack so it sits in the root folder instead of Less Used; new uid avoids colliding with the chart's copy |
| `argo-health-kiosk` | `grafana-dashboard-argo-health-kiosk.yaml` | ArgoCD Health Kiosk |
| `homelab-cert-manager` | `grafana-dashboard-cert-manager.yaml` | Cert Manager |
| `homelab-gitops` | `grafana-dashboard-gitops.yaml` | GitOps |
| `homelab-kiosk` | `grafana-dashboard-homelab-kiosk.yaml` | Homelab — Kiosk |
| `homelab-mbp` | `grafana-dashboard-homelab-mbp.yaml` | Homelab |
| `homelab-platform` | `grafana-dashboard-homelab-platform.yaml` | Platform |
| `launchpad-kiosk` | `grafana-dashboard-launchpad-kiosk.yaml` | Launchpad — Kiosk |
| `homelab-namespace-overview` | `grafana-dashboard-namespace-overview.yaml` | Namespace Overview |
| `orphans-kiosk` | `grafana-dashboard-orphans-kiosk.yaml` | Orphans — Kiosk |
| `homelab-orphans` | `grafana-dashboard-orphans.yaml` | Orphaned Resources |
| `homelab-pod-health` | `grafana-dashboard-pod-health.yaml` | Pod Health Breakdown |
| `homelab-pods-by-node` | `grafana-dashboard-pods-by-node.yaml` | Pods by Node |
| `service-mesh` | `grafana-dashboard-service-mesh.yaml` | Service Mesh |
| `sump-pump-kiosk` | `grafana-dashboard-sump-pump-kiosk.yaml` | Sump Pump — Kiosk |
| `sump-pump` | `grafana-dashboard-sump-pump.yaml` | Sump Pump |
| `web-traffic-kiosk` | `grafana-dashboard-web-traffic-kiosk.yaml` | Web Traffic — Kiosk |
| `web-traffic` | `grafana-dashboard-web-traffic.yaml` | Web Traffic |

**Adding a new dashboard to the kiosk playlist:**
1. Create the dashboard ConfigMap in `cluster/monitoring/` with `grafana_dashboard: "1"` label
2. Keep height at exactly 5 grid units (`"h": 5`) so it fits the 1U display
3. Use `"instant": true` on all stat panel targets — avoids heavy range queries that crash the Pi
4. Apply locally to test: `kubectl apply -f cluster/monitoring/<dashboard>.yaml`
5. Add the dashboard to the kiosk playlist in the Grafana UI at `https://grafana.local.lab/playlists` (playlist `adc6g24` — UI-managed, not provisioned from Git)

### Traefik Prometheus label quirk
Prometheus renames the `service` label from Traefik metrics to `exported_service` to avoid collision. Always use `exported_service=~"..."` in Traefik queries.

Service label format: `{namespace}-{servicename}-{port}@kubernetes`
- `blog.mattjarrett.dev` → `blog-ghost.*@kubernetes`
- `mattjarrett.dev` → `mattjarrett-dev-mattjarrett-dev.*@kubernetes` or `web-mattjarrett-dev.*@kubernetes` (both exist; use alternation `|`)
- `mattjarrett.com` → `mattjarrett-com-mattjarrett-com-wordpress.*@kubernetes`
- `myvinyl.mattjarrett.dev` → `my-vinyl-my-vinyl.*@kubernetes`
- `jspollock.mattjarrett.dev` → `js-pollock-js-pollock.*@kubernetes`

## 1U Display (ctrl-1)
`ctrl-1` runs a kiosk browser on the attached display. It is **not** managed by systemd — it's a bare background process under the `pi` user.

- Hardware: GeeekPi 6.91" 1U rack-mount LCD, native 1424×280, capacitive touch, mounted in the DeskPi RackMate
- Script: `~/kiosk.sh` on `ctrl-1`
- Current URL: `https://grafana.local.lab/playlists/play/adc6g24?kiosk`

### X server config (manual — not in Git)
The Pi 5 has two DRM devices (`card0` = v3d, `card1` = display). Without explicit config, Xorg fails with "Cannot run in framebuffer mode". A config file must exist at `/etc/X11/xorg.conf.d/99-pi5.conf` on ctrl-1:
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
If ctrl-1 is ever rebuilt, create this file before attempting to start the kiosk:
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

To update the URL without rebooting ctrl-1:
```bash
# 1. Edit the URL
ssh pi@192.168.10.100 "sed -i 's|OLD_URL|NEW_URL|' ~/kiosk.sh"

# 2. Restart the tty1 session — triggers autologin → startx → kiosk.sh (k3s is unaffected)
ssh pi@192.168.10.100 "sudo systemctl restart getty@tty1.service"
```

**Do not** just `pkill chromium` — the `while true` loop in kiosk.sh will relaunch chromium with the URL already loaded in memory, ignoring the file change. Restarting getty re-runs `.bashrc` which re-sources the updated script.

## Crossplane Platform

Crossplane core runs with `--enable-realtime-compositions` (set via Helm `args` in `cluster/argocd/crossplane.yaml`) so composite reconciliation reacts immediately to composed-resource changes via watch, instead of only on the default 60s poll interval. Without it, a composed resource (e.g. an AWS-backed `Role`/`Bucket`) going `Ready` can sit for up to a minute before its dependent secret/status propagates to the XR — this was diagnosed as multi-second dead time in Launchpad guest sandbox rollouts before the flag was added.

Nine platform types are defined under `platform/`:

| XRD | Kind | Notes |
|---|---|---|
| `wordpresses.platform.local.lab` | `Wordpress` | MariaDB StatefulSet + WordPress Deployment; credentials from XR UID |
| `spas.platform.local.lab` | `Spa` | nginx + Angular SPA; nginx config generated via go-templating function — **app repos must NOT include an nginx.conf; composition owns it entirely** |
| `apis.platform.local.lab` | `Api` | Generic REST API |
| `caches.platform.local.lab` | `Cache` | Cache for apps |
| `topics.platform.local.lab` | `Topic` | Pub/sub topic |
| `subscriptions.platform.local.lab` | `Subscription` | Consumer subscription to a topic |
| `sqls.platform.local.lab` | `Sql` | In-cluster Postgres Deployment; used by Launchpad guest demo sandboxes |
| `nosqls.platform.local.lab` | `NoSql` | AWS DynamoDB table; used by Launchpad guest demo sandboxes — kept within AWS free tier by design |
| `objectstorages.platform.local.lab` | `ObjectStorage` | AWS S3 bucket; used by Launchpad guest demo sandboxes — kept within AWS free tier by design |

Which namespaces use which XR types is listed in the Namespaces & Applications table above.

### GitOps flow for XR instances
1. Commit XR files to a top-level directory in the `homelab-workspaces` repo (e.g. `mattjarrett-com/mattjarrett-com.yaml`)
2. `xrs` ApplicationSet (`cluster/argocd/xrs-appset.yaml`) generates one ArgoCD Application per directory, deployed into a namespace named after the directory
3. ArgoCD applies the XR to the cluster
4. Crossplane reconciles and creates all composed resources

XR instance files live in `homelab-workspaces/<name>/` (one directory per workspace, e.g. `mattjarrett-com/`, `kentjarrett-com/`). Ephemeral `demo{1-5}` sandbox directories are written and deleted automatically by `launchpad-api`; all other workspace directories are hand-maintained.

### Deleting an XR instance (correct order — prevents data loss)
```bash
# 1. Delete the XR — Crossplane cascade-deletes all composed resources
kubectl delete spa <name> -n <namespace>
# or: kubectl delete wordpress <name> -n <namespace>

# 2. Remove the workspace directory from the homelab-workspaces repo and push — ArgoCD prunes the Application
git rm -r <name>/ && git commit -m "..." && git push
```
DO NOT remove the file first — that orphans resources.

### Storage classes for XR PVCs
- `longhorn-retain` — use for `dataRetention: retain` (PV survives XR deletion, data recoverable)
- `longhorn-delete` — use for `dataRetention: delete` (PV wiped on XR deletion)
- The `dataRetention` field in the WordPress XR controls which is used

### WordPress restore
Backup location: `REDACTED`
```bash
bash docs/wordpress/restore-wordpress.sh \
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
| `platform` | homelab git + `argoproj.github.io/argo-helm` + `charts.crossplane.io/stable` | ArgoCD, Crossplane, compositions, bootstrap |
| `cluster` | homelab git + `nats-io.github.io/k8s/helm/charts` + `charts.jetstack.io` + `helm.cilium.io` + `spiffe.github.io/helm-charts-hardened` | Longhorn, Traefik, cert-manager, AdGuard, Cloudflare, NATS + NACK, Cilium, SPIRE |
| `observability` | homelab git + `prometheus-community.github.io/helm-charts` + `grafana.github.io/helm-charts` | kube-prometheus-stack, Loki, Promtail, platform-exporter |
| `workloads` | homelab git + homelab-workspaces git | All workspace apps (one Application per homelab-workspaces directory) + blog; `sourceNamespaces: ["*"]` for app-in-any-namespace |

Applications from the `workloads` project can live in any namespace (`sourceNamespaces: ["*"]`).

## Key Conventions
- ArgoCD `automated: { prune: true, selfHeal: true }` on all apps — cluster converges to repo state automatically
- `ServerSideApply: true` used on most apps
- Secrets (tunnel tokens, Grafana admin creds, etc.) are pre-created manually in the cluster — never stored in Git
- Traefik annotations on all Ingresses: `traefik.ingress.kubernetes.io/router.entrypoints: websecure` and `traefik.ingress.kubernetes.io/router.tls: "true"`
- cert-manager annotation on all Ingresses: `cert-manager.io/cluster-issuer: local-lab-ca-issuer` (internal) or `letsencrypt-prod` (public) — Spa and Api expose this via the `tlsIssuer` parameter (default `local-lab-ca-issuer`); the WordPress composition hardcodes `letsencrypt-prod` since WordPress sites are always public
- Spa compositions use `gotemplating.fn.crossplane.io/ready: "True"` on go-templating resources to avoid false `Ready=False` on the XR

## Go App Conventions

All homelab Go services follow the same layout. When editing or creating a Go app:

- **Build tool: `just`, not `make`** — every Go repo has a `justfile` at the root
- **Standard recipes** (always the same across all apps):
  | Recipe | What it does |
  |---|---|
  | `just ci` | `lint → test → build` (run this before pushing) |
  | `just lint` | `go mod tidy -diff` + `golangci-lint run` |
  | `just test` | `go test -race ./...` |
  | `just build` | `go build -o <app-name> .` |
  | `just run` | `go run .` |
- **Binary name = repo name** — always pass `-o <repo-name>` to `go build`
- **Race detector always on** — `go test -race ./...`, not `go test ./...`
- **Stdlib only** — no HTTP frameworks; stdlib `net/http` + `slog`
- **Graceful shutdown** via `signal.NotifyContext`
- **/healthz route required** on every app — Kubernetes readiness probe hits `/healthz`
- **CI/CD** — every repo ships `.github/workflows/ci.yml`: a separate `test` job (`go test ./...` + `go vet ./...`), then `build-and-push` (`needs: test`, `if: main`, builds ARM64 → `ghcr.io/cujarrett/<repo>`), then `deploy` (updates the image tag in `homelab-workspaces`). Test always gates build.
- **Dependabot** — every repo ships `.github/dependabot.yml` (gomod daily, github-actions weekly). For a monorepo, one `gomod` block per module directory.
- **Per-repo `CLAUDE.md`** — standalone repos, so each carries the git rules, pre-commit safety check, and grug philosophy (Claude working in that repo won't see this file). The `/new-go-api` skill scaffolds all of the above.

Go apps in this workspace:
| Repo | Binary | Notes |
|---|---|---|
| `my-vinyl-api` | `my-vinyl-api` | REST API for my-vinyl SPA |
| `sump-pump-bridge` | `sump-pump-bridge` | IoT bridge, publishes to NATS |
| `sump-pump-consumer` | `sump-pump-consumer` | NATS consumer, exposes Prometheus metrics |
| `weather-exporter` | `weather-exporter` | Weather Prometheus exporter |
| `launchpad-api` | `launchpad-api` | BFF for Launchpad UI |

To scaffold a new Go API, use the `/new-go-api` skill (`.claude/commands/new-go-api.md`).

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
