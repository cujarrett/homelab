# Cluster

Four Raspberry Pi 5 nodes running k3s. All state is in this repo. ArgoCD drives the cluster to match it.

Start with [Stack](#stack) for what runs, then [Namespaces](#namespaces) for where it runs.

| Chapter | What it covers |
|---|---|
| [Hardware](#hardware) | The four nodes, their IPs and the rack |
| [Kiosk Display](#kiosk-display) | The 1U screen that `ctrl-1` drives |
| [Stack](#stack) | Each layer of the cluster and the tool that fills it |
| [Namespaces](#namespaces) | Every namespace and the apps in it |
| [Networking](#networking) | How traffic gets in and moves between pods |
| [Hostnames](#hostnames) | Internal and public names, and how clients resolve them |
| [Monitoring](#monitoring) | Prometheus, Grafana, Loki and Alloy settings, and the dashboard rules |
| [GitOps](#gitops) | How ArgoCD applies this repo, and the four AppProjects |
| [Related Docs](#related-docs) | Where to read next |

---

## Hardware

Four Raspberry Pi 5 nodes sit in one small rack on their own VLAN.

- **All nodes:** Raspberry Pi 5, NVMe SSD boot, PoE+ power, ARM64. Always use ARM64-compatible images.
- **Rack:** GeeekPi DeskPi RackMate T0 Plus 10" 4U, with a 1U LCD driven by `ctrl-1`.
- **Network:** VLAN 10 (`192.168.10.0/24`) is the k3s subnet. The gateway is a Ubiquiti UDR7 at `192.168.1.1`.

| Node | Hostname | IP | Role |
|---|---|---|---|
| Raspberry Pi 5 #1 | `ctrl-1` | `192.168.10.100` | k3s server (control plane) |
| Raspberry Pi 5 #2 | `work-1` | `192.168.10.101` | k3s agent |
| Raspberry Pi 5 #3 | `work-2` | `192.168.10.102` | k3s agent |
| Raspberry Pi 5 #4 | `work-3` | `192.168.10.103` | k3s agent |

SSH access: `ssh pi@192.168.10.10x`

---

## Kiosk Display

`ctrl-1` drives an attached 1424x280 LCD with a kiosk browser. [Kiosk](./kiosk/README.md) has the script, the setup a rebuilt `ctrl-1` needs, and how to change the URL.

---

## Stack

Each row is one layer of the cluster and the tool that fills it.

| Layer | Tool | Notes |
|---|---|---|
| Kubernetes | k3s | Lightweight distro |
| GitOps | ArgoCD | App-of-apps. `cluster/argocd/bootstrap.yaml` applies every Application in `cluster/argocd/`. The `cluster-apps` ApplicationSet adds one Application per plain directory under `cluster/` |
| Ingress | Traefik | A DaemonSet, deployed through a k3s HelmChartConfig. Binds hostPorts 80 and 443. Every route is a Gateway API `HTTPRoute` on the shared `traefik-gateway` in `kube-system`. That gateway serves one HTTPS listener with the certs in [cluster/traefik/certificates.yaml](../cluster/traefik/certificates.yaml) |
| TLS | cert-manager | `.local.lab` hosts use the local CA issuer (`local-lab-ca-issuer`). Public hosts use Let's Encrypt (staging and prod) through a Cloudflare DNS-01 challenge. The Gateway holds one wildcard cert per zone, so workloads issue no certs. Workload mTLS uses Istio's own CA (`istio-ca-secret`), and cert-manager plays no part in it |
| Storage | Longhorn | Three StorageClasses: `longhorn` (default, Delete), `longhorn-retain` (Retain, for stateful platform XRs) and `longhorn-delete` (explicit Delete) |
| DNS | AdGuard Home | Runs in the `adguard` namespace, pinned to `ctrl-1` by nodeSelector. Uses hostPort 53 UDP |
| External Access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in the `cloudflare` namespace. Token from the secret `cloudflare-tunnel-token` |
| Platform Abstraction | Crossplane | Thirteen XR types. See [Platform → Offerings](../platform/README.md#offerings) |
| CNI | flannel | k3s's bundled CNI at its defaults, with no install flags and no `/etc/rancher/k3s/config.yaml`. k3s's kube-router enforces NetworkPolicy, also at its defaults. Istio handles mesh concerns such as mTLS and connection policy |
| Service Mesh | Istio | Sidecar mesh chained onto flannel, giving workload mTLS. Platform workloads get STRICT mTLS. Inbound, an `AuthorizationPolicy` allows their declared `provides`. Outbound, `REGISTRY_ONLY` egress allows their declared `consumes`. A call passes only when both sides agree. See [Platform Connections](../platform/docs/connections.md). The proxy, pilot and CNI images are the distroless variant, so `istio-proxy` has no shell. Debug it with `kubectl debug` |
| Observability | kube-prometheus-stack | Prometheus (30d retention), Grafana, Alertmanager |
| Logs | Loki + Alloy | Loki in SingleBinary mode with 30d retention. An Alloy DaemonSet ships logs |
| Messaging | NATS JetStream | 3-replica cluster in `nats`. The NACK controller manages Stream and Consumer CRDs |
| GraphQL | Apollo operator + router | Two installs, `apollo-operator-test` and `apollo-operator-prod`. Each has its own key and watches only its own lane. Helm chart from `registry-1.docker.io/apollograph`. Joins each team's subgraph into one supergraph. See [Platform Graph](../platform/docs/graph.md). The router image is `ghcr.io/cujarrett/apollo-router-arm64`, rebuilt from source because the official image aborts on a 16K-page kernel |
| Secrets | External Secrets Operator | Renders cluster-setup credentials from AWS SSM Parameter Store. The `ClusterSecretStore` `aws-parameter-store` signs in as the `eso-reader` IAM user, which can only read the `/homelab/` path. `aws-eso-creds` is the only hand-created Secret |
| Workload Identity | SPIRE | `spire-server` and `spire-system` namespaces. Helm chart from `spiffe.github.io/helm-charts-hardened`. Issues X.509 SVIDs for AWS IAM Roles Anywhere, and JWT-SVIDs that the OIDC discovery provider publishes at `oidc.mattjarrett.dev` |
| Promotion | Kargo | Promotes artifacts between stages. Official Helm chart, signed in with the admin account. Warehouses poll, so the public webhook receiver is off. Argo Rollouts runs only the AnalysisRuns that verify a Stage. No app deploys with Rollouts |
| Workflows | Temporal | Server and UI from the official Helm chart, with one Postgres StatefulSet holding both of its databases. `temporal-controller` creates each Temporal namespace from a `TemporalNamespace` resource |
| Vulnerability Scanning | Trivy operator | Scans every workload image for CVEs as `linux/arm64` and feeds the Security dashboard. Istio sidecars are injected at pod creation, so `cluster/monitoring/istio-proxy-scan.yaml` gives Trivy their image to scan |

---

## Namespaces

Each row is one namespace and the apps that run in it.

| Namespace | App | Notes |
|---|---|---|
| `argocd` | ArgoCD | Ingress at `argocd.local.lab` |
| `monitoring` | kube-prometheus-stack | Prometheus (30d retention, 35Gi), Grafana (2Gi), Alertmanager (2Gi) |
| `monitoring` | prometheus-sump-pump | Long-term Prometheus for sump pump and weather data. 18250d retention, 2Gi PVC on `longhorn-retain`, no node pinning. Grafana datasource UID `sump-pump-archive` |
| `monitoring` | Loki | SingleBinary mode, filesystem storage, 5Gi PVC. 30d retention, or 365d for the visitor and sandbox `log_type` streams |
| `monitoring` | Alloy | DaemonSet that ships logs to Loki at `http://loki.monitoring.svc.cluster.local:3100` |
| `longhorn-system` | Longhorn | Ingress at `longhorn.local.lab` |
| `adguard` | AdGuard Home | DNS ad-blocking and resolver |
| `cloudflare` | cloudflared | Cloudflare Tunnel for public ingress |
| `cert-manager` | cert-manager | TLS issuers |
| `crossplane-system` | Crossplane | Platform compositions, XRDs and providers |
| `istio-system` | Istio | Control plane (`istiod`) and the `istio-cni-node` DaemonSet for the sidecar mesh |
| `nats` | NATS + NACK | JetStream cluster (3 replicas) and the NACK controller for Stream and Consumer CRDs |
| `mattjarrett-com` | WordPress (Wordpress) | `mattjarrett.com` through Cloudflare Tunnel. 7Gi wp-content, 1Gi MariaDB |
| `kentjarrett-com` | WordPress (Wordpress) | `kentjarrett.com` through Cloudflare Tunnel. 10Gi wp-content, 2Gi MariaDB |
| `mattjarrett-dev` | Angular SPA (Spa) + Api | `mattjarrett.dev` through Cloudflare Tunnel. The Spa's nginx proxies `/api/stats/` to `homelab-stats`, which serves the live homelab section |
| `blog` | Ghost (Deployment) | `blog.mattjarrett.dev` through Cloudflare Tunnel. 2Gi content PVC |
| `my-vinyl` | Spa + Api + Cache | `myvinyl.mattjarrett.dev` through Cloudflare Tunnel |
| `js-pollock` | Spa | `jspollock.mattjarrett.dev` through Cloudflare Tunnel |
| `sump-pump` | Api ×2 + Topic + Subscription | IoT sump pump bridge, consumer and weather-exporter |
| `launchpad` | Spa + Api | `launchpad.mattjarrett.dev` through Cloudflare Tunnel. The Spa's nginx proxies `/api/` to `launchpad-api`. That is a cluster-internal BFF (backend for the frontend) that provisions short-lived demo sandboxes. |
| `platform-connections-demo` | Api ×3 + Spa | Service mesh walkthrough at `connections.mattjarrett.dev`. Two callers run one image and differ only in what they declare |
| `platform-graph-demo` | Api + Spa | Schema management walkthrough at `graph.mattjarrett.dev`. The backend runs fixed queries against the `graph-prod` router under a call budget. It reads GitHub every ten minutes |
| `platform-exporter` | platform-exporter | Custom Prometheus exporter for platform metrics, scraped through `platform-exporter-servicemonitor` |
| `external-secrets` | External Secrets Operator | Renders cluster-setup Secrets from Parameter Store. Every store and `ExternalSecret` is in `cluster/external-secrets/` |
| `kyverno` | Kyverno | Admission, background and reports controllers. The policy engine that enforces workspace and namespace rules |
| `github-exporter` | github-exporter | Prometheus exporter for pull request, auto-merge and workflow metrics across the account's repos |
| `reloader` | Stakater Reloader | Restarts a workload when a ConfigMap it names changes. It watches only workloads annotated `reloader.stakater.com/auto`. The Api composition sets that annotation whenever `configFrom` is used. Secrets are ignored, because they reach apps as files that kubelet refreshes in place |
| `graph-test` | GraphApi ×2 + FederatedGraph | `records` and `reviews` subgraphs, one repo each (`storefront-records`, `storefront-reviews`). Composed into `storefront-homelab@test`. Router at `graph-test.local.lab` |
| `graph-prod` | GraphApi ×2 + FederatedGraph | `records` and `reviews` subgraphs at the digests Kargo promotes from test. Composed into `storefront-homelab@prod`. Router at `graph-prod.local.lab`. Only the prod operator in `apollo-operator-prod` publishes here, with its own key |
| `node-sysctls` | node-sysctls, k3s-env | DaemonSets that write host settings from Git. `node-sysctls` applies sysctls on every node. `k3s-env` writes a `GOMEMLIMIT` drop-in to ctrl-1's `/etc/systemd/system/k3s.service.d/`. It takes effect on the next daemon-reload and k3s restart |
| `spire-server`, `spire-system` | SPIRE | Workload identity (SPIFFE). Agent DaemonSet on all nodes. OIDC discovery provider serving `oidc.mattjarrett.dev` |
| `trivy-system` | Trivy operator | Image CVE scans for the Security dashboard |
| `kargo` | Kargo | API, controller, management controller and webhooks server. UI at `kargo.local.lab`. The chart also creates `kargo-system-resources` and `kargo-shared-resources` |
| `kargo-storefront` | Kargo project | Promotes the storefront subgraph images from `graph-test` to `graph-prod`. Freight reaches prod only after both schemas pass a check against prod, using the graph key in `/homelab/kargo/apollo-graph-key`. Kargo creates the namespace from the `Project` in [cluster/kargo/storefront.yaml](../cluster/kargo/storefront.yaml) |
| `argo-rollouts` | Argo Rollouts | Controller only. Runs the AnalysisRuns Kargo creates for verification |
| `temporal` | Temporal | Frontend, history, matching, worker and UI, plus `temporal-postgres` (5Gi on `longhorn-retain`). UI at `temporal.local.lab`, signed in through Entra |
| `temporal-controller` | temporal-controller | Kubebuilder controller that creates, corrects and deletes Temporal namespaces from `TemporalNamespace` resources |

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

Internal names end in `.local.lab` and resolve on the LAN or over Tailscale. Public names route through Cloudflare Tunnel.

### Internal

All use `local-lab-ca-issuer` (a self-signed CA), with TLS on Traefik's `websecure` entrypoint. AdGuard Home holds the wildcard rewrite `*.local.lab → 192.168.10.100`.

- `adguard.local.lab`
- `argocd.local.lab`
- `grafana.local.lab`
- `prometheus.local.lab`
- `longhorn.local.lab`
- `graph-test.local.lab`
- `graph-prod.local.lab`
- `my-vinyl-api.local.lab`
- `sump-pump-bridge.local.lab`
- `temporal.local.lab`
- `kargo.local.lab`

### How clients resolve

**Clients on VLAN 10 ask the UDR7 at `192.168.10.1` for DNS. They never ask AdGuard directly.** Check with `scutil --dns` on a Mac. This has three effects:

- AdGuard filters and logs nothing for those clients. `*.local.lab` still reaches them, because Tailscale split DNS points `local.lab` at AdGuard separately.
- A client asks a second resolver only when the first gives no answer. A wrong answer is still an answer, and so is a cached `NXDOMAIN`. Listing AdGuard second would never help.
- The UDR7 caches a "no such name" answer for the full SOA TTL (30 minutes on Cloudflare zones). Flushing it needs **Settings → System → Advanced → Device SSH Authentication** turned on. AdGuard and CoreDNS recover on their own, but the UDR7 cache lasts longer. If anything looked up a new public hostname before its DNS record existed, the LAN can't reach it until that cache expires.

To get filtering back without making every device depend on AdGuard, point the UDR7's own upstream resolver at AdGuard. Leave what DHCP hands out unchanged.

### Public

All of these route through Cloudflare Tunnel.

- `mattjarrett.com`: WordPress
- `kentjarrett.com`: WordPress
- `mattjarrett.dev`: static site
- `blog.mattjarrett.dev`: Ghost blog
- `myvinyl.mattjarrett.dev`: my-vinyl SPA
- `jspollock.mattjarrett.dev`: js-pollock SPA
- `launchpad.mattjarrett.dev`: Launchpad UI, with `/api/` proxied to the cluster-internal BFF
- `connections.mattjarrett.dev`: service mesh walkthrough
- `graph.mattjarrett.dev`: schema management walkthrough
- `argocd-webhook.mattjarrett.dev`: GitHub push webhooks from `homelab-workspaces` for ArgoCD. Only the exact paths `/api/webhook` and `/applicationset/api/webhook` route.
- `oidc.mattjarrett.dev`: SPIRE OIDC discovery document and JWKS. The JWKS is served under `/.well-known/keys`, because Cloudflare's bot protection returns 403 to datacenter callers elsewhere on the zone.
- `demo{1-5}.mattjarrett.dev` and `demo{1-5}-api.mattjarrett.dev`: fixed demo sandbox slots that `launchpad-api` provisions. No slot belongs to one app for good.

Add one with the `/add-cloudflare-tunnel-hostname` skill.

---

## Monitoring

kube-prometheus-stack, Loki and Alloy run in the `monitoring` namespace.

- **Prometheus (main):** `monitoring-kube-prometheus-prometheus`, port 9090, 30d retention, 35Gi PVC.
- **Prometheus (sump-pump):** `prometheus-sump-pump`, port 9090, 18250d retention, 2Gi PVC on `longhorn-retain`, no node pinning.
  - Scrapes sump-pump-bridge, sump-pump-consumer and weather-exporter.
  - Grafana datasource UID is `sump-pump-archive`.
  - **The PVC mounts at the `prometheus-db/` subdirectory.** Migration jobs must write blocks there, and never to the PVC root.
- **Grafana:**
  - Admin secret is `grafana-admin-secret`. Anonymous viewer access is on.
  - The Loki datasource is configured. A sidecar loads dashboards from the `monitoring` namespace only.
  - The kiosk playlist lives in the Grafana UI. Git does not provision it.
- **Loki:** StatefulSet `loki`, SingleBinary, filesystem, 5Gi PVC (`storage-loki-0`), 30d retention, compactor on.
  - Streams labelled `log_type="access"` (US visitors) and `log_type="sandbox"` (sandbox launches) are kept 365 days for the visitor maps.
  - Query results are cached in-process and split by day. A repeat year-long query only computes today.
  - `argocd` makes about 80% of all log volume. Check it first if the PVC fills.
- **Alloy:** DaemonSet that ships logs to Loki.
  - Drops every Traefik access log line that isn't from a US visitor, or that comes from a bot or script.
  - Replaces the visitor IP with a salted hash. The salt comes from `/homelab/monitoring/visitor-salt`.
- **Alertmanager:** 2Gi PVC.

### Resizing a StatefulSet PVC
`volumeClaimTemplates` can't change. Bumping `size:` in Git does nothing to an existing StatefulSet. ArgoCD retries the sync until it gives up with `updates to statefulset spec ... are forbidden`. The PVC stays at its old size while the repo shows the new one. Expand the PVC first, then recreate the StatefulSet so its template matches:
```bash
kubectl patch pvc <pvc> -n <namespace> -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'
kubectl delete sts <name> -n <namespace> --cascade=orphan   # keeps the pod and PVC alive
argocd app sync <app> --grpc-web                            # recreates the STS; it adopts the running pod
```
If you skip the recreate, the app stays OutOfSync for good. Any later pod recreate also comes back at the old size.

### Grafana Dashboards
Colors follow [Dashboard Colors](../cluster/monitoring/dashboard-colors.md). Green, yellow and red are reserved for health. Every other value uses the blue and purple family. Read it before adding or editing a panel.

Each dashboard is a ConfigMap in [cluster/monitoring/](../cluster/monitoring/) named `grafana-dashboard-*.yaml`. It is labelled `grafana_dashboard: "1"` and holds its UID inside the file. List them with `ls`, because this file keeps no index of them. Test with `kubectl apply -f` before committing.

For the kiosk playlist:
- Panel height must be exactly 5 grid units (`"h": 5`) to fit the 1U display.
- Stat panel targets need `"instant": true`. Range queries crash the Pi.
- Add the dashboard to playlist `adc6g24` in the Grafana UI. Git does not provision the playlist.

### Traefik Prometheus label quirk
Prometheus renames the `service` label on Traefik metrics to `exported_service`, to avoid a clash. Always use `exported_service=~"..."` in Traefik queries.

Current series name the service like this: `httproute-{namespace}-{route}-gw-…-svc-{namespace}-{servicename}-{n}@kubernetesgateway`. Older series use `{namespace}-{servicename}-{port}@kubernetes`. Prefix patterns with `(.*-svc-)?` to match both.
- `blog.mattjarrett.dev` → `(.*-svc-)?(blog-ghost.*)`
- `mattjarrett.dev` → `(.*-svc-)?(mattjarrett-dev-mattjarrett-dev.*|web-mattjarrett-dev.*)` (both exist)
- `mattjarrett.com` → `(.*-svc-)?(mattjarrett-com-mattjarrett-com-wordpress.*)`
- `myvinyl.mattjarrett.dev` → `(.*-svc-)?(my-vinyl-my-vinyl.*)`
- `jspollock.mattjarrett.dev` → `(.*-svc-)?(js-pollock-js-pollock.*)`

---

## GitOps

ArgoCD uses an app-of-apps pattern. `cluster/argocd/bootstrap.yaml` is the root Application. It recurses `cluster/` and creates Applications for everything defined there.

All apps use `automated: { prune: true, selfHeal: true }`. The cluster converges to repo state on every push. Most apps use `ServerSideApply: true`.

Cluster-setup Secrets (tunnel tokens, admin credentials) are rendered from AWS Parameter Store and never stored in Git. See [External Secrets](./external-secrets.md).

### AppProjects

Four projects group workloads by concern:
| Project | Allowed source repos | Contents |
|---|---|---|
| `platform` | homelab git + `argoproj.github.io/argo-helm` + `charts.crossplane.io/stable` | ArgoCD, Crossplane, compositions, bootstrap |
| `cluster` | homelab git + `nats-io.github.io/k8s/helm/charts` + `charts.jetstack.io` + `spiffe.github.io/helm-charts-hardened` + `registry-1.docker.io/apollograph` + `go.temporal.io/helm-charts` + `ghcr.io/akuity/kargo-charts` + `argoproj.github.io/argo-helm` | Longhorn, Traefik, cert-manager, AdGuard, Cloudflare, NATS + NACK, SPIRE, Apollo operator, Temporal, temporal-controller, Kargo, Argo Rollouts |
| `observability` | homelab git + `prometheus-community.github.io/helm-charts` + `grafana.github.io/helm-charts` | kube-prometheus-stack, Loki, Alloy, platform-exporter |
| `workloads` | homelab git + homelab-workspaces git | All workspace apps (one Application per homelab-workspaces directory) + blog |

---

## Related Docs

- [How I built it](https://blog.mattjarrett.dev/homelab/): step-by-step build history from bare Pi to this state
- [Platform](../platform/README.md): Crossplane-based internal developer platform
- [Nothing Novel](./nothing-novel.md): the public prior art behind every mechanism here
