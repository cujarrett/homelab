# Cluster

Four Raspberry Pi 5 nodes run k3s. All state lives in this repo, and ArgoCD makes the cluster match it.

## Hardware

The nodes sit in one small rack on VLAN 10 (`192.168.10.0/24`). Each boots from NVMe, runs on PoE+ and is ARM64, so every image must support ARM64.

| Node | IP | Role |
|---|---|---|
| `ctrl-1` | `192.168.10.100` | k3s server. It also runs workloads, with 6Gi reserved for the system |
| `work-1` | `192.168.10.101` | k3s agent |
| `work-2` | `192.168.10.102` | k3s agent |
| `work-3` | `192.168.10.103` | k3s agent |

SSH: `ssh pi@192.168.10.10x`.

| Part | Model | Notes |
|---|---|---|
| Gateway | Ubiquiti UDR7 | `192.168.1.1` |
| Rack | GeeekPi DeskPi RackMate T0 Plus 10" 4U | |
| Display | 1424x280 1U LCD | `ctrl-1` drives it. See [Kiosk](./kiosk/README.md) |

## Stack

Each row is one layer of the cluster and the tool that fills it.

| Layer | Tool | Notes |
|---|---|---|
| Kubernetes | k3s | |
| GitOps | ArgoCD | See [GitOps](#gitops) |
| Ingress | Traefik | A DaemonSet set up through a k3s HelmChartConfig. Binds hostPorts 80 and 443 |
| TLS | cert-manager | Issues the two Gateway certs |
| Storage | Longhorn | Four StorageClasses, listed below |
| DNS | AdGuard Home | Pinned to `ctrl-1` by nodeSelector, on hostPort 53 UDP |
| Public access | Cloudflare Tunnel | Two `cloudflared` replicas. The token is in the Secret `cloudflare-tunnel-token` |
| Platform | Crossplane | Thirteen XR types. See [Platform → Offerings](../platform/README.md#offerings) |
| CNI | flannel | k3s's bundled CNI at its defaults. No CNI install flags and no `/etc/rancher/k3s/config.yaml` |
| NetworkPolicy | kube-router | Bundled with k3s, at its defaults |
| Service mesh | Istio | Sidecars chained onto flannel, for workload mTLS |
| Metrics | kube-prometheus-stack | Prometheus, Grafana, Alertmanager. See [Monitoring](#monitoring) |
| Logs | Loki | Fed by an Alloy DaemonSet |
| Messaging | NATS JetStream | Three replicas. NACK manages Stream and Consumer CRDs |
| GraphQL | Apollo operator and router | Join each team's subgraph into one supergraph. See [Platform Graph](../platform/docs/graph.md) |
| Secrets | External Secrets Operator | Renders cluster-setup credentials from AWS SSM Parameter Store. See [External Secrets](./external-secrets.md) |
| Workload identity | SPIRE | Chart from `spiffe.github.io/helm-charts-hardened`. See [SPIRE OIDC Federation](./spire-oidc-federation.md) |
| Promotion | Kargo | Official chart, signed in with the admin account |
| Workflows | Temporal | Official chart. One Postgres StatefulSet holds both its databases |
| Vulnerability scanning | Trivy operator | Scans every workload image as `linux/arm64` for the Security dashboard |

More on some layers:

- Ingress
  - Every route is a Gateway API `HTTPRoute` on the shared `traefik-gateway` in `kube-system`.
  - The gateway serves one HTTPS listener with the certs in [cluster/traefik/certificates.yaml](../cluster/traefik/certificates.yaml).
- TLS
  - `.local.lab` hosts: the local CA issuer `local-lab-ca-issuer`.
  - Public hosts: Let's Encrypt (staging and prod) through a Cloudflare DNS-01 challenge.
  - The Gateway holds two certs, so workloads issue no certs. One covers every public host. The other is the `*.local.lab` wildcard.
  - Workload mTLS uses Istio's own CA (`istio-ca-secret`), not cert-manager.
- Service mesh
  - Platform workloads run STRICT mTLS.
  - Inbound, an `AuthorizationPolicy` allows the workload's declared `provides`.
  - Outbound, `REGISTRY_ONLY` egress allows its declared `consumes`.
  - A call passes only when both sides agree. See [Platform Connections](../platform/docs/connections.md).
  - Proxy, pilot and CNI images are distroless, so `istio-proxy` has no shell. Debug it with `kubectl debug`.
- GraphQL
  - Two installs, `apollo-operator-test` and `apollo-operator-prod`. Each has its own key and watches only its own lane.
  - Chart: `registry-1.docker.io/apollograph`.
  - Router image: `ghcr.io/cujarrett/apollo-router-arm64`. It is built from source, because the official image aborts on a 16K-page kernel.
- Secrets
  - The `ClusterSecretStore` `aws-parameter-store` signs in as the IAM user `eso-reader`, which reads only `/homelab/`.
  - `aws-eso-creds` is the only hand-created Secret.
- Workload identity
  - X.509 SVIDs: for AWS IAM Roles Anywhere.
  - JWT-SVIDs: verified with the keys published at `oidc.mattjarrett.dev`.
- Promotion
  - Warehouses poll, so the public webhook receiver is off.
  - Argo Rollouts runs only the AnalysisRuns that verify a Stage. No app deploys with Rollouts.
- Vulnerability scanning
  - Istio injects sidecars at pod creation, so `cluster/monitoring/istio-proxy-scan.yaml` gives Trivy their image.

Longhorn's StorageClasses are below. StorageClass parameters can't change in place. Delete the StorageClass and let ArgoCD recreate it. Existing volumes keep their settings.

| StorageClass | Reclaim | Use |
|---|---|---|
| `longhorn` | Delete | The default |
| `longhorn-retain` | Retain | Stateful platform XRs |
| `longhorn-delete` | Delete, two copies | Short-lived data such as Launchpad sandboxes |
| `longhorn-static` | | Longhorn creates it for pre-made volumes. Nothing here uses it |

## Namespaces

Each cluster tool runs in its own namespace. Each workspace gets one namespace too.

Cluster tools:

| Namespace | Runs | Notes |
|---|---|---|
| `argocd` | ArgoCD | At `argocd.local.lab` |
| `monitoring` | kube-prometheus-stack, prometheus-sump-pump, prometheus-cluster-availability, the blackbox and json exporters, Loki and Alloy | See [Monitoring](#monitoring) |
| `longhorn-system` | Longhorn | At `longhorn.local.lab` |
| `adguard` | AdGuard Home | |
| `cloudflare` | cloudflared | |
| `cert-manager` | cert-manager | |
| `crossplane-system` | Crossplane | Compositions, XRDs and providers |
| `istio-system` | Istio | `istiod` and the `istio-cni-node` DaemonSet |
| `nats` | NATS and NACK | |
| `external-secrets` | External Secrets Operator | Every store and `ExternalSecret` is in `cluster/external-secrets/` |
| `kyverno` | Kyverno | Admission, background, cleanup and reports controllers. Enforces workspace and namespace rules |
| `spire-server` | SPIRE | An agent DaemonSet on every node, and the OIDC discovery provider for `oidc.mattjarrett.dev`. The chart also creates `spire-system`, which stays empty |
| `apollo-operator-test`, `apollo-operator-prod` | Apollo operator | One each |
| `trivy-system` | Trivy operator | |
| `kargo` | Kargo | UI at `kargo.local.lab`. The chart also creates `kargo-system-resources` and `kargo-shared-resources` |
| `kargo-storefront` | Kargo project | Promotes storefront subgraph images from `graph-test` to `graph-prod` |
| `argo-rollouts` | Argo Rollouts controller | Runs only the AnalysisRuns Kargo creates |
| `temporal` | Temporal and `temporal-postgres` | Postgres has 5Gi on `longhorn-retain`. UI at `temporal.local.lab`, signed in through Entra |
| `temporal-controller` | temporal-controller | Creates, corrects and deletes Temporal namespaces from `TemporalNamespace` resources |
| `platform-exporter` | platform-exporter | Platform metrics, scraped through `platform-exporter-servicemonitor` |
| `reloader` | Stakater Reloader | Restarts a workload when a ConfigMap it names changes |
| `node-sysctls` | Host setting DaemonSets | Write host settings from Git, listed below |
| `node-updates` | A DaemonSet | Reports each node's unattended-upgrades state as metrics |

More on some namespaces:

- `kargo-storefront`
  - Freight reaches prod only after both schemas pass a check against prod, with the graph key in `/homelab/kargo/apollo-graph-key`.
  - Kargo creates the namespace from the `Project` in [cluster/kargo/storefront.yaml](../cluster/kargo/storefront.yaml).
- `reloader`
  - It watches only workloads annotated `reloader.stakater.com/auto`. The Api composition sets that when `configFrom` is used.
  - It ignores Secrets, because they reach apps as files that kubelet refreshes in place.

The `node-sysctls` namespace runs these DaemonSets.

| DaemonSet | Does |
|---|---|
| `node-sysctls` | Applies sysctls on every node |
| `apt-origins` | Sets the archives unattended-upgrades installs from |
| `journald` | Keeps each node's journal on disk |
| `k3s-env` | Writes a `GOMEMLIMIT` drop-in to ctrl-1's `/etc/systemd/system/k3s.service.d/`, and a 6Gi kubelet memory reservation to `/etc/rancher/k3s/config.yaml.d/`. Both take effect on the next daemon-reload and k3s restart |

Workspaces are below. Capitalised names such as Spa and Api are platform XR types.

| Namespace | Runs | Notes |
|---|---|---|
| `mattjarrett-com` | WordPress (Wordpress) | `mattjarrett.com`. 7Gi wp-content, 1Gi MariaDB |
| `kentjarrett-com` | WordPress (Wordpress) | `kentjarrett.com`. 10Gi wp-content, 2Gi MariaDB |
| `mattjarrett-dev` | Angular SPA (Spa) | `mattjarrett.dev` |
| `jerks` | Angular SPA (Spa) | `jerks.mattjarrett.dev` |
| `homelab-stats` | Api, ManagedSecret | Live homelab numbers for `mattjarrett.dev` and `jerks.mattjarrett.dev`. Each site's nginx proxies `/api/stats/` here |
| `blog` | Ghost (Deployment) | `blog.mattjarrett.dev`. 2Gi content PVC |
| `my-vinyl` | Spa, Api, Cache, ManagedSecret | `myvinyl.mattjarrett.dev` |
| `js-pollock` | Spa | `jspollock.mattjarrett.dev` |
| `sump-pump` | Api ×2, Topic, Subscription | IoT sump pump bridge and consumer |
| `weather-exporter` | Api | Rain and temperature from open-meteo, to compare with the sump pump |
| `github-exporter` | Api, ManagedSecret | Pull request, auto-merge and workflow metrics across the account's repos |
| `launchpad` | Spa, Api, ManagedSecret, WorkflowSpace | `launchpad.mattjarrett.dev`. The Spa's nginx proxies `/api/` to `launchpad-api`, an internal BFF (backend for the frontend) that provisions short-lived demo sandboxes |
| `platform-connections-demo` | Api ×3, Spa, NoSql | Service mesh walkthrough at `connections.mattjarrett.dev`. Two callers run one image and differ only in what they declare |
| `platform-graph-demo` | Api, Spa | Schema management walkthrough at `graph.mattjarrett.dev`. The backend runs fixed queries against the `graph-prod` router under a call budget. It reads GitHub every ten minutes |
| `graph-test` | GraphApi ×2, FederatedGraph | `records` and `reviews` subgraphs, one repo each (`storefront-records`, `storefront-reviews`). Composed into `storefront-homelab@test`. Router at `graph-test.local.lab` |
| `graph-prod` | GraphApi ×2, FederatedGraph | The same subgraphs at the digests Kargo promotes from test. Composed into `storefront-homelab@prod`. Router at `graph-prod.local.lab`. Only the operator in `apollo-operator-prod` publishes here, with its own key |
| `graph-pr-<subgraph>-<number>` | GraphApi, FederatedGraph | One per open PR in `storefront-records` or `storefront-reviews`. Serves every `graph-test` subgraph, with the PR's subgraph in its place. Closing the PR deletes it. See [Platform Graph → PR environments](../platform/docs/graph.md#pr-environments) |

## Networking

Public traffic comes in through Cloudflare Tunnel. Traefik terminates TLS and routes to Services.

| Traffic | Path |
|---|---|
| Public | Internet → Cloudflare → `cloudflared` → Traefik, a DaemonSet on every node → pod, in plain text on the app port (PERMISSIVE) |
| Internal | AdGuard's wildcard DNS entry sends `*.local.lab` to Traefik on `192.168.10.100` |
| Off network | A Tailscale subnet router on `ctrl-1` exposes `192.168.10.0/24`. Split DNS in the Tailscale admin console resolves `*.local.lab` through AdGuard |
| Pod to pod | flannel VXLAN across the shared VLAN, unencrypted. Istio adds mTLS in meshed namespaces |

## Hostnames

Internal names end in `.local.lab` and resolve over Tailscale. Public names route through Cloudflare Tunnel.

### Internal

Each uses `local-lab-ca-issuer` (a self-signed CA), with TLS on Traefik's `websecure` entrypoint. AdGuard Home holds the wildcard rewrite `*.local.lab → 192.168.10.100`.

`adguard`, `argocd`, `grafana`, `prometheus`, `longhorn`, `graph-test`, `graph-prod`, `my-vinyl-api`, `sump-pump-bridge`, `temporal` and `kargo`, each followed by `.local.lab`.

### How clients resolve

**Clients on VLAN 10 ask the UDR7 at `192.168.10.1` for DNS, never AdGuard directly.** Check with `scutil --dns` on a Mac.

| Effect | What happens |
|---|---|
| Filtering | AdGuard filters and logs nothing for these clients. `*.local.lab` still works, because Tailscale split DNS points `local.lab` at AdGuard |
| Second resolver | A client asks it only when the first gives no answer. A wrong answer or a cached `NXDOMAIN` still counts as an answer, so listing AdGuard second never helps |
| Negative cache | The UDR7 caches "no such name" for the full SOA TTL (30 minutes on Cloudflare zones). A public hostname looked up before its record existed stays unreachable on the LAN until then. Flushing needs **Settings → System → Advanced → Device SSH Authentication** on |

To get filtering back, point the UDR7's own upstream resolver at AdGuard. Leave what DHCP hands out unchanged, so devices don't depend on AdGuard.

### Public

All of these route through Cloudflare Tunnel. Add one with the `/add-cloudflare-tunnel-hostname` skill.

| Hostname | Serves |
|---|---|
| `mattjarrett.com` | WordPress |
| `kentjarrett.com` | WordPress |
| `mattjarrett.dev` | Static site |
| `jerks.mattjarrett.dev` | Live map of scanner requests, with `/api/stats/` proxied to `homelab-stats` |
| `blog.mattjarrett.dev` | Ghost blog |
| `myvinyl.mattjarrett.dev` | my-vinyl SPA |
| `jspollock.mattjarrett.dev` | js-pollock SPA |
| `launchpad.mattjarrett.dev` | Launchpad UI, with `/api/` proxied to the internal BFF |
| `connections.mattjarrett.dev` | Service mesh walkthrough |
| `graph.mattjarrett.dev` | Schema management walkthrough |
| `argocd-webhook.mattjarrett.dev` | GitHub push webhooks from `homelab-workspaces` for ArgoCD. Only `/api/webhook` and `/applicationset/api/webhook` route |
| `oidc.mattjarrett.dev` | SPIRE OIDC discovery and JWKS. The JWKS sits under `/.well-known/keys`, because Cloudflare's bot protection returns 403 to datacenter callers elsewhere on the zone |
| `demo{1-5}.mattjarrett.dev`, `demo{1-5}-api.mattjarrett.dev` | Demo sandbox slots that `launchpad-api` provisions. No slot belongs to one app for good |

## Monitoring

kube-prometheus-stack, Loki and Alloy run in the `monitoring` namespace.

| Component | Runs as | Retention | Storage |
|---|---|---|---|
| Prometheus (main) | `monitoring-kube-prometheus-prometheus`, port 9090 | 30d | 35Gi PVC |
| Prometheus (sump-pump) | `prometheus-sump-pump`, port 9090, no node pinning | 18250d | 2Gi PVC on `longhorn-retain` |
| Prometheus (cluster-availability) | `prometheus-cluster-availability` | 1825d | 2Gi PVC on `longhorn-retain` |
| Grafana | | | 2Gi PVC |
| Loki | StatefulSet `loki`, SingleBinary, filesystem, compactor on | 30d | 5Gi PVC (`storage-loki-0`) |
| Alloy | A DaemonSet that ships logs to `http://loki.monitoring.svc.cluster.local:3100` | | |
| Alertmanager | | | 2Gi PVC |

More on some components:

- Prometheus (sump-pump)
  - Scrapes sump-pump-bridge, sump-pump-consumer and weather-exporter.
  - Grafana datasource UID: `sump-pump-archive`.
  - **The PVC mounts at the `prometheus-db/` subdirectory.** Migration jobs must write blocks there, never to the PVC root.
- Prometheus (cluster-availability)
  - Keeps node `up`, node boot time and the internet probe.
  - Grafana datasource UID: `cluster-availability-archive`.
- Grafana
  - Admin secret: `grafana-admin-secret`. Anonymous viewer access is on.
  - The Loki datasource is set up. A sidecar loads dashboards from the `monitoring` namespace only.
- Loki
  - Streams labelled `log_type="access"` (US visitors) and `log_type="sandbox"` (sandbox launches) keep 365 days for the visitor maps.
  - Query results are cached in-process and split by day. A repeat year-long query computes only today.
  - `argocd` makes about 60% of all log volume. Check it first if the PVC fills.
- Alloy
  - Drops Traefik access log lines from non-US visitors, bots and scripts.
  - Replaces the visitor IP with a salted hash. The salt comes from `/homelab/monitoring/visitor-salt`.

### Resizing a StatefulSet PVC

A StatefulSet's `volumeClaimTemplates` can't change. Raising `size:` in Git does nothing, and ArgoCD fails with `updates to statefulset spec ... are forbidden`. Expand the PVC first, then recreate the StatefulSet so its template matches.

```bash
kubectl patch pvc <pvc> -n <namespace> -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'
kubectl delete sts <name> -n <namespace> --cascade=orphan   # keeps the pod and PVC alive
argocd app sync <app> --grpc-web                            # recreates the STS; it adopts the running pod
```

Skip the recreate and the app stays OutOfSync for good. Any later pod recreate also comes back at the old size.

### Grafana Dashboards

Each dashboard is a ConfigMap named `grafana-dashboard-*.yaml` in [cluster/monitoring/](../cluster/monitoring/). It carries the label `grafana_dashboard: "1"` and holds its own UID. List them with `ls`. Test with `kubectl apply -f` before committing.

| Rule | Detail |
|---|---|
| Colors | Follow [Dashboard Colors](../cluster/monitoring/dashboard-colors.md). Green, yellow and red mean health. Everything else uses blues and purples |
| Kiosk panel height | Exactly 5 grid units (`"h": 5`) to fit the 1U display |
| Kiosk stat targets | `"instant": true`. Range queries crash the Pi |
| Kiosk playlist | Add the dashboard to `adc6g24` in the Grafana UI. Git does not provision the playlist |

### Traefik Prometheus label quirk

Prometheus renames the `service` label on Traefik metrics to `exported_service`. Always query `exported_service=~"..."`.

Current series look like `httproute-{namespace}-{route}-gw-…-svc-{namespace}-{servicename}-{n}@kubernetesgateway`. Older ones look like `{namespace}-{servicename}-{port}@kubernetes`. Prefix patterns with `(.*-svc-)?` to match both.

| Host | Pattern |
|---|---|
| `blog.mattjarrett.dev` | `(.*-svc-)?(blog-ghost.*)` |
| `mattjarrett.dev` | `(.*-svc-)?(mattjarrett-dev-mattjarrett-dev.*\|web-mattjarrett-dev.*)` (both exist) |
| `jerks.mattjarrett.dev` | `(.*-svc-)?(mattjarrett-dev-jerks.*\|jerks-jerks.*)` |
| `mattjarrett.com` | `(.*-svc-)?(mattjarrett-com-mattjarrett-com-wordpress.*)` |
| `myvinyl.mattjarrett.dev` | `(.*-svc-)?(my-vinyl-my-vinyl.*)` |
| `jspollock.mattjarrett.dev` | `(.*-svc-)?(js-pollock-js-pollock.*)` |

## GitOps

ArgoCD applies this repo as an app-of-apps. The root Application, `cluster/argocd/bootstrap.yaml`, applies every Application in `cluster/argocd/`. The `cluster-apps` ApplicationSet adds one Application per plain directory under `cluster/`.

- Every app uses `automated: { prune: true, selfHeal: true }`, so the cluster follows each push.
- Most apps use `ServerSideApply: true`.
- Cluster-setup Secrets come from AWS Parameter Store and never sit in Git. See [External Secrets](./external-secrets.md).

### AppProjects

Five projects group the Applications. Each limits which source repos its apps may use.

| Project | Allowed source repos | Contents |
|---|---|---|
| `platform` | homelab git, `argoproj.github.io/argo-helm`, `charts.crossplane.io/stable` | ArgoCD, Crossplane, compositions, bootstrap |
| `cluster` | homelab git, `nats-io.github.io/k8s/helm/charts`, `charts.jetstack.io`, `spiffe.github.io/helm-charts-hardened`, `charts.external-secrets.io`, `istio-release.storage.googleapis.com/charts`, `kyverno.github.io/kyverno`, `stakater.github.io/stakater-charts`, `charts.longhorn.io`, `registry-1.docker.io/apollograph`, `go.temporal.io/helm-charts`, `ghcr.io/akuity/kargo-charts`, `argoproj.github.io/argo-helm` | Longhorn, Traefik, cert-manager, AdGuard, Cloudflare, NATS and NACK, SPIRE, Istio, Kyverno, External Secrets, Reloader, Apollo operator, Temporal, temporal-controller, Kargo, Argo Rollouts, node-sysctls, node-updates, the blog |
| `observability` | homelab git, `prometheus-community.github.io/helm-charts`, `grafana.github.io/helm-charts`, `aquasecurity.github.io/helm-charts` | kube-prometheus-stack, Loki, Alloy, platform-exporter, Trivy operator, blackbox and json exporters |
| `workloads` | homelab-workspaces git | Every workspace app, one Application per homelab-workspaces directory |
| `graph-pr` | homelab git | One environment per open subgraph PR, made by the `graph-pr` ApplicationSet from [pr-chart](../platform/federated-graph/pr-chart/). Deploys only to `graph-pr-*` |

## Related Docs

| Doc | What it holds |
|---|---|
| [How I built it](https://blog.mattjarrett.dev/homelab/) | The build, step by step, from bare Pi to this state |
| [Platform](../platform/README.md) | The Crossplane-based internal developer platform |
| [Nothing Novel](./nothing-novel.md) | The public prior art behind every mechanism here |
