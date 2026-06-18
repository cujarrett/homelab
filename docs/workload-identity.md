# Workload Identity

Every platform API that integrates with an AWS resource needs credentials. If those
credentials are static access keys, each new service is a new long-lived secret to manage,
rotate, and audit. The attack surface grows with every deployment. A compromised key remains
valid until someone catches it — that does not scale.

The fix: give each workload its own short-lived identity instead of a shared password.
A cert — an SVID (SPIFFE Verifiable Identity Document) — that proves "this is the
`foo-api` pod, in the `foo` namespace, on this cluster" and expires in an hour.
AWS validates it against a registered CA and issues temporary credentials scoped to a role.
No key to leak. Nothing to rotate manually. The platform rotates SVIDs before they expire.

---

## The Stack

```
AWS IAM Roles Anywhere  ← "Trust certs signed by this CA; map to this role"
        ↑
   SPIRE / SPIFFE        ← "This pod is who it claims; here is its cert"
```

**SPIRE** issues SVIDs to workloads via a CSI volume — a Kubernetes-standard mechanism where
a driver DaemonSet intercepts the pod's volume mount, fetches the SVID from the local SPIRE
agent, and writes the cert and private key directly into the pod's filesystem. They rotate in
place before expiry. The pod never restarts.

**IAM Roles Anywhere** is the AWS STS integration for on-prem and hybrid workloads ([like my homelab](https://blog.mattjarrett.dev/platform)). SPIRE's CA is registered as a trust anchor. AWS validates the cert chain and issues temporary
credentials scoped to an IAM role. The role trust policy is locked to a specific SPIFFE ID.
Each workload gets its own least-privilege role. Automatically.

---

## Why IAM Roles Anywhere, not OIDC

OIDC federation requires AWS to reach the cluster's OIDC discovery endpoint to validate JWT
tokens. For an on-prem cluster like mine, that means exposing the JWKS on a public URL. It works.
It's also an unnecessary attack surface.

IAM Roles Anywhere is purely certificate-based. The workload presents its cert directly to
AWS STS. No inbound connection to the cluster required. The topology fits on-prem natively.

> **On ROSA?** Skip this entirely. ROSA automatically provisions a managed OIDC provider
> and integrates with AWS STS out of the box. Use
> [AWS Pod Identity / STS-based service account token projection](https://docs.aws.amazon.com/rosa/latest/userguide/rosa-sts-about-iam-resources.html)
> instead — OIDC is the right answer when AWS already hosts and trusts the endpoint.

---

## What changes for the platform

Today:
```
Crossplane → creates IAM user → generates access key → writes to Secret → mounted at /bindings/
```

After:
```
Crossplane → creates IAM role (with SPIFFE ID condition) → writes role ARN to binding Secret
SPIRE      → issues SVID to pod via CSI volume (cert + key files, auto-rotated)
Sidecar    → writes ~/.aws/config entry with credential_process = aws_signing_helper
App        → aws.NewFromConfig(ctx) — zero credential wiring
```

**Example: an XApi binding to both S3 and DynamoDB**

```yaml
# XApi instance
spec:
  objectStorageRef: foo-media     # S3 bucket
  nosqlRef: foo-catalog           # DynamoDB table
```

The composition provisions one sidecar per AWS binding, each with its own SPIFFE identity,
IAM role, and named AWS profile. It injects env vars the app reads by convention:

```
AWS_PROFILE_OBJECT_STORAGE=object-storage
AWS_PROFILE_NOSQL=nosql
```

Each env var value is a profile name. The sidecar for that binding writes a matching entry
to `~/.aws/config`:

```ini
[profile object-storage]
credential_process = aws_signing_helper credential-process \
  --certificate /spire/tls.crt \
  --private-key /spire/tls.key \
  --role-arn arn:aws:iam::...:role/foo-api-object-storage \
  --trust-anchor-arn ... \
  --profile-arn ...
```

`credential_process` is a standard AWS SDK feature. When the SDK needs credentials for that
profile, it executes the command as a subprocess, reads the JSON from stdout (access key,
secret, session token, expiry), and caches them. When the cached credentials near expiry, the
SDK re-executes the command automatically. The sidecar's only job is writing this config entry.
`aws_signing_helper` reads the SVID cert from the CSI volume, calls IAM Roles Anywhere, and
returns fresh STS credentials as JSON. The app never sees a key.

App code — one line per AWS client, no credential details:

```go
s3Cfg, _  := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_OBJECT_STORAGE")))
s3Client  := s3.NewFromConfig(s3Cfg)

ddbCfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_NOSQL")))
ddbClient := dynamodb.NewFromConfig(ddbCfg)
```

The profile name is a platform convention. If the underlying credential mechanism changes,
the env var contract stays stable and no application code changes are required.

---

## Scope

| Offering | Auth mechanism | Changes |
|---|---|---|
| `XObjectStorage` | IAM Roles Anywhere | Replace static key with role ARN + SPIRE sidecar |
| `XNoSql` | IAM Roles Anywhere | Replace static key with role ARN + SPIRE sidecar |
| `XSql` (RDS) | IAM DB Auth + Roles Anywhere | IAM role grants `rds-db:connect`; no password |
| `XSql` (in-cluster Postgres) | Linkerd mTLS | No AWS auth; mesh enforces identity |
| `XCache` (in-cluster Redis) | Linkerd mTLS | No AWS auth; mesh enforces identity |
| `XCache` (ElastiCache) | IAM Roles Anywhere | Replace static key with role ARN + SPIRE sidecar |
| `XTopic` | NATS JWT auth (separate) | Out of scope for this plan |
| `XSubscription` | NATS JWT auth (separate) | Out of scope for this plan |

---

## Roadmap

---

### Phase 1 — SPIRE: understand the model ✅

SPIRE has two components. Read these before touching anything.

**Read:**
1. [SPIFFE spec — what an SVID actually is](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/) — 15 minutes
2. [SPIRE architecture](https://spiffe.io/docs/latest/spire-about/spire-concepts/) — control plane vs agent, attestation, workload API
3. [Kubernetes workload attestation](https://github.com/spiffe/spire/blob/main/doc/plugin_agent_workloadattestor_k8s.md) — how SPIRE proves a pod is who it claims

**Mental model to confirm:**

```
SPIRE Server  → root CA, registration entries, issues SVIDs on request
SPIRE Agent   → DaemonSet on every node, talks to kubelet API to verify pod identity,
                 serves Workload API socket at /run/spire/agent.sock
Workload API  → Unix socket the app calls to get its X.509 SVID (cert + private key)
Registration  → entry says "pod with serviceaccount X in namespace Y gets SPIFFE ID Z"
```

A registration entry is the binding between a Kubernetes identity (serviceaccount + namespace)
and a SPIFFE ID. Without one, a pod gets nothing from the Workload API.

**Exit criteria:** You can explain the difference between the SPIRE server, the SPIRE agent,
and the workload API to someone else without notes. Draw the diagram. Then proceed.


<details>
<summary>Answers</summary>

```
┌────────────────────────────────────────────────────────────┐
│                        SPIRE Server                        │
│  - Runs as a Deployment (one replica is fine for homelab)  │
│  - Owns the root CA; signs all SVIDs                       │
│  - Holds all registration entries (spiffeID ↔ selectors)   │
│  - Agents bootstrap against it and attest to it            │
└───────────────────────────┬────────────────────────────────┘
                            │ mTLS (agents attest on join)
          ┌─────────────────┼─────────────────┐
          ▼                 ▼                 ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│   SPIRE Agent    │ │   SPIRE Agent    │ │   SPIRE Agent    │
│   (work-1)       │ │   (work-2)       │ │   (work-3)       │
│                  │ │                  │ │                  │
│ - DaemonSet pod  │ │ - DaemonSet pod  │ │ - DaemonSet pod  │
│ - Talks to local │ │                  │ │                  │
│   kubelet API to │ │                  │ │                  │
│   verify pod ns/ │ │                  │ │                  │
│   serviceaccount │ │                  │ │                  │
│ - Exposes the    │ │                  │ │                  │
│   Workload API   │ │                  │ │                  │
│   Unix socket    │ │                  │ │                  │
└────────┬─────────┘ └──────────────────┘ └──────────────────┘
         │ /run/spire/agent.sock
         │ (Unix socket, host path)
         ▼
┌──────────────────────────────────────────┐
│              Workload API                │
│                                          │
│  The socket the app (or sidecar) calls.  │
│  Agent checks: does this pod's ns +      │
│  serviceaccount match a registration     │
│  entry? If yes → fetch SVID from server  │
│  and hand it back. If no → nothing.      │
└──────────────────────────────────────────┘
         │ X.509 SVID (cert + private key)
         ▼
┌──────────────────────────────────────────┐
│                  App pod                 │
│  Reads SVID. Hands it to                 │
│  aws_signing_helper → STS creds.         │
└──────────────────────────────────────────┘
```

**The key distinction:**

- **SPIRE Server** — the CA and the policy store. It knows what identities exist and signs their certs. There's one, and workloads never talk to it directly.
- **SPIRE Agent** — the node-local proxy. Runs everywhere a workload runs. It's the one that actually verifies pod identity (by asking the kubelet) and serves the socket. Workloads only ever talk to their local agent.
- **Workload API** — not a separate process. It's the interface the agent exposes. The Unix socket at `/run/spire/agent.sock`. The app calls this to get its SVID; it has no idea a server exists.
</details>

---

### Phase 2 — Install SPIRE ✅

**Install:**

The ArgoCD Application is at `cluster/argocd/spire.yaml`. Push to git — ArgoCD picks it up automatically.

Key values used (see `cluster/argocd/spire.yaml` for the full config):
- `trustDomain: homelab.local` — appears in every SPIFFE ID
- `storageClass: longhorn-retain` — retains the CA PVC on pod restart
- `logLevel: DEBUG` on agents — turn down to `INFO` once attestation is confirmed working
- SPIKE, CSI driver, OIDC provider, and controller manager are disabled — not needed until later phases

**What to look at after install:**

```bash
# SPIRE server and agents are running (namespace is spire-server)
k get pods -n spire-server

# SPIRE server logs — you'll see it bootstrapping its CA
k logs -n spire-server spire-server-0 | head -50

# Confirm all 4 agents have attested
k exec -n spire-server spire-server-0 -- \
  /opt/spire/bin/spire-server agent list

# The server's bundle (root CA public cert) — treat as sensitive
k exec -n spire-server spire-server-0 -- \
  /opt/spire/bin/spire-server bundle show -format pem
```

Save that CA cert. It is the root of trust for every SVID the cluster issues and is highly
sensitive. Anyone who registers it as a trust anchor in AWS can issue SVIDs that will be accepted as
valid cluster identities. You'll register it in IAM Roles Anywhere in Phase 4.

**Exit criteria:**  `spire-server-0` and all `spire-agent-*` pods are `1/1 Running`, `agent list` shows 4 attested agents, bundle command returns a PEM cert.

---

### Phase 3 — Register a workload ✅

Before any app gets an SVID, you register it. This is the step that binds a Kubernetes identity
to a SPIFFE ID.

| Term | What it means |
|---|---|
| SPIFFE ID | A URI: `spiffe://trust-domain/path`. The identity. |
| SVID | The cert (or JWT) that proves the SPIFFE ID. Short-lived. |
| Trust domain | The namespace for SPIFFE IDs in your deployment. `homelab.local`. |
| Workload API | The Unix socket a workload calls to get its SVID. |
| Attestation | How SPIRE proves a workload is who it claims. For Kubernetes: checks pod namespace, service account, labels against the kubelet API. |
| Trust anchor | The CA cert you register in AWS. AWS uses it to validate SVID cert chains. |
| Profile (Roles Anywhere) | Maps a trust anchor to a set of IAM roles and sets session duration. |
| Registration entry | SPIRE's mapping from Kubernetes selectors to a SPIFFE ID. |

**Create a registration entry for `my-vinyl-api`:**

You need one entry per node — each agent's parentID is its own SPIFFE ID. Get all four from the server:

```bash
k exec -n spire-server spire-server-0 -- \
  /opt/spire/bin/spire-server agent list | grep "SPIFFE ID"
```

Create an entry for each node agent (the selectors ensure only the right pod gets the SVID regardless of which node it lands on):

```bash
# Copy the UIDs from the agent list output above, then run:
for uid in \
  "spiffe://homelab.local/spire/agent/k8s_psat/homelab/REPLACE-UID-1" \
  "spiffe://homelab.local/spire/agent/k8s_psat/homelab/REPLACE-UID-2" \
  "spiffe://homelab.local/spire/agent/k8s_psat/homelab/REPLACE-UID-3" \
  "spiffe://homelab.local/spire/agent/k8s_psat/homelab/REPLACE-UID-4"; do
  k exec -n spire-server spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
      -spiffeID spiffe://homelab.local/ns/my-vinyl/sa/my-vinyl-api \
      -parentID "$uid" \
      -selector k8s:ns:my-vinyl \
      -selector k8s:sa:my-vinyl-api
done
```

The selectors tell SPIRE: "only pods in namespace `my-vinyl` with service account `my-vinyl-api`
can claim this SPIFFE ID." Anything else gets rejected.

Note: Phase 7 (SPIRE Controller Manager) automates this — you won't create entries by hand at scale.

**Verify the workload can fetch its SVID:**

The `spire-agent` image is distroless — no shell or `sleep`. Run the fetch directly as the container command and read it from logs:

```bash
k run spire-test -n my-vinyl \
  --image=ghcr.io/spiffe/spire-agent:1.15.1 \
  --restart=Never \
  --overrides='{
    "spec": {
      "serviceAccountName": "my-vinyl-api",
      "volumes": [{"name":"spire-agent-socket","hostPath":{"path":"/run/spire/agent-sockets/spire-agent.sock","type":"Socket"}}],
      "containers":[{
        "name":"spire-test",
        "image":"ghcr.io/spiffe/spire-agent:1.15.1",
        "command":["/opt/spire/bin/spire-agent","api","fetch","x509","-socketPath","/run/spire/agent.sock"],
        "volumeMounts":[{"name":"spire-agent-socket","mountPath":"/run/spire/agent.sock"}]
      }]
    }
  }'

sleep 10 && k logs spire-test -n my-vinyl -c spire-test

k delete pod spire-test -n my-vinyl
```

You should see output like:

```
Received 1 svid after 576ms

SPIFFE ID:    spiffe://homelab.local/ns/my-vinyl/sa/my-vinyl-api
SVID Valid After:  ...
SVID Valid Until:  ...
CA #1 Valid After: ...
CA #1 Valid Until: ...
```

**Exit criteria:** SVID received, SPIFFE ID matches `spiffe://homelab.local/ns/my-vinyl/sa/my-vinyl-api`.

---

### Phase 4 — IAM Roles Anywhere: trust anchor and role ✅

AWS needs to trust your SPIRE CA before it will accept SVIDs. You're registering the CA's
public cert as a trust anchor. No private key leaves the cluster.

**Register the trust anchor:**

```bash
# Get the SPIRE CA bundle
k exec -n spire-server spire-server-0 -- \
  /opt/spire/bin/spire-server bundle show -format pem > ~/Desktop/spire-ca.pem

# Register it in IAM Roles Anywhere
aws rolesanywhere create-trust-anchor \
  --name homelab-spire \
  --source "sourceType=CERTIFICATE_BUNDLE,sourceData={x509CertificateData=$(cat ~/Desktop/spire-ca.pem)}" \
  --tags key=cluster,value=homelab \
  --enabled

# Delete the local copy — it's a public cert (no private key), safe to remove.
# Re-fetch any time with the bundle show command above.
rm ~/Desktop/spire-ca.pem
```

**Create an IAM role for `my-vinyl-api` S3 access:**

The trust policy allows IAM Roles Anywhere to assume it, then locks down to the specific SPIFFE ID
via the URI SAN principal tag.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "rolesanywhere.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession",
        "sts:SetSourceIdentity"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/x509SAN/URI": "spiffe://homelab.local/ns/my-vinyl/sa/my-vinyl-api"
        }
      }
    }
  ]
}
```

The condition is the lock. Only a cert with that exact URI SAN — signed by your SPIRE CA —
can assume this role. Every workload gets its own role with its own condition.

**Create a profile:**

A profile maps the trust anchor to the roles it's allowed to assume, and sets the session duration.

```bash
TRUST_ANCHOR_ARN=$(aws rolesanywhere list-trust-anchors \
  --query 'trustAnchors[?name==`homelab-spire`].trustAnchorArn' \
  --output text)

ROLE_ARN=arn:aws:iam::<account>:role/homelab-my-vinyl-api

aws rolesanywhere create-profile \
  --name homelab-my-vinyl-api \
  --role-arns "$ROLE_ARN" \
  --duration-seconds 3600 \
  --enabled
```

**Exit criteria:** Trust anchor shows `enabled: true`. Role trust policy is saved. Profile exists.

**Cleanup — before Phase 5:** The IAM role and profile created here were manual proof-of-concept resources. Once Phase 5 has the composition managing them, delete these:

```bash
# Delete the manual proof-of-concept role and profile (Crossplane will own these going forward)
aws rolesanywhere delete-profile \
  --profile-id $(aws rolesanywhere list-profiles \
    --query 'profiles[?name==`homelab-my-vinyl-api`].profileId' --output text)

# The role has no attached or inline policies — delete directly
aws iam delete-role --role-name homelab-my-vinyl-api
```

The trust anchor (`homelab-spire`) is cluster-wide and permanent — do not delete it.

---

### Phase 5 — Update XObjectStorage composition

**Implementation decisions:**

| Decision | Choice | Why |
|---|---|---|
| SVID delivery to sidecar | SPIRE CSI driver | Mounts SVID cert+key directly as pod volume files — no extra sidecar needed. The two-sidecar alternative (spiffe-helper + aws_signing_helper) adds inter-container coordination with no benefit. CSI driver is the upstream-recommended pattern and is already in `cluster/argocd/spire.yaml`, just disabled. Enable it there before this phase. |
| `trust-anchor-arn` + `profile-arn` source | EnvironmentConfig | Cluster-wide constants, not per-instance values. Same pattern as `abacPolicyArn` already in the config. Not stored in Git. |
| Credentials delivery to SDK | Named profiles in shared AWS config | Each sidecar writes a named profile (`[object-storage]`, `[nosql]`) to a shared AWS config. The composition injects `AWS_PROFILE_<BINDING>` env vars. For a single AWS binding, `config.LoadDefaultConfig(ctx)` works with no arguments. For multiple bindings, the app passes `config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_OBJECT_STORAGE"))` — one line per client, no credential details. Supports the full XApi multi-binding model. |

**The credential exchange mechanism:**

AWS provides `aws_signing_helper` ([rolesanywhere-credential-helper](https://github.com/aws/rolesanywhere-credential-helper)) accepts an SVID cert+key, calls `rolesanywhere.amazonaws.com`, and returns STS credentials. The platform runs it as a sidecar with a pinned image tag — no floating `latest`, so a bad upstream release can't silently break credential exchange. Renovate keeps the tag current via PRs.

```
SPIRE CSI volume (cert + key files, auto-rotated)
      ↓
aws-credentials-sidecar writes ~/.aws/config:
  [profile object-storage]
  credential_process = aws_signing_helper ...  ← full example in "What changes for the platform"
      ↓
SDK executes aws_signing_helper on demand → IAM Roles Anywhere → STS creds (cached, auto-refreshed)
```

The composition currently creates an IAM user and writes static keys into the binding Secret.
Replace that with:

1. **Create an IAM role** (not a user) with the SPIFFE ID condition in the trust policy
2. **Write the role ARN** (not keys) into the binding Secret under the key `role-arn`
3. **Inject the SPIRE socket** as a volume in `XApi`'s pod spec
4. **Add the credentials sidecar** to `XApi` — it writes a `credential_process` entry to `~/.aws/config` pointing `aws_signing_helper` at the SVID cert and the role ARN

The binding Secret format changes from:

```
username   → access key ID       (deleted)
password   → secret access key   (deleted)
role-arn   → arn:aws:iam::...    (new)
```

The app changes from:

```go
// Before
accessKey := os.ReadFile("/bindings/object-storage/username")
secretKey := os.ReadFile("/bindings/object-storage/password")

// After — single AWS binding
cfg, _ := config.LoadDefaultConfig(ctx)
s3Client := s3.NewFromConfig(cfg)

// After — multiple AWS bindings (e.g. objectStorageRef + nosqlRef)
// The composition injects AWS_PROFILE_<BINDING> env vars automatically.
// Each sidecar writes a named profile to the shared AWS config.
s3Cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_OBJECT_STORAGE")))
s3Client := s3.NewFromConfig(s3Cfg)

ddbCfg, _ := config.LoadDefaultConfig(ctx,
    config.WithSharedConfigProfile(os.Getenv("AWS_PROFILE_NOSQL")))
ddbClient := dynamodb.NewFromConfig(ddbCfg)
```

The sidecar handles the SPIRE ↔ STS exchange. The composition injects the profile env vars. The app reads an env var and passes it to the SDK — one line per AWS client, no credential details in app code.

**What to update in the composition:**

- `platform/object-storage/composition.yaml` — replace `IAMUser` + `AccessKey` + `UserPolicyAttachment` managed resources with `IAMRole` + trust policy
- `platform/api/composition.yaml` — add the SPIRE CSI volume and the credentials sidecar when an `objectStorageRef` is present
- `cluster/argocd/spire.yaml` — enable `spire-agent.spiffeCSIDriver.enabled: true`
- EnvironmentConfig — add `trustAnchorArn` and `rolesAnywhereProfileArn`; remove `abacPolicyArn` (only referenced by `XObjectStorage`, now obsolete)
- AWS — delete the ABAC IAM policy (`abacPolicyArn`) once no XObjectStorage instances reference it

**Exit criteria:** Deploy the updated composition. Exec into the `my-vinyl-api` pod and confirm:

```bash
# Credentials file is present and non-empty
k exec -n my-vinyl deploy/my-vinyl-api -c aws-credentials-sidecar -- \
  cat /credentials/object-storage/credentials

# Verify S3 access with the issued credentials
k exec -n my-vinyl deploy/my-vinyl-api -c my-vinyl-api -- \
  aws s3 ls s3://my-vinyl-assets-bucket/ --profile default
```

No static key anywhere in the process. If the credentials file is missing or empty, check sidecar logs for SPIRE socket or STS errors.

---

### Phase 6 — Repeat for XNoSql and XSql (RDS)

Same pattern as XObjectStorage. Each gets its own IAM role, its own SPIFFE ID condition.

For RDS specifically: IAM database authentication replaces the password. The IAM role gets
`rds-db:connect` permission to a specific DB resource ARN. The app requests a short-lived
token from RDS and connects with it instead of a password. The sidecar can write this token
to `/bindings/sql/password` on a refresh loop — no app change needed.

For in-cluster Postgres: mTLS via Linkerd is sufficient. No IAM auth. The platform enforces
network identity; no credential required.

---

### Phase 7 — Automate registration entries

Today you created the SPIRE registration entry by hand in Phase 3. That doesn't scale.

When `XApi` creates a Deployment with service account `foo-api` in namespace `foo`, the
platform should automatically create the corresponding SPIRE registration entry.

Two options:

| | SPIRE Controller Manager | Crossplane go-templating |
|---|---|---|
| **What** | Kubernetes controller that watches ClusterSPIFFEID/SPIFFEIDs CRDs and creates entries | go-template in the composition creates an Entry MR via SPIRE provider |
| **Complexity** | Low — install the controller, create a ClusterSPIFFEID per workload type | Medium — need a Crossplane provider for SPIRE |
| **Fits platform model** | Partially — CRDs are separate from XR | Yes — entry lifecycle tied to XR lifecycle |

**Use SPIRE Controller Manager.** One `ClusterSPIFFEID` CRD per workload type, created
alongside the composition. When the XR creates the Deployment, the controller manager
creates the SPIRE entry automatically. When the XR is deleted, the entry is cleaned up.

---

### Phase 8 — Declared connection topology (long-term)

Once every workload has a SPIFFE identity and Linkerd is running, the platform can enforce
*who is allowed to call whom*.

Today there's nothing stopping service A from calling service B's internal endpoint.
With Linkerd `AuthorizationPolicy`, you declare it:

```yaml
apiVersion: policy.linkerd.io/v1alpha1
kind: AuthorizationPolicy
metadata:
  name: my-vinyl-api-only
  namespace: my-vinyl
spec:
  targetRef:
    group: policy.linkerd.io
    kind: Server
    name: my-vinyl-api
  requiredAuthenticationRefs:
    - name: my-vinyl-spa-identity
      kind: MeshTLSAuthentication
```

The platform composition creates this alongside every binding. If `XApi` `foo` declares
`sqlRef: name: foo-db`, the composition creates an `AuthorizationPolicy` that allows
`foo`'s SPIFFE identity to reach the DB — and nothing else can. The connection topology
is declared, enforced, and visible in Grafana without a line of app code.

That's "platform manages connections." The composition owns both the credential and the
network gate.

---

## One-Way Doors

These decisions are hard to reverse. Make them deliberately.

| Decision | Why it's sticky |
|---|---|
| SPIRE trust domain (`homelab.local`) | Baked into every SVID and every IAM trust policy condition. Changing it requires re-registering trust anchors and updating all role trust policies. |
| One credential sidecar per AWS binding | Each sidecar assumes a distinct IAM role scoped to one resource. Collapsing to a shared sidecar later would require merging IAM permissions across resources, breaking least-privilege, or building role-chaining logic with no security upside. |
