# Nothing Novel

Nothing here was invented. Every mechanism is a published pattern, used the way its docs say to use it.

A homelab is for learning what the industry already agreed on, so being recognisable is the goal and cleverness is the failure mode.

## The claim, and how to break it

Every piece below traces to a public spec, a vendor's reference architecture, or a conference talk. If one cannot, it does not belong here.

## Where each piece comes from

| What it does | What it is | Public source |
|---|---|---|
| A team declares an app or a database; the platform renders the Kubernetes and cloud objects | Crossplane `XRD` + `Composition` | [Crossplane](https://crossplane.io) — Upbound ships this same structure as its reference architecture |
| Credentials arrive as files the app reads at `/bindings/sql/host` | Service binding | [servicebinding.io](https://servicebinding.io) — files not env vars is the spec's own choice |
| The app waits until its credentials exist before starting | Init container gate | Standard Kubernetes readiness ordering |
| No AWS keys anywhere; a pod trades a short-lived certificate for temporary credentials | SPIFFE SVID → STS | [SPIRE](https://spiffe.io) and [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html), the service AWS built for exactly this |
| A workload names who may call it; everything else is refused | `AuthorizationPolicy`, `PeerAuthentication` STRICT | [Istio](https://istio.io) — the first ALLOW policy making a workload deny-by-default is documented behaviour |
| A workload names what it calls; nothing else is reachable | `Sidecar` `REGISTRY_ONLY` + `ServiceEntry` | Istio's own egress control task |
| One namespace per environment, branch, or engineer | Kubernetes multi-tenancy | The usual way ephemeral environments are built |
| CI writes the new image tag to Git; ArgoCD converges | GitOps | OpenGitOps principles; Flux and Argo both ship image automation that does this |

Deny-by-default is older than all of it — a firewall rule, or a Kubernetes `NetworkPolicy`.

## What is actually mine

The selection, and nothing else: which offerings exist, what each one exposes, what the defaults are, and where the platform stops. See [Platform](../platform/README.md) for the offerings and [Platform Connections](./platform-connections.md) for where it stops.

That leaves judgement, not invention. Judgement is meant to be argued with.
