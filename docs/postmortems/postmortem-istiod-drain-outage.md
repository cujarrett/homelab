# Postmortem - istiod Drain Outage

Draining `ctrl-1` for the k3s v1.37.0 upgrade evicted istiod, which is pinned to the control
plane. With the sidecar-injection webhook unreachable and set to fail closed, every mesh pod
evicted after it could not be recreated until the node was uncordoned.

## Impact

About four and a half minutes on 2026-09-25, 03:52 to 03:56 UTC.

- `mattjarrett.dev`, `myvinyl.mattjarrett.dev` and `jspollock.mattjarrett.dev` returned 503.
  All three are single-replica Spa XRs, so an evicted pod leaves the Service with no endpoints.
- Pods evicted before istiod was recreated fine. Pods evicted after it stayed absent.
- No data loss. Longhorn stayed healthy throughout.

## Root cause

istiod runs one replica pinned to `ctrl-1` with `nodeSelector: node-role.kubernetes.io/control-plane`.
`ctrl-1` is the only control-plane node, so cordoning it leaves istiod with nowhere to go and the
replacement pod sits `Pending` until uncordon.

Istio's mutating webhook has `failurePolicy: Fail`. While the `istiod` Service had no endpoints,
every pod create in an injected namespace was rejected with
`failed calling webhook "namespace.sidecar-injector.istio.io"`. The three affected ReplicaSets
hit that error repeatedly and entered exponential backoff.

Uncordon at 03:54 brought istiod back within seconds, but the ReplicaSets did not retry until
their backoff expired. The pods were created at 03:55:56 and Ready at 03:56:12.

The runbook drain order was correct. It just did not account for istiod being pinned to the node
being drained.

## Resolution

Uncordoning `ctrl-1` and waiting. Nothing else was needed.

## Actions

- [x] istiod runs two replicas on different nodes with no `nodeSelector`, set in
      [cluster/argocd/istio.yaml](../../cluster/argocd/istio.yaml). One replica survives any
      single drain, so the webhook keeps answering.
- [x] [Upgrading k3s](../runbooks/k3s-upgrade.md) now says to check the public URLs after
      uncordon, because mesh pods can lag up to five minutes on ReplicaSet backoff.
