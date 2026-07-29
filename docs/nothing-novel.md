# Nothing Novel

Every mechanism in this platform is a published pattern, applied as documented. Nothing here was invented. This doc names the public prior art behind each piece, so anyone — including me, later — can check the claim rather than take it on trust.

Start with [The claim](#the-claim), then read whichever mechanism you care about.

| Chapter | What it covers |
|---|---|
| [The claim](#the-claim) | What "nothing novel" means, and what would falsify it |
| [The shape of the platform](#the-shape-of-the-platform) | Why apps declare a resource instead of writing Kubernetes YAML |
| [Getting credentials into the app](#getting-credentials-into-the-app) | Files under `/bindings/`, and why not env vars |
| [Proving who a workload is](#proving-who-a-workload-is) | Short-lived certificates traded for cloud credentials |
| [Deciding which calls get through](#deciding-which-calls-get-through) | Declared callers and declared destinations |
| [Sizing, environments, and delivery](#sizing-environments-and-delivery) | T-shirt sizes, namespace-per-environment, image tags in Git |
| [Where the platform stops](#where-the-platform-stops) | The things it deliberately does not do |
| [What novelty would look like](#what-novelty-would-look-like) | The kinds of claims this platform does not make |

## The claim

The interesting question about any platform is not "is it clever?" but "is it the thing everyone else already agreed on?" A homelab is a place to learn the industry's answers, not to invent private ones. So the goal here is the opposite of novelty — every abstraction should be recognisable on sight to someone who works on an internal developer platform elsewhere.

That claim is falsifiable. If a mechanism below cannot be traced to a public specification, a vendor's reference architecture, or a conference talk, it does not belong. Each chapter names the source.

## The shape of the platform

Application teams declare a resource — an [Api](../platform/api/), a [Sql](../platform/sql/), an [ObjectStorage](../platform/object-storage/) — and the platform renders the Kubernetes and cloud objects behind it.

This is [Crossplane](https://crossplane.io)'s composite resource model used as designed: a `CompositeResourceDefinition` states the API the team writes against, and a `Composition` states what it becomes. The [platform README](../platform/README.md) lists the nine offerings.

The broader idea — a platform team publishing a small, opinionated API that hides infrastructure detail — is the central subject of *Team Topologies*' platform-as-a-product framing, of Google's [Site Reliability Engineering](https://sre.google/books/), and of essentially every platform engineering track talk at KubeCon. Upbound ships this exact XRD-and-Composition structure as its reference architecture. Kratix, Port, and Backstage solve the same problem with different plumbing.

## Getting credentials into the app

A provisioned resource is useless until the application can reach it. Here, credentials arrive as files in a directory the app reads at a fixed path.

```
/bindings/sql/host
/bindings/sql/port
/bindings/sql/username
```

That is the [servicebinding.io](https://servicebinding.io) specification, followed rather than adapted: one directory per binding, one file per value, mounted at a well-known root. The app reads a path and stays ignorant of whether the database is in-cluster Postgres or RDS.

Files rather than environment variables is the specification's choice, and the reasoning is public: env vars are fixed at process start, so a rotated credential cannot reach a running pod, and they leak into crash dumps and child processes. An init container that blocks startup until every binding is present is the standard Kubernetes readiness-ordering idiom.

For the full walkthrough, see [Platform Engineering: Binding](./platform-engineering-binding.md).

## Proving who a workload is

AWS-backed resources hold no access keys anywhere. A pod presents a short-lived X.509 certificate that identifies it, and trades that certificate for temporary credentials.

The certificate is a SPIFFE SVID issued by [SPIRE](https://spiffe.io), the CNCF project whose entire purpose is workload identity. The trade is [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html), the service AWS built for exactly this: validate an external certificate chain, return STS credentials. Scoping each IAM role's trust policy to one SPIFFE ID is the pattern AWS and the SPIFFE project both document.

The only locally written piece is [aws-spiffe-helper](https://github.com/cujarrett/aws-spiffe-helper), a sidecar that performs the exchange and refreshes before expiry. It is a small reimplementation of the credential-helper role that AWS's own `aws_signing_helper` fills, written to run as a sidecar. Different packaging, same published protocol.

For the full walkthrough, see [Platform Engineering: Workload Identity](./platform-engineering-workload-identity.md).

## Deciding which calls get through

A workload declares which callers may reach it, and which destinations it needs to reach. Anything undeclared is refused.

Both halves render stock [Istio](https://istio.io) objects. Declared callers become an `AuthorizationPolicy` on the callee's own pod, which relies on Istio's documented behaviour that the first ALLOW policy selecting a workload makes that workload deny-by-default. Declared destinations become a `Sidecar` in `REGISTRY_ONLY` mode plus a `ServiceEntry`, which is the configuration Istio's own egress-control documentation prescribes. `PeerAuthentication` in STRICT mode is the standard way to require mTLS.

Deny-by-default with explicit grants is old enough to predate all of this — it is the same principle as a firewall default-deny rule or a Kubernetes `NetworkPolicy`. The `provides` and `consumes` vocabulary is borrowed too: [Score](https://score.dev) and TOSCA both describe workload dependencies in those terms.

For the full walkthrough, see [Platform Engineering: Connections](./platform-engineering-connections.md).

## Sizing, environments, and delivery

Three conventions, none of them local inventions.

**Compute is chosen from a fixed set of sizes** — `xs`, `sm`, `md`, `lg` — rather than by writing CPU and memory numbers. T-shirt sizing appears in nearly every internal platform because it converts an unbounded decision into a short menu.

**The namespace is the environment boundary.** One namespace per environment, per branch, or per engineer, with resource names scoped by namespace so two copies never collide. This is standard Kubernetes multi-tenancy, and the per-branch variant is the usual way ephemeral environments are built.

**CI commits the new image tag back to Git**, and ArgoCD converges the cluster to it. That is GitOps as the OpenGitOps principles define it, and the image-tag-in-Git flow is what Flux's image automation controllers and Argo Image Updater both implement.

## Where the platform stops

The absences are as conventional as the mechanisms.

Connection policy answers "may this workload call that workload?" and never "may this person view that record?" — workload authorization and user authorization are separate layers, kept separate deliberately. Secrets are created out-of-band rather than committed. Data resources outlive the apps that use them, so deleting an API cannot destroy a database.

None of these is a discovery. They are the defaults a reviewer would expect, and the reason to write them down is that a platform is judged as much by what it refuses to do as by what it provisions.

## What novelty would look like

For contrast, the claims this platform does not make: a new scheduling algorithm, a new consensus or storage engine, a new identity protocol, a new configuration language, or a control loop that solves something Crossplane's does not.

What is genuinely local is the *selection* — which nine offerings exist, which knobs each exposes, what the defaults are, and where the platform draws the line between its concerns and the application's. That is the work of running a platform, and it is the same work every platform team does. It is judgement, not invention, and judgement is meant to be argued with.
