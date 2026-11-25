# Update Lanes

Renovate opens dependency updates for every repo. It waits 7 days after a release, then merges on its own. Hijacked or broken releases are usually found and pulled within that week, before they reach the cluster.

Rules: [shared preset](../.github/renovate-shared.json) for every repo, plus the [homelab config](../renovate.json).

# Exceptions

Some updates wait less or not at all. A few always wait for a person.

| Wait | Applies to |
|---|---|
| No wait | Digest pins of a running tag, this account's own images (`ghcr.io/cujarrett/*`), and WordPress digest rebuilds |
| 3 days | CVE fixes in `go.mod` or `package.json`, and the daily npm lockfile refresh |
| 7 days from the branch | Registries with no release dates (GHCR, Quay, GCR, `registry.k8s.io`, ECR, Upbound, Crossplane), and tags with no version, such as `trixie-slim` |
| A person merges | Majors, and action tags moved to a new commit. In this repo, also AdGuard, SPIRE minors and Apollo federation minors |

Base images rebuild nightly and reach their main tag after 7 days. See [Base Images](../images/README.md#how-a-fix-reaches-an-app).

# Skipping the wait

A CVE fix can skip the wait only when all three hold.

- The CVE is exploited or scores 9+.
- The image is [public](./cluster.md#public). cloudflared and Traefik count.
- The running process loads the vulnerable code.

`ExploitedCVERunning` and `CriticalCVEPublic` flag candidates. Run `/cve-check <CVE>` to decide.
