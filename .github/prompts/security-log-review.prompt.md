---
agent: agent
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

## XWordpress pod

Pull logs for `mattjarrett-com` namespace (wordpress container):

1. **`/wp-login.php` brute force** — count POST attempts. Flag if > 10 in a rolling hour. Note user agents and IPs.

2. **Successful logins vs failed** — a POST to `/wp-login.php` returning 302 (redirect to wp-admin) indicates success. A 200 response is a failed login (WP re-renders the form).

3. **Known vulnerability scans** — `/wp-json/gravitysmtp/`, `/xmlrpc.php`, `/wp-includes/wlwmanifest.xml`, `/.git`, `/.env`. All should be 404.

4. **Unexpected admin access** — any `GET /wp-admin/` from an IP not in `192.168.10.0/24`.

## Summary format

Report findings as:

- **Clean** — nothing to act on
- **Informational** — expected scanner noise, all blocked correctly
- **Action needed** — a path returned 200 that should be blocked, or brute-force volume is high

If any new hardening is needed, propose the specific nginx `location` block to add to [platform/spa/composition.yaml](../../platform/spa/composition.yaml) and remind to sync `platform-definitions` after pushing:
```bash
argocd app sync platform-definitions --grpc-web
```
