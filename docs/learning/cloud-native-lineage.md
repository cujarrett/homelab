# Cloud Native Lineage

> **The one idea (grug):** almost nothing in Kubernetes was invented for Kubernetes. Borg, Chubby, Raft, cgroups, and CoreOS each solved one piece first. Once you know which piece came from where, the design stops looking arbitrary and starts looking inevitable.

This is the missing context behind the vocabulary Kelsey Hightower and that generation use casually - CoreOS, etcd, fleet, rkt, Ignition, Borg.

| Session | Topic | Feeds |
|---|---|---|
| [1. Borg to Kubernetes](#1-borg-to-kubernetes) | Where the model came from | everything |
| [2. Consensus, and why etcd](#2-consensus-and-why-etcd) | The one irreplaceable component | Kubernetes the Hard Way |
| [3. The runtime wars](#3-the-runtime-wars) | How interfaces beat implementations | Kubernetes the Hard Way |
| [4. CoreOS](#4-coreos) | The company, and what survived it | - |
| [5. Service discovery, the old way](#5-service-discovery-the-old-way) | Why Services are boring | - |
| [6. Declarative, and what it replaced](#6-declarative-and-what-it-replaced) | Converge once vs converge forever | Secret Mirror |
| [7. The Kelsey canon](#7-the-kelsey-canon) | His arguments, not his quotes | - |

## 1. Borg to Kubernetes

Kubernetes is the third system in a line, built by people who had already shipped the first two and knew what they regretted.

**Read** - *Large-scale cluster management at Google with Borg* (2015), then *Borg, Omega, and Kubernetes* (ACM Queue, 2016). The second is short, plain-spoken, and the highest-value thing on this list: the authors name which of their own earlier decisions were mistakes.

**Come away with** - why the API server is the only component that talks to storage, why every object carries a declared spec, and why the reconciliation loop is the organising idea rather than an implementation detail.

## 2. Consensus, and why etcd

etcd is the only thing in a cluster that cannot be recreated. Everything else is derived state, which is a strange and load-bearing fact.

**Read** - the Raft paper, *In Search of an Understandable Consensus Algorithm* (2014). Its stated goal is being easier to follow than Paxos, and it succeeds. Then Google's *Chubby* paper (2006), the lock service Borg used and etcd's ancestor in spirit.

**Come away with** - leader election and log replication, why quorum makes clusters three or five nodes and never four, and why losing quorum stops a cluster rather than slowing it.

**Worth ten minutes on your own cluster** - k3s does not necessarily run etcd at all. A single-server install typically keeps state in SQLite behind a shim called kine. Find out which `ctrl-1` uses and what that implies if you ever add a second server. The Learning Plan works with etcd in throwaway VMs; it never asks this about the real cluster.

## 3. The runtime wars

Containers were a kernel feature for years before anyone made them pleasant.

**The lineage** - cgroups and namespaces land in the kernel around 2007 → LXC makes them usable → Docker (2013) adds the image format and the developer experience that catches on → CoreOS ships rkt as a rival → the fight ends politically, by standardising interfaces rather than picking a winner: OCI for image and runtime format, CRI for how a kubelet talks to a runtime.

**The lesson, which outlives the history** - the winner was an interface, not a product. Kubernetes survives runtime churn because it only ever speaks CRI. Docker was removed as a runtime in 1.24 and almost nobody noticed. Interfaces are what let a system outlive its own components, which is the same reason `client.Client` is an interface in the controller you are about to write.

## 4. CoreOS

CoreOS built a complete pre-Kubernetes stack - etcd for coordination, fleet for scheduling, flannel for networking, rkt for runtime - on a stripped-down auto-updating OS. Kubernetes won. What survived was etcd and a philosophy.

**The philosophy** - the operating system is an immutable image, not a mutable pile of packages. Upgrades are atomic and roll back. Nothing is configured by SSH-ing in.

**Read** - the CoreOS operator pattern announcement from 2016, which is where the word "operator" enters the vocabulary, and the Ignition-versus-cloud-init comparison for the argument rather than the syntax.

**What happened** - Red Hat acquired CoreOS in 2018. Container Linux became Fedora CoreOS; the same lineage became RHEL CoreOS, which exists only underneath OpenShift.

**The uncomfortable comparison** - your Pis are pets. Configured over SSH, with real state outside git: the k3s `config.yaml` on `ctrl-1`, the X config for the kiosk, `~/kiosk.sh`. Immutable infrastructure is the direct argument against that. Whether it is worth it on four Pis is a genuine question and having an opinion is the point.

## 5. Service discovery, the old way

Kubernetes Services look obvious in hindsight. They were not.

**The problem** - processes move, ports are dynamic, and a client needs a healthy instance right now. Before Kubernetes this meant Zookeeper or Consul, or etcd plus a sidecar rewriting an HAProxy config and reloading it on every change.

**Read** - enough of the Consul or Zookeeper documentation to see the shape of what was replaced, then the Kubernetes Services design.

**Come away with** - Kubernetes chose a stable virtual IP and a DNS name, so applications need no client library and no awareness at all. A Service is boring, and the boringness is the achievement. It is worth noticing that Istio quietly hands some of that complexity back, in exchange for things a plain Service cannot do.

## 6. Declarative, and what it replaced

The word only means something if you remember what came before it.

**The lineage** - hand-run shell scripts → CFEngine, Puppet, and Chef converging mutable machines → Ansible pushing over SSH → Terraform declaring cloud resources behind plan-and-apply → Kubernetes running the loop continuously rather than when a human types apply.

**The distinction worth carrying** - Terraform converges when you run it. Kubernetes converges forever. That gap is the entire reason controllers exist, and it is what [Platform Secret Mirror](./secret-mirror-lab.md) demonstrates in one command: delete the copy and it returns, because nobody has to run anything.

**Read** - the twelve-factor app (2011). Half of it now reads as assumed, which is the interesting half. Note which factors Kubernetes made trivial and which it simply made someone else's problem.

## 7. The Kelsey canon

Read the arguments rather than collecting the quotes.

**"Kubernetes is a platform for building platforms."** Widely quoted, rarely finished. The rest of the thought is that Kubernetes is a low-level toolkit, and handing it directly to application developers is handing them a box of parts. Your Crossplane XRDs are the platform built on the platform, which puts you on the right side of the argument already.

**nocode** - his joke repo: the best way to write secure and reliable applications is to write nothing. The joke has an edge, and it is the same one grug swings. Every component is a liability. The most reliable system is the one not built.

**Kubernetes the Hard Way** - his framing is the part worth taking, since [Kubernetes the Hard Way](./kubernetes-the-hard-way.md) already schedules the work. It exists so you understand the parts, and he is emphatic that nobody should run production this way.

**The serverless thread** - a long-running argument that most teams should not be operating clusters at all. Worth engaging with honestly rather than dismissing, particularly from inside a homelab built for the pleasure of operating one.

**Watch** - his KubeCon keynotes and live demos rather than any one canonical talk. Search by year; the live-coding ones age best, because he argues by demonstration.

## Write it down

One page, in your own words:

- Which parts of Kubernetes are inherited, and from what?
- What does etcd solve that a database would not?
- What would this homelab look like on immutable nodes, and would it be better?

If the third one will not write, session 4 has not landed. That is the check.
