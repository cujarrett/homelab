---
description: Add a new public hostname to the Cloudflare tunnel
---

# Add a Cloudflare tunnel hostname

A new public hostname needs **two** things in Cloudflare, and missing either one fails
differently:

| | What it does | Missing it looks like |
|---|---|---|
| **DNS record** | tells the internet the hostname exists and points it at the tunnel | `NXDOMAIN` — nothing connects, and cert-manager's HTTP-01 self-check fails with `no such host` |
| **Tunnel ingress entry** | tells `cloudflared` where to send traffic once it arrives | hostname resolves, then returns the tunnel's catch-all 404 |

Existing hostnames already have their DNS records, which is why only the ingress half is
usually visible. A genuinely new hostname needs both.

All hostnames route to `https://192.168.10.101:443`. A new one must start with
`noTLSVerify: true` — it can only flip to verified once its Let's Encrypt cert is issued
and being served, otherwise the tunnel 502s.

## Inputs

Ask the user for the hostname. The temp token is passed in from `local-only/cloudflare.txt`
(gitignored) — read it from there rather than asking, and never echo it.

**Token permissions.** Two different scopes are needed:

- Account → **Cloudflare Tunnel** → Edit — for the ingress config
- Zone → **DNS** → Edit, on the relevant zone — for the DNS record

A tunnel-only token cannot create the DNS record and will not fail loudly — it simply
returns zero zones. Check before assuming:

```bash
curl -s "https://api.cloudflare.com/client/v4/zones?name=<zone>" \
  -H "Authorization: Bearer $CF_TOKEN" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('zones visible:', len(d.get('result') or []))"
```

Zero means DNS must be done in the dashboard instead — see step 2.

## 1. Tunnel ingress entry

Retrieve the IDs. The secret holds one key, `tunnel-token`, double-base64-encoded JSON
with `a` (account) and `t` (tunnel):

```bash
CREDS=$(kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.tunnel-token}' | base64 -d | base64 -d)
ACCOUNT_ID=$(echo "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)['a'])")
TUNNEL_ID=$(echo "$CREDS" | python3 -c "import json,sys; print(json.load(sys.stdin)['t'])")
CF_TOKEN=$(tr -d ' \n\r' < local-only/cloudflare.txt)
```

The API is a **full replace** — fetch, insert, PUT the whole array back. Do it
programmatically so existing entries keep their exact `originRequest` settings; the
WordPress hosts use `noTLSVerify: false` with `originServerName`, and retyping them by
hand takes those sites down.

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer $CF_TOKEN" > /tmp/cf-config.json

python3 - <<'PY'
import json
d = json.load(open('/tmp/cf-config.json'))
cfg = d['result']['config']
ing = cfg['ingress']
assert ing[-1].get('service') == 'http_status:404', "catch-all not last — aborting"
new = {"hostname": "<new-hostname>", "service": "https://192.168.10.101:443",
       "originRequest": {"noTLSVerify": True}}
cfg['ingress'] = ing[:-1] + [new] + [ing[-1]]
json.dump({"config": cfg}, open('/tmp/cf-put.json', 'w'))
print(f"{len(ing)} -> {len(cfg['ingress'])} entries")
PY

curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/cf-put.json | python3 -c "import json,sys; print(json.load(sys.stdin).get('success'))"
```

Then confirm no existing hostname was dropped, and that the live sites still serve.

## 2. DNS record

A `CNAME` at the tunnel, **proxied**. DNS-only does not route through a tunnel.

| Field | Value |
|---|---|
| Type | `CNAME` |
| Name | the subdomain, e.g. `foo` |
| Target | `<TUNNEL_ID>.cfargotunnel.com` |
| Proxy | Proxied (orange cloud) |

With a DNS-capable token:

```bash
ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=<zone>" \
  -H "Authorization: Bearer $CF_TOKEN" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])")

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d "{\"type\":\"CNAME\",\"name\":\"<subdomain>\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success') or d.get('errors'))"
```

Otherwise the user adds it in the dashboard under **DNS → Add record**.

## 3. Order, and the DNS caching trap

Both Cloudflare halves must exist **before** the Kubernetes Ingress or Certificate. The
HTTP-01 challenge resolves the hostname from inside the cluster, so it fails if either is
missing.

If anything looked the hostname up while it was still `NXDOMAIN`, that negative answer is
cached and outlives the fix — the resolvers keep saying `no such host` after the record
exists. Public DNS resolving while the cluster still fails is the signature.

```bash
dig +short <hostname> @1.1.1.1     # public — should answer
dig +short <hostname>              # local resolver — may still be empty
```

Clear it, then retry the cert. cert-manager backs off after failures and will not
re-check promptly on its own:

```bash
kubectl rollout restart deployment adguard-home -n adguard
kubectl rollout restart deployment coredns -n kube-system
kubectl delete certificaterequest -n <namespace> --all
```

## 4. Verify

Test with a browser user-agent. The `Spa` composition's nginx returns **403** to raw
`curl/` as a scanner defence, so a bare curl looks like a failure when the site is fine:

```bash
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0 Safari/537.36"
curl -s -o /dev/null -w "%{http_code}\n" -A "$UA" https://<hostname>/
kubectl get certificate -n <namespace>
```

Then add the hostname to the **Public Hostnames** list in `CLAUDE.md`.
