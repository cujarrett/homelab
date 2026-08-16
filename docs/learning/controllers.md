# Kubernetes Controllers

> **The one idea (grug):** you declare a thing, a controller makes the world match, forever.
> Nobody tells it what changed - it is handed your declaration and works out the rest, every
> time. That is the whole job. Everything below is detail.

The worked example throughout is [secret-mirror-controller](https://github.com/cujarrett/secret-mirror-controller),
built with kubebuilder and deployed by ArgoCD from [cluster/secret-mirror-controller/](../../cluster/secret-mirror-controller/).
Every section links to the code that does the thing.

## Index

| Chapter | What it covers |
|---|---|
| [A CRD is a registration form](#a-crd-is-a-registration-form) | How a new kind comes to exist |
| [Reconcile is a loop, not an event handler](#reconcile-is-a-loop-not-an-event-handler) | The idea everything else rests on |
| [Watches and map functions](#watches-and-map-functions) | Reacting to objects you do not own |
| [Ownership](#ownership) | Never modifying something you did not create |
| [Finalizers and ownerReferences](#finalizers-and-ownerreferences) | Cleaning up on delete |
| [Status](#status) | How an object explains itself |
| [RBAC and the cache have to agree](#rbac-and-the-cache-have-to-agree) | The first-controller wall |
| [Testing](#testing) | Fake client versus envtest |

## A CRD is a registration form

A `CustomResourceDefinition` teaches the API server a new noun. Apply one and `kubectl get
secretmirrors` starts working immediately, before any controller exists - the API server will
happily store objects nobody acts on.

With kubebuilder you never write that YAML. You write a Go struct, and `make manifests`
generates the CRD from it. Struct tags become field names, `+kubebuilder` comments become
schema and columns:

```go
// +kubebuilder:validation:MinLength=1
SourceSecret string `json:"sourceSecret"`
```

Three markers earn their keep:

- `+kubebuilder:subresource:status` splits status onto its own endpoint. Without it,
  `r.Status().Update()` silently does nothing, and `metadata.generation` stops being meaningful.
- `+kubebuilder:printcolumn` adds columns to `kubectl get`, free readability.
- `+required` and validation markers are enforced by the API server, so malformed objects never
  reach your code.

The spec is the user's half, the status is the controller's half. Never mix them.

## Reconcile is a loop, not an event handler

`Reconcile` receives a namespace and name. Not what changed, not the old value, not the event -
just "look at this object again".

```go
func (r *SecretMirrorReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error)
```

So it reads the world, compares it to the declaration, and fixes the difference. Every time,
from the top. That is why deleting a copy makes it come back: nothing scheduled a repair, the
next reconcile simply found the world wrong.

Two consequences worth internalising:

- **It must be safe to run twice**, because it will be. A failure requeues and runs it again.
- **Never assume what changed.** A reconcile triggered by a namespace label change and one
  triggered by a source Secret renewal run identical code.

The return value is a schedule, not a result. `ctrl.Result{}` means "done, wake me when
something happens". `RequeueAfter` means "look again in N", which is polling and usually a sign
you are missing a watch. Returning an error requeues with exponential backoff - so returning an
error **is** the retry mechanism.

## Watches and map functions

By default a controller only wakes for its own kind. To react to anything else you register a
watch plus a function that answers "which of my objects care about this?"

```go
.Watches(&corev1.Namespace{}, handler.EnqueueRequestsFromMapFunc(r.mirrorsForNamespace))
```

The map function receives the changed object and returns a list of requests. This is where the
domain logic lives, and where the subtle bug lives too: filtering by "does this namespace match
my selector" looks efficient but drops the most important event, because a namespace that just
*lost* its label matches nothing. Returning every candidate is often the correct answer.

`Owns()` is the common shortcut for children you created, but it works by following
ownerReferences, so it cannot help across namespaces.

## Ownership

A controller with write access must never modify something it did not create. Give every object
you create a label naming its owner, and check that label before writing:

- nothing there - create it, labelled
- there, wearing your label - yours, update it
- there, without your label - leave it alone and report the conflict

The third case is the whole rule, and it applies to deletes exactly as much as writes. A pruning
pass that skips the ownership check will eventually eat something a human put there.

A real upgrade hazard falls out of this: objects created before you added the ownership scheme
carry no label, so your own controller will refuse to touch them. Production operators handle it
with a one-off adoption pass.

## Finalizers and ownerReferences

Two ways to clean up when an object is deleted.

**ownerReferences** are the automatic one. Mark B as owned by A, and Kubernetes' garbage
collector deletes B when A goes. No controller code at all. The catch is that a namespaced owner
cannot own an object in another namespace - set the reference anyway and the collector silently
ignores it.

**A finalizer** is the manual one. It is a string in `metadata.finalizers`. While present,
`kubectl delete` deletes nothing: the API server stamps `deletionTimestamp` and the object stays.
The controller sees the timestamp, does its cleanup, removes the string, and only then does the
object disappear.

Why it is needed at all: the object is the only record of what it created. Delete it outright and
the controller wakes to `NotFound` with no idea what to clean up.

Two traps: cleanup must be idempotent, because a failure requeues it; and a finalizer whose
cleanup can never succeed leaves the object stuck in `Terminating` until someone strips the field
by hand.

```bash
kubectl patch <kind> <name> -n <ns> --type=merge -p '{"metadata":{"finalizers":[]}}'
```

## Status

Status is how the object explains itself without anyone reading logs.

- **Conditions** - the standard shape (`type`, `status`, `reason`, `message`). Use
  `meta.SetStatusCondition`, which only moves `lastTransitionTime` when the value actually flips.
- **observedGeneration** - `metadata.generation` bumps on every spec edit. Recording it in status
  is what lets a reader tell "Ready, and current" from "Ready, but that was two edits ago".
- **Events** - `kubectl describe` output, for things a human should see once.

The judgement call status forces you to make: what counts as an error versus a state. A missing
source Secret is reported as a condition and left alone. Treating it as an error would delete
every copy over a typo.

## RBAC and the cache have to agree

`make run` uses your admin kubeconfig, so permissions are invisible until the controller runs as
a pod. Two rules:

**Every API call needs a marker.** `+kubebuilder:rbac` comments generate `config/rbac/role.yaml`.
Miss one and it works locally, then fails in-cluster.

**A watch is a cluster-wide list.** This is the wall. The manager's cache lists and watches every
type it reads across all namespaces, so namespaced RBAC makes it fail at startup no matter what
your Roles say. Either scope the cache to the namespaces you were granted, or disable caching for
that type and read directly from the API server.

That constraint shapes real designs. secret-mirror-controller holds no cluster-wide Secret
access: it watches Secrets only in the source namespace (a fixed name), reads target Secrets
uncached, and receives write access one namespace at a time through a RoleBinding that
launchpad-api renders beside each sandbox. Least privilege costs a watch.

## Testing

**The fake client** ([controller-runtime's `pkg/client/fake`](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/client/fake))
stands in for the API server in memory. Build a small world, call `Reconcile` directly, assert
what changed. No cluster, no binaries, milliseconds per test. It covers logic, not API-server
behaviour - it will not enforce your CRD schema or run admission.

**envtest** runs a real API server and etcd binary locally. Slower, needs a download, and worth it
for anything that depends on real API behaviour: validation, defaulting, subresources, finalizer
mechanics.

Start with the fake client for reconcile logic. Reach for envtest when you are testing
Kubernetes, not your code.

## Still to learn

Each of these is a session in itself.

- **Server-side apply and field managers** - who owns which field when two controllers write the
  same object, and what `.metadata.managedFields` actually records.
- **Webhooks and CEL validation** - rejecting bad specs before they persist, and the lighter CEL
  rules that cover most of the same ground without a webhook server.
- **Multi-version CRDs and conversion** - what `served` and `storage` are for once there is more
  than one version.
- **Owned resources** - the `Owns()` plus ownerReferences pattern, which secret-mirror-controller
  deliberately never uses. Any controller that creates a Deployment or ConfigMap in its own
  namespace leans on it.
- **Crossplane mapped onto kubebuilder** - XRD to CRD, Composition to reconcile logic, composed
  resources to owned resources. Two systems, one model.
