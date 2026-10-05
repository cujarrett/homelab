# WordPress Backup and Restore

Back up a running site with a script, then restore a backup into the homelab `Wordpress` stack.

| Chapter | What it covers |
|---|---|
| [Back up the cluster](#back-up-the-cluster) | Dump a running site to a local folder |
| [Export from an existing site](#export-from-an-existing-site) | Produce a dump and `wp-content` outside the cluster |
| [Prerequisites](#prerequisites) | What a restore needs |
| [Run the restore script](#run-the-restore-script) | Import a backup into the `Wordpress` XR |
| [Verify](#verify) | Check the site is serving |
| [Notes](#notes) | What the restore rewrites |
| [Gotchas](#gotchas) | Traefik, and a wiped cluster |

## Back up the cluster

```bash
./scripts/wordpress/backup-wordpress.sh \
  --namespace mattjarrett-com \
  --instance  mattjarrett-com
```

Writes `wordpress-backup.sql` and `wp-content.tar.gz` to `~/Desktop/wp-backups/<instance>/<date-time>` unless `--backup-dir` is given. [status-wordpress.sh](../../scripts/wordpress/status-wordpress.sh) reports version drift across sites.

## Export from an existing site

A restore needs a database dump and the `wp-content` directory. Skip this chapter when the backup came from the script above.

SSH into the server and find the database credentials in `wp-config.php`:

```bash
grep -E "DB_NAME|DB_USER|DB_PASSWORD" /var/www/html/wp-config.php
```

Export the database, archive `wp-content`, and copy both to your Mac:

```bash
mysqldump -u <DB_USER> -p<DB_PASSWORD> <DB_NAME> > wordpress-backup.sql
tar czf wp-content.tar.gz -C /var/www/html wp-content
scp user@host:~/wordpress-backup.sql user@host:~/wp-content.tar.gz ~/Desktop/wp-backup/
```

With WP-CLI on the server, the export is:

```bash
wp db export wordpress-backup.sql --allow-root
tar czf wp-content.tar.gz wp-content/
```

## Prerequisites

- XR applied and both pods `Running` (`kubectl get pods -n <namespace>`)
- Backup directory on your Mac containing:
  - `wordpress-backup.sql`
  - `wp-content/` directory **or** `wp-content.tar.gz`

## Run the restore script

```bash
./scripts/wordpress/restore-wordpress.sh \
  --backup-dir  ~/Desktop/wp-backups/mattjarrett-com/<date-time> \
  --namespace   mattjarrett-com \
  --instance    mattjarrett-com \
  --old-url     https://mattjarrett.com \
  --new-url     https://mattjarrett.com
```

| Flag | Description |
|---|---|
| `--backup-dir` | Local path to the folder containing `wordpress-backup.sql` and `wp-content/` (or `wp-content.tar.gz`) |
| `--namespace` | Kubernetes namespace the XR was deployed into |
| `--instance` | Name of the XR (`metadata.name` in the XR yaml) - used to find the correct pods |
| `--old-url` | The URL baked into the database dump - the domain the site was running on before the backup was taken |
| `--new-url` | The public domain the site will be served from going forward - Cloudflare Tunnel routes this to the cluster, so use the real domain, not the `.local.lab` hostname |

The script will:
1. Wait for MariaDB and WordPress pods to be `Ready`
2. Import the SQL dump into MariaDB
3. Rewrite all occurrences of `--old-url` → `--new-url` in the database
4. Extract `wp-content` into the WordPress pod and fix ownership

## Verify

```bash
curl -sk https://mattjarrett.com | grep -i wordpress
```

Log in at `https://mattjarrett.com/wp-admin` with your original credentials.

---

## Notes

- **URL rewrite** covers `wp_options` (siteurl/home), `wp_posts` content and GUIDs, and `wp_postmeta`. If you have a custom table prefix (not `wp_`), edit the script's SQL statements.
- **Credentials carry over** from the dump - your existing admin username/password will work after import.
- **Media** is in `wp-content/uploads/` - the script restores the whole `wp-content` tree so nothing is lost.
- **Plugins/themes** are restored from `wp-content` but may need reactivation from wp-admin if the database references are stale.

---

## Gotchas

**Traefik caches broken routers and won't recover on its own.**
If Traefik loaded the Ingress before the `Middleware` resource existed, it marks that router as errored and holds it there. Kubernetes change events don't trigger re-evaluation in Traefik v3. After the XR is fully synced (`READY: True`), restart Traefik:

```bash
kubectl rollout restart daemonset/traefik -n kube-system
```

If the rollout hangs, the DaemonSet update strategy may be set to `maxSurge: 1` which conflicts with host port binding. Patch it first:

```bash
kubectl patch daemonset traefik -n kube-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/updateStrategy/rollingUpdate/maxUnavailable","value":1},{"op":"replace","path":"/spec/updateStrategy/rollingUpdate/maxSurge","value":0}]'
```

**After a cluster wipe, the PVC is gone but the PV may survive.**
If using `longhorn-retain`, the PV enters `Released` state. Rebind it before running the restore script - otherwise the script imports data into a fresh empty volume and the old data is still sitting in the released PV.

1. Clear the `claimRef` on the PV: `kubectl patch pv <pv-name> --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'`
2. Set the PVC's Crossplane annotation so it's recognized as managed: `kubectl annotate pvc <pvc-name> -n <namespace> crossplane.io/composition-resource-name=wordpress-pvc`
3. Confirm the XR is `SYNCED: True` before running the restore script.
