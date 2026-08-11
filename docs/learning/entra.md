# Entra

Microsoft Entra is the identity provider behind every sign-in in this homelab, and the thing standing between a browser and an API. This is enough to read a token, know which flow you are in, and understand a refusal.

Read it alongside the real thing. Open [entra.microsoft.com](https://entra.microsoft.com) and look at `App registrations`, and when a chapter names a setting, go and look at it on one of your own apps.

## The three parties

| Party | What it is | What it can do |
|---|---|---|
| **The client** | A browser app, or a service making a call | Asks for tokens. Sends them. Verifies nothing, it has no key |
| **Entra** | The issuer | Authenticates people and mints tokens. Never sees a call to an API |
| **The resource** | The API being called | Verifies tokens offline against published keys, then allows or refuses |

**The API never asks Entra about your token.** It fetches Entra's public signing keys once at startup and checks the signature itself. That is why validation costs nothing and scales anywhere, and why an issued token cannot be recalled before it expires. There is nobody in the loop to ask, which is why access tokens live 60 to 90 minutes rather than days.

## Client and resource

A **client** registration asks for tokens. A **resource** registration owns the permissions being asked for.

One registration can be both, and for a single app calling only itself it works — the token's `aud` is that app, and the app accepts it. It stops working the moment a second client needs the same API, because that client would have to be granted permissions on a registration that also carries the first app's redirect URIs and sign-in config. Splitting them costs nothing up front and is very awkward to undo later.

| Registration | Holds | Notes |
|---|---|---|
| Client | Redirect URIs, and the permissions it wants | A browser app is registered as platform type **SPA**, which turns on PKCE and makes Entra refuse to issue it a secret |
| Resource | An App ID URI, the scopes it exposes, the app roles it defines | The strings here must match what the API code checks, character for character |

**A SPA holds no secret.** Everything shipped to a browser is public. Instead it proves itself with PKCE: it invents a random `code_verifier`, sends only its SHA-256 hash up front, and produces the raw value when redeeming the code. Someone who steals the authorization code has nothing to send.

## What is secret, and what is not

The rule of thumb: anything the browser puts in a URL is public. Anything that obtains or
spends a token is not.

| Value | Secret | Why |
|---|---|---|
| Tenant id | No | Sent in every authorize URL |
| Client id, either registration | No | Sent as `client_id` on every authorize and token request, and readable in any network tab |
| App ID URI and scope strings | No | Sent as the `scope` parameter on every token request |
| Redirect URI | No | Public by definition. Its safety comes from being an allow-list, not from being hidden |
| Signing keys | No | Only the public half is published, at the JWKS URL |
| **Client secret** | **Yes** | Whoever holds it can be that application, with no user and no expiry short enough to save you |
| **Access token** | **Yes, until it expires** | Bearer means whoever holds the string is you. It cannot be revoked, only outlived |
| **Refresh token** | **Yes** | Mints fresh access tokens. Worse than an access token, because it does not expire quickly |
| **`code_verifier`** | **Yes, for a few seconds** | Redeems the authorization code. Useless afterwards |

Two consequences worth internalising. Publishing the three ids in source is normal practice
and Microsoft documents it, so do not waste effort hiding them. And a token pasted into a
chat, a log or a bug report is a live credential for as long as it lives, which is the usual
way one escapes.

## Scopes and roles

| | Scope (`scp`) | App role (`roles`) |
|---|---|---|
| Shape | Space-delimited **string** | JSON **array** |
| Source | Consent — by each user, or once for everyone by an admin | Assignment, per user or per application |
| Means | This app may do X while acting for you | This identity has been granted X |
| Use when | A person is behind the call | A service or job is calling as itself |
| Never | Grants a role, however many you consent to | Grants a scope, however many are assigned |

**Where each one lives.** Both are defined by the API and granted somewhere else entirely,
which is most of the confusion.

| | Scope | Role |
|---|---|---|
| Defined by | The API | The API |
| Attached to | The calling app | A user, or another app |
| Granted by | Consent | Assignment |
| Answers | What may this app do while acting for someone | What is this identity to me |

**Where to look in the portal.** Scopes and roles are both defined on the API's own
registration, one left-nav item apart. Everything about *who was granted* them lives
somewhere else, under Enterprise apps.

| To see | Click through |
|---|---|
| The scopes an API exposes | App registrations → the API → **Expose an API** |
| The roles an API defines | App registrations → the API → **App roles** |
| Which users hold a role | Enterprise apps → the API → **Users and groups** |
| Which apps hold a role | Enterprise apps → the API → **Users and groups**, filtered to applications |
| What a client app may ask for | App registrations → the client → **API permissions** |

The two names are unhelpfully close. *App registrations* is the definition of an app.
*Enterprise apps* is that same app as it exists in your tenant, and it is the only
place a grant to a person or a program shows up.

Most real APIs are called both ways. Branch on the **presence of `scp`**, not on config — an app-only token has no `scp` at all, because there is no user to delegate for.

```js
if (claims.scp) {
  // A person is behind this. Their delegated scope decides.
  if (!hasScope(claims, "Bar.Read")) return deny("insufficient_scope")
  return dataFor(claims.oid)
}

// No scp means an application calling as itself.
if (!hasRole(claims, "Bar.Reader")) return deny("missing_app_role")
return dataForService()
```

## Which flow, and when

Three flows. Which one you are in is decided by one question: **is a person waiting on this request?**

| Situation | Flow | What the token carries |
|---|---|---|
| A person in a browser | Authorization code with PKCE | The user, and `scp` |
| An API or cron job, no user involved | Client credentials | The application, and `roles`. No user at all |
| An API calling onward, for a person | On-behalf-of | The same user, with a new audience |

The second and third look identical from outside — same caller, same endpoint — and produce tokens that agree on almost nothing. Choosing between them is choosing whether the next service can know who asked.

## A SPA calls foo-api

**In the browser.** Three ids and two scope strings, none of them secret. Entra puts all of them in the redirect URL the browser sends.

```js
const msal = new PublicClientApplication({
  auth: {
    clientId: FOO_SPA_CLIENT_ID,
    authority: `https://login.microsoftonline.com/${TENANT_ID}`,
    // redirectUri is compared as an exact string against the registration's list.
    // That list is the only thing stopping someone pointing your sign-in at their own page.
    redirectUri: window.location.origin
  },
  cache: { cacheLocation: "sessionStorage" }
})

await msal.initialize()
await msal.handleRedirectPromise()

// The ask. Silent means the user sees nothing: MSAL returns a cached token, or
// quietly redeems a refresh token against the /token endpoint for a new one.
// It can only return scopes already consented to at sign-in.
const { accessToken } = await msal.acquireTokenSilent({
  account: msal.getActiveAccount(),
  scopes: [`api://${FOO_API_CLIENT_ID}/Foo.Read`]
})

await fetch("/api/things", { headers: { Authorization: `Bearer ${accessToken}` } })
```

Notice that nothing in the code above enforces the scope, and nothing can. Asking for
`Foo.Read` decided what Entra wrote into the token, and the API is the only thing that reads
it. Change that one string to `Foo.Write` and the browser code runs exactly the same way,
while the API starts answering differently.

**In the API.** Keys fetched once, then every decision is local.

```js
const keys = createRemoteJWKSet(
  new URL(`https://login.microsoftonline.com/${TENANT_ID}/discovery/v2.0/keys`)
)

const { payload } = await jwtVerify(token, keys, {
  issuer: `https://login.microsoftonline.com/${TENANT_ID}/v2.0`,
  // The check that catches the most mistakes. A token can be real, unexpired and
  // yours, and still be for a different API.
  audience: FOO_API_CLIENT_ID
})

// scp is one space-delimited string, not an array.
const scopes = (payload.scp ?? "").split(" ")
if (!scopes.includes("Foo.Read")) return deny(403, "insufficient_scope")
```

## foo-api calls bar-api with no user

foo-api needs data from bar-api. Nobody is signed in, so there is no user to act for and
foo-api authenticates as itself.

**Set up once, before any code runs.**

| What | Where | Why |
|---|---|---|
| An app role `Bar.Read`, with `allowedMemberTypes: ["Application"]` | On bar-api's registration | Marks the permission as assignable to a program rather than a person |
| That role assigned to foo-api | On bar-api's enterprise app | Assignment is the grant. Without it the token comes back with no `roles` |
| A client secret or federated credential | On foo-api's registration | foo-api has to prove it is foo-api, and there is no user to do that for it |

**Step one, get a token.** foo-api asks Entra for a token for itself.

```js
const body = new URLSearchParams({
  grant_type: "client_credentials",
  client_id: FOO_API_CLIENT_ID,
  client_secret: FOO_API_CLIENT_SECRET,
  scope: `api://${BAR_API_CLIENT_ID}/.default`
})

const response = await fetch(
  `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`,
  { method: "POST", body }
)
const { access_token } = await response.json()
```

`.default` means "every permission foo-api has already been granted on bar-api". You cannot
name a single scope here. Naming one is how you ask a *user* to consent in the moment, and
there is no user, so the grant has to have happened in advance.

Hold on to that token. It lasts around an hour, and fetching a fresh one per request is a
round trip you did not need and a good way to get throttled. Cache it and re-fetch a few
minutes before expiry.

**Step two, make the call.** Exactly like the browser did, with a different token.

```js
await fetch("https://bar-api.example/api/v1/data", {
  headers: { Authorization: `Bearer ${access_token}` }
})
```

**What bar-api receives.** The same validation as any other token, and a different shape
inside it.

| Claim | Value | Meaning |
|---|---|---|
| `aud` | bar-api's client id | Normal. This is a token for bar-api |
| `roles` | `["Bar.Read"]` | The assignment, arriving as a claim |
| `scp` | absent | There is no user, so there is nothing delegated |
| `sub` | foo-api's service principal | The caller is a program |

So bar-api checks `roles` rather than `scp`, and that is the whole difference in its code.

**The cost.** bar-api cannot tell who triggered this. Its logs say foo-api called, and if a
person did start the chain by clicking something, that fact is gone. Passing a user id in the
request body does not fix it, because bar-api has no way to know the id is honest. When bar-api
needs to make a decision about a person, this is the wrong flow.

## foo-api calls bar-api carrying the user

Same two APIs, same endpoint, same audience. foo-api presents the user's token as proof a user is behind the call, and its own secret as proof of what it is.

```js
const body = new URLSearchParams({
  grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
  client_id: FOO_API_CLIENT_ID,
  client_secret: FOO_API_CLIENT_SECRET,
  assertion: userToken,
  scope: `api://${BAR_API_CLIENT_ID}/Bar.Read`,
  requested_token_use: "on_behalf_of"
})
```

bar-api needs no new code. What arrives is different:

| Claim | Client credentials | On-behalf-of |
|---|---|---|
| `scp` | absent | `Bar.Read` |
| `roles` | `Bar.Reader` | absent |
| `sub` | foo-api's service principal | the user, scoped to bar-api |
| `oid` | absent | the user, the same value every app in the tenant sees |

That `oid` is the point. bar-api never saw the browser and still knows which person is behind the call.

**It cannot manufacture authority.** If the incoming token lacks the scope, the exchange fails. On-behalf-of carries permission forward; it never invents it.

## What the errors mean

`401` means *I do not believe you*. `403` means *I believe you, and the answer is still no*. Returning `401` for a missing scope sends the caller off to re-authenticate, which cannot help.

| What you see | What it actually is |
|---|---|
| `invalid_audience` | The token is for a different API. Real, signed, unexpired, and not yours |
| Signature failure on a Microsoft Graph token | Graph tokens carry a `nonce` and are signed so only Graph can verify them. Every other API fails them at the signature and never reaches `aud` |
| `AADSTS65001` | Consent is missing. In on-behalf-of it means the middle tier was never granted the downstream permission, and nothing about the incoming token hints at it |
| `AADSTS50105` | The user is not assigned to an app whose service principal requires assignment. Refused at sign-in, not at the API |
| `AADSTS7000215` | Wrong client secret |
| A token that decodes but fails everywhere | Check `iss`. A v1 token comes from `sts.windows.net`, a v2 token from `login.microsoftonline.com/…/v2.0`, and which you get depends on the API's manifest rather than anything the caller did |
