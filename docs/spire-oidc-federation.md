# SPIRE OIDC Federation

SPIRE publishes its JWT signing keys on the public internet. AWS and Entra use them to verify tokens minted in this cluster. A pod's SPIFFE ID then trades for real cloud credentials, with no shared secret.

See [Nothing Novel](./nothing-novel.md) for the public patterns behind this.

## The endpoint

The `spiffe-oidc-discovery-provider` subchart serves two public documents. It is enabled in [cluster/argocd/spire.yaml](../cluster/argocd/spire.yaml). A cloud can verify a token only if it can fetch the signing key.

| URL | What it serves |
|---|---|
| `https://oidc.mattjarrett.dev/.well-known/openid-configuration` | The discovery document. It names the issuer and where the keys live |
| `https://oidc.mattjarrett.dev/.well-known/keys` | The JWKS, the public half of SPIRE's JWT signing key |

Neither accepts input or issues anything. A caller still needs a JWT-SVID signed by SPIRE, and only pods SPIRE attested get one.

**Set the issuer once, with `global.spire.jwtIssuer`.** It sets both the `iss` claim in tokens and the issuer in the discovery document. Setting it on the subchart alone changes only the document. Every cloud then rejects the tokens, because `iss` no longer matches what it registered.

## The /.well-known rewrite

Cloudflare's bot protection returns 403 to datacenter callers on this zone, so AWS and Entra can't fetch from it. Requests under `/.well-known/` get through.

- The JWKS is published at `/.well-known/keys`.
- The HTTPRoute in [cluster/spire/oidc-jwks-ingress.yaml](../cluster/spire/oidc-jwks-ingress.yaml) rewrites it to the provider's real `/keys` path.
- `config.jwksUri` points the discovery document at the rewritten URL.
- Bot Fight Mode stays on, because it is zone-wide and guards the two WordPress sites.
- Cloudflare does not document the `/.well-known/` pass-through. It is observed behaviour.

When this breaks, the origin log shows the cloud fetch `/.well-known/openid-configuration` with a 200, then never request the keys. The cloud reports it could not retrieve a verification key.

## Federating a cloud

Register the issuer, then write a trust policy pinned to one exact SPIFFE ID. AWS derives the thumbprint itself.

```bash
aws iam create-open-id-connect-provider \
  --url https://oidc.mattjarrett.dev \
  --client-id-list sts.amazonaws.com
```

The trust policy matches the SPIFFE ID as `sub` and the registered client ID as `aud`.

```json
"Condition": {
  "StringEquals": {
    "oidc.mattjarrett.dev:aud": "sts.amazonaws.com",
    "oidc.mattjarrett.dev:sub": "spiffe://homelab.local/ns/{ns}/sa/{name}"
  }
}
```

Entra matches issuer, subject and the audience `api://AzureADTokenExchange`. It allows 20 federated credentials per app registration.

**The agent caches tokens.** It keeps a JWT-SVID per audience for most of its one-hour life, so a config change won't show in the next fetch. Use a throwaway audience to force a fresh token when verifying.

## Verifying end to end

Run a pod labelled `app: api` with the SPIFFE CSI volume mounted. Fetch a token and trade it for credentials. Success returns `SubjectFromWebIdentityToken` equal to the pod's SPIFFE ID.

```bash
kubectl exec -n default oidc-test -- /opt/spire/bin/spire-agent api fetch jwt \
  -audience sts.amazonaws.com -socketPath /spiffe-workload-api/spire-agent.sock

aws sts assume-role-with-web-identity \
  --role-arn <role-arn> --role-session-name test --web-identity-token <token>
```

## One-way doors

These choices are hard to undo.

| Decision | Why it is hard to undo |
|---|---|
| Issuer URL `https://oidc.mattjarrett.dev` | It is in every token's `iss` claim and every cloud trust policy. Changing it means re-registering the provider in each cloud and updating every trust policy at once |
| Public signing keys | Once a cloud trusts this issuer, credential refresh needs the endpoint. An outage leaves running pods alone, but every refresh fails until it returns |
