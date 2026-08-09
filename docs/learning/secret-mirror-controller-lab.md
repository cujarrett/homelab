# Secret Mirror

> **The one idea (grug):** you declare a thing. The controller makes the world match, forever. Nobody tells it what changed — it is handed your declaration and works out the rest every time. Delete a copy and it comes back. That is the whole job.

`SecretMirror` says "this Secret should exist in every namespace with this label". The controller makes that true and keeps it true.

## Index

| Chapter | What it covers |
|---|---|
| [What it solves](#what-it-solves) | The real problem, stated without overselling |
| [Shape](#shape) | The CRD, and what the controller does with it |
| [Two rules](#two-rules) | Never clobber a Secret it does not own, and why the finalizer is a choice |
| [Build order](#build-order) | Ten steps with checkpoints — the lab itself |
| [What this skipped](#what-this-skipped) | Optional follow-on reading, after the build |
| [What this teaches](#what-this-teaches) | Concept checklist, and what it skips |
| [Parked candidates](#parked-candidates) | Follow-on projects |

## What it solves

[launchpad-api](https://github.com/cujarrett/launchpad-api) currently copies TLS Secrets from the `demo-certs` namespace into each sandbox namespace so cert-manager never has to issue them. It does this once, at namespace creation, with a `Create` that swallows `AlreadyExists`, wrapped in a retry ticker.

Worse, that copy is racing ArgoCD. The namespace does not exist when the goroutine starts — it was only just committed to git — so the loop retries once a second and gives up after thirty. If a sync runs slow, the sandbox comes up with no TLS Secret, cert-manager sees an Ingress with no certificate, and starts issuing against the exact hostnames the `demo-certs` scheme exists to keep away from Let's Encrypt's rate limiter.

A controller does not guess when a namespace is ready. It is told. There is no timeout to exceed and no give-up branch to write.

The renewal case comes free on top: when a source cert renews every sixty days, every copy follows. Sandboxes are short-lived so that rarely bites in practice — the timeout is the live failure, the staleness is the bonus.

**Prerequisite before this is useful for real.** `RenderNamespace` in `launchpad-api` emits a Namespace with no labels, so there is nothing to select on. It needs to stamp `launchpad.local.lab/slot: <slot>` at creation. That is a one-line change reaching the cluster through git and ArgoCD like everything else, and it is worth doing separately from the controller — the lab runs entirely on scratch namespaces until then.

## Shape

One CRD, one CR per mirrored Secret, one controller. It creates real Secrets in real namespaces.

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: SecretMirror
metadata:
  name: demo1-tls
spec:
  source:
    namespace: demo-certs
    name: demo1-tls
  targetNamespaceSelector:
    matchLabels:
      launchpad.local.lab/slot: demo1
status:
  copies: 0           # selected namespaces holding an up-to-date copy
  conditions: []      # Ready, SourceMissing
  observedGeneration: 0
```

Cluster-scoped, because it spans namespaces by definition.

Selection is by label, never by name — guests choose their own workspace names, so there is no pattern to match on. The label has to name the *slot* rather than just marking a namespace as a sandbox, because the Secrets are per-slot: a blanket `sandbox: "true"` would copy `demo1`'s cert into `demo3`'s namespace. One `SecretMirror` per slot, each selecting the single namespace currently holding it, or none while the slot is free.

Each reconcile does the same four things regardless of what triggered it — read the source, work out which namespaces match, make every one of them hold an identical copy, and remove copies from namespaces that no longer match.

## Two rules

**Never touch a Secret it did not create.** Every copy gets a label naming the `SecretMirror` that owns it. If a Secret already exists at the target name without that label, leave it alone and report it. A controller with write access to Secrets in every namespace must not clobber something a human put there.

**The finalizer is chosen, not forced.** ownerReferences would work — the disallowed case is a *cross-namespace* owner, and a cluster-scoped `SecretMirror` may legally own a Secret in any namespace, so garbage collection would clean the copies up on its own. What a finalizer adds is certainty about *when*: the mirror survives until the controller has confirmed every copy is gone, so deleting a mirror and immediately recreating it cannot race a collection still in flight. That is the whole technical gain. The other half of the reason is that finalizers are worth knowing and this is a cheap place to write one.

This has nothing to do with pruning. Removing a copy from a namespace that stopped matching is ordinary reconcile work in step 5, and happens while the mirror is very much alive.

## Build order

Ten steps. Stop at each **Checkpoint** — that is where the idea lands. No code is written ahead of time; ask for each piece when you reach it.

### 0. Prerequisites

```bash
kubebuilder version   # v4.15.0
go version            # 1.24+
```

Nothing here touches the cluster until step 3, and even then only a scratch namespace.

### 1. Scaffold

```bash
mkdir -p ~/Developer/secret-mirror-controller && cd ~/Developer/secret-mirror-controller
kubebuilder init --domain local.lab --repo github.com/cujarrett/secret-mirror-controller
kubebuilder create api --group platform --version v1alpha1 --kind SecretMirror --resource --controller
```

Answer yes to both prompts. `--repo` is only the Go module path — no GitHub repo needs to exist yet, but it must match where the repo eventually lives or every import is a lie.

**Checkpoint:** those are the only two kubebuilder commands in the whole project. Everything after this is Go and `make`. Look at what landed:

| Path | What it is |
|---|---|
| `api/v1alpha1/secretmirror_types.go` | the CRD, written as a Go struct |
| `internal/controller/secretmirror_controller.go` | the reconcile loop |
| `cmd/main.go` | builds the manager, registers the controller, starts it |
| `config/` | generated YAML — never hand-edit |
| `Makefile` | the codegen entrypoint, kept even though the rest of the homelab uses `just` |

### 2. The type

Write the spec and status from [Shape](#shape) into `secretmirror_types.go`, then:

```bash
make generate manifests
```

Things to get right: `+kubebuilder:resource:scope=Cluster`, `+kubebuilder:subresource:status`, and printcolumns for copies and Ready so `kubectl get secretmirror` is readable.

**Checkpoint:** open `config/crd/bases/platform.local.lab_secretmirrors.yaml`. Every field, default, and column came from a Go struct tag or a `+kubebuilder` comment. That translation is all CRD authoring is.

### 3. Make one copy

The smallest thing that does something. Reconcile reads the source Secret, lists namespaces matching the selector, and makes each one hold a copy — creating it if absent, correcting it if it has drifted, leaving it alone if it is already right. No pruning, no finalizer, no status yet.

That last distinction is the whole job. A reconcile is not a create; it is a decision taken fresh every time, per target namespace:

| Target Secret | Owned by this mirror | Matches source | Action |
|---|---|---|---|
| missing | — | — | create |
| exists | yes | no | update |
| exists | yes | yes | no-op |
| exists | no | either | leave alone, report conflict |
| exists, namespace no longer selected | yes | either | delete |

Step 3 handles the first three rows, step 4 the fourth, step 5 the fifth.

Set up a scratch source and target rather than touching `demo-certs`:

```bash
kubectl create namespace mirror-src
kubectl create namespace mirror-dst
kubectl label namespace mirror-dst mirror-test=true
kubectl create secret generic hello -n mirror-src --from-literal=greeting=hi
```

Then `make install`, apply a `SecretMirror` pointing at it, and `make run`.

**Checkpoint:** the payoff. Delete the copy and watch it return.

```bash
kubectl get secret hello -n mirror-dst
kubectl delete secret hello -n mirror-dst
kubectl get secret hello -n mirror-dst
```

Nothing scheduled that. The controller was watching, saw the world stop matching the declaration, and fixed it. That is Kubernetes in one command.

### 4. Do not clobber

Add the ownership label to every copy, and refuse to modify a Secret at the target name that lacks it.

**Checkpoint:** create an unlabelled `hello` Secret by hand in a matching namespace. The controller must leave it exactly as it is and say so, rather than overwrite it.

### 5. Prune

A namespace that stops matching the selector should lose its copy. Find copies by label across all namespaces, and delete the ones no longer wanted.

**Checkpoint:** `kubectl label namespace mirror-dst mirror-test-` and watch the copy disappear. Re-add the label and watch it return.

This is the step that earns its keep in production: when a sandbox is torn down and its slot is handed to a new one, pruning is what stops a stale copy lingering.

### 6. Finalizer

Deleting the `SecretMirror` must remove every copy. Add the finalizer, and do the cleanup in the deletion branch.

Two traps to handle:

- Cleanup must be safe to run twice, because a failure requeues and runs it again.
- A finalizer that can never succeed leaves the object stuck in `Terminating` forever, and someone has to strip the field by hand.

**Checkpoint:** test the alternative before writing it. Put an ownerReference to the cluster-scoped `SecretMirror` on a copy in another namespace, delete the mirror, and watch GC remove the copy within seconds. It works — which is the point. The finalizer is not what makes deletion possible; it only decides whether the mirror disappears before or after its copies do.

### 7. Watches

So far only changes to the `SecretMirror` itself trigger anything. Add watches so the controller reacts to the world:

- Secrets, so a renewed source propagates to every copy
- Namespaces, so a newly labelled namespace gets a copy without anyone editing the CR

Both need a map function to translate the event into the `SecretMirror` that cares about it.

**Checkpoint:** edit the source Secret and watch every copy update. Then label a brand new namespace and watch a copy appear in it. Neither action touched the CR.

### 8. Status and events

Set `copies`, `observedGeneration`, and conditions — `Ready` when everything is in sync, something explicit when the source is missing. Emit Events so `kubectl describe secretmirror` explains itself.

`observedGeneration` is what tells a reader whether the status refers to the spec they are looking at.

**Checkpoint:** delete the source Secret. The status should say so plainly, and existing copies should be left alone rather than deleted — losing the source is not the same as being told to remove the copies.

### 9. RBAC and deploy

`make run` uses your admin kubeconfig, so RBAC mistakes stay invisible. Running as a pod under its own ServiceAccount is the only way to find out what permissions are actually missing.

ARM64 image, deployed under ArgoCD. RBAC needs read and write on Secrets cluster-wide, read on Namespaces, and write on its own status.

Cluster-wide write on Secrets is real power. This is why step 4 exists.

### 10. Test with envtest

Unit-test the pure parts first — namespace selection and the decision of what to create, update, skip, or delete. Then envtest for the reconcile loop: create, prune, source-missing, and delete-with-finalizer.

Steps 9 and 10 are the stretch goals. Stop after step 8 if the afternoon is gone; everything above stands on its own.

## What this teaches

Scaffolding, CRD schema and markers, the status subresource, conditions, `observedGeneration`, printcolumns, typed clients, label selectors, `Watches` with map functions, drift correction, finalizers and idempotent cleanup, when ownerReference GC applies and when a finalizer is the better path, Events, RBAC that actually bites, envtest, ARM64 images, GitOps deploy.

It leaves owned-resource garbage collection mostly untouched — step 6 proves GC would work, then deliberately does the cleanup by hand instead. [`Backup`](#parked-candidates) is the candidate that actually leans on it. For the rest, see [What this skipped](#what-this-skipped).

Honest caveat: emberstack/reflector and kubed already do this. The value here is a small thing fully understood rather than a novel capability.

## What this skipped

Optional, and better read after the build than before — each item lands once you have hit the shape it describes.

**Server-side apply, field managers, ownership conflicts.** Who owns which field when two controllers write the same object, and what happens when they disagree. `ServerSideApply: true` is on nearly every app in this cluster, so read `.metadata.managedFields` on a real object and work out who owns what.

**Crossplane mapped onto kubebuilder.** The highest-value item here for the day job, because you already run one controller platform daily. XRD maps to CRD plus schema, Composition to reconcile logic, composed resources to owned resources, `crossplane.io/composition-resource-name` to owner references, and a composition function to a single stateless step inside someone else's reconcile loop. Two systems, one model — moving fluently between them turns KRM from a topic into a lens.

**Webhooks and CEL validation.** Validating and defaulting webhooks reject bad specs before they persist; CEL rules in the CRD are the lighter option covering most of the same ground without running a webhook server. Multi-version CRDs and conversion belong here too.

**`ctrl.Result{Requeue: true}` versus returning an error.** Both re-run the reconcile. They differ in backoff and in whether the controller counts it as a failure, and picking the wrong one is a common way to build an accidental hot loop.

**The model underneath, if you want it** — the KRM spec (`kubernetes/design-proposals`, `resource-management`) and the API conventions doc. Why status is separate from spec, and why every field has to be declaratively settable.

## Parked candidates

- **Entra app registration** — an `Identity` CR that provisions a Microsoft Entra app registration and writes the credentials back into a Secret. The most true-to-work shape there is: declare a CR, provision an external thing, clean it up on delete. App registrations are free tier. The tenant, the controller's own registration, and admin consent are the time sink, not the Go — so it deserves its own session.
- **`Backup`** — scheduled WordPress and PVC backups. Spec of source, schedule, retention; creates and owns a `CronJob`, derives status from the Job. Clean, but the real work is backup scripting rather than controller logic.
- **`SandboxLease`** — TTL on Launchpad demo namespaces. The only candidate that teaches time-based reconcile via `RequeueAfter`.
- **`ConnectionGraph`** — aggregate `provides` and `consumes` across [`Api`](../../platform/api/) and [`Spa`](../../platform/spa/) into a graph, flagging where caller and callee disagree. Real value, since nothing checks that agreement today, but a pure aggregator skips the create-and-own half of the framework.
