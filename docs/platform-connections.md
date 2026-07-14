# Platform-Managed Connections Plan

This plan covers how workloads on the platform register and enforce network connections — to each other and to the outside world.

An internal developer platform's job is to take decisions that are easy to get wrong and expensive to audit later — like who can talk to whom, and what's allowed to leave the cluster — off individual app teams and make them a platform primitive instead. Declaring connections through the platform means every one is consistent, visible, and enforced by construction, rather than hand-rolled mesh policy scattered across app repos and drifting unnoticed.

**Decision: Istio is the enforcement layer, deployed sidecar mode first and migrated to ambient.** Cilium stays underneath as the CNI; connection policy belongs to Istio. (The specific objects Istio uses are covered in Architecture, below.)

---

## Requirements

1. **No workload external calls leave the platform unless the connection is registered.** A workload cannot reach any host outside the cluster (public internet, LAN) unless the platform has an explicit declaration for that destination. Non-workload traffic keeps working unchanged (requirement 4).
2. **In-platform connections use mTLS and only work when registered.** Workload-to-workload traffic requires cryptographic workload identity (SPIFFE/mTLS), and the connection itself must be declared — identity alone is not authorization.
3. **"Registered" means declared through the platform.** Ultimately a Crossplane XR (working name `XConnection`); the composition renders the Istio enforcement objects. Dev teams never hand-write mesh CRDs.
4. **Scope: `XApi`/`XSpa` workload namespaces only.** Default-deny applies only to platform-managed namespaces (XR workspaces + POC namespaces). Everything else is out of scope and keeps working unchanged: system namespaces (`argocd`, `monitoring`, `cert-manager`, `kube-system`, `crossplane-system`) stay open for now — locking those down broke ArgoCD/Grafana/cert-manager during the Linkerd → Cilium migration, a separate later campaign; WordPress (`mattjarrett-com`, `kentjarrett-com`) and Ghost (`blog`) are excluded permanently, not "for now" — they're third-party code the platform doesn't control, and enumerating their outbound calls (plugin update checks, update pings) isn't worth the effort for the security value it buys.
5. **v1 `XConnection` covers HTTP only, `XApi`→`XApi` and `XApi`→external.** An `XApi`'s existing integrations with `XCache`, `XSql`, `XNoSql`, `XObjectStorage`, `XTopic`, and `XSubscription` never go through a registered `XConnection` — they stay exactly as they work today, covered by baseline (below); nobody declares a connection to their own co-provisioned cache, bucket, topic, or subscription. `XTopic`/`XSubscription` (NATS) get baseline treatment too, but need `nats` itself to join the mesh — see "NATS, `XTopic`, `XSubscription`" below. **Off-platform SQL** (an `XApi` reaching a database outside the platform) is a real future need but a deliberately separate chapter — not solved here.

**Non-goals (v1):** canary deployments, traffic shaping, and advanced mesh tuning. `XConnection` decides *whether* a connection is allowed, not *how* its traffic behaves — that's a different, later problem (see "future traffic management" in open questions).

---

## Architecture — Istio, sidecar first, then ambient

Two phases: **sidecar** (per-pod Envoy, full L7 — injection, `istio-proxy` containers, `istioctl proxy-config`), then **migrate the same namespaces to ambient** (per-node ztunnel for L4 mTLS, waypoint proxies where L7 is needed) — a deliberate rehearsal of a sidecar→ambient migration end to end.

Requirement mapping (identical objects in both phases — the point of Istio's API):

- **Registration → `AuthorizationPolicy`.** Deny-by-default per namespace, one ALLOW policy per connection keyed on SPIFFE principal (`cluster.local/ns/poc-caller/sa/authorized-caller`) — identity is the service account, not labels.
- **Internal mTLS → `PeerAuthentication: STRICT`.** Real per-connection mTLS with workload certs.
- **External egress → `outboundTrafficPolicy: REGISTRY_ONLY` + `ServiceEntry`.** The mesh refuses any destination not in its service registry. A `ServiceEntry` *is* the registration.
- **Default deny →** `REGISTRY_ONLY` (egress) + a namespace-wide deny `AuthorizationPolicy` (ingress).

What differs between the phases:

| | Sidecar phase | Ambient phase |
|---|---|---|
| Data plane | `istio-proxy` Envoy container injected per pod | ztunnel DaemonSet (L4); waypoint proxy per namespace only if L7 rules needed |
| L7 policy (paths/methods) | Free — every pod already has Envoy | Requires deploying a waypoint |
| Pod spec impact | Every meshed pod restarts with an extra container | No pod spec change; enrollment is a namespace label |
| Memory cost | ~40–60Mi per injected pod + istiod | ztunnel per node + istiod; waypoints only where used |
| Cilium interop surface | Smaller — known issue is socket-level LB bypassing the sidecar; fix is `socketLB.hostNamespaceOnly: true` | Larger — ztunnel traffic redirection vs Cilium's eBPF datapath |

**Risks to validate early:**
- **Cilium interop is the big risk** (flags and steps in POC phase 1, step 1). Ambient adds further documented conflicts between ztunnel redirection and Cilium's eBPF datapath.
- **Pi memory cost is why ambient, not sidecar, is the steady state** (see Memory cost row above). Measure istiod, sidecar, ztunnel, and waypoint usage as you go; the cluster already runs 365d-retention Prometheus and Longhorn.
- **mTLS coverage stops at the mesh boundary.** System namespaces stay unmeshed (requirement 4), protected by WireGuard node encryption only.

**Enrollment vs enforcement — two independent dials.** Being *in* the mesh (sidecar injected / ambient label) is separate from being *locked down* (`STRICT` + deny-by-default + `REGISTRY_ONLY`). Enrollment alone is the Linkerd-style permissive experience: mTLS when both sides are meshed, plaintext still accepted, nothing denied — zero breakage risk, but every flow now visible in mesh telemetry with workload identity. Rollout uses this deliberately: **enroll broadly in permissive mode first (ambient phase — one label per namespace), watch telemetry to inventory real connections, then enforce namespace-by-namespace once its observed flows are all registered.** Permissive mode satisfies none of the requirements — it's the on-ramp that writes the XConnection list, not the destination.

**mTLS policy decision: always on, not a flag.** Every registered in-platform connection gets `STRICT` mutual TLS, baked into the composition. No `mutualAuth: true` for teams to forget; a connection either is platform-managed (and authenticated) or doesn't exist. External (`ServiceEntry`) connections are the only unauthenticated kind, by nature.

---

## Test apps

Two Go apps, deployed as three workloads, in POC namespaces. Same structure as the Death Star demo, applied to the platform:

| App | Role | Proves |
|---|---|---|
| `api` | Upstream API, restricted. Go, serves `GET /api/v1/data` on 8080. | Ingress registration + mTLS |
| `caller` | Generic caller. Go, serves `GET /api/call` (calls `api`) and `GET /api/weather` (calls a **registered** external FQDN, e.g. `api.open-meteo.com`) and `GET /api/leak` (calls an **unregistered** FQDN, e.g. `example.com` — must fail). Deployed **twice**, as `authorized-caller` and `unauthorized-caller` — same image, same code, different service account. Identity is the only variable, which is the point: enforcement is proven by identity, not by anything the caller's code does. | Egress registration, internal + external; identity-based enforcement |

Code: [`platform-connections-poc`](https://github.com/cujarrett/platform-connections-poc) (sibling repo to `homelab`, not yet pushed) — `api/` and `caller/` are already scaffolded locally and build cleanly. Both follow the standard Go app conventions (`just ci`, stdlib `net/http` + `slog`, `signal.NotifyContext`, `/healthz`). Scaffold with the `/new-go-api` skill (`.claude/commands/new-go-api.md`). Deploy as plain manifests in `poc-api` / `poc-caller` (both `caller` instances in `poc-caller`) — **not** as XApi instances yet; the POC must not depend on composition changes.

### Success matrix (run in the sidecar phase, re-run after the ambient migration)

| # | Check | Expected |
|---|---|---|
| 1 | `authorized-caller → api` GET /api/v1/data | **Allowed**, and only over mTLS |
| 2 | Same, after swapping authorized-caller's service account | **Denied** — identity is enforced, not just reachability |
| 3 | `unauthorized-caller → api` | **Denied**, visible in mesh telemetry |
| 4 | `authorized-caller → api.open-meteo.com` (registered `ServiceEntry`) | **Allowed** |
| 5 | `authorized-caller → example.com` (unregistered) | **Blocked** by `REGISTRY_ONLY` |
| 6 | `unauthorized-caller → example.com` | **Blocked** |
| 7 | Traefik → api Ingress, Prometheus scrape → both apps, kubelet probes | **Still work** — baseline allows are sufficient (Prometheus scraping a STRICT-mTLS pod is a known wrinkle to solve here) |
| 8 | DNS resolution from all pods | **Works** |

### Baseline allow policy (per default-denied workload namespace)

Default deny alone bricks a namespace. Each managed namespace needs a baseline allowing:
- **Ingress:** Traefik (kube-system DaemonSet) → app port, for apps with an Ingress
- **Ingress:** Prometheus (monitoring namespace) → metrics port
- **Egress:** DNS to kube-dns
- **Egress (internal):** an `XApi` → its own co-provisioned `XCache`/`XSql`, same namespace, in-cluster. Not a registered connection — provisioned together, no cross-boundary trust decision to make (requirement 5).
- **Egress (external):** an `XApi` → its own `XNoSql` (DynamoDB) / `XObjectStorage` (S3). These are AWS API calls leaving the cluster, so they need a `ServiceEntry`, not just an internal allow — but the same logic applies: it's the `XApi`'s own resource, so the `XNoSql`/`XObjectStorage` composition renders that `ServiceEntry` itself as baseline. No `XConnection`, no developer action.
- **Egress (internal, cross-namespace) → `nats`:** an `XApi` with `topicRef` (publish) or `subscriptionRef` (consume) set. `XTopic`/`XSubscription` compositions already render their NACK `Stream`/`Consumer` objects into the `nats` namespace regardless of which app owns the XR — so this is always cross-namespace, unlike `XCache`/`XSql`. Still not a registered `XConnection`: `nats` is a platform-owned shared service, not a peer team's namespace, so there's no consent decision to make, just a policy to render. The `XApi` composition already knows the calling SA and, from `topicRef`/`subscriptionRef`, exactly which stream/consumer it's allowed to touch — it renders the matching `AuthorizationPolicy` ALLOW into `nats` as a side effect of setting either ref. L7 doesn't apply (NATS isn't HTTP); enforcement is L4 only — "can this SA reach NATS' port," not "which subjects can it touch." Subject-level authorization stays NATS' own job (JetStream Stream/Consumer scoping), same as today. Requires `nats` to actually join the mesh — it's currently outside platform scope; do that as part of the observation stage like any other namespace, then flip it to STRICT + deny once every real publisher/consumer's `AuthorizationPolicy` is rendered.

Without these three, flipping a namespace to default-deny silently breaks every workload with an in-cluster store, an AWS-backed store, or a NATS topic/subscription.

Everything else comes from registered connections. This baseline should eventually be rendered by the workload compositions (XApi/XSpa) — a workload's own composition declares "I can be scraped, ingressed, and reach my own backing stores," a *connection's* XR declares everything else.

---

## POC steps

### Phase 1 — sidecar mode

   The interop spike is split across steps 1 (Cilium prep) and 2 (Istio install). No fallback stack — if either destabilizes the cluster, stop and debug; interop gates the rest of the plan.

1. **Cilium prep (done).** In Cilium's Helm values: `cni.exclusive: false`, `socketLB.hostNamespaceOnly: true`, `authentication.enabled: false` and `mutual.spire.enabled: false` (Istio owns mTLS). Roll the agents to apply.
2. **Istio install (done).** istiod + Istio CNI plugin (chart 1.30.2) in sidecar mode as an ArgoCD app; istiod pinned to ctrl-1. istio-cni chains onto Cilium (`plugins: [cilium-cni, istio-cni]`); fresh pods still get IP + DNS; Traefik/Prometheus/Longhorn/NATS unaffected.
3. **Scaffold + deploy (next).** `api`, `authorized-caller`, `unauthorized-caller` in `poc-api` / `poc-caller`. Confirm everything works unmeshed (baseline traffic flows).
4. Label `poc-*` namespaces for injection (`istio-injection: enabled`); restart deployments and confirm `istio-proxy` containers appear. Poke at Envoy: `istioctl proxy-config listeners/clusters/routes`, `istioctl proxy-status`.
5. `PeerAuthentication: STRICT` on the `poc-*` namespaces.
6. Namespace-wide deny `AuthorizationPolicy` + baseline allows. Verify matrix rows 3, 7, 8.
7. ALLOW policy for `authorized-caller → api` keyed on service-account principal, including an L7 rule (GET `/api/v1` only — free in sidecar mode). Verify rows 1, 2.
8. `outboundTrafficPolicy: REGISTRY_ONLY` (scoped if possible) + `ServiceEntry` for `api.open-meteo.com`. Verify rows 4, 5, 6.
9. Wire Istio telemetry into Prometheus/Grafana; record sidecar per-pod memory + istiod overhead.

### Phase 2 — migrate the same namespaces to ambient (migration rehearsal)

10. Install the ambient data plane (ztunnel DaemonSet); confirm coexistence with sidecar-phase workloads.
11. Migrate `poc-*` namespaces: remove the injection label, add `istio.io/dataplane-mode: ambient`, restart pods (sidecars gone). Re-run the full matrix — note which `AuthorizationPolicy` semantics changed (L4 rules should hold; the L7 rule from step 7 now needs a waypoint).
12. Deploy a waypoint for `poc-api` to restore the L7 rule; re-verify. Note the operational delta — the per-namespace tradeoff any sidecar→ambient migration faces.
13. Document the migration steps + gotchas. Record ambient overhead vs sidecar.
14. Decide the platform's steady-state mode (expected: ambient, for Pi memory reasons).

---

## After the POC: platformize as `XConnection`

**The workload owns its baseline; the connection owns the relationship.** Metrics, logging, tracing, DNS, ingress, and a workload's own backing stores are the workload composition's job (see "Baseline allow policy," above). `XConnection` expresses nothing but the relationship itself — "`authorized-caller` depends on `api`" — and stays mesh-agnostic: no Istio-specific concepts leak into what a dev team writes. If the mesh ever changes (e.g. off Istio), only the `XConnection` composition changes — not every existing `XConnection` instance.

Wrap the winning objects in an XRD + composition (`platform/connection/`). Sketch:

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XConnection
metadata:
  name: foo-to-bar
spec:
  parameters:
    from:
      namespace: foo-ns
      serviceAccount: foo        # identity is the SA — Istio principal
    to:
      # exactly one of `service` or `external`
      service:
        namespace: bar-ns
        appLabel: bar
        port: 8080
        httpPolicy:              # optional L7 rules — requires a waypoint in ambient
          allowPaths:
            - path: /api/v1
              method: GET
      external:
        fqdn: api.example.com
        port: 443
        secretRef: my-vinyl-api-discogs-token   # optional; a Secret already kubectl-created in the same namespace, injected as an env var — no XSecret abstraction yet
```

- Internal connections: composition renders the `AuthorizationPolicy` with mTLS **always required** — no flag.
- External connections: composition renders the `ServiceEntry`. `external` is the *only* way traffic leaves the platform from a managed namespace. `secretRef` is optional and only for the credential the external call needs (e.g. an API key) — it doesn't touch mesh enforcement.
- Standalone XRD rather than a field on XApi, so connections can involve non-XApi endpoints later; revisit a convenience `connectionRefs` on XApi only after the standalone pattern has repeated three times (grug rule).
- The workload compositions (XApi/XSpa) additionally render the namespace baseline (mesh enrollment label, default deny, Traefik + Prometheus allows) so a managed namespace is born locked down.
- **Acceptor pattern (resolves "who may declare a connection into another namespace"):** the target must consent. `XApi`/`XSpa` compositions gain an `acceptedCallers: []` parameter — identities allowed to have ingress `AuthorizationPolicy` rendered into that namespace. An `XConnection`'s internal ALLOW only renders if `from.serviceAccount` appears in the target's `acceptedCallers`; otherwise the `XConnection` reports `Ready: False` (reason `NotAccepted`) and renders nothing — declaring a connection is not the same as the target granting it. Validate directly with the POC apps once onboarded (rollout step 6): `authorized-caller` is in `api`'s `acceptedCallers` and gets the ALLOW; the same `XConnection` shape for `unauthorized-caller` (not on the list) must be actively refused, not just absent.
- First real candidates once the XRD exists: internal — `authorized-caller → api` itself, once the POC apps convert (rollout step 6); external — `my-vinyl-api → Discogs`, which is unregistered today and needs an API key via `secretRef`.

### Long-run shape of the POC apps in `homelab-workspaces`

Once converted (rollout step 6), the POC lives as four XRs:

| XR | Kind | Role |
|---|---|---|
| `api` | `XApi` | Protected upstream service |
| `authorized-caller` | `XApi` | The `caller` image, granted a connection to `api` via `XConnection` |
| `unauthorized-caller` | `XApi` | The same `caller` image, no `XConnection` granted — denied by default |
| (name TBD) | `XSpa` | Demo frontend: one button calls `authorized-caller`'s endpoint and shows the allowed response, another calls `unauthorized-caller`'s and shows the denial — the mesh decision made visibly interactive instead of a success-matrix table |

### Rollout order

1. POC phase 1 (sidecar) — interop spike gates everything
2. POC phase 2 (ambient migration); pick steady-state mode
3. Record findings + decisions in this file
4. **Observation stage:** enroll all meshable `XApi`/`XSpa` workload namespaces, **and `nats`**, in ambient **permissive** mode (no STRICT, no deny policies, egress stays `ALLOW_ANY`). Zero enforcement, zero breakage risk. Watch mesh telemetry for a couple of weeks to inventory every real internal and external flow. This inventory *is* the XConnection backlog. Excluded regardless of mode: WordPress and Ghost (requirement 4), hostNetwork pods (Traefik, AdGuard), Longhorn data path, `kube-system` — WireGuard keeps covering those.
5. `platform/connection/` XRD + composition reproducing the POC's hand-written objects; `argocd app sync platform-definitions`
6. Convert POC apps to XApi + XConnection instances in `homelab-workspaces` — proves the GitOps flow end-to-end, and validates the acceptor pattern (`authorized-caller` accepted, `unauthorized-caller` refused)
7. Bake namespace baseline + mesh enrollment into XApi/XSpa compositions, **and add `AuthorizationPolicy` rendering to the `XApi` composition's `topicRef`/`subscriptionRef` handling** so publishing/subscribing to NATS is registered automatically
8. Register each namespace's observed connections as XConnections, then flip that namespace to STRICT + deny — one namespace at a time, only after its observed flows (including any `nats` dependency) are all registered, watching mesh telemetry for denials. Flip `nats` itself to STRICT + deny only after every real publisher/consumer's `AuthorizationPolicy` is rendered per step 7.
9. Grafana: panel for denied-connection count by namespace — the "missing registration" alarm (mesh telemetry; keep Hubble panels for the unmeshed layer)
10. **Out of scope for now:** system namespaces (`argocd`, `monitoring`, `cert-manager`, `crossplane-system`, `kube-system`) — enrollment may extend there during the observation stage if harmless, but *enforcement* is a separate future campaign
11. **Phase 3 — Temporal approval workflow** (below): only after `XConnection` exists (step 6). Today, granting a connection means a dev PRs an `XConnection` into `homelab-workspaces`; Phase 3 automates that path.

---

## Phase 3 — Temporal approval workflow

Not v1. Requires `XConnection` to already exist (rollout step 6) — this automates *requesting* a connection, it doesn't change how one is enforced.

Today, getting a connection granted means hand-writing an `XConnection` and opening a PR. Phase 3 replaces that with a request/approval flow, using tools already decided elsewhere in this stack:

- **Requestor:** Launchpad — no new front-end (no Backstage). Launchpad already exists as the platform's self-service surface; this is a new capability on it, not a new service.
- **Orchestration:** Temporal runs the workflow — request → notify the target's owner → approval → commit the `XConnection` into `homelab-workspaces` (reusing the same GitHub Contents/Git Data API pattern `launchpad-api` already uses for demo sandboxes) → wait for Crossplane/Istio to report the connection `Ready` → notify the requestor.
- **Ownership split:** Crossplane owns desired state; Temporal owns the human workflow around *getting to* that desired state; Istio enforces the runtime policy. Temporal never talks to Istio directly — it only ever writes GitOps commits and watches XR status, same as a human would.

This is real future work, not a placeholder — but it's explicitly sequenced after the POC and platformization, and doesn't block any of it.

---

## Open questions

1. **Resolved — Istio-over-Cilium interop on k3s/ARM64 works.** istio-cni chains onto Cilium (`cni.exclusive: false` + `socketLB.hostNamespaceOnly: true`); fresh pods still get IP + DNS, existing traffic unaffected. This was the pivotal gate.
2. **Prometheus scraping STRICT-mTLS pods** — permissive port-level exception, scrape through the mesh, or Istio's metrics merging? Solve in phase 1 step 6; whatever works becomes part of the baseline.
3. **Resolved — who may declare a connection into another namespace:** acceptor pattern. `XApi`/`XSpa` compositions gain `acceptedCallers`; an `XConnection`'s ALLOW only renders if the target lists the caller's identity. See "After the POC" and rollout step 6.
4. **Resolved — cloudflared / tunnel traffic:** WordPress and Ghost are excluded from this plan entirely (requirement 4), so their external phone-homes are never surfaced or blocked. The baseline + registered connections already cover the remaining `XApi`/`XSpa` workloads.
5. **Resolved — demo sandboxes (`demo{1-5}`):** they get a real managed connection, not an exclusion. launchpad, launchpad-api, and the sandboxes must keep working once enforcement lands — a maintenance page during the cutover is acceptable, permanent breakage isn't. Sandbox mesh enrollment + baseline + `XConnection`(s) must be baked into the sandbox-creation composition so a sandbox is never born without them; sequence this before default-deny reaches sandbox namespaces. Launchpad-api's own outbound calls (K8s API, GitHub API for workspace commits, etc.) need to be enumerated and registered too once its namespace is onboarded.
6. **Resolved — NATS, `XTopic`, and `XSubscription`:** `nats` joins the mesh like any other namespace. Registration isn't a generic `XConnection` — `XApi`'s existing `topicRef`/`subscriptionRef` fields already declare exactly what a publisher/consumer needs, so the `XApi` composition renders the matching `AuthorizationPolicy` into `nats` as a side effect of setting either ref. See the baseline section and rollout steps 4/7/8.
7. **Escape hatches:** no break-glass path exists yet for an unregistered connection that's urgently needed (e.g. debugging an incident). Needs an answer before any namespace flips to STRICT + deny in production use, not just for the POC.
8. **Retries/timeouts in `XConnection`?** Leaning no — non-goals already rule out traffic shaping, and this is the same category. `XConnection` decides *whether*, not *how*. Revisit only if a real need shows up.
9. **Long-term boundary of `XConnection` / future traffic management:** out of scope for this plan by design (non-goals). If canary/traffic-shaping needs ever show up, that's a separate proposal, not a scope-creep addition here.
