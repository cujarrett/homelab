---
description: Review Spa and Wordpress pod logs for security issues - credential leaks, scanner 200s, brute-force attempts, and hardening gaps.
---

Review the last 7 days of logs across all Spa and Wordpress pods for security issues.

## Spa pods

Pull nginx (`-c spa`) logs for every Spa in the cluster. List them, rather than working from memory:

```bash
kubectl get spa -A
```

For each, check:

1. **Paths returning 200 that shouldn't** - filter `" 200 "` then exclude known-good patterns (`.js`, `.css`, `.png`, `.ico`, `.woff`, `.svg`, `.webmanifest`, `robots.txt`, `.jpg`, `sitemap`, `/`, `/login`, `/main-`, `/chunk-`, `/styles-`, `/favicon`). Any remaining 200s on probed paths (`.env`, `.git`, config files, credentials) are a hardening gap in the composition nginx config.

2. **Scanner sweeps** - bursts of 4xx on credential/config paths. Note the User-Agent, frequency, and what was probed. No action needed if all returning 404, but flag if volume is high.

3. **Unexpected POST/PUT/DELETE** - SPAs should only serve GET. A POST returning anything other than 405 is suspicious.

4. **New probe patterns not covered by existing blocks** - compare against the blocked paths in [platform/spa/composition.yaml](../../platform/spa/composition.yaml). If a probe returns 200 via the SPA catch-all (`try_files`), a new nginx `location` block is needed.

5. **Stale running config** - before concluding a probe path is a hardening gap, check whether it's already blocked in the current composition source but just not live yet. Compare live config (`kubectl exec deploy/<name> -n <namespace> -c spa -- nginx -T`) against [platform/spa/composition.yaml](../../platform/spa/composition.yaml). The Spa composition hashes nginx.conf into a pod annotation, so a config change rolls the Deployment on its own. A pod still serving old config means `platform-definitions` has not synced yet, or the roll failed. Sync, then check the rollout:
```bash
argocd app sync platform-definitions --grpc-web
kubectl rollout status deployment/<name> -n <namespace>
```

## Verifying a fix against a public hostname

Always send a browser User-Agent. Cloudflare 403s a bare `curl` UA at the edge, so a raw `curl` can't tell "my nginx rule denied it" from "the request never reached nginx" - both look like a non-200.

```bash
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
curl -s -o /dev/null -w '%{http_code}\n' -A "$UA" https://<host>/<probed-path>
```

Check a known-good path in the same run. If `/` doesn't return 200 with the same UA, the probe result means nothing.

A response served by nginx carries an `x-envoy-decorator-operation` header; a Cloudflare edge block does not. Use that to tell the two apart when a status is ambiguous.

## Client IP is not in the logs

Traefik binds hostPorts, so both nginx and WordPress log the node IP (`192.168.10.100-103`), not the originating client. Per-IP attribution, "single IP" burst correlation, and "is this admin access from off-LAN" are all unanswerable from these logs - say so rather than reporting node IPs as if they were sources. Distinguish scanners by User-Agent, path pattern, and timing instead.

## Log window is bounded by pod age

`--since=168h` returns only what the current pod has written. Check `kubectl get pods` age first, and state the real coverage in the report - a pod restarted 11 hours ago gives an 11-hour review, not a 7-day one.

## Wordpress pods

Pull logs for the wordpress container in each namespace:
- `mattjarrett-com`
- `kentjarrett-com`

Both `mattjarrett-com` and `kentjarrett-com` have MFA enabled (Two-Factor plugin, TOTP + recovery codes) - a correct password alone can't complete a login on either site. Factor this into severity when reporting brute-force volume: still worth flagging bursts, but a password-guessing burst is not an imminent account-takeover risk the way it would be on a password-only site.

1. **`/wp-login.php` brute force** - count POST attempts. Flag if > 10 in a rolling hour. Note user agents. Also flag any burst where per-request User-Agent rotates on every request within a tight time window (seconds apart) - that's a scripted credential-stuffing tool, not manual guessing, and is worth calling out even if the raw hourly count looks unremarkable.

2. **Successful logins vs failed** - a POST to `/wp-login.php` returning 302 (redirect to wp-admin) indicates success. A 200 response is a failed login (WP re-renders the form).

3. **Known vulnerability scans** - `/wp-json/gravitysmtp/`, `/xmlrpc.php`, `/wp-includes/wlwmanifest.xml`, `/.git`, `/.env`. All should be 404.

4. **Unexpected admin access** - any `GET /wp-admin/` returning 200. `install.php` returning 200 is stock WordPress serving its "Already Installed" page, not a session. Anything else means an authenticated request got through, so report it with its User-Agent and timing.

5. **Rate-limit effectiveness** - both WordPress instances have a Traefik rate-limit Middleware on `/wp-login.php`, `/xmlrpc.php`, `/wp-json/wp/v2/users` (see [platform/wordpress/composition.yaml](../../platform/wordpress/composition.yaml), keyed on the `CF-Connecting-IP` header). If a brute-force burst's request count exceeds the configured `burst`/`average` thresholds with no corresponding 429s in the log, flag it - the middleware may not be binding correctly (e.g., header not reaching Traefik as expected) rather than assume it's providing protection.

   The rate limit is attached to a dedicated `<name>-wp-security` IngressRoute, not to the main Ingress - that Ingress's `router.middlewares` annotation lists only the headers middleware, so its absence there is not evidence the limit is unbound. Confirm with:
```bash
kubectl get ingressroute <name>-wp-security -n <namespace> -o jsonpath='{.spec.routes}'
```
   The `www.` host does not bypass it - Cloudflare 301s to the apex before the request reaches Traefik.

## Output format

**Clean run: one or two lines, nothing else.**

- Line 1: `No leaks, no compromise.` plus real coverage in hours, e.g. `Coverage 11-38h.`
- Line 2, only if needed: one gut-check, e.g. `Confirm the 04:12 UTC mattjarrett.com admin login was you.`

No counts, rates, User-Agents, 429 totals, rate-limit confirmation or scanner summary on a clean run.

**Something actionable: one bullet per finding**, with the fix command inline. Spend the words only there. Add more only for a live compromise.

If new nginx hardening is needed (the block does not exist in source at all, not a stale-pod issue), fix it/ them, followed by the sync and restart commands:
```bash
argocd app sync platform-definitions --grpc-web
kubectl rollout restart deployment/<name> -n <namespace>
```
