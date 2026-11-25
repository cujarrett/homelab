# Platform Workload Identity

A pod proves who it is with a token it cannot forge. It trades that token for short-lived credentials in AWS and Entra. No long-lived secret is stored anywhere. Crossplane builds all of it from the app's own manifest.

[Fortune 100 Internal Developer Platform patterns, learned on a homelab. Nothing novel.](../../docs/nothing-novel.md)

## The shape of it

Five systems each do one job. None shares a secret with another.

| Part | Its job |
|---|---|
| SPIRE server | The identity provider. Its controller manager gives an identity to any pod labelled `app: api`, which the composition sets |
| SPIFFE ID | `spiffe://homelab.local/ns/{namespace}/sa/{service-account}`, templated in [cluster/argocd/spire.yaml](../../cluster/argocd/spire.yaml). Every trust decision is an exact string match on it |
| SPIRE agent | Asks the node's kubelet whether the pod really runs with the namespace and service account it claims. Only then does it sign. A stolen manifest is not an identity |
| [OIDC discovery provider](../../docs/spire-oidc-federation.md) | Publishes SPIRE's signing keys at `oidc.mattjarrett.dev`. Both clouds fetch them to check signatures. It takes no input and issues nothing |
| [`workload-identity-sidecar`](https://github.com/cujarrett/workload-identity-sidecar) | Fetches tokens (SVIDs) over the CSI-mounted Workload API socket. It writes credential files the app reads. The app never sees a token |
| Crossplane | Builds and keeps everything above that is not a running process |

## Who verifies what

A call from a pod to AWS or Entra passes four checks. Four parties run them, and any one can refuse.

| Check | Who runs it | What it catches |
|---|---|---|
| Workload attestation | SPIRE agent, against the local kubelet | A process claiming a namespace and service account it does not run under |
| Signature | AWS or Entra, against the published keys | A token this cluster's SPIRE did not mint |
| `sub` claim, *who sent it* | AWS or Entra, exact match, no wildcards | The right cluster, the wrong pod. A renamed service account is a new identity and loses access |
| `aud` claim, *what it's for* | AWS or Entra, exact match | A token minted for one cloud replayed at another |

One pod holds tokens for both clouds, with the same `sub`.

- **AWS token:** `aud` is `sts.amazonaws.com`.
- **Entra token:** `aud` is `api://AzureADTokenExchange`.

## Provisioning

One commit creates everything below. The three groups run in parallel. With Entra, the first Deployment waits for the app's client ID.

| Where | What gets created |
|---|---|
| AWS | An IAM role trusting one SPIFFE ID, with an inline policy for this resource only |
| Entra | An Application (v2 tokens, stable identifierUri), its service principal, a federated identity credential (issuer, sub, aud), and an app role plus role assignment per caller |
| Cluster | One binding Secret per declared ref, and a Deployment with the app and the sidecar |

The pod then starts in this order.

1. The kubelet syncs each binding Secret to a volume.
2. One init container per binding waits until `/bindings/{name}/type` exists.
3. The sidecar image pulls and the sidecar does its first exchange.
4. The sidecar's ready check passes once every ManagedSecret has a value.
5. The app container starts.

> **`Init:0/N` means the pod is still provisioning.**
> N counts one init container per binding, plus Istio's two and the sidecar. On first deploy a pod sits at `Init:0/N` for 60 to 90 seconds, waiting on Crossplane and the clouds.

> **The Entra grant shows red for about 30 seconds.**
> The role has to copy from the app registration to its service principal. It heals on its own.

Crossplane predicts two values, so nothing waits for them.

- **Role ARN:** `arn:aws:iam::{account}:role/crossplane/crossplane-{ns}-{xr-name}-{suffix}`. Past AWS's 64 character limit it becomes `xp-{sha256sum[:61]}`.
- **Entra role GUID:** a hash of `{namespace}/{app}/{role}`. Entra expects the same GUID every reconcile. Renaming the role gives a new GUID, because it is a new permission.

**Each declared ref gets its own binding Secret**, shaped for its resource type. It holds the role ARN and the metadata the app needs. It holds no credentials, so it is useless without a valid SVID. The S3 shape:

```
type:      s3
role-arn:  arn:aws:iam::…:role/crossplane/…
bucket:    platform-{namespace}-{name}
region:    us-east-1
```

**A `managedSecretRefs` binding carries `secret-id`, `region` and `role-arn`, never a value.** The sidecar fetches the value and writes it as files at `/secrets/{name}/{key}`. Apps need no cloud SDK code to read a secret.

## Runtime: AWS

The sidecar turns one token into credentials for each AWS binding.

1. It fetches one JWT-SVID with `aud` `sts.amazonaws.com`.
2. It calls STS `AssumeRoleWithWebIdentity` once per binding, naming a different role each time.
3. STS checks the signature against the published keys, then matches `sub` and `aud`.
4. The sidecar writes named profiles to `/aws-credentials/credentials`.
5. The app's AWS SDK reads the profile named by its `AWS_PROFILE_*` env var.
6. Every 50 minutes it repeats, ahead of the one hour expiry.

Facts about that loop.

| Fact | Detail |
|---|---|
| One token, many roles | The AWS SDK's default chain allows one role per pod. The protocol does not. This is why the platform runs its own sidecar instead of stock IRSA. Each resource is reachable only by the code that asked for it |
| Failure is quiet | If an exchange fails, the sidecar keeps the old file, still valid for up to an hour. It retries in 30 seconds |
| `managedSecretRefs` | The same exchange, then `GetSecretValue`. Each property lands read-only at `/secrets/{name}/{key}`. It refreshes every 15 minutes, since an owner may rotate the value at any time. Until the owner sets a value, it writes nothing and logs why |

## Runtime: Entra

The sidecar never contacts Entra. It keeps one file holding a fresh token, and the app's Azure SDK does the exchange.

1. Every 240 seconds, ahead of the 5 minute SVID expiry, the sidecar fetches a JWT-SVID with `aud` `api://AzureADTokenExchange`.
2. It writes the raw token to `/entra-identity/token`.
3. The app's `WorkloadIdentityCredential` sends that token and `AZURE_CLIENT_ID` to Entra.
4. Entra matches issuer, subject and audience against the federated credential.
5. Entra returns an access token carrying the `roles` claim.

Facts about that flow.

| Fact | Detail |
|---|---|
| Stock SDK | Azure Kubernetes Service uses the same env vars and token file. Apps call the stock credential with no platform code |
| Two clocks | The SVID refreshes every few minutes. The Entra access token lasts about an hour. Cache it and refresh it early |
| Injected env vars | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`, and one `ENTRA_SCOPE_<APP>` per declared callee |
| The app checks the token | The platform creates the registration, principal, federated credential, role and grant. App code reads the `roles` claim, because only the app knows which route needs which role |
| After the mesh | This check runs in addition to the mesh. See [Platform Connections](./connections.md) |

## What the app writes

The declaration lives in the app's own [Api XR](../api/README.md).

```yaml
spec:
  parameters:
    objectStorageRefs:
      - name: foo-assets
    provides:
      - name: assets
        auth: workload
        allowedCallers:
          - { namespace: bar, app: bar-api }
```

AWS code uses the profile named after the ref.

```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_OBJECT_STORAGE_FOO_ASSETS")))
s3Client := s3.NewFromConfig(cfg)
```

Entra code needs nothing platform specific. The Azure SDK already reads the injected env vars.

```go
cred, _ := azidentity.NewWorkloadIdentityCredential(nil)
```

**Static frontends get none of this.** Identity matters only when server code makes an authenticated call for itself.

| Frontend | Needs identity | Why |
|---|---|---|
| Client-rendered SPA | No | No server call, so SPIRE does not match it |
| Server-rendered pages | Yes | They call on every request |
| Incrementally regenerated pages (Next.js ISR) | Yes | A server job rebuilds the cached page |

## Operational notes

| Concern | What to know |
|---|---|
| Federated credentials | Entra allows 20 per app registration. One per workload is fine. Per-environment variants use them up fast |
| Key rotation | SPIRE publishes old and new signing keys during overlap. Keep the CA TTL well past any cloud's key cache |
| Control plane credential | Crossplane's own Entra app registration holds a client secret with `Application.ReadWrite.OwnedBy`. It is rotated by hand in Parameter Store. See [crossplane-entra App Registration](../../cluster/crossplane/azuread-permissions.md). Crossplane's AWS keys and the External Secrets reader key are static too |
| Owners on Entra objects | An Entra app is never owned by its creator automatically. Without an explicit `owners` entry, the controller can create objects it can never update or delete |
| Token version | Entra mints v1 tokens by default, issued by `sts.windows.net`. An API checking the v2 issuer rejects them all. Set `requestedAccessTokenVersion: 2` at creation |

## Choices

| Choice | Why |
|---|---|
| One role per binding | The object storage role cannot touch DynamoDB. A compromised pod reaches only one resource |
| Api creates the role | The trust policy needs the Api's service account and namespace. `ObjectStorage` and `NoSql` don't know who will use them |
| `Sql` creates its own IAM roles | Its binding Secret needs RDS details known only after provisioning, and an Api cannot read another XR's status. Each consuming Api is listed in `consumerServiceAccounts` and gets a role scoped to its exact SPIFFE ID |

## One-way doors

These are hard to change later.

| Decision | Why it is hard to change |
|---|---|
| Trust domain `homelab.local` | It is in every SVID and every cloud trust policy. Changing it means rewriting every policy at once |
| Issuer URL `https://oidc.mattjarrett.dev` | It is in the `iss` claim and registered in both clouds. Changing it means re-registering the provider and every trust policy and federated credential at once |
| Public signing keys | Once a cloud trusts this issuer, credential refresh needs that endpoint up |
| One sidecar per Api, many bindings per sidecar | A shared sidecar would merge IAM permissions across workloads |
| Derived Entra role GUIDs | Changing the hash renames every role in the tenant at once |

## Where the detail lives

| Doc | What it adds |
|---|---|
| [SPIRE OIDC Federation](../../docs/spire-oidc-federation.md) | The discovery endpoint, the Cloudflare `/.well-known` rewrite, and registering a cloud |
| [Platform Connections](./connections.md) | The mesh checks a call passes before any token is read |
| [AzureAD Permissions](../../cluster/crossplane/azuread-permissions.md) | Setting up Crossplane's own Entra registration |
