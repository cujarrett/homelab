# Base Images

The platform builds one runtime base image per app kind. App images build `FROM` one of them, so an OS fix lands here once and reaches every app.

| Image | Built from | For |
|---|---|---|
| `ghcr.io/cujarrett/base-spa:nginx1.31-alpine` | nginx Alpine, plus `apk upgrade` | Angular SPAs |
| `ghcr.io/cujarrett/base-go:static-debian13` | distroless static, Debian 13 | Go services |

Each tag names what is inside. A new nginx minor or Debian release gets a new tag, and each app moves to it by hand.

## Use

Use the base as the runtime stage of the app's Dockerfile. Renovate pins the digest on its first run.

```dockerfile
FROM ghcr.io/cujarrett/base-go:static-debian13
COPY --from=builder /app/foo /app/foo
ENTRYPOINT ["/app/foo"]
```

- **base-spa:** copy the built files to `/usr/share/nginx/html`. Leave out `apk upgrade`. The base already ran it.
- **base-go:** runs as the `nonroot` user. It has no shell.

## How a fix reaches an app

base-spa:
1. The [base-images](../.github/workflows/base-images.yml) workflow runs nightly. When Alpine has upgrades, it builds a dated tag, such as `nginx1.31-alpine-2026-11-10`.
2. The same run moves `nginx1.31-alpine` to the newest dated build that is at least 7 days old. A bad Alpine package gets a week to be caught before any app runs it.
3. Renovate in each SPA repo sees the new digest and automerges it.

To skip the cooldown for one build, run the workflow by hand with `promote` set to its dated tag. The run log records who promoted which build.

```bash
gh workflow run base-images.yml -R cujarrett/homelab -f promote=nginx1.31-alpine-2026-11-11
```

base-go:
1. Renovate bumps the distroless digest in this folder after its 7-day wait.
2. The workflow rebuilds `static-debian13`.
3. Renovate in each Go repo automerges the new digest.
