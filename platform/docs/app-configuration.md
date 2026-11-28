# App Configuration

An app declares its callers, its dependencies and its config in its own file. The platform turns that into Entra objects, mounts and env vars. Reachability is in [Platform Connections](./connections.md).

## Requirements

1. Config changes without a new image.
2. No secret reaches git, and no client secret exists.
3. Every auth flow works: service to service, browser sign-in, browser to its own backend, and downstream as the signed-in user.
4. The platform issues the identity and grants the role. The app validates the token and decides what a claim permits.
5. Nobody invents an `aud`, `iss`, scope, redirect URI or role GUID. For a registration the platform does not own, values come from its owner.

## Api

```yaml
kind: Api
metadata:
  name: orders
  namespace: team-b
spec:
  parameters:
    image: ghcr.io/cujarrett/orders:sha-...
    size: md
    host: orders.example.com
    configFrom: [orders-config]            # ConfigMaps
    managedSecretRefs:                     # secret values, never Kubernetes Secrets
      - name: orders-credentials
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

| Field | Meaning |
|---|---|
| `provides` | What this API offers. Each `allowedCallers` line is a grant |
| `consumes` | Everything it calls, either an on-platform app or an off-platform host |
| `auth` | What a caller must prove. Required on every interface, never defaulted |

The three `auth` values:

| Value | Means | Entra object | Token checked through |
|---|---|---|---|
| `mesh` | The caller's workload identity is enough. Most interfaces use this | None | No token |
| `workload` | A service calling as itself | App role | The `roles` claim |
| `user` | A service calling for a signed-in person | Delegated scope | The `scp` claim |

A `consumes` entry names only the app, never an interface. The callee's `allowedCallers` already says what the caller may use.

## Spa

```yaml
kind: Spa
metadata:
  name: storefront
  namespace: team-b
spec:
  parameters:
    image: ghcr.io/cujarrett/storefront:sha-...
    host: app.example.com
    publicConfig:
      FEATURE_X: "true"
    apiProxies:
      - path: /api/
        app: storefront-api          # on-platform, address derived
    userAuth:
      client: storefront-api
      scopes: [profile]
```

| Field or object | What it does |
|---|---|
| `publicConfig` | Served as JSON at `/config.json` and fetched on load. One image deploys everywhere. Any browser can read it, so it holds no secrets |
| `apiProxies` | Each entry names an `app`. The platform derives the address and declares the connection. `platform-reference-integrity` checks the target exists |
| `userAuth.client` | The one proxied app that completes sign-in and holds the tokens. A Spa with no user auth omits the block |
| Sign-in client | Its own Entra registration, deleted with the Spa. The backend signs in as it with its SPIFFE identity, so it has no secret |
| `<spa>-signin` ConfigMap | Holds the tenant, redirect URI and scopes. The backend names it in its own `configFrom` |

## Entra

The platform creates and owns every Entra object. None is made by hand.

| Object | How the platform sets it |
|---|---|
| Registration | Created only when an app offers an interface that needs a token, or calls an app that might. There is no `enabled` flag |
| Application ID URI | `api://<tenant-id>/platform-<namespace>-<app>`. The tenant refuses a bare `api://<name>` |
| Credential | A federated identity credential whose subject is the pod's SPIFFE ID |
| `allowedCallers` | Each entry becomes a role assignment or permission grant |
| Redirect URIs | Derived from the Spa's `host` |

Every derived value lands in the XR's `status`. That covers client ID, audience, issuer, the Spa's redirect URIs, and the scope for each `consumes` entry. Read it with `kubectl get apis.platform.local.lab orders -n team-b -o yaml`.

One value can be added in spec.

- **`userAuth.extraRedirectUris`:** adds a localhost callback, or a second domain during a migration.

## The flows

| Flow | How it works |
|---|---|
| Service to service | The caller's Azure SDK trades its SPIFFE token for an Entra access token. See [Platform Workload Identity → Runtime: Entra](./workload-identity.md#runtime-entra). Each `ENTRA_SCOPE_<APP>` ends in `/.default`, which asks for every role the caller holds there. The receiver validates the token |
| User sign-in | Authorization Code with PKCE, because a browser cannot keep a secret. The `userAuth.client` app does the code exchange, keeps the tokens and sets an httpOnly session cookie. The browser never holds an access token |
| Browser to its backend | The browser sends only the cookie. The nginx-to-backend hop is a normal meshed call, allowed by the `apiProxies` entry |
| Downstream as the signed-in user | The backend uses the on-behalf-of grant. It sends its federated credential as `client_assertion`, the incoming user token and the target scope. The incoming token's `aud` must be the backend itself. The downstream interface must be `auth: user`, with the backend in its `allowedCallers`. The downstream app sees `scp`, not `roles` |

No flow needs a secret. Entra accepts a client assertion anywhere it accepts a client secret, on-behalf-of included.

## Config and secrets

- **`configFrom`:** names ConfigMaps. They mount as env vars, in order, later entries winning.
- **`managedSecretRefs`:** names secret values. Each mounts as files. A list keeps each vendor's lifecycle separate. A value never becomes a Kubernetes Secret. See [Platform Workload Identity](./workload-identity.md).

What a running pod sees when something changes:

| What changed | What the pod sees |
|---|---|
| A key in a bound Secret | The file updates in place, no restart. See [Platform Binding → Credential rotation](./service-binding.md#credential-rotation) |
| A property of a `managedSecretRefs` value | The file updates in place, no restart. See [Platform Workload Identity → Runtime: AWS](./workload-identity.md#runtime-aws) |
| A key in a ConfigMap named by `configFrom` | [Stakater Reloader](https://github.com/stakater/Reloader) rolls the Deployment, because `envFrom` values cannot change in place |
| A field in the XR | Crossplane re-renders the Deployment and it rolls out |

The platform also injects env vars nobody declared. Read what an app got from its pod spec, never by guessing the names.

```bash
k get deploy <app> -n <namespace> -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}'
```

Every name and path is in [Api](../api/README.md#configuration).

## Lifecycle

Every Entra object the platform creates has one owning app. Adding an `allowedCallers` entry creates its grant, and removing it revokes it. Deleting the app deletes everything it owned. A grant made outside the platform is the exception. See the box under [Not offered](#not-offered).

## Third-party egress

A `consumes` entry naming a host renders egress right away. The mesh refuses anything undeclared, so every external host is visible in git.

To shut one off, add it to `platform-egress-denials`. Then remove the host from any app that already declares it. Kyverno checks only at admission, so an existing declaration keeps working until it is re-applied or removed.

## Admission checks

Kyverno catches what a CEL rule on the XRD cannot. Most read another object, or a resource no XRD governs. All of them deny.

| Policy | Refuses |
|---|---|
| `platform-reference-integrity` | An `app` in `consumes` or `apiProxies` that is not a real Api in the named namespace. A `consumes` entry may also name a graph router. Also a `configFrom` entry that is not a ConfigMap in this namespace |
| `platform-host-ownership` | A `host` another namespace already serves |
| `platform-stream-ownership` | A Topic, Subscription or Api naming a stream a Topic in another namespace owns |
| `platform-image-registry` | An Api, Spa or GraphApi image outside `ghcr.io/cujarrett/`, so every app image gets the provenance check |
| `platform-egress-denials` | A host on the denial list. The list is empty until someone adds one |
| `platform-workload-ownership` | A workload in a platform namespace that no XR composed. Such a pod would get no Istio Sidecar |
| `platform-namespace-posture` | A platform namespace that is not meshed. The sidecar is the only egress control on its pods |
| `platform-service-types` | A workload Service that sets `externalIPs` or is not ClusterIP. A NodePort is allowed only when the policy names it |

## Built but unused

`userAuth` and `auth: user` are built, but no app uses them. Neither has run against a real sign-in.

## Not offered

A `Spa` never holds the access token in the browser. Any script on the page could read it, including one from a dependency. A stolen token impersonates the user everywhere it is accepted.

<details>
<summary>Calling an API registered in Entra outside the platform</summary>

The API has its own Entra registration and runs outside the platform. Its owner supplies three values.

| Value | What it is |
|---|---|
| `appIdUri` | The API's Application ID URI. It becomes the audience |
| `role` | The app role to request |
| `host` | The hostname. `api://legacy-billing` is an identifier, not a URL |

```yaml
consumes:
  - entraApp:
      appIdUri: api://legacy-billing
      role: Invoices.Read
      host: billing.corp.example.com
```

| Who | Does |
|---|---|
| The platform | Renders egress for the host and injects the scope |
| The owner | Grants the app role assignment on their registration. That grant survives removing the `consumes` entry |

Check early. An older registration may expose only delegated scopes, with no app role whose `allowedMemberTypes` includes `Application`. App-only calls fail until the owner adds one.

</details>

## Reference

| Doc | What it adds |
|---|---|
| [Platform Connections](./connections.md) | How the mesh enforces this |
| [Platform Workload Identity](./workload-identity.md) | The SPIFFE identity the federated credential trusts |
| [Nothing Novel](../../docs/nothing-novel.md) | The published pattern behind each mechanism |
