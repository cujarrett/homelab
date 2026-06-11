# Service Mesh

Four nodes, every pod talking to every other pod over plain HTTP with no enforcement, no
per-route metrics, and no automatic retries. It works. Until it doesn't, and you're staring
at a pod log trying to figure out whether the failure was in the caller, the callee, or
somewhere in between.

A service mesh fixes that by inserting a proxy sidecar into every pod. Your app doesn't
change. The proxy intercepts all inbound and outbound traffic, enforces mTLS between
every pair of pods, and emits golden metrics (success rate, RPS, p99 latency) for every
route — without a single line of instrumentation code.

---

## What a Service Mesh Does (and Why You Want It)

Service meshes exist because Kubernetes solved the "where do I run my app" problem but not
the "how do I safely connect my apps to each other" problem. You still get:

- **No encryption in transit** between pods inside the cluster. Any compromised pod can
  sniff traffic from other pods on the same node.
- **No automatic retries or timeouts** at the infrastructure level. If `my-vinyl-api` goes
  slow, `my-vinyl-spa` waits forever unless the app handles it.
- **No golden metrics per route.** Prometheus can tell you a pod's CPU. It can't tell you
  that `/api/search` has a 3% error rate since the last deploy.
- **No identity.** There's nothing stopping pod A from claiming to be pod B.

A service mesh adds a transparent proxy sidecar to every pod. All traffic flows through it.
The mesh handles mTLS automatically — pods get short-lived certificates, rotate them, and
validate each other's identity. Traffic policy (retries, timeouts, circuit breakers) is
declared as Kubernetes resources, not buried in app code.

```
Without mesh:
  Pod A ──────────── TCP ────────────► Pod B

With mesh:
  Pod A → [proxy] ── mTLS ── [proxy] → Pod B
              ↑                  ↑
         metrics              metrics
```

---

## Tool Selection

Three realistic choices for this cluster. One clear winner.

| | Linkerd | Istio | Cilium |
|---|---|---|---|
| **Data plane** | Rust (`linkerd2-proxy`) | Envoy | eBPF (kernel-level) |
| **Memory per pod** | ~10–20 MB | ~50–100 MB | near zero (kernel) |
| **ARM64 support** | Native since v2.12 | Yes | Yes |
| **Complexity** | Low | High | High (CNI replacement) |
| **mTLS** | Automatic, zero-config | Needs PeerAuthentication CRDs | Yes (but different model) |
| **Traffic policy API** | HTTPRoute (Gateway API) | VirtualService + DestinationRule | CiliumNetworkPolicy |
| **Prometheus integration** | Native, no extra config | Needs telemetry config | Yes |
| **Traefik coexistence** | Works out of the box | Works, more config | Works |
| **Reversible install** | Yes — `linkerd uninstall \| kubectl delete -f -` | Yes, but messy | **No** — CNI swap requires cluster rebuild |

**Use Linkerd.** Istio's resource overhead is a real problem on Pi hardware — you don't
want 100 MB of Envoy per pod across 20+ pods. Cilium is architecturally interesting but
switching CNI on a running k3s cluster is a full cluster rebuild (see [One-Way Doors](#one-way-doors)).
Linkerd's Rust proxy uses a fraction of the memory, ARM64 images ship in the default
release, and the install/uninstall story is clean.

---

## Roadmap

Each phase has a **read** and a **do** section. The read gives you the mental model. The
do makes it real. You're on the other side when the **exit criteria** are met.

---

### Phase 1 — Understand the Model (read, ~2 hours)

The concepts you need before touching the cluster.

**Read:**

1. [Linkerd architecture overview](https://linkerd.io/2.15/reference/architecture/) — understand control plane vs data plane, the proxy-init container, and certificate rotation.
2. [What is mTLS?](https://linkerd.io/2.15/features/automatic-mtls/) — how Linkerd issues and rotates identities without you managing certificates.
3. [Golden metrics](https://linkerd.io/2.15/features/telemetry/) — success rate, requests/sec, latency. These are the three numbers that tell you whether a service is healthy.
4. [HTTPRoute](https://linkerd.io/2.15/features/httproute/) — the Gateway API resource Linkerd uses for traffic policy. This replaces what you'd do in app code.

**Mental model to confirm:**

- The *control plane* (`linkerd-control-plane`) issues certificates and pushes config to proxies. Runs in `linkerd` namespace.
- The *data plane* is the `linkerd-proxy` sidecar injected into every pod. It intercepts all traffic via iptables rules set by `linkerd-init`.
- Injection is opt-in per namespace via the `linkerd.io/inject: enabled` annotation. No annotation = no sidecar = not in the mesh.
- mTLS is automatic once a pod is meshed. You don't configure it. You verify it.

**Your public traffic topology:**

All public hostnames enter the cluster through Cloudflare Tunnel, not directly to Traefik.
The full path is:

```
Internet
  → Cloudflare Edge
  → cloudflared (Deployment, cloudflare namespace, 2 replicas)
  → Traefik (DaemonSet, kube-system, https://192.168.10.101:443)
  → backend pod (js-pollock, blog, my-vinyl, mattjarrett-com, etc.)
```

Public hostnames and their backend namespaces:

| Hostname | Namespace |
|---|---|
| `mattjarrett.com` | `mattjarrett-com` |
| `mattjarrett.dev` | `mattjarrett-dev` |
| `blog.mattjarrett.dev` | `blog` |
| `myvinyl.mattjarrett.dev` | `my-vinyl` |
| `jspollock.mattjarrett.dev` | `js-pollock` |
| `launchpad.mattjarrett.dev` | `launchpad` |
| `demo1.mattjarrett.dev` | `launchpad` (or tenant namespace) |
| `demo1-api.mattjarrett.dev` | `launchpad` (or tenant namespace) |

The mesh only sees traffic *between pods inside the cluster*. The cloudflared → Traefik
leg is outside the mesh until you inject both (Phase 6). Until then:
- Real traffic from the internet flows through your public sites and generates real metrics
- The source identity on every request will appear as Traefik (unmeshed) — not cloudflared
- mTLS is not enforced on the cloudflared → Traefik leg until Traefik is meshed

This is fine. The mesh still secures and observes everything from Traefik inward.

**Exit criteria:** You can explain the difference between the control plane and the data
plane to someone else, without notes. You can draw the full traffic path from internet to
backend pod, marking which legs are inside the mesh and which aren't.

---

### Phase 2 — Install Linkerd (hands-on, ~1 hour)

Install the CLI, validate prerequisites, and deploy the control plane.

```bash
# Install the Linkerd CLI (ARM64 Mac)
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install | sh
export PATH=$PATH:$HOME/.linkerd2/bin

# Verify the CLI
linkerd version
```

```bash
# Pre-flight checks — validates your cluster can run Linkerd
linkerd check --pre
```

Linkerd needs cluster-level cert-manager OR its own built-in trust anchor. Your cluster
already has cert-manager, but the simplest path for learning is Linkerd's built-in CA.
Use the Helm chart (ArgoCD can manage this later, but do it manually first so you understand
the pieces):

```bash
# Install the CRDs
linkerd install --crds | kubectl apply -f -

# Install the control plane
linkerd install | kubectl apply -f -

# Wait and verify — this should show all checks green
linkerd check
```

```bash
# Install the viz extension (Grafana-style dashboard for the mesh)
linkerd viz install | kubectl apply -f -
linkerd viz check

# Open the viz dashboard in your browser
linkerd viz dashboard &
```

**Exit criteria:**
- `linkerd check` shows all green
- `linkerd viz dashboard` opens and shows an empty topology graph
- Control plane pods in `linkerd` and `linkerd-viz` namespaces are all `Running`

```bash
kubectl get pods -n linkerd
kubectl get pods -n linkerd-viz
```

---

### Phase 3 — Mesh One Namespace (hands-on, ~30 minutes)

Pick a low-blast-radius namespace to inject first. `js-pollock` is a good choice — it's
an `XSpa` (just nginx), public-facing but low-risk, no stateful data.

```bash
# Annotate the namespace for auto-injection
kubectl annotate namespace js-pollock linkerd.io/inject=enabled

# Restart pods to pick up the annotation — Linkerd injects on pod creation, not retroactively
kubectl rollout restart deployment -n js-pollock
```

```bash
# Confirm sidecars are injected — look for 2/2 READY (app + proxy)
kubectl get pods -n js-pollock

# Verify mTLS is active
linkerd viz -n js-pollock edges deployment
```

The `edges` command shows you every connection in the namespace and whether it's secured
with mTLS. You want to see `√` next to each edge.

```bash
# Check golden metrics for the namespace
linkerd viz -n js-pollock stat deployment
```

This shows success rate, RPS, and p50/p95/p99 latency. If traffic is flowing through
Traefik to the nginx pod, you'll see real numbers here.

**What to expect with Cloudflare tunnel traffic:**

`jspollock.mattjarrett.dev` is routed via Cloudflare Tunnel → Traefik → the `js-pollock`
pod. When you run `linkerd viz edges -n js-pollock`, you'll see the edge from Traefik
marked `×` (no mTLS identity) because Traefik is not yet meshed. That's expected at this
phase — Traefik is the unmeshed entry point. The `√` you're looking for is on pod-to-pod
edges *within* the namespace, not the Traefik ingress edge.

The golden metrics in `linkerd viz stat` will show real numbers driven by actual internet
traffic hitting `jspollock.mattjarrett.dev`. No need to generate synthetic load.

**Exit criteria:**
- Pods in `js-pollock` show `2/2 READY`
- `linkerd viz stat deployment -n js-pollock` returns real RPS metrics from Cloudflare tunnel traffic
- You understand why the Traefik→js-pollock edge shows `×` and what will fix it (Phase 6)

---

### Phase 4 — Observe the Mesh (hands-on, ~1 hour)

Now you have data. Learn to read it.

```bash
# Watch live traffic — updates every second
linkerd viz tap -n js-pollock deployment/js-pollock

# Watch top-level route summary
linkerd viz top -n js-pollock deployment/js-pollock
```

The `tap` output shows individual requests in real time — method, path, status code,
response time. This is the thing you wished you had the last time you were debugging a
slow endpoint.

For public-facing services (`js-pollock`, `blog`, `my-vinyl`, etc.), you'll see real
requests from internet users routed through Cloudflare Tunnel. The `src` field in tap
output will show Traefik's pod IP as the caller — not cloudflared's IP, and not the
original client IP. That's because Traefik is the last hop before the backend pod, and
it's not yet meshed so it has no Linkerd identity. The `dst` will be the backend pod.
This is correct and expected until Phase 6.

```bash
# Mesh the blog namespace too (Ghost blog)
kubectl annotate namespace blog linkerd.io/inject=enabled
kubectl rollout restart deployment -n blog

# Compare two services side-by-side
linkerd viz stat deployments -n blog
linkerd viz stat deployments -n js-pollock
```

**Linkerd + your existing Grafana:**

Linkerd viz ships its own Grafana but you already have one. Add the Linkerd datasource to
your existing Prometheus and create a ServiceMonitor so kube-prometheus-stack scrapes
Linkerd's control plane:

```yaml
# cluster/monitoring/linkerd-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: linkerd-controller
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - linkerd
      - linkerd-viz
  selector:
    matchLabels:
      linkerd.io/control-plane-component: controller
  endpoints:
    - port: admin-http
      path: /metrics
```

**Exit criteria:**
- `linkerd viz tap` shows live request traces in `js-pollock` or `blog`
- You can see success rate drop to 0% if you `kubectl scale deployment --replicas=0` and watch
- Bonus: a Linkerd Grafana dashboard is visible in your existing Grafana

---

### Phase 5 — Traffic Policy (hands-on, ~1 hour)

The payoff for having a mesh. Declare retry and timeout behavior in YAML instead of app code.

HTTPRoute lets you define per-route policy. Linkerd reads it. Your app doesn't change.

**Example: timeout on a slow route**

```yaml
# Timeout all requests to my-vinyl-api after 5 seconds
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-vinyl-api-timeout
  namespace: my-vinyl
spec:
  parentRefs:
    - name: my-vinyl-api
      kind: Service
      group: core
      port: 80
  rules:
    - timeouts:
        request: 5s
```

**Example: retry on 5xx**

```yaml
# Retry GET requests that return 5xx (idempotent only — don't retry POSTs blindly)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-vinyl-api-retry
  namespace: my-vinyl
spec:
  parentRefs:
    - name: my-vinyl-api
      kind: Service
      group: core
      port: 80
  rules:
    - retry:
        codes: [500, 502, 503, 504]
        limit: 3
```

Apply one, then use `linkerd viz tap` to watch retries happen in real time when you
intentionally break the backend pod.

**Exit criteria:**
- You've applied at least one HTTPRoute and confirmed via `linkerd viz stat` that it's
  taking effect (retries show up as slightly higher RPS than you'd expect for one request)

---

### Phase 6 — Mesh the Whole Cluster (hands-on, ~1 hour)

Scale out to the remaining namespaces. A few have quirks.

**Annotate remaining namespaces:**

```bash
# Annotate and restart each namespace
for ns in mattjarrett-com mattjarrett-dev my-vinyl sump-pump; do
  kubectl annotate namespace $ns linkerd.io/inject=enabled
  kubectl rollout restart deployment -n $ns 2>/dev/null || true
  kubectl rollout restart statefulset -n $ns 2>/dev/null || true
done
```

**Mesh Traefik:**

Traefik itself can be meshed. When it is, the Traefik → backend connection is also mTLS.
Because Traefik runs as a DaemonSet in `kube-system`, annotate it with a pod annotation
rather than namespace-wide injection (injecting everything in `kube-system` is risky):

```bash
kubectl -n kube-system patch daemonset traefik \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/metadata/annotations/linkerd.io~1inject","value":"enabled"}]'
```

**Handle NATS (opaque ports):**

Linkerd does HTTP-level analysis by default. NATS speaks its own binary protocol over port
4222 — Linkerd can't parse it as HTTP and will log errors if you let it try. Mark port
4222 as opaque so Linkerd routes it as raw TCP:

```bash
kubectl annotate namespace nats config.linkerd.io/opaque-ports=4222
kubectl annotate service nats -n nats config.linkerd.io/opaque-ports=4222
kubectl rollout restart statefulset -n nats
```

Opaque ports still get mTLS — Linkerd encrypts the TCP stream — it just skips the HTTP
parsing and doesn't emit route-level metrics for that port. That's fine for NATS.

**Exclude Longhorn, cert-manager, and cloudflare:**

These namespaces interact badly with sidecar injection or need separate validation before
meshing. Leave them unmeshed for now. Longhorn uses host-network paths; cert-manager
webhook timing is sensitive; `cloudflared` establishes an outbound-only tunnel to
Cloudflare's edge — injecting a proxy here needs explicit validation that the tunnel
connection survives, and the mesh gives you nothing useful (there's no pod-to-pod traffic
in that namespace to observe or secure).

```bash
kubectl annotate namespace longhorn-system linkerd.io/inject=disabled
kubectl annotate namespace cert-manager linkerd.io/inject=disabled
kubectl annotate namespace cloudflare linkerd.io/inject=disabled
```

If you later want to mesh `cloudflare` to make the cloudflared→Traefik leg visible in the
topology, do it deliberately: inject it alone, restart the `cloudflared` Deployment, and
confirm your public hostnames still respond before proceeding.

**Exit criteria:**
- `linkerd viz stat deployments -A` shows metrics for all your application namespaces
- `linkerd check` is still all green
- All previously-working apps are still responding (check Traefik access logs)

---

### Phase 7 — Platform Integration (hands-on, ~2 hours)

This is where the mesh meets Crossplane. Right now, any XR deployed after you annotated
a namespace will get sidecars injected automatically. That's actually fine and is the
recommended path — annotate the namespace, let injection be the default.

But the platform should be explicit about it. Two changes:

**1. Document the mesh opt-in in XApi and XSpa READMEs**

Add a section to `platform/api/README.md` and `platform/spa/README.md` noting that if the
deployment namespace has `linkerd.io/inject: enabled`, pods will be injected automatically.
No parameter needed. The composition doesn't need to change for the default case.

**2. Add an escape hatch for pods that can't be meshed**

Some workloads can't tolerate a sidecar — DaemonSets that need host networking, batch jobs
with precise timing, etc. Add an optional `mesh.enabled` parameter to `XApi` (default
`true`) that sets `linkerd.io/inject: disabled` on the pod template when false:

In `platform/api/composition.yaml`, in the Deployment pod template annotations block:

```yaml
# In the go-templating template, inside the Deployment pod template metadata:
{{- if and $xr.spec.parameters.mesh (eq $xr.spec.parameters.mesh.enabled false) }}
    linkerd.io/inject: disabled
{{- end }}
```

And add to `platform/api/xrd.yaml` under `spec.parameters`:

```yaml
mesh:
  type: object
  description: "Service mesh options. Defaults to namespace-level injection setting."
  properties:
    enabled:
      type: boolean
      default: true
      description: "Set to false to explicitly opt this pod out of sidecar injection."
```

**3. Verify init containers still work**

The XApi init containers wait for binding Secrets to exist by querying the Kubernetes API.
This is a cluster API call, not pod-to-pod traffic. It goes through the proxy but doesn't
require the destination to be meshed. Test with a new XApi deployment in an already-meshed
namespace and confirm the init container completes and the pod starts.

**Exit criteria:**
- A new XApi XR deployed in a meshed namespace comes up with `3/3 READY` (init container exits, app starts, proxy is running — init container doesn't count in READY but you can verify proxy injection via `kubectl describe pod`)
- `linkerd viz stat deployment -n <namespace>` shows the new XApi in the topology
- An XApi with `mesh.enabled: false` shows `1/1 READY` (no proxy)

---

## Platform Impacts

Summarized for reference:

| Component | Impact | Action needed |
|---|---|---|
| `XApi` Deployments | Auto-injected if namespace is annotated | Add optional `mesh.enabled` escape hatch |
| `XApi` init containers | No impact — they use Kubernetes API, not mesh traffic | None |
| `XSpa` (nginx) | Auto-injected — static file serving works fine with sidecar | None |
| `XWordpress` | MariaDB StatefulSet + WordPress Deployment both get injected | Test and verify DB connections work |
| `XTopic` / `XSubscription` (NATS) | Port 4222 must be marked opaque | Annotate `nats` namespace with `config.linkerd.io/opaque-ports=4222` |
| `XCache` (Redis) | Redis port 6379 may need opaque annotation if you see proxy errors | Annotate if needed |
| Service bindings (`/bindings/`) | Completely unaffected — these are volume mounts, not network | None |
| Cloudflare Tunnel | `cloudflared` can be meshed; traffic enters at Traefik, not cloudflared | Optional — mesh if you want the cloudflared→Traefik leg visible |
| Prometheus scraping | kube-prometheus-stack scrapes pods via ServiceMonitor | Add Linkerd ServiceMonitor for control plane metrics; proxy metrics scraped automatically |
| ArgoCD sync | ArgoCD itself can be meshed | Optional — annotate `argocd` namespace if you want it in the topology |

---

## One-Way Doors

These are decisions you can't easily reverse. Call them out before you make them.

### Switching CNI (Cilium, Calico, etc.)

**This is a full cluster rebuild.**

k3s bundles Flannel as the CNI. Replacing it requires re-installing k3s on every node.
Your data (Longhorn PVCs on NVMe) survives, but the cluster state doesn't — you'd
re-bootstrap from the GitOps repo. This is a weekend, not an evening.

Linkerd runs on top of Flannel. You don't need to change CNI to get a service mesh.
If you later want Cilium's eBPF network policies, that decision is independent of the
mesh decision. Don't let curiosity about Cilium delay the mesh work.

**Decision:** Stick with Flannel. Revisit CNI only if you rebuild the cluster for another
reason.

---

### mTLS Strict Mode (STRICT policy)

In permissive mode (the default), meshed pods accept traffic from both meshed and unmeshed
clients. In strict mode, a meshed pod *rejects* connections from anything without a valid
Linkerd identity.

Once you set strict mode on a namespace, anything outside the mesh — Prometheus scraping,
kubectl port-forward, external load balancers — can't reach those pods. You have to
explicitly exclude each probe.

This is reversible on paper. In practice, rolling it back while services are down is
stressful. Don't enable strict mode until you've verified that every client that talks to
that namespace is itself meshed and healthy.

**Decision:** Stay in permissive mode through Phase 6. Revisit strict mode as an advanced
step after you trust the topology map.

---

### Linkerd Trust Anchor Rotation

Linkerd's control plane uses a root CA (the "trust anchor") to issue identity certificates
to proxies. The trust anchor has an expiration date. If you use Linkerd's built-in CA
(as recommended for learning in Phase 2), you need to rotate the trust anchor before it
expires.

The rotation process requires coordination across the control plane — it's not a rolling
restart. It's documented but non-trivial. If you move to production use, integrate
Linkerd's trust anchor with cert-manager from the start so rotation is automated.

**Decision:** For learning, the built-in CA is fine. Before you commit to Linkerd long-term,
migrate to cert-manager-issued trust anchors. Do this during Phase 7, not after.

Reference: [Linkerd cert-manager integration](https://linkerd.io/2.15/tasks/automatically-rotating-control-plane-tls-credentials/)

---

### Removing Linkerd after wide adoption

Linkerd itself is cleanly removable:

```bash
linkerd viz uninstall | kubectl delete -f -
linkerd uninstall | kubectl delete -f -
kubectl annotate namespace --all linkerd.io/inject-
```

But if you've written HTTPRoute resources for traffic policy and baked them into your
GitOps repo, those resources become orphaned CRDs after uninstall — harmless, but
messy. If you've added mesh annotations to XR instance files in `platform/xrs/`, you'd
need to clean those up too.

**Decision:** Keep mesh-specific resources (HTTPRoutes, ServiceProfiles) in separate files
from the XR instance files. Don't mix mesh policy into the core platform compositions —
it should be additive, not embedded.

---

## What You Know When You're Done

After Phase 6, you have:

- Every application pod encrypted in transit at the pod-to-pod level — without changing app code.
- Golden metrics for every service-to-service call in the cluster, visible in `linkerd viz stat` and your existing Grafana.
- A clear identity model: each pod has a certificate issued by Linkerd, rotated automatically.
- Traffic policy (retries, timeouts) declared as Kubernetes resources, not scattered across app configs.

After Phase 7, the platform knows about the mesh. New XApi and XSpa deployments get
injection automatically. Escape hatches exist. The compositions don't need to change for
the 90% case.

The remaining complexity — strict mTLS enforcement, multi-cluster mesh, traffic splitting
for canary deploys — exists when you want it. None of it requires undoing what you built here.

---

## Linkerd → Istio: The Work Translation Layer

Everything you learned in Phases 1–6 maps directly to Istio. The concepts are identical.
The API surface is bigger and the knobs are more exposed, but nothing is new.

This section is the Rosetta Stone. Left column is what you did at home. Right column is
what you'll see at work.

---

### Architecture

Both meshes have the same two-layer structure. The names differ.

| Concept | Linkerd | Istio |
|---|---|---|
| Control plane | `linkerd-control-plane` namespace | `istiod` (a single binary, `istio-system` namespace) |
| Data plane proxy | `linkerd-proxy` (Rust) | Envoy (C++) |
| Proxy injector | Mutating webhook in control plane | `istio-sidecar-injector` webhook |
| Init container (iptables) | `linkerd-init` | `istio-init` |
| Certificate authority | Built-in or cert-manager | Built-in or cert-manager (`cacerts` secret) |

`istiod` is a consolidation of what used to be three separate Istio processes (`Pilot`,
`Citadel`, `Galley`). When someone says "the control plane is down" at work, they mean
`istiod` is unhealthy.

---

### Injection

The mechanism is the same: annotate/label the namespace, restart pods, sidecars appear.
The trigger is slightly different.

| | Linkerd | Istio |
|---|---|---|
| Enable injection | **annotation** on namespace: `linkerd.io/inject: enabled` | **label** on namespace: `istio-injection: enabled` |
| Disable on one pod | annotation on pod: `linkerd.io/inject: disabled` | annotation on pod: `sidecar.istio.io/inject: "false"` |
| Verify injection | `kubectl get pod -o jsonpath='{.spec.containers[*].name}'` — look for `linkerd-proxy` | same — look for `istio-proxy` |
| Container count | `2/2` (app + proxy) | `2/2` (app + proxy) |

```bash
# Linkerd — namespace annotation
kubectl annotate namespace my-app linkerd.io/inject=enabled

# Istio — namespace label
kubectl label namespace my-app istio-injection=enabled
```

The effect is identical. The proxy intercepts all traffic in and out of the pod.

---

### mTLS

This is the biggest behavioral difference. Linkerd enables mTLS automatically and
silently the moment two meshed pods talk. Istio's mTLS is configurable and requires
a `PeerAuthentication` resource to actually *enforce* it.

| | Linkerd | Istio |
|---|---|---|
| mTLS between meshed pods | **Automatic.** No config needed. | Automatic in transit, but permissive by default (accepts plaintext too) |
| Enforce mTLS (reject plaintext) | Set `Server` policy resources | `PeerAuthentication` with `mtls.mode: STRICT` |
| Identity model | SPIFFE URI from Kubernetes ServiceAccount | SPIFFE URI from Kubernetes ServiceAccount (same model) |
| Cert rotation | Automatic, ~24h default | Automatic, ~24h default |

At work, you'll see `PeerAuthentication` objects. This is the Istio equivalent of checking
`linkerd viz edges` and seeing `√` — it's the declaration that plaintext is rejected:

```yaml
# Istio: enforce mTLS for an entire namespace
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: my-app
spec:
  mtls:
    mode: STRICT
```

Equivalent to what Linkerd gives you for free, but explicit.

---

### Traffic Policy

Linkerd uses standard Gateway API `HTTPRoute`. Istio has its own older API
(`VirtualService` + `DestinationRule`) and also supports Gateway API `HTTPRoute` in
newer versions (v1.17+). At most companies you'll see the older API.

**Timeouts:**

```yaml
# Linkerd — HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-api-timeout
  namespace: my-app
spec:
  parentRefs:
    - name: my-api
      kind: Service
      group: core
      port: 80
  rules:
    - timeouts:
        request: 5s
```

```yaml
# Istio — VirtualService
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: my-api-timeout
  namespace: my-app
spec:
  hosts:
    - my-api
  http:
    - timeout: 5s
      route:
        - destination:
            host: my-api
```

**Retries:**

```yaml
# Linkerd — HTTPRoute (retries on 5xx)
rules:
  - retry:
      codes: [500, 502, 503, 504]
      limit: 3
```

```yaml
# Istio — VirtualService (retries)
http:
  - retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: "5xx"
    route:
      - destination:
          host: my-api
```

**Load balancing / subsets (Istio-only concept):**

Istio adds `DestinationRule` for things Linkerd doesn't surface directly: connection pool
limits, outlier detection (circuit breaking), and traffic splitting across pod subsets
(e.g., by version label). If you see a `DestinationRule` at work, it's doing one of those.

```yaml
# Istio — DestinationRule: circuit breaker
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: my-api
  namespace: my-app
spec:
  host: my-api
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
```

No Linkerd equivalent for this exact API — Linkerd handles it differently via `ServiceProfile`
failure accrual.

---

### Observability

| | Linkerd | Istio |
|---|---|---|
| Dashboard | `linkerd viz dashboard` | Kiali (`kubectl port-forward -n istio-system svc/kiali 20001`) |
| Live request trace | `linkerd viz tap deploy/my-api` | `istioctl proxy-config log deploy/my-api --level debug` + access logs |
| Golden metrics (CLI) | `linkerd viz stat deploy -n my-app` | `istioctl experimental dashboard grafana` or Kiali |
| Topology graph | `linkerd viz dashboard` → topology tab | Kiali → Graph |
| Distributed tracing | Not built in (external Jaeger/Tempo) | Integrates with Zipkin/Jaeger via `meshConfig.enableTracing` |
| Prometheus metrics | Scraped automatically from proxy | Scraped from `istio-proxy` sidecar on port 15090 |

Kiali is Istio's equivalent of `linkerd viz dashboard`. It reads from Prometheus and shows
the same topology graph, golden metrics, and mTLS status. At work, if someone says "check
Kiali," they mean "look at the mesh topology."

```bash
# At work: verify mTLS is active between two services
istioctl x authz check <pod-name> -n my-app

# At home (Linkerd equivalent):
linkerd viz edges -n my-app
```

---

### Debugging

Same mental model, different commands.

| Task | Linkerd | Istio |
|---|---|---|
| Check control plane health | `linkerd check` | `istioctl analyze` |
| Inspect proxy config for a pod | `linkerd viz proxy-config -n my-app pod/<name>` | `istioctl proxy-config all -n my-app <pod>` |
| Watch live requests | `linkerd viz tap deploy/<name>` | Enable access logs: `istioctl proxy-config log deploy/<name> --level info` |
| Check cert expiry | `linkerd viz edges` shows identity | `istioctl proxy-config secret -n my-app <pod>` |
| Restart proxy without restarting pod | `kubectl rollout restart` (no hot-reload) | `kubectl rollout restart` (same) |

The most important one at work: `istioctl analyze`. Run it when something is broken and
you don't know where to start. It reads your Istio config and tells you what's wrong —
misconfigured VirtualServices, missing DestinationRules, stale references.

```bash
# Equivalent of linkerd check but for config correctness
istioctl analyze -n my-app
```

---

### Protocol Handling (Opaque Ports)

Both meshes need to know whether to parse traffic as HTTP or treat it as raw TCP. The
approach differs.

| | Linkerd | Istio |
|---|---|---|
| Mark a port as TCP (skip HTTP parsing) | `config.linkerd.io/opaque-ports: "4222"` on namespace or Service | `appProtocol: tcp` on the Service port, or `traffic.sidecar.istio.io/excludeInboundPorts` |
| Auto-detect HTTP | Yes, by default on standard ports | Yes, but can be overridden with `appProtocol` |
| gRPC | Detected automatically | Set `appProtocol: grpc` on Service port for correct metrics |

At work you'll see Service ports annotated with `appProtocol`:

```yaml
ports:
  - name: grpc
    port: 50051
    appProtocol: grpc   # tells Istio to parse as gRPC, not HTTP/1.1
  - name: nats
    port: 4222
    appProtocol: tcp    # skip HTTP parsing
```

---

### The Mental Model Stays the Same

Everything you built in the homelab translates directly:

- **Namespace annotation/label → sidecar injection.** Same mechanism, different keyword.
- **mTLS is the default behavior.** Istio just makes you declare enforcement explicitly with `PeerAuthentication`.
- **Traffic policy is YAML, not app code.** The resource kind changes (`HTTPRoute` → `VirtualService`), the concept doesn't.
- **Golden metrics come from the proxy.** Whether it's Linkerd's Rust proxy or Envoy, both expose the same three numbers: success rate, RPS, latency.
- **Kiali = `linkerd viz dashboard`.** Same graph, same data, different UI.
- **`istioctl analyze` = `linkerd check`.** Run it first when something breaks.

The main thing Istio adds on top of what you learned: `DestinationRule` for fine-grained
load balancing and circuit breaking, `PeerAuthentication` to explicitly enforce mTLS, and
`AuthorizationPolicy` for L7 access control (who can call what endpoint). All of those
are additive — they don't change the mental model you built here.
