# WordPress Backup and Restore

Back up a running site with a script, then restore a backup into the homelab `Wordpress` stack.

## Back up the cluster

```bash
./scripts/wordpress/backup-wordpress.sh \
  --namespace mattjarrett-com \
  --instance  mattjarrett-com
```

- Output: `wordpress-backup.sql` and `wp-content.tar.gz` in `~/Desktop/wp-backups/<instance>/<date-time>`, unless `--backup-dir` is given.
- Version drift across sites: [status-wordpress.sh](../../scripts/wordpress/status-wordpress.sh).

## Export from an existing site

Skip this when the backup came from the script above. A restore needs a database dump and the `wp-content` directory.

SSH into the server and find the database credentials.

```bash
grep -E "DB_NAME|DB_USER|DB_PASSWORD" /var/www/html/wp-config.php
```

Export the database, archive `wp-content`, and copy both to your Mac.

```bash
mysqldump -u <DB_USER> -p<DB_PASSWORD> <DB_NAME> > wordpress-backup.sql
tar czf wp-content.tar.gz -C /var/www/html wp-content
scp user@host:~/wordpress-backup.sql user@host:~/wp-content.tar.gz ~/Desktop/wp-backup/
```

With WP-CLI on the server, the export is shorter.

```bash
wp db export wordpress-backup.sql --allow-root
tar czf wp-content.tar.gz wp-content/
```

## Prerequisites

- XR applied, both pods `Running` (`kubectl get pods -n <namespace>`).
- A backup folder on your Mac with `wordpress-backup.sql`, plus `wp-content/` or `wp-content.tar.gz`.

## Run the restore script

```bash
./scripts/wordpress/restore-wordpress.sh \
  --backup-dir  ~/Desktop/wp-backups/mattjarrett-com/<date-time> \
  --namespace   mattjarrett-com \
  --instance    mattjarrett-com \
  --old-url     https://mattjarrett.com \
  --new-url     https://mattjarrett.com
```

| Flag | Value |
|---|---|
| `--backup-dir` | The folder holding the SQL dump and `wp-content` |
| `--namespace` | Where the XR runs |
| `--instance` | The XR's `metadata.name`. The script finds the pods by it |
| `--old-url` | The domain baked into the dump |
| `--new-url` | The real public domain. Cloudflare Tunnel routes it to the cluster. Never the `.local.lab` hostname |

The script waits for both pods to be `Ready`. Then it imports the dump, rewrites `--old-url` to `--new-url`, and extracts `wp-content` with the right ownership.

What the restore carries over:

| Item | How it carries over |
|---|---|
| URL rewrite | Covers `wp_options` (siteurl, home), `wp_posts` content and GUIDs, and `wp_postmeta`. A custom table prefix needs the script's SQL edited |
| Credentials | Come from the dump, so the old admin login works |
| Media and plugins | Restored with the whole `wp-content` tree. Plugins and themes may need reactivating in wp-admin |

## Verify

Then log in at `https://mattjarrett.com/wp-admin` with the original credentials.

```bash
curl -sk https://mattjarrett.com | grep -i wordpress
```

## Upgrade MariaDB

One image line in [the Wordpress composition](../../platform/wordpress/composition.yaml) sets MariaDB for every site. A major update restarts every site's database at once, for about a minute.

1. Check the new major is a Long Term Support release on [MariaDB's release list](https://mariadb.org/mariadb/all-releases/). Rolling releases lose support when the next one ships.
2. Back up every site, running the [backup script](#back-up-the-cluster) once per site.
3. Merge the Renovate PR. `MARIADB_AUTO_UPGRADE` upgrades the system tables on first start.
4. Confirm the version and that each site serves.
   ```bash
   kubectl exec -n mattjarrett-com mattjarrett-com-mariadb-0 -- mariadb --version
   curl -s -o /dev/null -w '%{http_code}\n' https://mattjarrett.com
   ```

Data files from a new major do not open on the old one. To go back, in order:

- Revert the image.
- Delete the site's `<instance>-mariadb-data` PVC, then its `<instance>-mariadb-0` pod. Crossplane creates an empty volume.
- [Run the restore script](#run-the-restore-script) with the backup from step 2.

## Gotchas

**Traefik keeps broken routers.** If Traefik loaded the HTTPRoute before its `Middleware` existed, it holds that router as errored. Traefik v3 does not re-check on Kubernetes changes. Once the XR shows `READY: True`, restart Traefik.

```bash
kubectl rollout restart daemonset/traefik -n kube-system
```

**A cluster wipe can leave the PV behind.** With `longhorn-retain`, the PV goes to `Released`. Rebind it before the restore, or the script fills a fresh empty volume.

1. Clear the PV's `claimRef`: `kubectl patch pv <pv-name> --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'`
2. Mark the PVC as Crossplane's: `kubectl annotate pvc <pvc-name> -n <namespace> crossplane.io/composition-resource-name=<resource-name>`. Use `wordpress-pvc` for `<instance>-wp-content` and `mariadb-pvc` for `<instance>-mariadb-data`.
3. Confirm the XR is `SYNCED: True` before running the restore script.
