# WordPress Restore Guide

How to get a backup from an existing WordPress site and restore it into the homelab `XWordPressPlatform` stack.

---

## Part 1 — Getting backup files from an existing site

You need two things: a database dump and the `wp-content` directory.

### Option A — Bitnami WordPress on AWS Lightsail

SSH into the instance:

```bash
ssh -i ~/.ssh/your-key.pem bitnami@<LIGHTSAIL_IP>
```

Export the database:

```bash
cd ~
mysqldump -u bn_wordpress -p"$(cat /home/bitnami/bitnami_credentials | grep 'password' | awk '{print $NF}')" \
  bitnami_wordpress > wordpress-backup.sql
```

Archive wp-content:

```bash
tar czf wp-content.tar.gz -C /opt/bitnami/wordpress wp-content
```

Copy both files to your Mac:

```bash
scp -i ~/.ssh/your-key.pem \
  bitnami@<LIGHTSAIL_IP>:~/wordpress-backup.sql \
  bitnami@<LIGHTSAIL_IP>:~/wp-content.tar.gz \
  ~/Desktop/wp-backup/
```

---

### Option B — Self-hosted / generic WordPress

SSH into the server and find the database credentials in `wp-config.php`:

```bash
grep -E "DB_NAME|DB_USER|DB_PASSWORD" /var/www/html/wp-config.php
```

Export the database:

```bash
mysqldump -u <DB_USER> -p<DB_PASSWORD> <DB_NAME> > wordpress-backup.sql
```

Archive wp-content:

```bash
tar czf wp-content.tar.gz -C /var/www/html wp-content
```

Copy to your Mac:

```bash
scp user@host:~/wordpress-backup.sql user@host:~/wp-content.tar.gz ~/Desktop/wp-backup/
```

---

### Option C — WP-CLI (if available on the server)

```bash
wp db export wordpress-backup.sql --allow-root
tar czf wp-content.tar.gz wp-content/
```

---

## Part 2 — Restore into the homelab cluster

### Prerequisites

- XR applied and both pods `Running` (`kubectl get pods -n <namespace>`)
- Backup directory on your Mac containing:
  - `wordpress-backup.sql`
  - `wp-content/` directory **or** `wp-content.tar.gz`

### Run the restore script

```bash
./scripts/restore-wordpress.sh \
  --backup-dir  ~/Library/CloudStorage/Dropbox/Projects/Matt\ Jarrett\ Media/website/lightsail-backup \
  --namespace   mattjarrett-com \
  --instance    mattjarrett-com \
  --old-url     https://mattjarrett.com \
  --new-url     https://mattjarrett.com
```

| Flag | Description |
|---|---|
| `--backup-dir` | Local path to the folder containing `wordpress-backup.sql` and `wp-content/` (or `wp-content.tar.gz`) |
| `--namespace` | Kubernetes namespace the XR was deployed into |
| `--instance` | Name of the XR (`metadata.name` in the XR yaml) — used to find the correct pods |
| `--old-url` | The URL baked into the database dump — the domain the site was running on before the backup was taken (e.g. your old Lightsail address) |
| `--new-url` | The public domain the site will be served from going forward — Cloudflare Tunnel routes this to the cluster, so use the real domain, not the `.local.lab` hostname |

The script will:
1. Wait for MariaDB and WordPress pods to be `Ready`
2. Import the SQL dump into MariaDB
3. Rewrite all occurrences of `--old-url` → `--new-url` in the database
4. Extract `wp-content` into the WordPress pod and fix ownership

### Verify

```bash
curl -sk https://mattjarrett.com | grep -i wordpress
```

Log in at `https://mattjarrett.com/wp-admin` with your original credentials.

---

## Notes

- **URL rewrite** covers `wp_options` (siteurl/home), `wp_posts` content and GUIDs, and `wp_postmeta`. If you have a custom table prefix (not `wp_`), edit the script's SQL statements.
- **Credentials carry over** from the dump — your existing admin username/password will work after import.
- **Media** is in `wp-content/uploads/` — the script restores the whole `wp-content` tree so nothing is lost.
- **Plugins/themes** are restored from `wp-content` but may need reactivation from wp-admin if the database references are stale.
