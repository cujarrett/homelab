#!/usr/bin/env bash
# Usage: ./docs/cluster-backup/backup-cluster-state.sh
#
# Captures cluster secrets, app data, and node config to ~/Desktop/cluster-backup/.
# Follow the printed instructions to encrypt and move to Dropbox, then delete the
# plaintext output.
set -uo pipefail

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

ssh "$CTRL1" "sudo kubectl exec -n mattjarrett-com deploy/mattjarrett-com-wordpress -- sh -c 'cd /var/www/html/wp-content && tar czf - uploads' > /tmp/wp-uploads.tar.gz" \
  && scp -q "$CTRL1:/tmp/wp-uploads.tar.gz" "$OUT/mattjarrett-com-wp-uploads.tar.gz" \
  && ssh "$CTRL1" "rm -f /tmp/wp-uploads.tar.gz" \
  && ok "mattjarrett-com-wp-uploads.tar.gz" || fail "mattjarrett-com-wp-uploads.tar.gz"

echo "==> WordPress (kentjarrett-com)"

# Fetch password on ctrl-1 to avoid passing credentials through SSH arguments
ssh "$CTRL1" 'WP_DB_PASS=$(sudo kubectl get secret kentjarrett-com-mariadb -n kentjarrett-com -o jsonpath='"'"'{.data.password}'"'"' | base64 -d) && sudo kubectl exec -n kentjarrett-com sts/kentjarrett-com-mariadb -c mariadb -- mariadb-dump -u wordpress -p"$WP_DB_PASS" wordpress > /tmp/wp.sql' \
  && scp -q "$CTRL1:/tmp/wp.sql" "$OUT/kentjarrett-com-wordpress.sql" \
  && ssh "$CTRL1" "rm -f /tmp/wp.sql" \
  && ok "kentjarrett-com-wordpress.sql" || fail "kentjarrett-com-wordpress.sql"

ssh "$CTRL1" "sudo kubectl exec -n kentjarrett-com deploy/kentjarrett-com-wordpress -- sh -c 'cd /var/www/html/wp-content && tar czf - uploads' > /tmp/wp-uploads.tar.gz" \
  && scp -q "$CTRL1:/tmp/wp-uploads.tar.gz" "$OUT/kentjarrett-com-wp-uploads.tar.gz" \
  && ssh "$CTRL1" "rm -f /tmp/wp-uploads.tar.gz" \
  && ok "kentjarrett-com-wp-uploads.tar.gz" || fail "kentjarrett-com-wp-uploads.tar.gz"

# ── Node files ────────────────────────────────────────────────────────────────
echo "==> Node files (ctrl-1)"
ssh "$CTRL1" 'sudo cat /var/lib/rancher/k3s/server/node-token' > "$OUT/nodes/ctrl-1/node-token" \
  && ok "ctrl-1/node-token" || fail "ctrl-1/node-token"
# disable-network-policy: true lives only here - losing it silently re-enables k3s's
# kube-router alongside Cilium and breaks kubelet probes. See docs/postmortem-kubelet-probe-outage.md.
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
