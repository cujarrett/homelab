# Learning

Everything here builds toward one thing — writing Kubernetes controllers and understanding the model underneath them. The homelab is the lab, so nearly every exercise lands in a repo already owned.

## Suggested order

Read the lineage first, build a controller second, and let the rest backfill. Writing a controller before the supporting theory exposes exactly which concepts are missing, and a gap that actually hurt is a better study target than one picked off a syllabus.

| # | Doc | What you end with |
|---|---|---|
| 1 | [Cloud Native Lineage](./cloud-native-lineage.md) | Where Kubernetes came from — Borg, Raft, the runtime wars, CoreOS |
| 2 | [Secret Mirror](./secret-mirror-controller-lab.md) | A real controller, built step by step against a genuine gap |
| 3 | [Kubernetes the Hard Way](./kubernetes-the-hard-way.md) | A cluster stood up from parts on VMs, and the Linux primitives under it |
| 4 | [OSI, for real](./osi-for-real.md) | A packet-path doc for one public hostname |
| 5 | [Pod Security Admission](./pod-security-admission.md) | What the cluster will refuse to run, and how to find out before it refuses |

## Rhythm

- Four hours hands-on to one hour reading. Reverse that ratio and none of it sticks.
- Finish every doc with one committed artifact — a script, a doc, a repo. Work with no commit did not happen.
- Write notes in your own words. Output from the KRM work belongs in [learning-krm](https://github.com/cujarrett/learning-krm) as real chapters; everything else can live wherever you keep notes. Notes you cannot write are topics you do not have yet.
