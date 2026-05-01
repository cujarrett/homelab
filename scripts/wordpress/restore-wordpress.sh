#!/usr/bin/env bash
# restore-wordpress.sh
# Restores a WordPress site into the XWordPressPlatform stack.
#
# Usage:
#   ./scripts/restore-wordpress.sh \
#     --backup-dir  /path/to/backup \
#     --namespace   mattjarrett-com \
#     --instance    mattjarrett-com \
#     --old-url     https://old-site.example.com \
#     --new-url     https://mattjarrett.com        (public domain — Cloudflare Tunnel routes this to the cluster)
#
# Required backup-dir contents:
#   wordpress-backup.sql   (database dump)
#   wp-content/            (directory) OR wp-content.tar.gz

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
BACKUP_DIR=""
NAMESPACE=""
INSTANCE=""
OLD_URL=""
NEW_URL=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir)  BACKUP_DIR="$2";  shift 2 ;;
    --namespace)   NAMESPACE="$2";   shift 2 ;;
    --instance)    INSTANCE="$2";    shift 2 ;;
    --old-url)     OLD_URL="$2";     shift 2 ;;
    --new-url)     NEW_URL="$2";     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
missing=()
[[ -z "$BACKUP_DIR" ]]  && missing+=("--backup-dir")
[[ -z "$NAMESPACE" ]]   && missing+=("--namespace")
[[ -z "$INSTANCE" ]]    && missing+=("--instance")
[[ -z "$OLD_URL" ]]     && missing+=("--old-url")
[[ -z "$NEW_URL" ]]     && missing+=("--new-url")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required arguments: ${missing[*]}"
  exit 1
fi

SQL_FILE="$BACKUP_DIR/wordpress-backup.sql"
WP_CONTENT_DIR="$BACKUP_DIR/wp-content"
WP_CONTENT_TAR="$BACKUP_DIR/wp-content.tar.gz"

if [[ ! -f "$SQL_FILE" ]]; then
  echo "ERROR: SQL dump not found at $SQL_FILE"
  exit 1
fi

if [[ ! -d "$WP_CONTENT_DIR" ]] && [[ ! -f "$WP_CONTENT_TAR" ]]; then
  echo "ERROR: wp-content not found. Expected $WP_CONTENT_DIR/ or $WP_CONTENT_TAR"
  exit 1
fi

# ── Wait for pods ─────────────────────────────────────────────────────────────
echo "==> Waiting for MariaDB pod to be ready..."
kubectl wait pod \
  -n "$NAMESPACE" \
  -l "app=mariadb,instance=$INSTANCE" \
  --for=condition=Ready \
  --timeout=120s

echo "==> Waiting for WordPress pod to be ready..."
kubectl wait pod \
  -n "$NAMESPACE" \
  -l "app=wordpress,instance=$INSTANCE" \
  --for=condition=Ready \
  --timeout=120s

# ── Resolve pod names ─────────────────────────────────────────────────────────
DB_POD=$(kubectl get pod -n "$NAMESPACE" -l "app=mariadb,instance=$INSTANCE" -o jsonpath='{.items[0].metadata.name}')
WP_POD=$(kubectl get pod -n "$NAMESPACE" -l "app=wordpress,instance=$INSTANCE" -o jsonpath='{.items[0].metadata.name}')
echo "==> MariaDB pod: $DB_POD"
echo "==> WordPress pod: $WP_POD"

echo "==> Waiting for MariaDB to accept connections..."
until kubectl exec -n "$NAMESPACE" "$DB_POD" -- bash -c \
  'mariadb-admin -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" ping' &>/dev/null; do
  sleep 3
done

# ── Import database ───────────────────────────────────────────────────────────
echo "==> Copying SQL dump to MariaDB pod..."
kubectl cp "$SQL_FILE" "$NAMESPACE/$DB_POD:/tmp/wordpress-backup.sql"

echo "==> Importing database..."
kubectl exec -n "$NAMESPACE" "$DB_POD" -- bash -c \
  'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" < /tmp/wordpress-backup.sql'

# ── Rewrite site URL ──────────────────────────────────────────────────────────
if [[ -n "$OLD_URL" ]] && [[ "$OLD_URL" != "$NEW_URL" ]]; then
  echo "==> Rewriting site URL: $OLD_URL → $NEW_URL..."
  kubectl exec -n "$NAMESPACE" "$DB_POD" -- bash -c \
    "mariadb -u\"\$MYSQL_USER\" -p\"\$MYSQL_PASSWORD\" \"\$MYSQL_DATABASE\" -e \"
      UPDATE wp_options SET option_value = '$NEW_URL'
        WHERE option_name IN ('siteurl','home');
      UPDATE wp_posts SET post_content =
        REPLACE(post_content, '$OLD_URL', '$NEW_URL');
      UPDATE wp_posts SET guid =
        REPLACE(guid, '$OLD_URL', '$NEW_URL');
      UPDATE wp_postmeta SET meta_value =
        REPLACE(meta_value, '$OLD_URL', '$NEW_URL');
    \""
fi

# ── Import wp-content ─────────────────────────────────────────────────────────
if [[ -d "$WP_CONTENT_DIR" ]]; then
  echo "==> Archiving wp-content directory..."
  _tmpbase=$(mktemp /tmp/wp-content.XXXXXX)
  rm -f "$_tmpbase"
  WP_CONTENT_TAR="${_tmpbase}.tar.gz"
  tar czf "$WP_CONTENT_TAR" -C "$BACKUP_DIR" wp-content
  CLEANUP_TAR=true
fi

echo "==> Copying wp-content archive to WordPress pod..."
kubectl cp "$WP_CONTENT_TAR" "$NAMESPACE/$WP_POD:/tmp/wp-content.tar.gz"

echo "==> Extracting wp-content..."
kubectl exec -n "$NAMESPACE" "$WP_POD" -- bash -c \
  "tar xzf /tmp/wp-content.tar.gz -C /var/www/html/ 2>&1 | grep -v 'Ignoring unknown extended header'; rc=\${PIPESTATUS[0]}; rm -f /tmp/wp-content.tar.gz; exit \$rc"

# Fix ownership so Apache can serve files
kubectl exec -n "$NAMESPACE" "$WP_POD" -- bash -c \
  "chown -R www-data:www-data /var/www/html/wp-content"

if [[ "${CLEANUP_TAR:-false}" == "true" ]]; then
  rm -f "$WP_CONTENT_TAR"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> Restore complete."
echo "    Site: $NEW_URL"
echo "    Admin: $NEW_URL/wp-admin"
