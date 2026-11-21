# Update Lanes

Most updates wait 7 days after release before they reach the cluster. The wait gives the community time to catch a hijacked or broken release, and a hijacked release can call itself a critical fix. A few updates go faster, each for a stated reason.

# Lanes

| Lane | Wait | Merges | Why |
|---|---|---|---|
| Digest pin of a tag already in use | None | Automerge | Pods pulling that tag already get this digest |
| `ghcr.io/cujarrett/base-*` in app repos | None | Automerge | The base image already waited 7 days in this repo |
| `ghcr.io/cujarrett/rover` | None | Automerge | Each build comes from a Renovate bump that already waited 7 days |
| `ghcr.io/cujarrett/workload-identity-sidecar` and `ghcr.io/cujarrett/apollo-router-arm64` | None | Automerge | Built and signed by this account's own CI |
| WordPress digest rebuild | None | Automerge | PHP and Debian security fixes arrive as a rebuild of the same tag |
| CVE fix in source code (`go.mod`, `package.json`) | 3 days | Automerge | Renovate learns of it from the OSV vulnerability database |
| Daily lockfile refresh in npm repos | 3 days, held by npm's `min-release-age` in each repo | Automerge | Renovate only bumps packages a repo lists directly, so this picks up fixes in the packages those pull in |
| Minor, patch or digest of any other image, chart or package | 7 days | Automerge | The default |
| Images from GHCR, Quay, GCR, `registry.k8s.io`, ECR Public, Upbound and Crossplane, and digest updates of tags with no version | 7 days from the PR branch's last commit | Automerge | These publish no release dates |
| Major version | 7 days | A person | A major can break the app |
| Action version tag that moved to a new commit | 7 days | A person | A moved tag is how a hijacked action spreads |
| Exploited CVE fix | None | A person, by hand | See below |

The rules live in the [shared Renovate preset](../.github/renovate-shared.json) and the [homelab Renovate config](../renovate.json).

# Base images

The nightly [base-images](../.github/workflows/base-images.yml) workflow rebuilds `base-nginx` and `base-nginx-unprivileged` whenever Alpine has upgrades. Each build gets a dated tag. The main tag moves to a build once it is 7 days old. [Base Images → How a fix reaches an app](../images/README.md#how-a-fix-reaches-an-app) has the details.

# Exploited and critical CVEs

A person can skip the wait for an exploited or critical CVE on a public image. Two alerts find them.

- `ExploitedCVERunning`: the CVE is on CISA's Known Exploited Vulnerabilities list (KEV).
- `CriticalCVEPublic`: the CVE scores 9 or higher. CISA often lists an exploit days after it starts.

Skip the wait only when all three hold.

- Exploited or critical: the CVE is on the KEV list, or scores 9 or higher.
- Public: the image serves a host in [Cluster → Public](./cluster.md#public), or is `cloudflared` or Traefik.
- Reachable: the running process loads the vulnerable package. A library that only ships with a CLI tool does not count.

Then bump the version in a PR. For a base image, promote its newest dated build by hand.

```bash
gh workflow run base-images.yml -R cujarrett/homelab -f image=base-nginx-unprivileged -f promote=1.31-alpine-2026-11-19
```

Any other match waits in its lane. Run `/cve-check <CVE>` to decide.
