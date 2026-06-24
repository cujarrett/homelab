---
description: Review staged/changed files before committing — checks for secrets, sensitive identifiers, PII, credential templates, and cluster safety. Reports whether changes are safe for a public repo and safe to apply to the homelab cluster.
---

Run `git diff HEAD` (or `git diff --cached` if changes are staged) to get all changed files, then review every changed file against the checks below. Report results inline — one section per check.

```bash
git diff HEAD
git diff --cached
git status
```

## Checks

### 1. Hardcoded secrets
Passwords, API keys, tokens, private keys, connection strings with credentials embedded.

### 2. Sensitive identifiers
- AWS account IDs
- Cloudflare account/tunnel IDs (flag any non-REDACTED values)
- Internal IPs outside the documented `192.168.10.0/24` range
- UUIDs that appear to be runtime secrets (not resource UIDs)

### 3. Personal data
Email addresses, full names, or other PII not already public.

### 4. Credentials in templates
Go-template or Helm values that embed literal secrets instead of referencing a Kubernetes Secret or external store.

### 5. Cluster safety
- No `kubectl delete` or other destructive operations baked into manifests
- No `hostNetwork: true` without justification
- No `privileged: true` without justification
- No `runAsRoot` or `runAsUser: 0` without justification

## Output format

Keep the output short. Only report issues found — skip empty checks entirely. End with two one-line verdicts:

**Safe for public repo?** Yes / No — reason if No.
**Safe to apply to homelab cluster?** Yes / No — reason if No.

If all checks pass with no issues, output only those two verdict lines.
