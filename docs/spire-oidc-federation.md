# SPIRE OIDC Federation

SPIRE publishes its JWT-SVID signing keys on the public internet so cloud providers can
verify tokens minted in this cluster. A pod's SPIFFE ID becomes something AWS or Entra will
trade for real credentials, with no shared secret anywhere.

[Fortune 100 Internal Developer Platform patterns, learned on a homelab. Nothing novel.](./nothing-novel.md)

## The endpoint

The `spiffe-oidc-discovery-provider` subchart, enabled in
[cluster/argocd/spire.yaml](../cluster/argocd/spire.yaml), serves two documents. Both are
public by necessity: a cloud can only verify a token if it can fetch the signing key.

| URL | What it serves |
|---|---|
| `https://oidc.mattjarrett.dev/.well-known/openid-configuration` | Discovery document - names the issuer and where the keys live |
| `https://oidc.mattjarrett.dev/.well-known/keys` | JWKS - the public half of SPIRE's JWT signing key |

Neither accepts input and neither issues anything. Holding a key from here proves nothing;
a caller still needs a JWT-SVID signed by SPIRE, which requires being a pod SPIRE attested.

**The issuer is set once, globally.** `global.spire.jwtIssuer` sets both the `iss` claim
that `spire-server` mints into tokens and the issuer the discovery document advertises.
Setting it on the subchart alone changes only the document, and every cloud rejects the
resulting tokens because `iss` does not match what it registered.

## The /.well-known rewrite

Cloudflare's bot protection returns 403 to datacenter callers on this zone, so AWS and
Entra cannot fetch anything here. Requests under `/.well-known/` are let through, so the
JWKS is published there and rewritten back to the provider's real `/keys` path by a Traefik
middleware in [cluster/spire/oidc-jwks-ingress.yaml](../cluster/spire/oidc-jwks-ingress.yaml).
`config.jwksUri` points the discovery document at the rewritten URL.

The signature of this failing is specific: the origin log shows the cloud fetching
`/.well-known/openid-configuration` and returning 200, then never requesting the keys at
all, and the cloud reports that it could not retrieve a verification key.

> **Choice: rewrite the path, not disable bot protection**
> Turning off Bot Fight Mode fixes it in one click, but it is zone-wide and this zone also
> carries two WordPress sites, which are the things here actually worth attacking. The
> rewrite is fifteen lines and touches nothing else. The tradeoff is that Cloudflare's
> `/.well-known/` pass-through is observed behavior rather than a documented guarantee.

## Federating a cloud

Register the issuer, then write a trust policy pinned to one exact SPIFFE ID.

```bash
aws iam create-open-id-connect-provider \
  --url https://oidc.mattjarrett.dev \
  --client-id-list sts.amazonaws.com
```

The thumbprint is derived automatically. The trust policy conditions on the SPIFFE ID as
`sub` and the registered client ID as `aud`:

```json
"Condition": {
  "StringEquals": {
    "oidc.mattjarrett.dev:aud": "sts.amazonaws.com",
    "oidc.mattjarrett.dev:sub": "spiffe://homelab.local/ns/{ns}/sa/{name}"
  }
}
```

Entra works the same way, matching issuer, subject, and an audience of
`api://AzureADTokenExchange`, with a limit of 20 federated credentials per app registration.

**Tokens are cached by the agent.** A JWT-SVID is cached per audience for most of its
hour-long life, so a configuration change does not show up in the next fetch. Use a
throwaway audience value to force a fresh mint when verifying.

## Verifying end to end

Run a pod labelled `app: api` with the SPIFFE CSI volume mounted, fetch a token, and trade
it for credentials. Success returns `SubjectFromWebIdentityToken` equal to the pod's
SPIFFE ID.

```bash
kubectl exec -n default oidc-test -- /opt/spire/bin/spire-agent api fetch jwt \
  -audience sts.amazonaws.com -socketPath /spiffe-workload-api/spire-agent.sock

aws sts assume-role-with-web-identity \
  --role-arn <role-arn> --role-session-name test --web-identity-token <token>
```

## One-way doors

| Decision | Why it's sticky |
|---|---|
| The issuer URL `https://oidc.mattjarrett.dev` | Baked into the `iss` claim of every token and into every cloud-side trust policy. Changing it requires re-registering the provider in each cloud and updating every trust policy at the same time. |
| Publishing signing keys on the public internet | Once a cloud trusts this issuer, credential refresh depends on the endpoint being reachable. An outage does not break running pods, but it does break every refresh until it returns. |
