# WordPress Custom Login Slug

Move `/wp-login.php` to a non-standard URL on `mattjarrett.com` to reduce brute-force exposure.

## Plan

In `platform/wordpress/composition.yaml`, update the existing `wp-security` IngressRoute and add a new Traefik `replacepath` Middleware:

1. **Add a `replacepath` middleware** — rewrites `/<custom-slug>` → `/wp-login.php`
2. **Update the IngressRoute** (`wp-security`) so:
   - `/<custom-slug>` → applies replacepath + rate-limit middleware → WordPress
   - `/wp-login.php` (direct access) → 404
3. Keep `/xmlrpc.php` on the existing rate-limited route (already disabled at app layer too)

## Before starting

Decide on a custom slug — avoid obvious values like `/login`, `/signin`, `/admin`.
