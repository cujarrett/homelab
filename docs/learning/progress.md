# Learning Progress

Tracks calibrated level per topic and the next grill question, so a session can pick up cold. Update it at the end of each session — don't batch.

## Sequence

1. Controllers - **in progress**, via [secret-mirror-controller-lab.md](./secret-mirror-controller-lab.md)
2. Crossplane - not started, blocked on (1)
3. Entra / authz - not started, no dependency

## Controllers

Level: understands the GitOps flow (git → Argo → cluster → controller) and the declarative-vs-Terraform distinction. Gap: the actual reconcile trigger - explained it as "Argo applies it" rather than watch/informer → work queue → reconcile.

Next question: after building the SecretMirror lab, ask what specifically put the reconcile request on the queue when you deleted a copy by hand - not "the controller watches for changes," but which object's watch fired and what got queued.

## Crossplane

Level: correctly identifies that a provider replaces a hand-authored controller. Gap: how an XRD/Composition maps to real controller logic - XR vs MR, what a provider does with a rendered Composition.

Next question: point at a real Composition in `platform/` and ask which parts are "the controller logic" and which the provider gives for free.

## Entra / authz

Level: zero, not yet calibrated beyond "don't know."

Next question: why can't one App Registration cleanly serve as both client and resource once a second client needs the same API?
