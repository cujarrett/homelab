---
description: Render every workspace XR against the current compositions and check the output is sane. Catches template errors, bad XRD schemas, and unintended changes to other apps before pushing. Requires Docker running locally.
---

# Render check

Run it from `platform/`:

```bash
just render-check
```

**Prerequisite:** Docker must be running — `crossplane render` pulls `function-go-templating` as a container.

## What it checks

Five gates. Each exists because that class of bug reached the cluster at least once.

| Gate | Catches |
|---|---|
| **schema** | An XRD whose enum holds a YAML boolean (`off`, `on`, `yes`, `no` unquoted), or a `default` outside its own enum. Kubernetes rejects the generated CRD, Crossplane leaves it at the old generation, and nothing logs why. A server-side dry-run does **not** catch this — the XRD is valid, only CRD generation fails. |
| **render** | `crossplane render` exits non-zero. |
| **parse** | Output is valid YAML and no block sequence collapsed into a single string. `crossplane render` exits 0 even when whitespace trimming (`{{- … -}}`) flattens a list, so exit code alone proves nothing. |
| **blast radius** | A composition edit changing an app you did not intend to touch. `Api` and `Spa` are shared by every workspace, so one edit reaches all of them. |
| **rbac** | A composed resource kind that [cluster/crossplane/rbac.yaml](../../cluster/crossplane/rbac.yaml) does not grant. Crossplane composes with its own ServiceAccount, so a kind the platform has never composed before renders perfectly and is then refused by the API server. The XR lands on `SYNCED=False` while staying `READY=True` — the app keeps serving and nothing looks broken. XR kinds and AWS managed resources are skipped; Crossplane grants those through its generated composite and provider roles. |

**What it does not check:** whether your *workspace* edits took effect. The comparison renders the current XR against `HEAD`'s composition, and workspaces live in a separate repo this script cannot read history for — so it answers "did my composition change break anyone else", not "did my XR change do what I meant". Verify workspace edits by reading the rendered output.

## Reading the output

- `ok … (composition change does not affect it)` — this is what every workspace you did not intend to touch must say.
- `ok … (CHANGED vs HEAD — review below)` — your composition edit reaches this app. Read the diff and confirm you meant it.
- `ok … (new)` — not present at `HEAD`, so there is nothing to compare against.
- `FAIL` — fix before pushing.

Workspaces are discovered from `../homelab-workspaces/*/*.yaml` by their `kind`, so new apps and new XR types are picked up automatically — nothing to keep in sync here.
