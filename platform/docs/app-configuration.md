# App Configuration

## Requirements

1. An app declares its callers and its dependencies in its own file.
2. Config changes without a new image.
3. No secret reaches git.
4. Workload identity is a federated credential. No client secrets exist.
5. Every auth flow works: service to service, browser sign-in, browser to its own backend, and downstream as the signed-in user.
6. The token is the app's business. The platform issues the identity and grants the role; the app validates the token and decides what a claim permits.
7. Nobody invents an `aud`, `iss`, scope, redirect URI, or role GUID. Values for a registration the platform does not own come from whoever does.

Reachability is a separate concern, in [Platform Connections](./connections.md).

## Api

```yaml
kind: Api
metadata:
  name: orders
  namespace: team-b
spec:
  image: ghcr.io/example/orders:sha-...
  size: md
  host: orders.example.com
  configFrom: [orders-config]            # ConfigMaps
  secretsFrom: [orders-credentials]      # Secrets
  provides:
    - name: browse
      auth: mesh
      allowedCallers:
        - { namespace: team-b, app: storefront }
    - name: collection-write
      auth: workload
      allowedCallers:
        - { namespace: team-a, app: reconciler }
    - name: profile
      auth: user
      allowedCallers:
        - { namespace: team-b, app: storefront-api }
  consumes:
    - { namespace: team-c, app: profiles }
    - { host: api.vendor.com }
```

`provides` is what this API offers and who holds it. `consumes` is everything it calls, naming either an on-platform app or an off-platform host. Both live in the app's own file, and an `allowedCallers` line is the grant.

`auth` says what a caller must prove, and decides which Entra object exists and which claim arrives. It is required on every interface rather than defaulted, because whether a call needs a token is worth stating.
- `mesh` means the caller's workload identity is enough. No token, no Entra object.
- `workload` is a service calling as itself, carrying an Entra app role, checked through the `roles` claim.
- `user` is a service calling for a signed-in person, carrying a delegated scope, checked through `scp`.

Most interfaces are `mesh`. An app gets an Entra registration only when it offers an interface that needs a token, or calls an app that might.

A `consumes` entry naming an app names only the app. Which interfaces it may use is already stated by that app's `allowedCallers`, and the injected scope ends in `/.default`, which asks Entra for every role this caller already holds there. A caller never has to read another team's file to find an interface name.

Off-platform is the opposite, because there is no second party in git. A caller reaching a registration the platform does not own supplies the audience, the role, and the host itself, since nothing else knows them. That form is at the end of this document.

## Spa

```yaml
kind: Spa
metadata:
  name: storefront
  namespace: team-b
spec:
  image: ghcr.io/example/storefront:sha-...
  host: app.example.com
  publicConfig:
    FEATURE_X: "true"
  apiProxies:
    - path: /api/
      app: storefront-api          # on-platform, address derived
    - path: /weather/
      host: api.weather.com        # off-platform, verbatim
  userAuth:
    client: storefront-api
    scopes: [profile]
```

`publicConfig` is served as JSON at `/config.json` and fetched on load, so one image deploys everywhere unchanged. Everything in it reaches any browser that asks, so nothing in it is a secret.

Each `apiProxies` entry names exactly one of `app` or `host`. `app` means the platform derives the address and declares the connection, so no FQDN is typed. Checking that the target exists needs Kyverno and is not in place yet. `host` is an off-platform destination taken verbatim. This is the same shape `consumes` uses.

`userAuth.client` names which proxied app completes sign-in and holds the tokens. There can only be one, because only one backend owns the session. A SPA with no user auth omits the block and proxies to as many backends as it likes.

The sign-in client is its own Entra registration, separate from the backend's workload identity. It exists for the browser flow and dies with the SPA, while the backend's identity outlives it. The backend authenticates as that client using its own SPIFFE identity, so this registration has no secret either.

A composition cannot write environment into another XR's Deployment, so the SPA publishes a ConfigMap named `<spa>-signin` carrying the tenant, the redirect URI, and the scopes. The backend names it in its own `configFrom`. That handoff is explicit rather than magic, which is what keeps each composition rendering only its own resources.

## Entra

The platform creates and owns every Entra object. None is made by hand.

An app gets a registration the first time something needs one, with an Application ID URI of `api://<namespace>-<app>`. Its credential is a federated identity credential whose subject is the pod's SPIFFE ID, so no client secret exists. There is no `enabled` flag: an identity appears when a token is actually in play, the same way a SPIFFE ID appears for every pod without anyone asking.

A `provides` entry becomes an app role when `auth: workload` and a delegated scope when `auth: user`. A `mesh` entry becomes nothing in Entra, which is why most apps have no registration. Each `allowedCallers` entry becomes the matching role assignment or permission grant. Redirect URIs derive from the Spa's `host`.

Every derived value lands in the XR's `status`: client ID, audience, issuer, role and scope GUIDs, redirect URIs, and the scope requested for each `consumes` entry. Spec is what you asked for, status is what you got, so `kubectl get api orders -o yaml` answers what an app expects without opening a composition or the Azure portal.

Two of those are overridable in spec, because derivation is only usually right. `extraRedirectUris` adds a localhost callback for local development or a second domain during a migration. `audience` overrides the derived URI for an app arriving with an existing registration other systems already point at.

## The flows

**Service to service.** The caller gets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`, and one `ENTRA_SCOPE_<TARGET>` for each app it consumes, holding that app's audience with `/.default`, which asks for every role the caller already holds there. Its Azure SDK trades the SPIFFE token for an Entra access token with no secret at any step. The receiving app validates the token and decides what `collection-write` permits on this route.

**User sign-in.** Authorization Code with PKCE, the only correct choice because a browser cannot keep a secret. The app named in `userAuth.client` completes the code exchange, keeps the tokens, and sets an httpOnly session cookie, so the browser never holds an access token.

**Browser to its backend.** The browser sends only the cookie. The nginx-to-backend hop behind it is a normal meshed call, authorized through the connection the `apiProxies` entry declared.

**Downstream as the signed-in user.** The backend calls Entra with the on-behalf-of grant, presenting its federated credential as the `client_assertion`, the incoming user token, and the target scope. That incoming token must carry an `aud` of the backend itself, because Entra refuses to redeem a token issued for anyone else. It returns a token carrying the user's identity, which works only because the backend appears in the downstream interface's `allowedCallers` and that interface is `auth: user`, making it a delegated scope rather than an app role. The downstream app sees `scp`, not `roles`.

No secret is needed here either. A client assertion is accepted anywhere a client secret would be, on-behalf-of included, and workload identity federation is how an assertion signed by another issuer becomes that credential.

## Config and secrets

`configFrom` names ConfigMaps and `secretsFrom` names Secrets. The composition mounts them as environment, in order. Both are lists, because a `Secret` XR produces one Secret and an app may want two vendors' credentials on separate lifecycles.

The team owns the ConfigMap. It is a plain Kubernetes object in the workspace directory alongside the app, applied by ArgoCD. Changing a value touches that file and nothing else, so the app is never re-reconciled and no image is rebuilt.

`secretsFrom` says nothing about where a Secret came from. Hand-create it and the app mounts it. Declare a `Secret` XR and the platform creates an AWS Secrets Manager entry plus the ExternalSecret that syncs it, with the app owner setting the value in AWS. Either way the app reads env vars and nothing about it changes, which is what makes moving from one to the other a change to one file.

No secret value reaches git on either path.

## Lifecycle

Every Entra object the platform creates has one owning app. Creating an app creates its registration, service principal, and federated credential. Adding an `allowedCallers` entry creates its grant, removing it revokes it, and deleting the app cascades to everything it owned.

The exception is a grant the platform did not create, in the collapsed section below.

## Third-party egress

A `consumes` or `apiProxies` entry naming a host renders egress immediately. The mesh refuses anything undeclared, so every external destination any workload reaches is visible in git.

Shutting one off will be two steps once Kyverno lands: a `ClusterPolicy` rejecting any app that declares the host, and a sweep removing the ones that already do. The denied hosts live in the policy, so a takedown is a pull request against one file rather than a new resource type. Today it is only the sweep, and nothing stops the host being declared again.

## Admission checks

Two `ClusterPolicy` objects catch what CEL cannot, because both have to read an object other than the one being admitted. `platform-reference-integrity` refuses an `app` named in `consumes` or `apiProxies` that is not a real Api in the namespace the reference claims. `platform-egress-denials` refuses a host on the denial list, which is empty until someone puts one there.

Both ship as `Audit` rather than `Enforce`. A policy matching every `Api` and `Spa` that is subtly wrong would reject every XR update, which is worse than the silent failure it exists to catch, so the reports get read before the switch is flipped.

## Not built yet

`userAuth` and `auth: user` are implemented but no app uses either, so neither has run against a real sign-in.

Until the policies move to `Enforce`, a reference to an app that does not exist still renders and enforces nothing. It shows up in a `PolicyReport` rather than being refused.

## Not offered

A `Spa` cannot hold the access token in the browser, which is how many single-page apps are built. Any script on the page can read that token, including one arriving through a dependency, and stealing it means impersonating the user everywhere the token is accepted. The requirement that a page script cannot read a user's token rules it out, so no mode turns it on.

<details>
<summary>Calling an API registered in Entra outside the platform</summary>

An existing API has its own Entra registration and runs somewhere the platform does not manage.

Three facts come from its owner: the Application ID URI (the API's identifier in Entra), which becomes the audience; the role name; and the hostname, which is separate because `api://legacy-billing` is an identifier and not a URL. The issuer is not one of them, since it is the tenant's and identical for every app in it.

```yaml
consumes:
  - entraApp:
      appIdUri: api://legacy-billing
      role: Invoices.Read
      host: billing.corp.example.com
```

The platform renders egress for the host and injects the scope. The app role assignment lives on a registration the platform does not control, so it is granted by whoever owns that registration. A grant made that way survives removing the `consumes` entry, which is the lifecycle exception.

One failure mode is worth catching early. An older registration may expose only delegated scopes and no app role with `allowedMemberTypes` including `Application`. App-only calls to it cannot work until the owner adds one, and no amount of granting changes that.

</details>

## Reference

- [Platform Connections](./connections.md) - how the mesh enforces this
- [Platform Workload Identity](./workload-identity.md) - the SPIFFE identity the federated credential trusts
- [Nothing Novel](../../docs/nothing-novel.md) - the published pattern each mechanism traces to
