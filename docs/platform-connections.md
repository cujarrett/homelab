# Platform-Managed Connections

## Why

An internal developer platform should decide, by construction, who can talk to whom and what's allowed to leave the cluster — not leave it to hand-rolled mesh policy scattered across app repos, drifting unnoticed. Declaring a connection through the platform makes every one consistent, visible, and enforced the same way, with the team on each side of a connection in control of their own half.

## How (short version)

- **Istio** is the enforcement layer — `AuthorizationPolicy` for internal ALLOW/deny, `ServiceEntry` + `REGISTRY_ONLY` for egress, `STRICT` mTLS everywhere in-mesh, always on, not a flag. Sidecar mode today; ambient is the planned steady state (Pi memory).
- **Two namespace-scoped resources, not one cluster-scoped one.** A `ConnectionRequest` lives in the caller's own namespace ("I want to reach X"). A `ConnectionGrant` lives in the destination's own namespace — the thing that's actually enforced. Each object lives where the authority already belongs, so ordinary Kubernetes RBAC (not a bespoke permission model) decides who can request vs. who can approve or revoke.
- **Temporal** orchestrates the human approval step — notify the owner, wait for a decision — and, once approved, **commits the Grant's YAML to Git**. It never writes to the cluster directly. ArgoCD applies it like anything else. Git stays the single source of truth.
- **GitHub CODEOWNERS on the Grant paths is the actual enforcement boundary, not Temporal.** Anyone with ordinary repo-write access could otherwise bypass the whole request flow by hand-authoring a Grant and merging it. The same CODEOWNERS mapping doubles as "who to notify" for Temporal.
- **Egress (`toExternals`) skips the request flow entirely.** It only touches the caller's own namespace, so it stays self-service, same as today.

Read on for how the mesh mechanics actually work, what the POC has already proven, and the open questions still being worked through.

---

## Architecture — Istio mechanics

- **Registration → `AuthorizationPolicy`.** Deny-by-default per namespace, one ALLOW per connection keyed on SPIFFE principal (`cluster.local/ns/poc-caller/sa/authorized-caller`) — identity is the service account, not labels.
- **Internal mTLS → `PeerAuthentication: STRICT`.**
- **External egress → `outboundTrafficPolicy: REGISTRY_ONLY` + `ServiceEntry`.** A `ServiceEntry` *is* the registration; the mesh refuses anything not in its registry.
- **Enrollment vs. enforcement are two independent dials.** Being *in* the mesh (sidecar injected) is separate from being *locked down* (`STRICT` + deny + `REGISTRY_ONLY`). Rollout enrolls a namespace in permissive mode first (nothing denied, full telemetry) to inventory its real connections, then flips to enforced once every observed flow is registered.
- **Sidecar now, ambient later.** Same Istio objects in both phases. Ambient's ztunnel removes the per-pod Envoy memory cost (~40–60Mi/pod) that matters on Pi hardware; L7 rules need a waypoint proxy only where used.

**Risks already validated:** Istio-over-Cilium interop on k3s/ARM64 works (`cni.exclusive: false` + `socketLB.hostNamespaceOnly: true`, istio-cni chains onto Cilium, fresh pods still get IP+DNS). mTLS coverage stops at the mesh boundary — system namespaces (`kube-system`, `argocd`, `monitoring`, `cert-manager`, `crossplane-system`) stay out of scope, protected by WireGuard node encryption only, same as WordPress/Ghost (third-party code, permanently excluded).

## Scope (v1)

- Only `Api`/`Spa` workload namespaces get default-deny. System namespaces and third-party apps (WordPress, Ghost) are out of scope, not "for now."
- HTTP only, `Api`→`Api` and `Api`→external. A workload's own co-provisioned `Cache`/`Sql`/`NoSql`/`ObjectStorage`/`Topic`/`Subscription` never go through a registered connection — that's baseline, not a cross-team trust decision (see below).
- Non-goals: canary/traffic-shaping. A connection decides *whether* traffic is allowed, not *how* it behaves.

## Baseline (not a registered connection)

Default deny alone bricks a namespace. Every managed namespace needs, rendered by its own `Api`/`Spa` composition, not a `ConnectionRequest`:
- Ingress: Traefik → app port, Prometheus → metrics port
- Egress: DNS
- Egress: to its own co-provisioned `Cache`/`Sql` (same namespace) and `NoSql`/`ObjectStorage` (AWS, needs a `ServiceEntry` but still baseline — it's the workload's own resource)
- Egress: to `nats`, when `topicRef`/`subscriptionRef` is set — the `Api` composition already knows exactly which stream/consumer, so it renders the matching `AuthorizationPolicy` as a side effect, no separate request needed

Everything else goes through a registered connection.

## Test apps (POC)

Two Go apps, three workloads, in `platform-connections-demo` (sibling repo, not yet pushed):

| App | Role | Proves |
|---|---|---|
| `upstream-api` | Restricted upstream, `GET /api/v1/data` | Ingress registration + mTLS |
| `caller` | Calls `upstream-api` (`/api/call`), a registered external FQDN (`/api/weather`), and an unregistered one (`/api/leak`, must fail). Deployed twice — `authorized-caller` / `unauthorized-caller` — same image, only the service account differs. | Identity-based enforcement, internal + external egress |

**Full 8-row success matrix passes** (identity-based allow/deny, registered/unregistered external, Prometheus/DNS/probes unaffected) — sidecar phase complete. Ambient migration deliberately paused to dwell in sidecar mode first.

---

## The connection model: Request + Grant

A single cluster-scoped `Connection` (the original v1 sketch) let anyone who could author one grant *any* caller into *any* namespace, unilaterally — no RBAC could restrict that to "only the namespace's own team," because cluster-scoped resources can't be scoped by namespace RBAC. The fix: split into two namespace-scoped resources, each living where its authority actually belongs.

```yaml
# ConnectionRequest — lives in the CALLER's own namespace. Self-service: developer
# authors and views this with nothing but their own ordinary namespace RBAC.
apiVersion: platform.local.lab/v1alpha1
kind: ConnectionRequest
metadata:
  name: authorized-caller-to-upstream-api
  namespace: poc-caller
spec:
  to:
    namespace: poc-api
    appLabel: upstream-api
    port: 8080
    httpPolicy:
      allowMethods: ["GET"]
      allowPaths: ["/api/v1/*"]
status:
  phase: Pending   # Pending | Approved | Denied
  grantRef: ...     # set once approved
```

```yaml
# ConnectionGrant — lives in the DESTINATION's own namespace. The thing that's actually
# enforced. Created by Temporal only after the owner approves; that team can view, edit,
# or `kubectl delete` it any time using their own namespace RBAC — including to revoke,
# independent of whether the requester still wants it.
apiVersion: platform.local.lab/v1alpha1
kind: ConnectionGrant
metadata:
  name: authorized-caller-to-upstream-api
  namespace: poc-api
spec:
  from:
    namespace: poc-caller
    serviceAccount: authorized-caller
  port: 8080
  httpPolicy:
    allowMethods: ["GET"]
    allowPaths: ["/api/v1/*"]
```

Two controllers, single responsibility each:
- **Request controller** (watches `ConnectionRequest`): starts the Temporal workflow, updates status. Never touches Istio.
- **Grant controller** (watches `ConnectionGrant`): renders/deletes the `AuthorizationPolicy`. Never knows a workflow exists.

**Flow:** developer creates a `ConnectionRequest` → controller starts a Temporal workflow → Temporal notifies the destination's owner → owner approves (in Launchpad) → Temporal commits the `ConnectionGrant` YAML into `homelab-workspaces` (same GitHub Contents/Git Data API pattern `launchpad-api` already uses for demo sandboxes) → ArgoCD applies it → Grant controller reconciles → `AuthorizationPolicy` appears → traffic allowed.

`toExternals` (egress) doesn't go through any of this — the resulting `ServiceEntry` lands in the caller's own namespace, so no other team's perimeter is touched. Self-service, rendered directly, same as a workload's own baseline.

**Launchpad's role:** pass the signed-in user through to real Kubernetes RBAC (`SubjectAccessReview`) for view/edit decisions, rather than inventing a separate authorization model. Because Requests and Grants each live in the namespace their owner already controls, this falls out for free.

**Grant controller vs. Crossplane composition — undecided.** The transform is currently 1:1 (`Grant` → one `AuthorizationPolicy`), simple enough that a lightweight custom controller is tempting. But every other platform primitive (`Api`, `Spa`, `Cache`, ...) is a Crossplane composition using the same `function-go-templating` pattern — a bespoke controller means a second reconciliation technology to operate, not less complexity overall. Leaning custom controller; not committed.

---

## Rollout order

1. POC phase 1 (sidecar) — done, full matrix passing
2. POC phase 2 (ambient migration) — paused, deliberately not started yet
3. `Connection{Request,Grant}` XRDs/CRDs + controllers, replacing the old single-`Connection` sketch
4. Observation stage: enroll all `Api`/`Spa` namespaces (+ `nats`) in permissive mode, watch telemetry to inventory real flows — this inventory becomes the initial Request/Grant backlog
5. Convert POC apps (`upstream-api`, `authorized-caller`, `unauthorized-caller`) to real `Api` instances with a real `ConnectionRequest`/`ConnectionGrant` pair, proving the GitOps flow end to end
6. Bake namespace baseline + mesh enrollment into the `Api`/`Spa` compositions
7. Register each namespace's observed connections, then flip to `STRICT` + deny one namespace at a time, only after its flows are all registered
8. Temporal workflow + Launchpad UI for self-service requesting — automates step 5's manual PR path, doesn't change enforcement
9. CODEOWNERS on `homelab-workspaces` Grant paths, mapped by destination namespace — the actual approval-bypass backstop, and the source of "who to notify" for Temporal

System namespaces (`argocd`, `monitoring`, `cert-manager`, `crossplane-system`, `kube-system`) stay out of enforcement scope for now — a separate future campaign.

## Open questions

- **Split-brain state.** If a `Grant` is deleted directly (revoked), what reconciles the matching `Request`'s status back down? Cross-namespace owner references don't exist natively — needs an explicit watch, not garbage collection.
- **Temporal's git-push credential is a real trust boundary.** If it commits straight to `main`, that credential can write anything ArgoCD will apply — treat it like a sensitive, scoped credential, not a convenience token.
- **Re-approval on edit.** If an approved `Request`/`Grant` is later edited to widen scope (e.g. `GET /foo` → `GET /admin/*`), does that silently take effect, or does it need to flip back to `Pending`? Unanswered today — a privilege-escalation path if left open.
- **Namespace → approver mapping.** Needs to exist for Temporal to know who to notify; CODEOWNERS is the leading candidate since it solves the enforcement question too, but the mapping itself needs protecting (a requester shouldn't be able to self-appoint as approver).
- **Grant controller vs. Crossplane** — see above, not decided.
- **Escape hatch.** No break-glass path exists yet for an urgently-needed unregistered connection (e.g. incident debugging). Needed before any namespace flips to enforced in real use.
- **Prometheus scraping `STRICT`-mTLS pods** — solved for the fixed-shape POC; needs to generalize into the baseline once real workloads onboard.
