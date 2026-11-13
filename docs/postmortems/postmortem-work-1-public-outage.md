# Postmortem: Public Sites Down With work-1

On 2026-11-13 `work-1` stopped responding and every public site went down with it. Cloudflare was healthy. The tunnel sends all traffic to `work-1`'s own address, so one Pi took out every public hostname.

## Impact

- From 06:31 UTC: every hostname behind the Cloudflare tunnel failed. That includes Launchpad, `oidc.mattjarrett.dev`, `kentjarrett.com`, `mattjarrett.dev` stats and the ArgoCD webhook.
- AWS could not fetch the SPIRE OIDC documents, so new workload identity token exchanges failed.
- Internal `*.local.lab` sites stayed up.

## Causes

**work-1 lost power or hung below the kernel.** It stopped all at once at about 06:31:30 UTC.

- The last scrapes looked normal: 4 GB memory free, load 0.7, 38C.
- No attack. Traffic stayed under 1 request a second, and no node is reachable from the internet.
- The hardware watchdog was on, with a 1 minute timeout. A kernel hang would have rebooted the Pi on its own.
- It stayed dead until someone power-cycled it. So the board itself stopped: power from the PoE HAT, or a hardware fault.
- The nodes keep logs in memory only, so nothing from before the crash survived.

**The tunnel targets one node.** Every ingress rule points at `https://192.168.10.101:443`. Traefik runs on all four nodes, but the tunnel only ever reaches the copy on `work-1`.

## Detection

- The `aws-oidc` and `argocd-webhook` probes failed from 06:31 UTC. No alert read them.
- `KubeNodeNotReady` fired at 06:48 UTC, after its 15 minute wait, as a warning.
- It arrived with alerts from 15 other namespaces at once. Discord rate-limited the burst and Alertmanager dropped four groups without retrying.

## Recovery

`work-1` took 7m23s from power-on to Ready. Its network was blocked by the stopgap that kept the sites up.

- 12:23:17 UTC: the kernel starts.
- 12:23:27: the link comes up. NetworkManager finds `192.168.10.101` already held by `work-2`, so it refuses to set the address and keeps retrying.
- 12:24 to 12:30: k3s fails five times with no default route.
- 12:30:36: `work-2` has dropped the address. The network comes up.
- 12:30:40: Ready.

Without the clash, the network is up 10 seconds after the kernel starts. The node's clock also read about 2 minutes slow until it reached a time server, so log times before 12:30:40 need that correction.

## Side effects

- **Stats page:** mattjarrett.dev showed work-2 at -604% CPU. Prometheus read work-2's counters under `work-1`'s address while `work-2` held it.
- **Power outage date:** the stats page said "0 days since power outage". One missed scrape on another node while `work-1` booted put the count of nodes up below 3.
- **Memory:** pods moved off `work-1` filled `work-2` to 91% of its memory requests. Kubernetes never moves them back on its own.
- **A Mac's DNS cache:** it kept a "no such host" answer for `kargo.local.lab` from the outage. Kargo itself stayed up.
- **No switch log:** the Netgear GS305PP is unmanaged, so nothing recorded whether `work-1`'s port lost power.

## Actions

- [x] `PublicSitesDown` (critical) fires after 3 minutes of every public probe failing while the internet is up. See [availability rules](../../cluster/monitoring/prometheusrule-availability.yaml).
- [x] `NodeDown` (critical) fires after 3 minutes of a node's exporter not answering.
- [x] `work-2` took `work-1`'s address with `ip addr add`, so the tunnel reached Traefik there. Public sites recovered.
- [x] 12:23 UTC: `work-1` power-cycled. 12:30: address removed from `work-2`, and `work-1` was Ready four seconds after.
- [x] The [journald DaemonSet](../../cluster/node-sysctls/journald.yaml) keeps each node's journal on disk. Raspberry Pi OS keeps it in memory by default, so `work-1`'s log from before the crash was lost and the cause is unknown.
- [x] Every tunnel rule points at the in-cluster Traefik Service, so any healthy node serves public traffic. [The tunnel hostname skill](../../.claude/commands/add-cloudflare-tunnel-hostname.md) matches.
- [x] Discord alerts group by severity, so a node failure sends at most three messages.
- [x] homelab-stats clamps node CPU to 0 to 100, and counts a power outage only after two samples in a row with under 3 nodes up.
- [x] Crossplane core and four AWS providers moved off `work-2`, taking its memory requests from 91% to 64%.
