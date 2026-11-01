# Homelab Cluster Context

## Rules

- **Never run `git add`, `git commit`, `git push`, or any git command that writes to the index, history or remotes.** Output the commands for the user to run. Staging is part of their review. Running it for them removes that checkpoint.
- **Never add a `Co-Authored-By` trailer or a "Generated with Claude Code" line** to commit messages or PR descriptions. That includes suggested commit messages. The user alone authors commits.
- **Always give a suggested commit message** when a task needs a commit.
- **Give `git add` and the commit as two separate steps.**
  - List every file by name. Never `git add .`, `git add -A`, or a bare directory.
  - Group related files onto one `git add` line.
  - Give one `git add` and one commit message per repo. Put each repo under its own heading when more than one changed.
  - Start with a `cd` to the repo's absolute path, so the commands work when pasted from anywhere.
- **Never output a `git push` command.** The user pushes as a deliberate step.
- **`storefront-records` and `storefront-reviews` need a PR to main.** Start their commands with `git checkout -b <branch>`.
- **Read a sibling repo's `AGENTS.md` before editing that repo.**
- **Never end a YAML comment with `:`.** Editors read a trailing colon as a key and mis-colour the rest of the block. Reword it, such as `# depends on host, a .local.lab host means...`. A colon mid-line is fine, such as `# curl: raw curl without browser UA`.
- **Use `k` in commands shown in chat.** Doc files use `kubectl`.
- **Run `kubectl` and `k` directly in the terminal.** The local machine has Tailscale and a kubeconfig. Never wrap them in `ssh pi@...`.
- **When debugging, list every command as you run it.** Show the command, what it does, and why. The user is learning the workflow. Write each one inline at the moment you run it.
- **After changing XRDs or Compositions, remind the user to sync `platform-definitions`** with `argocd app sync platform-definitions --grpc-web`.
- **Use `foo`, `bar` or `baz` as placeholder names in platform READMEs and XRD examples.** Never put a real instance name, such as `nms-events` or `mattjarrett-com`, in `platform/*/README.md` or in `platform/*/xrd.yaml` description fields.
- **Write every table row and list item in full.** Never write "Same as above", "Same as XFoo pattern" or "See above". Each row stands on its own.
- **Platform READMEs and XRD descriptions say what the platform does, never how.**
  - XRD `description` fields name no infrastructure technology, such as "NATS", "Redis", "S3" or "NACK".
  - README prose names no internal resource, namespace or controller, such as "managed by NACK" or `kubectl get consumer -n nats`.
  - User-facing descriptions leave out internal naming rules, such as "uppercased to become the stream name".
  - Exception: document env var names injected into containers. App code must read them.
  - Exception: document wildcard syntax a parameter needs. Dev teams need it to set the value correctly.
  - The composition is the platform team's implementation file. Details are fine there.

### Pre-commit safety check

Before telling the user to commit, run `/security-review`. It checks the pending changes on the current branch for security issues. Once it says the changes are safe, offer a suggested commit message. Never run `git commit` yourself.

**Report length grows with risk. This overrides the skill's own output format.**

- **Clean:** one line, `Clean. No findings.` Say nothing about what was scanned, which checks passed, or why the change is low risk.
- **Anything real:** spend the words. For each finding, give the file and line, what an attacker does with it, and the fix. One concrete exploit walkthrough beats a list of categories.
- **Uncertain:** say in one sentence what would settle it.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." ([grugbrain.dev](https://grugbrain.dev/))

- **Say no.** "No" is the best weapon against complexity. Add no feature or abstraction until it earns its place.
- **Cheapest rung that works.** Before writing code, go down this ladder and stop at the first rung that solves it: skip the feature, reuse code already here, standard library, native platform feature, a dependency already installed, one line, then build the minimum.
- **Wait for a pattern to repeat three times before abstracting.** Let cut points show up in the code. Don't invent them up front.
- **80/20 solutions.** Ship 80% of the value with 20% of the code. Ugly code that works beats elegant code that is over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it. If you can't see the use, go away and think.
- **Boring, obvious code wins.** Well-named intermediate variables beat clever one-liners. They are easier to debug.
- **DRY is not a law.** A little copy-paste beats a complex abstraction built for two cases.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so. That is a signal to simplify.
- **Comments are grug too.** Two or three lines. Say why the value is what it is, or what breaks if you change it. Never restate what the code does. Cut percentile tables, rejected alternatives, and the history of how you got there.
- **Write comments as lines.** One fact per line. More than two facts become a list. Key each line by the case it covers (`Port 9500: ...`), so readers find theirs without reading the rest. Three or more flowing sentences is a defect, however accurate.

## Writing

Prose is hard for this repo's owner to read. Write **plain language** in chat replies, docs, code comments, commit messages, and UI copy in the app repos.

- **One idea per sentence.** Keep most sentences under 15 words.
- **Everyday words.** Say what a technical term means the first time it appears.
- **Who does what.** Name the actor and use active voice.
- **Lists for two or more facts.** One short line per item, starting with the thing it is about.
- **State facts directly.** A slogan ("One boundary, not two"), a "not X, Y" contrast or jargon ("thrash", "blast radius") becomes a plain statement. "Hand-made objects on this map: one, the commit" becomes "The commit is the only thing on this map a person wrote by hand."
- **Full stops, commas and brackets.** Never a spaced hyphen (` - `) doing a dash's job.

## Documentation

Applies to every `.md` file in this repo, on top of the [Writing](#writing) rules.

- **Grug first, then depth.** Every section opens with one or two plain sentences before any table, diagram, or YAML. If a reader stops after the first line, they should still have the idea.
- **Concise > long.** One representation per idea. Never a diagram that repeats the prose, or a table that repeats the diagram.
- **One numbering scheme per doc.** If steps or phases are numbered, nothing else is. Chapters are flat `#` headings with plain titles, such as "Storage".
- **Flat hierarchy.** No wrapper heading whose only content is other headings. If a chapter holds ten things, those ten things are the chapters.
- **Every chapter does one job.** A chapter titled "where we are today" must not contain timeless explanation. Move it.
- **No meta-content.** Never document what changed from an earlier draft, critique a previous plan, or narrate the doc's own history. Same principle as the code-comment rule: state current rationale only.
- **No time-bound content.** No "tonight", "this session", "first night", no timeboxes. Say "Phases 0, 1 and 6 touch no cluster". Docs outlive the session that wrote them.
- **Index at the top** for any doc with more than three chapters: one "start here" line, then a table of every chapter. Verify every anchor resolves before finishing.
- **Link to real paths**, such as `[Api](../platform/api/)`.
- **Cross-doc links use the human title and a `./` relative path**, such as `[Platform Connections](./platform/docs/connections.md)`. The reader sees what the doc is. Deep links keep the title too: `[Platform Connections → Known limits](./platform/docs/connections.md#known-limits)`.
- **Never link to a doc under `local-only/`.** It is gitignored, so the link is dead for every reader but you.

## Overview
A 4-node k3s Kubernetes homelab, managed entirely through GitOps with ArgoCD.
Every workload is a manifest under `cluster/` or `platform/` in this repo, or in the `homelab-workspaces` repo.
GitHub repo: `https://github.com/cujarrett/homelab.git` (branch `main`).

## Hardware & Network
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

## Remote Access (Tailscale)
- `ctrl-1` runs a Tailscale subnet router that advertises `192.168.10.0/24`.
- Tailscale admin has split DNS: `local.lab` → `192.168.10.100` (AdGuard).
- This lets `kubectl`, SSH and `*.local.lab` work from any network.

## Cluster Stack
| Layer | Tool | Notes |
|---|---|---|
| Kubernetes | k3s | Lightweight distro |
| GitOps | ArgoCD | App-of-apps. `cluster/argocd/bootstrap.yaml` applies every Application in `cluster/argocd/`. The `cluster-apps` ApplicationSet adds one Application per plain directory under `cluster/` |
| Ingress | Traefik | A DaemonSet, deployed through a k3s HelmChartConfig. Binds hostPorts 80 and 443. Every route is a Gateway API `HTTPRoute` on the shared `traefik-gateway` in `kube-system`. That gateway serves one HTTPS listener with the certs in [cluster/traefik/certificates.yaml](./cluster/traefik/certificates.yaml) |
| TLS | cert-manager | `.local.lab` hosts use the local CA issuer (`local-lab-ca-issuer`). Public hosts use Let's Encrypt (staging and prod) through a Cloudflare DNS-01 challenge. The Gateway holds one wildcard cert per zone, so workloads issue no certs. Workload mTLS uses Istio's own CA (`istio-ca-secret`), and cert-manager plays no part in it |
| Storage | Longhorn | Three StorageClasses: `longhorn` (default, Delete), `longhorn-retain` (Retain, for stateful platform XRs) and `longhorn-delete` (explicit Delete) |
| DNS | AdGuard Home | Runs in the `adguard` namespace, pinned to `ctrl-1` by nodeSelector. Uses hostPort 53 UDP |
| External Access | Cloudflare Tunnel (`cloudflared`) | 2 replicas in the `cloudflare` namespace. Token from the secret `cloudflare-tunnel-token` |
| Platform Abstraction | Crossplane | Twelve XR types. See [Crossplane Platform](#crossplane-platform) |
| CNI | flannel | k3s's bundled CNI at its defaults, with no install flags and no `/etc/rancher/k3s/config.yaml`. k3s's kube-router enforces NetworkPolicy, also at its defaults. Istio handles mesh concerns such as mTLS and connection policy |
| Service Mesh | Istio | Sidecar mesh chained onto flannel, giving workload mTLS. Platform workloads get STRICT mTLS. Inbound, an `AuthorizationPolicy` allows their declared `provides`. Outbound, `REGISTRY_ONLY` egress allows their declared `consumes`. A call passes only when both sides agree. See [Platform Connections](./platform/docs/connections.md). The proxy, pilot and CNI images are the distroless variant, so `istio-proxy` has no shell. Debug it with `kubectl debug` |
| Observability | kube-prometheus-stack | Prometheus (30d retention), Grafana, Alertmanager |
| Logs | Loki + Alloy | Loki in SingleBinary mode with 30d retention. An Alloy DaemonSet ships logs |
| Messaging | NATS JetStream | 3-replica cluster in `nats`. The NACK controller manages Stream and Consumer CRDs |
| GraphQL | Apollo operator + router | Two installs, `apollo-operator-test` and `apollo-operator-prod`. Each has its own key and watches only its own lane. Helm chart from `registry-1.docker.io/apollograph`. Joins each team's subgraph into one supergraph. See [Platform Graph](./platform/docs/graph.md). The router image is `ghcr.io/cujarrett/apollo-router-arm64`, rebuilt from source because the official image aborts on a 16K-page kernel |
| Secrets | External Secrets Operator | Renders cluster-setup credentials from AWS SSM Parameter Store. The `ClusterSecretStore` `aws-parameter-store` signs in as the `eso-reader` IAM user, which can only read the `/homelab/` path. `aws-eso-creds` is the only hand-created Secret |
| Workload Identity | SPIRE | `spire-server` and `spire-system` namespaces. Helm chart from `spiffe.github.io/helm-charts-hardened`. Issues X.509 SVIDs for AWS IAM Roles Anywhere, and JWT-SVIDs that the OIDC discovery provider publishes at `oidc.mattjarrett.dev` |
| Workflows | Temporal | Server and UI from the official Helm chart, with one Postgres StatefulSet holding both of its databases. `temporal-controller` creates each Temporal namespace from a `TemporalNamespace` resource |
| Vulnerability Scanning | Trivy operator | Scans every workload image for CVEs as `linux/arm64` and feeds the Security dashboard. Istio sidecars are injected at pod creation, so `cluster/monitoring/istio-proxy-scan.yaml` gives Trivy their image to scan |

## Namespaces & Applications
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
| `launchpad` | Spa + Api + Sql | `launchpad.mattjarrett.dev` through Cloudflare Tunnel. The Spa's nginx proxies `/api/` to `launchpad-api`. That is a cluster-internal BFF (backend for the frontend) that provisions short-lived demo sandboxes. `launchpad-db` holds a year of sandbox map pins |
| `platform-connections-demo` | Api ×3 + Spa | Service mesh walkthrough at `connections.mattjarrett.dev`. Two callers run one image and differ only in what they declare |
| `platform-graph-demo` | Api + Spa | Schema management walkthrough at `graph.mattjarrett.dev`. The backend runs fixed queries against the `graph-prod` router under a call budget. It reads GitHub every ten minutes |
| `platform-exporter` | platform-exporter | Custom Prometheus exporter for platform metrics, scraped through `platform-exporter-servicemonitor` |
| `external-secrets` | External Secrets Operator | Renders cluster-setup Secrets from Parameter Store. Every store and `ExternalSecret` is in `cluster/external-secrets/` |
| `kyverno` | Kyverno | Admission, background and reports controllers. The policy engine that enforces workspace and namespace rules |
| `github-exporter` | github-exporter | Prometheus exporter for pull request, auto-merge and workflow metrics across the account's repos |
| `reloader` | Stakater Reloader | Restarts a workload when a ConfigMap it names changes. It watches only workloads annotated `reloader.stakater.com/auto`. The Api composition sets that annotation whenever `configFrom` is used. Secrets are ignored, because they reach apps as files that kubelet refreshes in place |
| `graph-test` | GraphApi ×2 + FederatedGraph | `records` and `reviews` subgraphs, one repo each (`storefront-records`, `storefront-reviews`). Composed into `storefront-homelab@test`. Router at `graph-test.local.lab` |
| `graph-prod` | GraphApi ×2 + FederatedGraph | `records` and `reviews` subgraphs at the digests promoted from test by PR. Composed into `storefront-homelab@prod`. Router at `graph-prod.local.lab`. Only the prod operator in `apollo-operator-prod` publishes here, with its own key |
| `node-sysctls` | node-sysctls, k3s-env | DaemonSets that write host settings from Git. `node-sysctls` applies sysctls on every node. `k3s-env` writes a `GOMEMLIMIT` drop-in to ctrl-1's `/etc/systemd/system/k3s.service.d/`. It takes effect on the next daemon-reload and k3s restart |
| `spire-server`, `spire-system` | SPIRE | Workload identity (SPIFFE). Agent DaemonSet on all nodes. OIDC discovery provider serving `oidc.mattjarrett.dev` |
| `trivy-system` | Trivy operator | Image CVE scans for the Security dashboard |
| `temporal` | Temporal | Frontend, history, matching, worker and UI, plus `temporal-postgres` (5Gi on `longhorn-retain`). UI at `temporal.local.lab`, signed in through Entra |
| `temporal-controller` | temporal-controller | Kubebuilder controller that creates, corrects and deletes Temporal namespaces from `TemporalNamespace` resources |

## Internal Hostnames (`.local.lab`)

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

### How clients actually resolve

**Clients on VLAN 10 ask the UDR7 at `192.168.10.1` for DNS. They never ask AdGuard directly.** Check with `scutil --dns` on a Mac. This has three effects:

- AdGuard filters and logs nothing for those clients. `*.local.lab` still reaches them, because Tailscale split DNS points `local.lab` at AdGuard separately.
- A client asks a second resolver only when the first gives no answer. A wrong answer is still an answer, and so is a cached `NXDOMAIN`. Listing AdGuard second would never help.
- The UDR7 caches a "no such name" answer for the full SOA TTL (30 minutes on Cloudflare zones). Flushing it needs **Settings → System → Advanced → Device SSH Authentication** turned on. AdGuard and CoreDNS recover on their own, but the UDR7 cache lasts longer. If anything looked up a new public hostname before its DNS record existed, the LAN can't reach it until that cache expires.

To get filtering back without making every device depend on AdGuard, point the UDR7's own upstream resolver at AdGuard. Leave what DHCP hands out unchanged.

## Public Hostnames
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

## Cloudflare Tunnel Operations

Use the `/add-cloudflare-tunnel-hostname` skill. The tunnel API replaces the whole config on every write. A hand edit must fetch the current ingress array, append to it, then PUT it all back. The skill does this.

- Every hostname routes to `https://192.168.10.101:443`.
- Every hostname uses `noTLSVerify: false` and `originServerName: <hostname>`.
- The Gateway already serves a cert for any `*.mattjarrett.dev` name, so a new one passes verification from the start.
- A new zone needs its name in [cluster/traefik/certificates.yaml](./cluster/traefik/certificates.yaml) first, or the tunnel returns 502.
- The token in `cloudflare-tunnel-token` is a double-base64 JSON blob with `a` (account), `t` (tunnel) and `s` (secret).
- The API token needs Zero Trust → Argo Tunnel (Legacy) → Edit.

## Monitoring Stack Details
- **Prometheus (main):** `monitoring-kube-prometheus-prometheus`, port 9090, 30d retention, 35Gi PVC.
- **Prometheus (sump-pump):** `prometheus-sump-pump`, port 9090, 18250d retention, 2Gi PVC on `longhorn-retain`, no node pinning.
  - Scrapes sump-pump-bridge, sump-pump-consumer and weather-exporter.
  - Grafana datasource UID is `sump-pump-archive`.
  - **The PVC mounts at the `prometheus-db/` subdirectory.** Migration jobs must write blocks there, and never to the PVC root.
- **Grafana:**
  - Admin secret is `grafana-admin-secret`. Anonymous viewer access is on.
  - The Loki datasource is configured. A sidecar loads dashboards from all namespaces.
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
Colors follow [Dashboard Colors](./cluster/monitoring/dashboard-colors.md). Green, yellow and red are reserved for health. Every other value uses the blue and purple family. Read it before adding or editing a panel.

Each dashboard is a ConfigMap in [cluster/monitoring/](./cluster/monitoring/) named `grafana-dashboard-*.yaml`. It is labelled `grafana_dashboard: "1"` and holds its UID inside the file. List them with `ls`, because this file keeps no index of them. Test with `kubectl apply -f` before committing.

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

## 1U Display (ctrl-1)
`ctrl-1` drives an attached 1424x280 LCD with a kiosk browser. The browser runs as a bare background process under the `pi` user, outside systemd. [Kiosk](./docs/kiosk/README.md) has the script, the setup a rebuilt ctrl-1 needs, and how to change the URL.

To pick up a URL change, restart `getty@tty1.service` so `.bashrc` re-sources the script. A plain `pkill chromium` is not enough, because the `while true` loop relaunches Chromium with the old URL from memory.

## Crossplane Platform

Crossplane core runs with `--enable-realtime-compositions`, set in the Helm `args` in [cluster/argocd/crossplane.yaml](./cluster/argocd/crossplane.yaml). Composite reconciliation then reacts to composed-resource changes by watch, instead of waiting for the 60s poll. Without it, a composed resource can turn Ready up to a minute before its status reaches the XR.

`platform/` defines twelve platform types, each as `<plural>.platform.local.lab`. The canonical list is [Platform → Offerings](./platform/README.md#offerings). That list leaves out these facts:

- `Spa`: the composition generates the nginx config. App repos must not include an `nginx.conf`.
- `Wordpress`: a MariaDB StatefulSet and a WordPress Deployment. Credentials derive from the XR UID.
- `Sql`, `NoSql`, `ObjectStorage`: used by Launchpad guest demo sandboxes. `NoSql` and `ObjectStorage` stay within the AWS free tier by design.
- `ManagedSecret`: the value never becomes a Kubernetes Secret.
- `GraphApi`: nests an `Api`. It publishes its schema from the same image digest to the named `FederatedGraph`. See [Platform Graph](./platform/docs/graph.md).

The [Namespaces & Applications](#namespaces--applications) table lists which namespaces use which XR types.

### GitOps flow for XR instances
1. For a new workspace, add its namespace in two places, then let it sync:
   - the `workloads` project `destinations` in [cluster/argocd/projects.yaml](./cluster/argocd/projects.yaml)
   - every namespace list in [cluster/kyverno/workspace-rbac.yaml](./cluster/kyverno/workspace-rbac.yaml)

   The project allows only `platform.local.lab` kinds, ConfigMap, Service and Namespace.
2. Commit XR files to a top-level directory in the `homelab-workspaces` repo, such as `mattjarrett-com/mattjarrett-com.yaml`.
3. The `xrs` ApplicationSet (`cluster/argocd/xrs-appset.yaml`) makes one ArgoCD Application per directory. Each one deploys into a namespace named after its directory.
4. ArgoCD applies the XR to the cluster.
5. Crossplane reconciles the XR and creates all composed resources.

The [homelab-workspaces README](https://github.com/cujarrett/homelab-workspaces#structure) covers the directory layout and the `namespace.yaml` requirement. XR instance files live in `homelab-workspaces/<name>/`, one directory per workspace, such as `mattjarrett-com/` and `kentjarrett-com/`. `launchpad-api` writes and deletes the short-lived `guest-*` sandbox directories. People maintain every other workspace directory by hand.

### Deleting an XR instance
Delete in this order, or data is lost.
```bash
# 1. Delete the XR. Crossplane cascade-deletes all composed resources.
kubectl delete spa <name> -n <namespace>
# or: kubectl delete wordpress <name> -n <namespace>

# 2. Remove the workspace directory from the homelab-workspaces repo and push. ArgoCD prunes the Application.
git rm -r <name>/ && git commit -m "..." && git push
```
**Never remove the file first.** That orphans the composed resources.

### Storage classes for XR PVCs
- `longhorn-retain`: for `dataRetention: retain`. The PV survives XR deletion, so data is recoverable.
- `longhorn-delete`: for `dataRetention: delete`. The PV is wiped when the XR is deleted.
- The `dataRetention` field in the WordPress XR picks which one is used.

### WordPress backup and restore
Scripts are in [scripts/wordpress/](./scripts/wordpress/). The procedure is in [WordPress Restore Guide](./docs/wordpress/README.md). Backups are kept outside the repo.

## ArgoCD AppProjects
Four projects group workloads by concern:
| Project | Allowed source repos | Contents |
|---|---|---|
| `platform` | homelab git + `argoproj.github.io/argo-helm` + `charts.crossplane.io/stable` | ArgoCD, Crossplane, compositions, bootstrap |
| `cluster` | homelab git + `nats-io.github.io/k8s/helm/charts` + `charts.jetstack.io` + `spiffe.github.io/helm-charts-hardened` + `registry-1.docker.io/apollograph` + `go.temporal.io/helm-charts` | Longhorn, Traefik, cert-manager, AdGuard, Cloudflare, NATS + NACK, SPIRE, Apollo operator, Temporal, temporal-controller |
| `observability` | homelab git + `prometheus-community.github.io/helm-charts` + `grafana.github.io/helm-charts` | kube-prometheus-stack, Loki, Alloy, platform-exporter |
| `workloads` | homelab git + homelab-workspaces git | All workspace apps (one Application per homelab-workspaces directory) + blog |

## Key Conventions
- Every app has ArgoCD `automated: { prune: true, selfHeal: true }`, so the cluster converges to the repo on its own.
- Most apps use `ServerSideApply: true`.
- Never hand-create or commit a cluster-setup Secret. Add a parameter and an `ExternalSecret` instead. See [External Secrets](./docs/external-secrets.md).
- Secrets that controllers generate (cert-manager TLS, Crossplane provider TLS, webhook CAs) hold no credential anyone chose. They stay in-cluster.
- Every `HTTPRoute` has `parentRefs: [{name: traefik-gateway, namespace: kube-system}]`. Traefik Middlewares attach as `ExtensionRef` filters.
- A host outside `*.local.lab`, `*.mattjarrett.dev`, `mattjarrett.com` and `kentjarrett.com` needs its name added to [cluster/traefik/certificates.yaml](./cluster/traefik/certificates.yaml).
- Spa compositions put `gotemplating.fn.crossplane.io/ready: "True"` on go-templating resources. This stops a false `Ready=False` on the XR.

## Go App Conventions

All homelab Go services share one layout. When editing or creating a Go app:

- **Build tool:** `just`, never `make`. Every Go repo has a `justfile` at the root.
- **Standard recipes**, the same in every app:
  - `just ci`: lint, test and build. Run it before pushing.
  - `lint`: `go mod tidy -diff` and `golangci-lint run`.
  - `test`: `go test -race ./...`.
  - `build` and `run`.
- **Binary name matches the repo name**, always `-o <repo-name>`. The race detector is always on.
- **Stdlib only.** Use `net/http` and `slog`, with no HTTP framework.
- **Graceful shutdown** through `signal.NotifyContext`.
- **A `/healthz` route on every app.** The Kubernetes readiness probe hits it.
- **CI/CD:** every repo ships `.github/workflows/ci.yml` with three jobs. Tests always gate the build.
  - `test`: `go test ./...` and `go vet ./...`.
  - `build-and-push`: `needs: test` and `if: main`. Builds ARM64 and pushes to `ghcr.io/cujarrett/<repo>`.
  - `deploy`: updates the image tag in `homelab-workspaces`.
- **Renovate:** every repo ships `renovate.json`, extending the shared preset at `github>cujarrett/homelab//.github/renovate-shared`. Policy lives in the preset.
- **Per-repo `AGENTS.md`:** each repo stands alone, so each carries the git rules, the pre-commit safety check and the grug philosophy. An agent working in that repo never sees this file. The `/new-go-api` skill scaffolds all of the above, and every new Go API starts there.

Go apps in this workspace:
| Repo | Binary | Notes |
|---|---|---|
| `my-vinyl-api` | `my-vinyl-api` | REST API for the my-vinyl SPA |
| `sump-pump` | `bridge`, `consumer` | Monorepo. `cmd/bridge` publishes IoT readings to NATS. `cmd/consumer` reads them and exposes Prometheus metrics. `internal/event` holds the shared subjects and payload. Images stay `ghcr.io/cujarrett/sump-pump-bridge` and `-consumer` |
| `weather-exporter` | `weather-exporter` | Weather Prometheus exporter |
| `launchpad-api` | `launchpad-api` | BFF (backend for the frontend) for the Launchpad UI |
| `demo-api` | `demo-api` | Sample Api in each Launchpad guest sandbox and the platform e2e tests. Probes every binding with a real round-trip |
| `github-exporter` | `github-exporter` | Prometheus exporter for pull request, auto-merge and workflow metrics across the account's repos |
| `platform-exporter` | `platform-exporter` | Prometheus exporter for Crossplane XR, binding and pod readiness timings |
| `workload-identity-sidecar` | `workload-identity-sidecar` | Sidecar that trades a SPIFFE SVID for short-lived cloud credentials. Go code lives in `sidecar/` |
| `homelab-stats` | `homelab-stats` | Read-only JSON for the homelab section on mattjarrett.dev, built from a fixed set of Prometheus queries and the blog-stats gist |
| `temporal-controller` | `manager` | Kubebuilder controller for the `TemporalNamespace` CRD. Uses the kubebuilder `Makefile`, not `just` |
| `platform-connections-demo` | `api`, `downstream` | Monorepo for the service mesh walkthrough. `api` runs as `upstream-api`. `downstream` runs as `authorized-api` and `unauthorized-api`. Each has its own `justfile` |

## Skills

Repo skills live in [.claude/commands/](./.claude/commands/), one file per skill. List them with `ls`, because this file keeps no index of them.

## Common Commands
```bash
# Always use the full name.
# A bare "applications" also matches Crossplane's Entra applications.azuread.m.upbound.io.
# Those report SYNCED/READY, so anything filtering on Synced reads them as unhealthy.
kubectl get applications.argoproj.io -A

argocd login argocd.local.lab --username admin --insecure
argocd app sync <app-name>
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```
