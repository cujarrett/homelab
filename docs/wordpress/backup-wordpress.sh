#!/usr/bin/env bash
# backup-wordpress.sh
# Backs up a WordPress site running in the Wordpress stack, producing exactly
# the layout restore-wordpress.sh expects:
#   <backup-dir>/wordpress-backup.sql
#   <backup-dir>/wp-content.tar.gz
#
# Usage:
#   ./docs/wordpress/backup-wordpress.sh \
#     --backup-dir  /path/to/backup \
#     --namespace   mattjarrett-com \
#     --instance    mattjarrett-com

set -euo pipefail

BACKUP_DIR=""
NAMESPACE=""
INSTANCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir)  BACKUP_DIR="$2";  shift 2 ;;
    --namespace)   NAMESPACE="$2";   shift 2 ;;
    --instance)    INSTANCE="$2";    shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

missing=()
[[ -z "$BACKUP_DIR" ]] && missing+=("--backup-dir")
[[ -z "$NAMESPACE" ]]  && missing+=("--namespace")
[[ -z "$INSTANCE" ]]   && missing+=("--instance")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required arguments: ${missing[*]}"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
SQL_FILE="$BACKUP_DIR/wordpress-backup.sql"
WP_CONTENT_TAR="$BACKUP_DIR/wp-content.tar.gz"

DB_POD=$(kubectl get pod -n "$NAMESPACE" -l "app=mariadb,instance=$INSTANCE" -o jsonpath='{.items[0].metadata.name}')
WP_POD=$(kubectl get pod -n "$NAMESPACE" -l "app=wordpress,instance=$INSTANCE" -o jsonpath='{.items[0].metadata.name}')
echo "==> MariaDB pod: $DB_POD"
echo "==> WordPress pod: $WP_POD"

echo "==> Dumping database..."
kubectl exec -n "$NAMESPACE" "$DB_POD" -- bash -c \
  'mariadb-dump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --single-transaction "$MYSQL_DATABASE"' \
  > "$SQL_FILE"

if ! grep -q "wp_options" "$SQL_FILE"; then
  echo "ERROR: dump looks wrong - wp_options not found in $SQL_FILE"
  exit 1
fi
echo "    $(du -h "$SQL_FILE" | cut -f1) - ok"

echo "==> Streaming wp-content (this can take a while for multi-GB sites)..."
kubectl exec -n "$NAMESPACE" "$WP_POD" -- \
  tar czf - -C /var/www/html wp-content \
  > "$WP_CONTENT_TAR"

echo "==> Verifying archive..."
tar tzf "$WP_CONTENT_TAR" > /dev/null
echo "    $(du -h "$WP_CONTENT_TAR" | cut -f1), $(tar tzf "$WP_CONTENT_TAR" | wc -l | tr -d ' ') entries - ok"

echo ""
echo "==> Backup complete: $BACKUP_DIR"
echo "    Restore with: ./docs/wordpress/restore-wordpress.sh --backup-dir $BACKUP_DIR --namespace $NAMESPACE --instance $INSTANCE --old-url <url> --new-url <url>"
