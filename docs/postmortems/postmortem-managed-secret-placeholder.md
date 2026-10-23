# Postmortem: ManagedSecret Values Overwritten

On 2026-10-22 a Crossplane provider restart overwrote every `ManagedSecret` value in AWS with the
platform's "unset" placeholder. Nothing went down, because running pods kept the values they had
already fetched. Any new pod would have waited forever.

## Impact

- 2026-10-22 03:33 UTC: `launchpad-github-token`, `github-exporter-token` and `discogs-credentials`
  all became the placeholder at the same second.
- About 24 hours of exposure. A restart of launchpad-api, github-exporter or my-vinyl-api in that
  window would have left it unready.
- 2026-10-23 03:52 UTC: a launchpad-api deploy stuck on its sidecar, which is how it was found.

## Cause

The composition wrote the placeholder through a `SecretVersion` limited to `Observe` and `Create`,
so the owner's later value would survive reconciles. The provider never stored that version's
`crossplane.io/external-name`, likely because the narrowed management policy stopped it, and kept
track of the version only in its local Terraform workspace.

The GOMEMLIMIT change restarted `provider-aws-secretsmanager` at 03:31:41 UTC and the workspace
went with it. On its next `Observe` the provider found no external-name, decided the version did
not exist, and created a new one holding the placeholder, which became `AWSCURRENT`.

## Detection

Nothing alerted. The overwrite was found by chance a day later, by a stuck rollout.

## Actions

- [x] `AWSCURRENT` moved back to the owner's version on all three secrets, 2026-10-23 04:05 UTC
- [x] The ManagedSecret composition composes no `SecretVersion`. The secret is created with no
      value, so nothing the platform owns can write one.
- [x] secret-fetcher treats a secret with no version as "waiting for value", replacing the
      placeholder check
- [x] `ManagedSecretWaiting` fires when `workload-identity-sidecar` runs unready for 10 minutes
