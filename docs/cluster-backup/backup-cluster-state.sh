#!/usr/bin/env bash
# Usage: ./docs/cluster-backup/backup-cluster-state.sh [--datastore]
#
# Captures cluster secrets, app data, and node config to ~/Desktop/cluster-backup/.
# Follow the printed instructions to encrypt and move to Dropbox, then delete the
# plaintext output.
#
# --datastore also copies the k3s control-plane datastore, which requires stopping
# k3s on ctrl-1 for about a minute. Off by default so a routine backup never takes
# the API server down. Use it before anything that reinstalls k3s.
set -uo pipefail

WITH_DATASTORE=false
for arg in "$@"; do
  case "$arg" in
    --datastore) WITH_DATASTORE=true ;;
    *) echo "unknown argument: $arg"; exit 2 ;;
  esac
done

OUT="$HOME/Desktop/cluster-backup"
CTRL1="pi@192.168.10.100"
WORK1="pi@192.168.10.101"
WORK2="pi@192.168.10.102"
WORK3="pi@192.168.10.103"

TENANT_NAMESPACES=(
  js-pollock
  kentjarrett-com
  launchpad
  mattjarrett-com
  mattjarrett-dev
  my-vinyl
  sump-pump
)

FAILED=()

ok()   { echo "  [ok] $1"; }
fail() { echo "  [FAIL] $1"; FAILED+=("$1"); }

mkdir -p "$OUT/nodes/ctrl-1" "$OUT/nodes/work-1" "$OUT/nodes/work-2" "$OUT/nodes/work-3"

# ── Kubernetes secrets ────────────────────────────────────────────────────────
echo "==> Kubernetes secrets"
kubectl get secret local-lab-ca-secret -n cert-manager -o yaml > "$OUT/local-lab-ca-secret.yaml" \
  && ok "local-lab-ca-secret.yaml" || fail "local-lab-ca-secret.yaml"

kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type -o yaml > "$OUT/argocd-repo-creds.yaml" \
  && ok "argocd-repo-creds.yaml" || fail "argocd-repo-creds.yaml"

kubectl get secrets -n cloudflare -o yaml > "$OUT/cloudflare-secrets.yaml" \
  && ok "cloudflare-secrets.yaml" || fail "cloudflare-secrets.yaml"

kubectl get environmentconfig aws-platform-config -o yaml > "$OUT/aws-platform-config.yaml" \
  && ok "aws-platform-config.yaml" || fail "aws-platform-config.yaml"

kubectl get secret aws-creds -n crossplane-system -o yaml > "$OUT/crossplane-aws-creds.yaml" \
  && ok "crossplane-aws-creds.yaml" || fail "crossplane-aws-creds.yaml"

kubectl get secret ghost-smtp -n blog -o yaml > "$OUT/ghost-smtp.yaml" \
  && ok "ghost-smtp.yaml" || fail "ghost-smtp.yaml"

kubectl get secret ghost-backup-creds -n blog -o yaml > "$OUT/ghost-backup-creds.yaml" \
  && ok "ghost-backup-creds.yaml" || fail "ghost-backup-creds.yaml"

kubectl get secret grafana-admin-secret -n monitoring -o yaml > "$OUT/grafana-admin-secret.yaml" \
  && ok "grafana-admin-secret.yaml" || fail "grafana-admin-secret.yaml"

for ns in "${TENANT_NAMESPACES[@]}"; do
  kubectl get secrets -n "$ns" -o yaml > "$OUT/tenant-secrets-${ns}.yaml" \
    && ok "tenant-secrets-${ns}.yaml" || fail "tenant-secrets-${ns}.yaml"
done

# ── Every secret in the cluster ───────────────────────────────────────────────
# Safety net for the targeted dumps above. ~9MB, and it means a secret added to a
# new namespace is never silently missing from a backup. Includes the demo-certs
# TLS secrets, which matter because Let's Encrypt allows only 5 certs per exact
# hostname per 168h - reissuing all ten would take days.
echo "==> Every secret in the cluster"
kubectl get secrets -A -o yaml > "$OUT/all-secrets.yaml" \
  && ok "all-secrets.yaml" || fail "all-secrets.yaml"

# ── SPIRE identity ────────────────────────────────────────────────────────────
# The spire-server container is distroless, so its datastore cannot be tarred out
# through kubectl exec. Capture the trust bundle and the registration entries
# instead: enough to tell whether the CA survived, and to rebuild the entries if
# it did not. A new CA means the AWS IAM Roles Anywhere trust anchor and anything
# pinning oidc.mattjarrett.dev must be updated by hand.
echo "==> SPIRE identity"
kubectl get configmap spire-bundle -n spire-server -o yaml > "$OUT/spire-bundle.yaml" \
  && ok "spire-bundle.yaml" || fail "spire-bundle.yaml"
kubectl get clusterspiffeids.spire.spiffe.io -o yaml > "$OUT/spire-clusterspiffeids.yaml" \
  && ok "spire-clusterspiffeids.yaml" || fail "spire-clusterspiffeids.yaml"
curl -s --max-time 15 https://oidc.mattjarrett.dev/.well-known/keys > "$OUT/spire-oidc-jwks.json" \
  && [[ -s "$OUT/spire-oidc-jwks.json" ]] \
  && ok "spire-oidc-jwks.json" || fail "spire-oidc-jwks.json"

# ── AdGuard config ────────────────────────────────────────────────────────────
echo "==> AdGuard config"
ADGUARD_POD=$(kubectl get pod -n adguard -l app=adguard-home -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n adguard "$ADGUARD_POD" -- cat /opt/adguardhome/conf/AdGuardHome.yaml > "$OUT/adguard-config.yaml" \
  && ok "adguard-config.yaml" || fail "adguard-config.yaml"

# ── Ghost ─────────────────────────────────────────────────────────────────────
# Use kubectl cp for the SQLite DB (single file, reliable over slow links).
# Tar images/files/settings separately, skipping logs (large, not needed for restore).
echo "==> Ghost content"
GHOST_POD=$(kubectl get pod -n blog -l app=ghost -o jsonpath='{.items[0].metadata.name}')

kubectl cp "blog/${GHOST_POD}:/var/lib/ghost/content/data/ghost.db" "$OUT/ghost.db" \
  && ok "ghost.db" || fail "ghost.db"

# Run kubectl FROM ctrl-1 (LAN connection, no Tailscale timeout).
# Stream tar to ctrl-1's /tmp, then scp to Mac.
ssh "$CTRL1" "sudo kubectl exec -n blog deploy/ghost -- sh -c 'cd /var/lib/ghost/content && tar czf - --exclude=logs --exclude=lost+found --exclude=public images files settings themes' > /tmp/ghost-media.tar.gz" \
  && scp -q "$CTRL1:/tmp/ghost-media.tar.gz" "$OUT/ghost-media.tar.gz" \
  && ssh "$CTRL1" "rm -f /tmp/ghost-media.tar.gz" \
  && ok "ghost-media.tar.gz" || fail "ghost-media.tar.gz"

# ── WordPress ─────────────────────────────────────────────────────────────────
echo "==> WordPress (mattjarrett-com)"
WP_DB_PASS=$(kubectl get secret mattjarrett-com-mariadb -n mattjarrett-com \
  -o jsonpath='{.data.password}' | base64 -d)

# Fetch password on ctrl-1 to avoid passing credentials through SSH arguments
ssh "$CTRL1" 'WP_DB_PASS=$(sudo kubectl get secret mattjarrett-com-mariadb -n mattjarrett-com -o jsonpath='"'"'{.data.password}'"'"' | base64 -d) && sudo kubectl exec -n mattjarrett-com sts/mattjarrett-com-mariadb -c mariadb -- mariadb-dump -u wordpress -p"$WP_DB_PASS" wordpress > /tmp/wp.sql' \
  && scp -q "$CTRL1:/tmp/wp.sql" "$OUT/mattjarrett-com-wordpress.sql" \
  && ssh "$CTRL1" "rm -f /tmp/wp.sql" \
  && ok "mattjarrett-com-wordpress.sql" || fail "mattjarrett-com-wordpress.sql"

# The whole of wp-content, not just uploads - plugins and themes carry site
# behaviour the image does not seed back, and NextGEN keeps gallery images in
# their own directory outside uploads.
# Streamed straight here rather than staged on ctrl-1 - its /tmp is a tmpfs with less
# room than these archives need. A live site rewrites caches mid-read, which makes tar
# exit 1 having still written every file, so the archive is verified instead of trusted.
kubectl exec -n mattjarrett-com deploy/mattjarrett-com-wordpress -c wordpress -- \
  tar czf - -C /var/www/html/wp-content --warning=no-file-changed \
  --exclude=lost+found --exclude=upgrade-temp-backup --exclude=cache . \
  > "$OUT/mattjarrett-com-wp-content.tar.gz" 2>/dev/null
tar tzf "$OUT/mattjarrett-com-wp-content.tar.gz" > /dev/null 2>&1 \
  && ok "mattjarrett-com-wp-content.tar.gz" || fail "mattjarrett-com-wp-content.tar.gz"

echo "==> WordPress (kentjarrett-com)"

# Fetch password on ctrl-1 to avoid passing credentials through SSH arguments
ssh "$CTRL1" 'WP_DB_PASS=$(sudo kubectl get secret kentjarrett-com-mariadb -n kentjarrett-com -o jsonpath='"'"'{.data.password}'"'"' | base64 -d) && sudo kubectl exec -n kentjarrett-com sts/kentjarrett-com-mariadb -c mariadb -- mariadb-dump -u wordpress -p"$WP_DB_PASS" wordpress > /tmp/wp.sql' \
  && scp -q "$CTRL1:/tmp/wp.sql" "$OUT/kentjarrett-com-wordpress.sql" \
  && ssh "$CTRL1" "rm -f /tmp/wp.sql" \
  && ok "kentjarrett-com-wordpress.sql" || fail "kentjarrett-com-wordpress.sql"

# Streamed straight here rather than staged on ctrl-1 - its /tmp is a tmpfs with less
# room than these archives need. A live site rewrites caches mid-read, which makes tar
# exit 1 having still written every file, so the archive is verified instead of trusted.
kubectl exec -n kentjarrett-com deploy/kentjarrett-com-wordpress -c wordpress -- \
  tar czf - -C /var/www/html/wp-content --warning=no-file-changed \
  --exclude=lost+found --exclude=upgrade-temp-backup --exclude=cache . \
  > "$OUT/kentjarrett-com-wp-content.tar.gz" 2>/dev/null
tar tzf "$OUT/kentjarrett-com-wp-content.tar.gz" > /dev/null 2>&1 \
  && ok "kentjarrett-com-wp-content.tar.gz" || fail "kentjarrett-com-wp-content.tar.gz"

# ── Node files ────────────────────────────────────────────────────────────────
echo "==> Node files (ctrl-1)"
ssh "$CTRL1" 'sudo cat /var/lib/rancher/k3s/server/node-token' > "$OUT/nodes/ctrl-1/node-token" \
  && ok "ctrl-1/node-token" || fail "ctrl-1/node-token"
# k3s runs with no config file today. Captured anyway - if one ever appears, the flags in
# it are not stored anywhere else.
ssh "$CTRL1" 'sudo cat /etc/rancher/k3s/config.yaml' > "$OUT/nodes/ctrl-1/k3s-config.yaml" \
  && ok "ctrl-1/k3s-config.yaml" || fail "ctrl-1/k3s-config.yaml"
scp -q "$CTRL1:~/kiosk.sh" "$OUT/nodes/ctrl-1/kiosk.sh" \
  && ok "ctrl-1/kiosk.sh" || fail "ctrl-1/kiosk.sh"
ssh "$CTRL1" 'sudo cat /etc/X11/xorg.conf.d/99-pi5.conf' > "$OUT/nodes/ctrl-1/99-pi5.conf" \
  && ok "ctrl-1/99-pi5.conf" || fail "ctrl-1/99-pi5.conf"
scp -q "$CTRL1:~/.bash_profile" "$OUT/nodes/ctrl-1/bash_profile" \
  && ok "ctrl-1/bash_profile" || fail "ctrl-1/bash_profile"

# Worker nodes use the server node-token (already captured above) to join -
# they do not store a separate token file.

# ── Long-retention Prometheus ─────────────────────────────────────────────────
# The two instances holding data that cannot be regenerated - sump-pump on 18250d
# retention and cluster-availability. Both are ~200MB on disk. The main
# Prometheus is 36GB of 30d cluster metrics and is deliberately not copied; it
# refills itself. Each PVC mounts at prometheus-db/, so the tar is taken from
# /prometheus, which is that subdirectory.
echo "==> Long-retention Prometheus"
for p in sump-pump cluster-availability; do
  ssh "$CTRL1" "sudo kubectl exec -n monitoring prometheus-${p}-0 -c prometheus -- tar czf - -C /prometheus . > /tmp/${p}-tsdb.tar.gz" \
    && scp -q "$CTRL1:/tmp/${p}-tsdb.tar.gz" "$OUT/${p}-tsdb.tar.gz" \
    && ssh "$CTRL1" "rm -f /tmp/${p}-tsdb.tar.gz" \
    && ok "${p}-tsdb.tar.gz" || fail "${p}-tsdb.tar.gz"
done

# ── Grafana database ──────────────────────────────────────────────────────────
# Dashboards come from ConfigMaps in git, but the kiosk playlist is UI-managed
# and lives only here.
echo "==> Grafana database"
ssh "$CTRL1" "sudo kubectl exec -n monitoring deploy/monitoring-grafana -c grafana -- tar czf - -C /var/lib/grafana grafana.db > /tmp/grafana-db.tar.gz" \
  && scp -q "$CTRL1:/tmp/grafana-db.tar.gz" "$OUT/grafana-db.tar.gz" \
  && ssh "$CTRL1" "rm -f /tmp/grafana-db.tar.gz" \
  && ok "grafana-db.tar.gz" || fail "grafana-db.tar.gz"

# ── k3s install flags ─────────────────────────────────────────────────────────
# The flags are stored nowhere but the unit file, and a plain reinstall silently
# drops any it is not given again. Capture them from every node, not from a doc.
echo "==> k3s install flags"
ssh "$CTRL1" 'sudo cat /etc/systemd/system/k3s.service' > "$OUT/nodes/ctrl-1/k3s.service" \
  && ok "ctrl-1/k3s.service" || fail "ctrl-1/k3s.service"
for n in work-1:$WORK1 work-2:$WORK2 work-3:$WORK3; do
  name="${n%%:*}"; host="${n#*:}"
  ssh "$host" 'sudo cat /etc/systemd/system/k3s-agent.service' > "$OUT/nodes/$name/k3s-agent.service" \
    && ok "$name/k3s-agent.service" || fail "$name/k3s-agent.service"
done

# ── k3s datastore (opt-in) ────────────────────────────────────────────────────
# k3s here is single-server on SQLite, not etcd, so there is no etcd-snapshot
# command. A live copy of a WAL-mode database can be torn, so stop k3s first.
# This is the last step because it takes the API server away.
if [[ "$WITH_DATASTORE" == true ]]; then
  echo "==> k3s datastore (stopping k3s on ctrl-1)"
  ssh "$CTRL1" "sudo systemctl stop k3s \
    && sudo tar czf /tmp/k3s-server.tar.gz -C /var/lib/rancher/k3s server \
    && sudo systemctl start k3s" \
    && scp -q "$CTRL1:/tmp/k3s-server.tar.gz" "$OUT/nodes/ctrl-1/k3s-server.tar.gz" \
    && ssh "$CTRL1" "sudo rm -f /tmp/k3s-server.tar.gz" \
    && ok "ctrl-1/k3s-server.tar.gz" || fail "ctrl-1/k3s-server.tar.gz"

  echo "  waiting for the API server to come back"
  for _ in $(seq 1 30); do
    kubectl get --raw /readyz >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl get --raw /readyz >/dev/null 2>&1 \
    && ok "apiserver back up" || fail "apiserver did not come back - check ctrl-1 before doing anything else"
else
  echo "==> k3s datastore skipped (pass --datastore before a k3s reinstall)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Files captured:"
find "$OUT" -type f | sort

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "FAILED (${#FAILED[@]}):"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo ""
  echo "Fix failures before proceeding with migration."
  exit 1
fi

echo ""
echo "Before encrypting, generate this manually - it cannot be pulled from the cluster:"
echo "  Tailscale auth key  → https://login.tailscale.com/admin/settings/keys"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ENCRYPT"
echo "════════════════════════════════════════════════════════════"
echo "  cd ~/Desktop && tar czf - cluster-backup/ | age -p > ~/Desktop/cluster-backup.tar.gz.age"
echo ""
echo "  Delete plaintext:"
echo "  rm -rf $OUT/"
echo ""
echo "  Move cluster-backup.tar.gz.age somewhere safe yourself."
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  DECRYPT (when you need to restore)"
echo "════════════════════════════════════════════════════════════"
echo "  1. mkdir -p ~/Desktop/unencrypted-backup"
echo ""
echo "  2. age -d ~/Desktop/cluster-backup.tar.gz.age \\"
echo "        > ~/Desktop/cluster-backup.tar.gz"
echo ""
echo "  3. tar xzf ~/Desktop/cluster-backup.tar.gz \\"
echo "        -C ~/Desktop/unencrypted-backup --strip-components=1"
echo ""
echo "  4. rm ~/Desktop/cluster-backup.tar.gz"
