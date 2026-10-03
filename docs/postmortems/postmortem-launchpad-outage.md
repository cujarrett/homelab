# Postmortem: Launchpad Outage

On 2026-10-02 Launchpad could not list workspaces for an hour, and while fixing it we found the
page had been rendering without most of its styles. The two faults were unrelated.

## Impact

- 23:45 to 00:44 UTC: `/api/workspaces` returned 502. Sandbox creation and guest cleanup failed.
- From 00:55 UTC: every repo that deploys to `homelab-workspaces` failed its `deploy` job.
- Unknown start: Launchpad and Connections rendered mostly unstyled.

## Causes

**GitHub tokens.** `launchpad-api` got a 401 on every GitHub call from 23:45:55, seven seconds
before `HOMELAB_WORKSPACES_PAT` was updated in a token rotation. The likely cause is a token
value placed in the wrong spot, since the token names `homelab-workspaces-launchpad` and
`homelab-workspaces-deploy` are easy to confuse. This is inferred from timing. The values were
not compared.

**Stylesheet.** Angular's production build loads the global stylesheet as `media="print"` and
switches it on with an inline script. Every Spa's Content-Security-Policy blocks inline scripts,
so the switch never runs. Sites that keep their styles in components look fine. Launchpad and
Connections keep most of theirs in the global stylesheet.

## Detection

`TargetDown` fired 25 minutes in, only because `/metrics` also calls GitHub. Nothing caught the
styling, since every page still returned 200.

## Actions

- [x] New Launchpad token patched into its Secret at 00:43. The API recovered with no restart.
- [x] [GitHub Token Rotate](../../scripts/github-token-rotate/) covers all three tokens, refuses
      a token pasted for the wrong job, and tests it where it lands
- [x] All three tokens rotated with it
- [x] Launchpad sets `inlineCritical: false` in `angular.json`, so the build emits a plain
      stylesheet link
- [x] Same change in `platform-connections-demo/spa`, `js-pollock`, `mattjarrett.dev`, `my-vinyl`
- [x] `LaunchpadGitHubTokenRejected` fires within about ten minutes of GitHub rejecting the
      token. `/metrics` now always answers, so the counter is scraped even while GitHub is failing.
