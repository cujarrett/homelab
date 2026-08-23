# Render Check

Compositions are templates, and a template can be syntactically fine while still producing something the cluster refuses. [`render-check.sh`](../../platform/test/render-check.sh) catches that class of bug before it reaches the cluster, by running the real Crossplane templating engine against every real workspace XR and checking the output against five specific failure modes - each one a bug that reached the cluster at least once before the gate existed.

## Index

| Chapter | What's in it |
|---|---|
| [The five gates](#the-five-gates) | What each one catches, and the incident it came from |
| [Reading a diff](#reading-a-diff) | The two-directional comparison, and what CHANGED actually means |
| [Provider-managed kinds need no grant](#provider-managed-kinds-need-no-grant) | Why the rbac gate has a skip list, and what happens when a new provider isn't on it |
| [Telling a real gap from a skip-list gap](#telling-a-real-gap-from-a-skip-list-gap) | The one command that answers it |

## The five gates

Each gate targets one way a composition can look fine and still break something.

| Gate | Checks | Catches |
|---|---|---|
| schema | Every XRD passes a server-side dry-run | A CRD Kubernetes silently refused to generate, leaving it at its old generation - `crossplane render` and `kubectl apply` both report success |
| render | `crossplane render` exits 0 | A template error |
| parse | The rendered output is valid YAML, and every list is a list | Whitespace trimming that collapsed a block sequence into one string - `crossplane render` exits 0 on this, so exit code alone proves nothing |
| diff | Two renders per workspace XR, one holding the composition still and one holding the XR still | What a composition edit does to every app that uses it, and what an XR edit did that the XRD silently dropped |
| rbac | Every kind in the rendered output is granted somewhere Crossplane's own ServiceAccount can reach | A kind the platform has never composed before. It renders fine and applies fine in `crossplane render` - the API server is the only thing that refuses it, and only once it's real |

## Reading a diff

The diff gate runs each workspace XR twice: once against the composition at `HEAD` with the XR as it is now, and once against the composition as it is now with the XR at `HEAD`. Holding one side still isolates what the other side changed.

A workspace showing `(composition change does not affect it)` means neither direction produced a diff - the safest possible result for an edit that's supposed to be additive. `(CHANGED vs HEAD - review below)` is not automatically a problem; it just means look at the diff and confirm it's the change you meant. Adding an opt-in parameter and enabling it on exactly one Api should show precisely one CHANGED line, for exactly that Api.

## Provider-managed kinds need no grant

The rbac gate's skip list exists because two very different kinds of composed resource need RBAC differently:

- **Kubernetes-native kinds** (`Secret`, `Deployment`, `Ingress`, and so on) are things Crossplane's core has no inherent reason to be allowed to touch. Each one needs an explicit grant in [`cluster/crossplane/rbac.yaml`](../../cluster/crossplane/rbac.yaml), aggregated to Crossplane's ClusterRole by label.
- **Provider-managed kinds** (anything a Crossplane provider owns - `Role`, `Bucket`, `Application`, `Principal`) ship with their own edit ClusterRole from the provider itself, aggregated the same way. Crossplane's core already has access the moment the provider is installed - a second, hand-written grant would just be redundant.

The gate's `skip()` function encodes that distinction by matching the `upbound.io` suffix and treating anything under it as already covered. An earlier version listed each provider's group by hand, which meant a new provider failed the gate until someone remembered to add it: adding the Entra composition produced three new kinds, real grants already present, and a `FAIL` anyway because nothing had told the gate that provider's groups were self-granting too.

## Telling a real gap from a skip-list gap

Don't guess. Ask the cluster directly whether Crossplane's own ServiceAccount can already do it:

```bash
kubectl auth can-i create applications.applications.azuread.m.upbound.io \
  --as=system:serviceaccount:crossplane-system:crossplane
```

`yes` means the access already exists and the gate is wrong - fix `skip()` in [`render-check.sh`](../../platform/test/render-check.sh) to cover the new provider's group. `no` means the gate is right, and the fix belongs in [`rbac.yaml`](../../cluster/crossplane/rbac.yaml) instead. Both fixes look identical from the gate's `FAIL` output alone - only this command tells you which one you're looking at.
