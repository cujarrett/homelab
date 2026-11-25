# Dependency Automation

Renovate opens dependency pull requests and merges most of them on its own. A person sees only what CI cannot judge: a major version, or a change whose failure does not fix itself. Wait times are in [Update Lanes](../../docs/update-lanes.md).

## How it works

Renovate merges with its own app credentials. No workflow or secret lives in the repo. Policy lives in [.github/renovate-shared.json](../../.github/renovate-shared.json), and every other repo carries one line.

```json
{ "extends": ["github>cujarrett/homelab//.github/renovate-shared"] }
```

| Topic | Detail |
|---|---|
| The `//` | Renovate's subdirectory separator. A bare `github>cujarrett/homelab` loads this repo's own `renovate.json`, which holds cluster-only rules |
| Shipping a change | Repos track the default branch, so an edit ships on push |
| Why not Dependabot | GitHub gives its pull requests a read-only token. Automerge would need a privileged `pull_request_target` workflow in every repo |

A pull request merges on its own only when all four hold.

| Gate | Rule | Set by |
|---|---|---|
| Update type | Minor, patch or digest | `matchUpdateTypes` in the shared preset |
| Checks | Every required status check passed | Branch protection on each repo |
| Age | The release is at least 7 days old | `minimumReleaseAge` in the shared preset |
| Exclusions | The package has no `automerge: false` rule | `automerge: false` rules in the shared preset or the repo's `renovate.json` |

A published vulnerability waits 3 days instead of 7 and still has to pass CI. The [SDLC dashboard](../../cluster/monitoring/grafana-dashboard-sdlc.yaml) tracks the share of merges no person clicked. A pull request armed for automerge but stuck on a failing check counts as toil.

## Who may merge without review

GitHub grants review bypass to an actor, never to a condition. It cannot be limited to an author, an update type or a passing check.

- **One maintainer (today):** no review requirement. The status check is the gate. With the requirement on, every automated merge sits in `BLOCKED` while checks show green.
- **A second committer:** keep the requirement and give the Renovate app a ruleset bypass. Major versions are then held only by `automerge: false`, so the exclusion list matters more.

## What never automerges

Every major version reaches a person. So do these.

| Excluded | Why a person looks first |
|---|---|
| AdGuard Home | It rolls out with `Recreate`, and `ctrl-1` resolves DNS through AdGuard. A cold image pull fails with `ImagePullBackOff`, and DNS stays down until a person fixes it. Run [/adguard-pre-pull](../../.claude/commands/adguard-pre-pull.md) first |
| SPIRE minor and major | Patches keep the same server version and automerge. The chart moves the server and the agent together. [workload-identity-sidecar](https://github.com/cujarrett/workload-identity-sidecar) talks to the agent through its own pinned `go-spiffe` library. Check the two still match before merging |
| Federation minor (`apollographql/federation-rs`) | Check the PR router in `composition-pr.yaml` supports the new federation version |
| A GitHub Action whose version tag moved to a new commit | A moved tag is how a hijacked action spreads. A person reads the new commit first |

Add a package here only if the person merging does something CI and the wait do not. Crossplane, Istio, Kyverno, External Secrets and WordPress stay automated.
