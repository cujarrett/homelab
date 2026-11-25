# Update Lanes

Renovate waits 7 days after a release, then merges on its own. The week catches hijacked or broken releases.

Rules: [shared preset](../.github/renovate-shared.json) for every repo, plus the [homelab config](../renovate.json).

# Exceptions

- No wait: digest pins of a running tag, this account's own images (`ghcr.io/cujarrett/*`), and WordPress digest rebuilds.
- 3 days: CVE fixes in `go.mod` or `package.json`, and the daily npm lockfile refresh.
- 7 days from the branch: registries with no release dates (GHCR, Quay, GCR, `registry.k8s.io`, ECR, Upbound, Crossplane) and tags with no version, such as `trixie-slim`.
- A person merges: majors, and action tags moved to a new commit.

Base images rebuild nightly and reach their main tag after 7 days. See [Base Images](../images/README.md#how-a-fix-reaches-an-app).

# Skipping the wait

Skip it for a CVE only when it is exploited or scores 9+, on a [public](./cluster.md#public) image (cloudflared and Traefik count), and loaded by the running process. `ExploitedCVERunning` and `CriticalCVEPublic` flag candidates. Run `/cve-check <CVE>` to decide.
