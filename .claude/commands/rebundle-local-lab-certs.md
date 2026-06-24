---
description: Rebundle local.lab TLS cert chains so iOS trusts them after a leaf cert renewal
---

Run the following to append the CA cert to every local-lab-ca signed TLS secret. This is needed when a leaf cert renews (cert-manager writes leaf-only, breaking iOS chain validation).

```bash
CA=$(k get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d)
for ns_secret in argocd/argocd-tls-cert monitoring/grafana-tls-cert monitoring/prometheus-tls-cert adguard/adguard-local-lab-tls longhorn-system/longhorn-tls-cert my-vinyl/my-vinyl-api-tls sump-pump/sump-pump-bridge-tls; do
  ns=${ns_secret%%/*}; secret=${ns_secret##*/}
  LEAF=$(k get secret "$secret" -n "$ns" -o jsonpath='{.data.tls\.crt}' | base64 -d)
  CHAIN=$(printf '%s\n%s\n' "$LEAF" "$CA" | base64 | tr -d '\n')
  k patch secret "$secret" -n "$ns" --type='json' -p="[{\"op\":\"replace\",\"path\":\"/data/tls.crt\",\"value\":\"$CHAIN\"}]"
done
```

Then verify a host is serving the full chain:

```bash
echo | openssl s_client -connect grafana.local.lab:443 -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE"
# Should output 2
```

If iOS still shows "connection not private", also export and re-trust the CA on the device:

```bash
k get secret local-lab-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/Desktop/local-lab-ca.crt
```

AirDrop `local-lab-ca.crt` to iPhone → Settings → General → VPN & Device Management → Install → Settings → General → About → Certificate Trust Settings → enable full trust.
