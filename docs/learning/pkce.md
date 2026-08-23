# PKCE

PKCE is how an app that cannot keep a secret proves, when it redeems an authorization code, that it is the same app that started the sign-in. Every browser sign-in on this platform uses it, and so does every confidential client that follows current guidance.

Read it against the real thing. Open devtools, watch the network tab through one sign-in, and find the two values this doc describes.

## The problem

The authorization code comes back through a redirect, which means it travels in a URL, through the browser's address bar, and into history. That is the least trustworthy channel in the whole flow. Anything that can observe the redirect holds a code that can be traded for a token.

A confidential client survives that, because redeeming the code also requires its client secret. A browser app has no secret to add, since everything it ships is readable. So the code alone was enough, and stealing it was enough.

## What came before it

The implicit flow skipped the code entirely and returned the access token in the URL fragment. No exchange, no second step.

That put the token itself in browser history, in `Referer` headers, and in any log that recorded a URL. It is deprecated, OAuth 2.1 removes it, and Entra will not enable it on a new SPA registration.

## The mechanism

One secret, invented fresh for each sign-in, never reused.

| Step | What happens |
|---|---|
| 1 | The client generates a `code_verifier`, a random string of 43 to 128 characters |
| 2 | It sends `SHA-256(code_verifier)`, base64url encoded, as `code_challenge`, with `code_challenge_method=S256` |
| 3 | Entra stores that challenge alongside the code it issues |
| 4 | The client redeems the code and sends the raw `code_verifier` |
| 5 | Entra hashes what it received and compares. Mismatch means no token |

**The hash is what makes step 2 safe.** Sending the challenge in the clear gives an observer nothing, because they cannot reverse SHA-256 to produce the verifier that step 4 demands.

Do not accept `plain` as the method. It sends the verifier itself as the challenge, which defeats the entire point, and it exists only for clients that cannot compute a SHA-256.

## Why it works

The attacker who steals the redirect holds a code and no verifier. The attacker who watches the authorize request holds a hash and no verifier. Only the party that invented the verifier can finish, and it never left that client.

## What it does not do

**PKCE is not client authentication.** It proves the redeemer is the party that started the flow. It does not prove which app that party is, because a client ID is public and anyone can put one in a URL.

Stopping someone from starting a flow as your app is a different control: the redirect URI allowlist on the registration. Entra refuses to send a code anywhere not on that list, which is why a wrong or overly broad redirect URI is a real vulnerability and not a config detail.

## Confidential clients too

PKCE started as the fix for public clients, and it is now recommended for every client. OAuth 2.1 requires it across the board.

A confidential client already has a secret, so PKCE adds nothing against a stolen secret. What it adds is protection against code interception, which is a separate attack the secret does not cover.

## Where it shows up here

A `Spa` declares `userAuth`, and the backend named in `userAuth.client` is the registered client. That backend completes the code exchange, holds the tokens, and hands the browser a session cookie, so no token reaches page scripts at all. The platform derives the redirect URIs from the app's `host`, which is why nobody types one.

See [App Configuration](../../platform/docs/app-configuration.md) for the fields and [Entra](./entra.md) for what the resulting token carries.

## Seeing it

In the network tab, the request to `/authorize` carries `code_challenge` and `code_challenge_method=S256`. The `POST` to `/token` carries `code_verifier` and the code. Compare them: hash the verifier yourself and you should get the challenge back.

```bash
# what the client did in step 2
printf '%s' "$CODE_VERIFIER" | openssl dgst -binary -sha256 | openssl base64 -A | tr '+/' '-_' | tr -d '='
```

## What the errors mean

| You see | Meaning |
|---|---|
| `invalid_grant`, code verifier mismatch | The verifier does not hash to the stored challenge. Usually a new verifier was generated between the two requests |
| `invalid_request`, missing code_challenge | The registration requires PKCE and the client did not send one. Common when a library is configured for a confidential client |
| `invalid_grant`, code already redeemed | Codes are single use. A retry or a double-fired effect in the app will produce this |
| `redirect_uri_mismatch` | Not PKCE. The redirect URI does not exactly match one on the registration, and matching is literal |

## Reference

| Concept | Source |
|---|---|
| PKCE | [RFC 7636](https://datatracker.ietf.org/doc/html/rfc7636) |
| Why implicit is out | [OAuth 2.0 Security Best Current Practice](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-security-topics) |
| PKCE for all clients | [OAuth 2.1 draft](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1) |
| Entra's implementation | [Authorization code flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow) |
