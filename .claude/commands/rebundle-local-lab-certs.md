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

## Trusting the CA on a device

A "connection not private" warning that survives rebundling means the device does not
trust the CA at all. Same file works everywhere, only the install differs. Export it once:

```bash
kubectl get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d \
  > ~/Desktop/local-lab-ca.crt
```

Only `tls.crt` leaves the cluster. `tls.key` in that same secret is the CA private key, and
anyone holding it can mint a trusted cert for any hostname on every machine trusting this CA.

**macOS**

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Desktop/local-lab-ca.crt
```

**iOS** - AirDrop the file, then Settings, General, VPN & Device Management, Install. Trust
is a separate step: Settings, General, About, Certificate Trust Settings, enable full trust.

**Windows** - copy the file over, right-click, Install Certificate, then **Local Machine**,
then **Place all certificates in the following store** and browse to **Trusted Root
Certification Authorities**. The default "Automatically select" files a self-signed CA under
Intermediate, where Chrome ignores it.

Quit the browser fully afterwards (Cmd-Q, not just the window) - it caches trust decisions
for the life of the process. Firefox ships its own trust store on every platform and ignores
the OS one, so import the same file again under Settings, Privacy & Security, Certificates,
View Certificates, Authorities.

## Replacing a rotated CA on macOS

Adding the new CA is not enough when an old one is still trusted. Compare the cluster's CA
against the keychain's:

```bash
kubectl get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -dates -fingerprint
security find-certificate -a -c local-lab-ca -p /Library/Keychains/System.keychain \
  | openssl x509 -noout -dates -fingerprint
```

Different fingerprints means the Mac trusts a rotated-out CA. Add the new one first, so an
interrupted run leaves the Mac over-trusting rather than trusting nothing, then delete the
rest.

`sudo` inside the loop would otherwise read its password prompt from the piped hash list and
swallow it:

```bash
sudo -v
```

```bash
# delete-certificate takes one hash per call, and a rotation can leave more than one
# behind. Collect the hashes before deleting - the list shifts as entries are removed.
NEW=$(openssl x509 -in ~/Desktop/local-lab-ca.crt -noout -fingerprint | sed 's/.*=//; s/://g')
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
