---
agent: agent
description: Add a new public hostname to the Cloudflare tunnel
---

Add a new hostname to the Cloudflare tunnel by fetching the current config and PUTting it back with the new entry appended before the catch-all.

All hostnames route to `https://192.168.10.101:443` with `noTLSVerify: true`.

Ask the user for:
1. The new hostname (e.g. `foo.mattjarrett.dev`)
2. Their Cloudflare API token (`CF_TOKEN`)

First retrieve the tunnel and account IDs from the cluster:

```bash
export ACCOUNT_ID=$(kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.accountID}' | base64 -d)
export TUNNEL_ID=$(kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.tunnelID}' | base64 -d)
export CF_TOKEN=<token>
```

Then fetch the current config:

```bash
curl -s -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer $CF_TOKEN" | python3 -m json.tool
```

Review the existing `ingress` array, then PUT back the full array with the new entry inserted **before** the final catch-all `{"service":"http_status:404"}`:

```bash
curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "ingress": [
        ...all existing entries...,
        {"hostname":"<new-hostname>","service":"https://192.168.10.101:443","originRequest":{"noTLSVerify":true}},
        {"service":"http_status:404"}
      ],
      "warp-routing":{"enabled":false}
    }
  }'
```

**Important:** Add the tunnel hostname *before* creating any Kubernetes Ingress or cert-manager Certificate for that hostname. Let's Encrypt HTTP-01 challenge will fail if the tunnel isn't routing the hostname yet.

If a cert is already stuck pending after adding the tunnel entry, force a retry:
```bash
kubectl delete certificaterequest -n <namespace> --all
```

After adding the hostname, also update the `Public Hostnames` list in `.github/copilot-instructions.md`.
