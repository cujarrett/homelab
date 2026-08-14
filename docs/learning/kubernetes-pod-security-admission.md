# Pod Security Admission

> **The one idea (grug):** hardening a workload makes *your* pods safe. Pod Security Admission makes the cluster refuse unsafe ones - including the pods you did not write.

Every securityContext in this repo is a decision the platform made on behalf of an app. Nothing about it stops a hand-written manifest asking for `privileged: true`, or a compromised commit mounting the host's `/`. Pod Security Admission is the control that does, and it is built into Kubernetes - no operator, no CRD, no sidecar.

| Chapter | What it covers |
|---|---|
| [How it works](#how-it-works) | Label a namespace, the API server does the rest |
| [The three levels](#the-three-levels) | privileged, baseline, restricted |
| [The three modes](#the-three-modes) | enforce, warn, audit - and why you want all three |
| [Ask, do not guess](#ask-do-not-guess) | The dry-run that tells you what would break |
| [It does not evict](#it-does-not-evict) | The trap that surfaces at the worst moment |
| [What it caught here](#what-it-caught-here) | Two real findings from this cluster |
| [What it does not do](#what-it-does-not-do) | Its limits, honestly |

## How it works

You put a label on a namespace. From then on the API server checks every pod created there against a standard and rejects the ones that fail.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mattjarrett-dev
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

That is the whole mechanism. It runs inside the API server as a built-in admission plugin, so there is nothing to install, nothing to keep running, and nothing that can be bypassed by talking to a different endpoint. It replaced PodSecurityPolicy, which was removed in Kubernetes 1.25.

The check happens at **pod create**. Not at deploy, not at image build - at the moment something asks the cluster for a pod.

## The three levels

Levels are cumulative: each one is the previous plus more.

| Level | What it allows | Use for |
|---|---|---|
| `privileged` | Everything. No checks. | Infrastructure that genuinely needs the host - CNI, storage drivers, node agents |
| `baseline` | Blocks the known escapes: `privileged`, host namespaces, `hostPath`, adding capabilities beyond `NET_BIND_SERVICE` | Workloads that must run as root but should not touch the host |
| `restricted` | Baseline plus: must run non-root, must drop all capabilities, must set a seccomp profile, no privilege escalation | Everything you can make comply |

The gap between `baseline` and `restricted` is the interesting one. `baseline` stops a container escaping to the node. `restricted` stops it being root at all, so an application bug has less to work with before escape is even attempted.

Worth knowing precisely, because it decides where most workloads land: **`baseline` allows the default capability set, but forbids adding to it.** A container that drops everything and adds back `CHOWN` and `SETUID` passes baseline, because both are in the default set. A container adding `NET_ADMIN` fails, because it is not.

## The three modes

The same three levels can be applied in three modes, independently, on the same namespace:

| Mode | Effect |
|---|---|
| `enforce` | Reject the pod |
| `warn` | Allow it, return a warning to whoever created it |
| `audit` | Allow it, write an annotation into the audit log |

Setting all three is the useful pattern, and they do not have to agree:

```yaml
pod-security.kubernetes.io/enforce: baseline
pod-security.kubernetes.io/warn: restricted
pod-security.kubernetes.io/audit: restricted
```

That reads as: *reject anything below baseline, and tell me every time something falls short of restricted.* The namespace is protected at the level it can meet today, while the gap to where it should be stays visible on every single pod create instead of living in a comment someone stops reading.

## Ask, do not guess

The best feature is that you never have to reason about whether a level will break something. The API server will tell you, checked against the pods actually running:

```bash
kubectl label --dry-run=server --overwrite ns <namespace> pod-security.kubernetes.io/enforce=restricted
```

Nothing is changed. If the level would be a problem, it names the pod and the specific violations:

```
Warning: existing pods in namespace "my-vinyl" violate the new PodSecurity enforce level "restricted:latest"
Warning: my-vinyl-api-cache-redis-...: allowPrivilegeEscalation != false, unrestricted capabilities,
         runAsNonRoot != true, seccompProfile
```

Run this before writing any YAML. Every level in this cluster was chosen from its output rather than from reading the standard.

## It does not evict

**PSA only checks pods being created.** Labelling a namespace `restricted` while non-compliant pods are running does nothing to them. They keep serving. Nothing looks wrong.

The rejection arrives later, when something recreates a pod - a node drain, an eviction, an image bump, a crash. In other words the failure is deferred to the least convenient moment, and to a change that looks unrelated.

So the order is: make the workloads comply, restart them, confirm the dry-run is clean, *then* label. Labelling first is not a safe way to find out what breaks - it is a way to postpone finding out.

## What it caught here

Two findings, neither of which was visible from reading manifests.

**The sidecar, not the app.** Meshed namespaces failed `restricted` - and also `baseline` - while their application containers already complied fully. The violator was `istio-init`, an init container Istio injects, running as root with `NET_ADMIN` and `NET_RAW` to write the pod's iptables. It fails baseline specifically because baseline forbids adding capabilities beyond `NET_BIND_SERVICE`.

What identified it was a comparison the dry-run made cheap: `launchpad` is the one namespace deliberately left out of the mesh, and it passed `restricted` on the first attempt. One namespace differing in exactly one way is a better diagnostic than any amount of reading.

The fix was to stop injecting that container rather than to lower the level. The `istio-cni` DaemonSet does the same iptables work from the node, and the injected init container becomes `istio-validation` - uid 1337, all capabilities dropped, read-only root. See [Platform Connections](../platform-connections.md) for how the mesh is put together.

**A composition nobody had revisited.** With the mesh fixed, one namespace still failed: a redis pod from the Cache composition, running as root with no securityContext at all. The Api, Spa and WordPress compositions had all been hardened; Cache had been quietly missed, and no one would have noticed by reading them, because you do not go looking in the file you already believe is fine.

That is the general value. PSA does not find bugs - it enumerates every pod in a namespace against one standard and reports what does not meet it, including the ones you forgot you owned.

## What it does not do

It checks the pod **specification**, not behaviour. A pod that passes `restricted` can still run malicious code, exfiltrate data, or attack anything it can reach on the network. PSA narrows what a workload is *permitted to ask the kernel for*; it says nothing about what the process then does.

It is namespace-scoped, so a namespace with no label is unrestricted - new namespaces are unprotected by default, and that is a gap worth having a habit about rather than a control.

And it is deliberately not applied to infrastructure. `kube-system`, `longhorn-system`, `cilium`, `spire-system` and `istio-system` legitimately run privileged workloads. Labelling those breaks the cluster. The point of PSA is not that nothing is privileged - it is that privilege is concentrated in a few namespaces you can name, instead of spread across every namespace that happens to run an application.
