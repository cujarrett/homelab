# Dependency Automation

Most dependency pull requests are read once, glanced at, and merged. That glance catches almost nothing CI would have missed. The slice worth a human is what CI cannot judge: a major version, or a change whose failure does not self-correct.

## How it works

Renovate opens the pull request and merges it with its own app credentials, so no workflow and no secret live in the repository. Dependabot cannot do this - GitHub gives its pull requests a read-only token by design, so automerge there needs a privileged `pull_request_target` workflow in every repo. Its security updates also arrive outside any grouping, so a workflow matching grouped branches would skip exactly the pull requests that matter most.

Policy lives in [.github/renovate-shared.json](../../.github/renovate-shared.json). Every other repo carries one line:

```json
{ "extends": ["github>cujarrett/homelab//.github/renovate-shared"] }
```

The `//` is Renovate's subdirectory separator; a bare `github>cujarrett/homelab` would resolve to this repo's own `renovate.json`, which holds cluster-specific managers rather than shared policy. Repos track the default branch, so an edit ships on push.

A pull request merges on its own only when all four hold.

| Gate | Enforced by |
|---|---|
| Update is minor, patch, or a digest bump | `matchUpdateTypes` in the shared preset |
| Every required status check passed | GitHub branch protection on each repo |
| The release is at least 7 days old | `minimumReleaseAge` in the shared preset |
| The package is not on the exclusion list | `automerge: false` rules in the preset |

Nothing opens during working hours. A published vulnerability drops the age and schedule gates but still has to pass CI. The [SDLC dashboard](../../cluster/monitoring/grafana-dashboard-sdlc.yaml) tracks the share of merges no person clicked; one armed for automerge but stuck on a failing check still counts as toil.

## Who may merge without review

GitHub grants review bypass to an actor, never to a condition - it cannot be scoped to the author, the update type, or whether CI passed.

With one maintainer, drop the review requirement and let the status check be the gate. Approving your own bot catches nothing, and leaving the requirement on blocks every automated merge silently, the pull request sitting in `BLOCKED` while its checks show green. That is the current setup.

The day a second person can commit, keep the requirement and grant the Renovate app a ruleset bypass. It covers all of the bot's pull requests, so major versions are then held by `automerge: false` rather than by GitHub, which makes the exclusion list load-bearing. An auto-approval workflow instead satisfies the rule literally while defeating its purpose, and puts back the per-repo privileged file Renovate removed.

## What never automerges

Every major version reaches a person. Beyond that:

| Excluded | Why a person adds something |
|---|---|
| AdGuard Home | Its `Recreate` rollout plus `ctrl-1` resolving DNS through AdGuard itself means a cold image pull fails with `ImagePullBackOff`, and DNS stays down until a person fixes it. Run [/adguard-pre-pull](../../.claude/commands/adguard-pre-pull.md) first. |
| SPIRE | The chart moves the server and a separate pin in [workload-identity-sidecar](https://github.com/cujarrett/workload-identity-sidecar) moves the agent binary, so the two can skew. Merging means checking the running server version. |

The test for adding a row is whether the person clicking merge does something CI and the cooldown do not. Crossplane, Istio, Kyverno, External Secrets and WordPress were all considered and left automated.
