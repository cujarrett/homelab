# Base Images

The platform builds one runtime base image per workload kind. Workload images build `FROM` one of them, so an OS fix lands here once and reaches every workload. The `rover` image is a tool the platform runs itself.

| Image | Built from | For |
|---|---|---|
| `ghcr.io/cujarrett/base-spa:1.31-alpine` | nginx Alpine, plus `apk upgrade` | Angular SPAs |
| `ghcr.io/cujarrett/base-go:static-debian13` | distroless static, Debian 13 | Go services |
| `ghcr.io/cujarrett/rover:main` | Apollo's rover, plus the `supergraph` plugin | PR routers, which compose their schema at startup |

Each tag names what is inside.

- **base-spa:** its tag matches the nginx tag it builds from. Renovate moves homelab and every SPA to each new nginx minor.
- **base-go:** a new Debian release gets a new tag, and each workload moves to it by hand.

## Use

Use the base as the runtime stage of the workload's Dockerfile. Renovate pins the digest on its first run.

```dockerfile
FROM ghcr.io/cujarrett/base-go:static-debian13
COPY --from=builder /app/foo /app/foo
ENTRYPOINT ["/app/foo"]
```

- **base-spa:** copy the built files to `/usr/share/nginx/html`. Leave out `apk upgrade`. The base already ran it.
- **base-go:** runs as the `nonroot` user. It has no shell.

## How a fix reaches an app

base-spa:
1. The [base-images](../.github/workflows/base-images.yml) workflow runs nightly. When Alpine has upgrades, it builds a dated tag, such as `1.31-alpine-2026-11-10`.
2. The same run moves `1.31-alpine` to the newest dated build that is at least 7 days old. A bad Alpine package gets a week to be caught before any app runs it.
3. Renovate in each SPA repo sees the new digest and automerges it.

To skip the cooldown for one build, run the workflow by hand with `promote` set to its dated tag. The run log records who promoted which build.

```bash
gh workflow run base-images.yml -R cujarrett/homelab -f promote=1.31-alpine-2026-11-11
```

base-go:
1. Renovate bumps the distroless digest in this folder after its 7-day wait.
2. The workflow rebuilds `static-debian13`.
3. Renovate in each Go repo automerges the new digest.
