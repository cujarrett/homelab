# Postmortem — Kubelet Probe Outage

A routine k3s upgrade exposed a latent misconfiguration: k3s's built-in kube-router NetworkPolicy controller had been running alongside Cilium since the cluster was rebuilt with Cilium. The
upgrade's restarts reordered their iptables chains, and every pod selected by a NetworkPolicy
stopped passing kubelet probes.

## Impact

Roughly 17 hours from first breakage to fix, 2026-08-06 through 2026-08-07.

- `mattjarrett.com` and `kentjarrett.com` returned 503 across several windows, the longest
  about 40 minutes. Both are single-replica on `Recreate`, so a pod that cannot pass readiness
  leaves the Service with no endpoints.
- All public sites were unreachable twice, roughly 15 minutes total — once from the Traefik
  failure below, once from a diagnostic step during the investigation.
- GitOps stalled for hours: `argocd-repo-server` crash-looped, so no Application could sync,
  including the fixes for this.
- `argocd-application-controller` sat `NotReady` ~14 hours while still working.
- No data loss; Longhorn stayed healthy apart from expected replica rebuilds.

## Root cause

k3s ships kube-router as a NetworkPolicy enforcer and enables it by default. Cilium enforces
policy too, so both were active — a conflict k3s's docs explicitly warn against.

In `filter/OUTPUT`, `KUBE-ROUTER-OUTPUT` sat ahead of Cilium's feeder. kube-router creates a
`KUBE-POD-FW-*` chain per NetworkPolicy-selected pod, each beginning with a rule accepting
traffic from the pod's own node (`--src-type LOCAL -j ACCEPT`) — exactly kubelet probe traffic.
`ACCEPT` ends filter-table traversal, so Cilium's `"host->any mark as from host"` rule never
applied the host identity mark. Cilium's BPF then saw an unmarked packet, fell back to the
`world` identity, and denied it under its own policy — explaining why only policy-selected pods
broke, and why no Cilium setting could fix it.

**Trigger.** The cluster was rebuilt onto Cilium 39 days prior, and chain ordering must have
favoured Cilium from that point — kube-router ran alongside it harmlessly the whole time. This
upgrade's restart of k3s on all four nodes is what let kube-router reinsert its jump at the top
of `OUTPUT`. Manually moving Cilium's feeder back to position 1 restored probes instantly,
confirming ordering alone decides the outcome.

## Why it took so long

Three things pointed at Cilium, which was never at fault.

**A real Cilium bug arrived the same night.** A Renovate PR had bumped Cilium 1.19.6 → 1.20.0
hours earlier. On this kernel (`6.12.75+rpt-rpi-2712`) 1.20.0's SNAT program fails the BPF
verifier and `cilium_host` cannot attach. Genuine, required pinning back to 1.19.6, and made
Cilium the obvious — wrong — suspect for the unrelated probe failures.

**Cilium agents read config only at startup.** A values-only change, by `helm upgrade` or
`kubectl patch`, does not restart the DaemonSet. The ConfigMap and running agents disagreed for
hours, so several experiments never reached a running agent yet were recorded as ruled out. A
DaemonSet reporting `4/4 ready` is not evidence of a restart.

**A post-restart race produced a false positive.** Shortly after a Cilium restart a
policy-enforced pod answered a probe, then failed once its policy converged. That single passing
check was taken as proof of a fix; probes were re-enabled on it and the sites went down again.

Progress came from reading the datapath instead: `cilium config Debug=Enable` (runtime, no
restart) plus `cilium monitor -v -v` stated the cause outright — `Inheriting identity=2 from
stack` — and `iptables -L -v -n` counters showed 64,482 packets entering kube-router's chain
against only 63,746 reaching Cilium's.

## Separately: the Traefik outage

k3s 1.36.3 bundles Traefik chart v40.x, whose install job could not adopt the existing Traefik
CRDs because they lacked Helm ownership metadata. The job failed and the Traefik DaemonSet was
removed, taking down all ingress. Fixed by labelling the CRDs (`app.kubernetes.io/managed-by`
plus `meta.helm.sh/release-*`) and deleting the failed jobs. Unrelated, but it cost the first
hour and a full outage.

## Resolution

`disable-network-policy: true` in `/etc/rancher/k3s/config.yaml` on the server, then
`systemctl restart k3s-agent` on each agent — agents inherit the setting and take no flag of
their own. k3s does not remove kube-router's existing rules when disabled
([k3s-io/k3s#7244](https://github.com/k3s-io/k3s/issues/7244)), so stale jump rules had to be
deleted by hand before pods that already had chains recovered.

**This configuration lives on the nodes, not in this repo.** k3s is installed by shell script,
so nothing in Git reflects it. A node rebuilt without it brings the bug back silently.

## Actions

- [x] Disable k3s's NetworkPolicy controller; clear stale kube-router rules on all four nodes
- [x] Pin Cilium to 1.19.6 until the 1.20.x verifier failure is fixed upstream
- [x] Restore the readiness probes removed as a workaround
- [x] Add [cilium-pre-merge-check](../.claude/commands/cilium-pre-merge-check.md), which probes a
      *policy-selected* pod — the only case that reveals this fault
- [x] Hold Cilium Renovate PRs 30 days with a pre-merge warning
- [x] Disable the `kubeProxy`, `kubeScheduler`, `kubeControllerManager` scrape jobs — they have
      alerted falsely since build, since those components are embedded in k3s or replaced by
      Cilium. Silenced until 2026-08-08.
