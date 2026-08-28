---
description: Rebundle local.lab TLS cert chains so iOS trusts them after a leaf cert renewal
---

Run the following to append the CA cert to every local-lab-ca signed TLS secret. This is needed when a leaf cert renews (cert-manager writes leaf-only, breaking iOS chain validation).

```bash
CA=$(kubectl get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d)
for ns_secret in argocd/argocd-tls-cert monitoring/grafana-tls-cert monitoring/prometheus-tls-cert adguard/adguard-local-lab-tls longhorn-system/longhorn-tls-cert my-vinyl/my-vinyl-api-tls sump-pump/sump-pump-bridge-tls; do
  ns=${ns_secret%%/*}; secret=${ns_secret##*/}
  LEAF=$(kubectl get secret "$secret" -n "$ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)

  # An empty read means the secret was renamed or deleted. Patching anyway would
  # replace the leaf with a CA-only chain and take the host offline.
  if [ -z "$LEAF" ]; then echo "SKIP $ns_secret - not found"; continue; fi

  # Appending to an already-bundled secret stacks duplicate CA copies, so a second
  # run of this skill would corrupt what the first one fixed.
  if [ "$(printf '%s' "$LEAF" | grep -c 'BEGIN CERTIFICATE')" -gt 1 ]; then
    echo "SKIP $ns_secret - already bundled"; continue
  fi

  CHAIN=$(printf '%s\n%s\n' "$LEAF" "$CA" | base64 | tr -d '\n')
  kubectl patch secret "$secret" -n "$ns" --type='json' -p="[{\"op\":\"replace\",\"path\":\"/data/tls.crt\",\"value\":\"$CHAIN\"}]"
done
```

Then verify a host is serving the full chain:

```bash
echo | openssl s_client -connect grafana.local.lab:443 -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE"
# Should output 2
```

If iOS still shows "connection not private", also export and re-trust the CA on the device:

```bash
kubectl get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/Desktop/local-lab-ca.crt
```

AirDrop `local-lab-ca.crt` to iPhone → Settings → General → VPN & Device Management → Install → Settings → General → About → Certificate Trust Settings → enable full trust.

## macOS trust store

Chrome on macOS shows `NET::ERR_CERT_AUTHORITY_INVALID` when the cluster CA has been rotated but the System keychain still holds the old one. Rebundling does not fix this - the trusted root itself has to be replaced.

Compare what the cluster has against what the Mac trusts:

```bash
kubectl get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -dates -fingerprint
security find-certificate -a -c local-lab-ca -p /Library/Keychains/System.keychain \
  | openssl x509 -noout -dates -fingerprint
```

Different fingerprints means the Mac is trusting a rotated-out CA. Replace it.

Authenticate first. `sudo` inside the loop below would otherwise read its password
prompt from the piped hash list and swallow it.

```bash
sudo -v
```

Add the new CA before removing the old one, so an interrupted run leaves the Mac
over-trusting rather than trusting nothing.

```bash
kubectl get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/local-lab-ca.crt
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/local-lab-ca.crt
```

```bash
# delete-certificate takes one hash per call, and a rotation can leave more than one
# behind. Collect the hashes before deleting - the list shifts as entries are removed.
NEW=$(openssl x509 -in /tmp/local-lab-ca.crt -noout -fingerprint \
  | sed 's/.*=//; s/://g')
STALE=$(security find-certificate -a -c local-lab-ca -Z /Library/Keychains/System.keychain \
  | awk '/^SHA-1 hash: /{print $3}' | grep -v "$NEW")
for hash in $STALE; do
  sudo security delete-certificate -Z "$hash" /Library/Keychains/System.keychain
done
```

Confirm exactly one CA is trusted and it matches the cluster:

```bash
security find-certificate -a -c local-lab-ca -Z /Library/Keychains/System.keychain \
  | grep -c "SHA-1 hash"   # should output 1
echo | openssl s_client -connect grafana.local.lab:443 -servername grafana.local.lab 2>&1 \
  | grep "Verify return code"   # should output 0 (ok)
```

Quit Chrome fully (Cmd-Q, not just the window) and reopen - it caches trust decisions for the life of the process.
