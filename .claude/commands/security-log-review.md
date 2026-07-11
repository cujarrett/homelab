---
description: Review XSpa and XWordpress pod logs for security issues — credential leaks, scanner 200s, brute-force attempts, and hardening gaps.
---

Review the last 7 days of logs across all XSpa and XWordpress pods for security issues.

## XSpa pods

Pull nginx (`-c spa`) logs for each namespace:
- `js-pollock`
- `launchpad`
- `mattjarrett-dev`
- `my-vinyl`

For each, check:

1. **Paths returning 200 that shouldn't** — filter `" 200 "` then exclude known-good patterns (`.js`, `.css`, `.png`, `.ico`, `.woff`, `.svg`, `.webmanifest`, `robots.txt`, `.jpg`, `sitemap`, `/`, `/login`, `/main-`, `/chunk-`, `/styles-`, `/favicon`). Any remaining 200s on probed paths (`.env`, `.git`, config files, credentials) are a hardening gap in the composition nginx config.

2. **Scanner sweeps** — bursts of 4xx on credential/config paths from a single IP. Note the IP, frequency, and what was probed. No action needed if all returning 404, but flag if volume is high.

3. **Unexpected POST/PUT/DELETE** — SPAs should only serve GET. A POST returning anything other than 405 is suspicious.

4. **New probe patterns not covered by existing blocks** — compare against the blocked paths in [platform/spa/composition.yaml](../../platform/spa/composition.yaml). If a probe returns 200 via the SPA catch-all (`try_files`), a new nginx `location` block is needed.

5. **Stale running config** — before concluding a probe path is a hardening gap, check whether it's already blocked in the current composition source but just not live yet. Compare live config (`kubectl exec deploy/<name> -n <namespace> -c spa -- nginx -T`) against [platform/spa/composition.yaml](../../platform/spa/composition.yaml). If the block already exists in source but is missing live, this is a stale-pod issue, not a missing-rule issue — the fix is a rollout restart, not a new `location` block. There's no ConfigMap-hash annotation on the XSpa Deployment template, so nginx.conf changes never trigger an automatic rollout; any pod that hasn't restarted since the fixing commit landed will keep leaking. Give the exact restart command:
```bash
kubectl rollout restart deployment/<name> -n <namespace>
```

## XWordpress pods

Pull logs for the wordpress container in each namespace:
- `mattjarrett-com`
- `kentjarrett-com`

Both `mattjarrett-com` and `kentjarrett-com` have MFA enabled (Two-Factor plugin, TOTP + recovery codes) — a correct password alone can't complete a login on either site. Factor this into severity when reporting brute-force volume: still worth flagging bursts, but a password-guessing burst is not an imminent account-takeover risk the way it would be on a password-only site.

1. **`/wp-login.php` brute force** — count POST attempts. Flag if > 10 in a rolling hour. Note user agents and IPs. Also flag any burst where per-request User-Agent rotates on every request within a tight time window (seconds apart) — that's a scripted credential-stuffing tool, not manual guessing, and is worth calling out even if the raw hourly count looks unremarkable.

2. **Successful logins vs failed** — a POST to `/wp-login.php` returning 302 (redirect to wp-admin) indicates success. A 200 response is a failed login (WP re-renders the form).

3. **Known vulnerability scans** — `/wp-json/gravitysmtp/`, `/xmlrpc.php`, `/wp-includes/wlwmanifest.xml`, `/.git`, `/.env`. All should be 404.

4. **Unexpected admin access** — any `GET /wp-admin/` from an IP not in `192.168.10.0/24`.

5. **Rate-limit effectiveness** — both WordPress instances have a Traefik rate-limit Middleware on `/wp-login.php`, `/xmlrpc.php`, `/wp-json/wp/v2/users` (see [platform/wordpress/composition.yaml](../../platform/wordpress/composition.yaml), keyed on the `CF-Connecting-IP` header). If a brute-force burst's request count exceeds the configured `burst`/`average` thresholds with no corresponding 429s in the log, flag it — the middleware may not be binding correctly (e.g., header not reaching Traefik as expected) rather than assume it's providing protection.

## Output format

Give a TLDR first: a tight bullet list, one line per namespace/finding, verdict-first (what's wrong or "clean") — no preamble. Follow with **Action needed** items only as the detail section (skip restating "Clean"/"Informational" namespaces in detail — the TLDR already covered them). Use these verdict labels:

- **Clean** — nothing to act on
- **Informational** — expected scanner noise, all blocked correctly
- **Action needed** — a path returned 200 that should be blocked, brute-force volume is high, or a rate limit isn't binding

For any stale-config finding, include the `kubectl rollout restart` command inline in the TLDR line itself, not just in the detail section — it's the whole action.

If new nginx hardening is needed (i.e., the block doesn't exist in source at all, not just a stale-pod issue), propose the specific `location` block to add to [platform/spa/composition.yaml](../../platform/spa/composition.yaml) and remind to sync `platform-definitions` after pushing:
```bash
argocd app sync platform-definitions --grpc-web
```
