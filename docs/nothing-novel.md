# Nothing Novel

Nothing here was invented. Every mechanism is a published pattern, used the way its docs say. A homelab is for learning what the industry already agreed on. Each piece traces to a public spec, a vendor reference architecture or a CNCF working group, or it does not belong here.

## Where each piece comes from

| What it does | What it is | Public source |
|---|---|---|
| A team declares an app or a database, and the platform renders the Kubernetes and cloud objects | Crossplane `XRD` + `Composition` | [Crossplane](https://crossplane.io). Upbound ships this structure as its reference architecture |
| Credentials arrive as files the app reads, such as `/bindings/sql/host` | Service binding | [servicebinding.io](https://servicebinding.io). The spec itself chooses files over env vars |
| The app waits for its credentials before it starts | Init container gate | Standard Kubernetes readiness ordering |
| A pod trades a short-lived certificate for temporary AWS credentials, with no AWS keys anywhere | SPIFFE SVID → STS | [SPIRE](https://spiffe.io) and [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html), which AWS built for this |
| A workload names who may call it, and everything else is refused | `AuthorizationPolicy`, `PeerAuthentication` STRICT | [Istio](https://istio.io). The first ALLOW policy makes a workload deny-by-default, as documented |
| A workload names what it calls, and nothing else is reachable | `Sidecar` `REGISTRY_ONLY` + `ServiceEntry` | Istio's own egress control task |
| One namespace per environment, branch or engineer | Kubernetes multi-tenancy | The usual way to build short-lived environments |
| A new image moves into test by itself, is checked there, then reaches prod with one click | Kargo Warehouse, Stages and verification | [Kargo](https://docs.kargo.io/), GitOps promotion from the team behind Argo CD |
| Each open pull request gets its own environment, deleted when the PR closes | Argo CD ApplicationSet pull request generator | [Argo CD Pull Request Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/), Argo's own preview environment pattern |
| CI writes the new image tag to Git, and ArgoCD applies it | GitOps | OpenGitOps principles. Flux and Argo both ship image automation that does this |
| Steps keep their progress through crashes, restarts and long waits | Durable execution | [Temporal](https://temporal.io), open source, from the engineers who built Uber's Cadence |
| A Kubernetes resource creates a team's workflow namespace | A custom controller for an outside system | The [Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/), as in AWS ACK and Crossplane providers |
| A workload signs in to Temporal with no stored secret, and its token names the namespace it may use | Workload identity federation and a JWT role claim | [Entra workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation) and Temporal's [JWT authorizer](https://docs.temporal.io/self-hosted-guide/security) |

## What is actually mine

The selection: which offerings exist, what each one exposes, the defaults, and where the platform stops. Every platform team makes the same contribution. They pick a set of tools, give it defaults and draw a line around it.

## Why companies do this

One team solves a problem once. Every other team gets the answer without learning it was a problem. Otherwise each team solves it again, differently, and the company owns every answer forever.

The [CNCF Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) makes this case in full. It defines a platform as "an integrated collection of capabilities defined and presented according to the needs of the platform's users."

AWS, Adobe, Autodesk, Nike, Intuit and Cisco publish reference architectures for this through [CNOE](https://cnoe.io/). This repo is one small instance of that pattern.
