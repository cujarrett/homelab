# Workload Identity

Static IAM keys in Kubernetes Secrets are a solved problem. You just have to actually solve it.

Today every platform offering that touches AWS writes a long-lived access key pair into a
binding Secret. That key never rotates unless you rotate it manually. If a pod is compromised,
the key is valid indefinitely. SPIFFE and SPIRE exist to fix this by giving every workload a
cryptographic identity — a short-lived X.509 certificate scoped to exactly that workload —
that it can exchange for temporary AWS credentials at runtime.

No static keys. No rotation scripts. No "we'll clean that up later."

---

## The Stack

Three layers, each building on the last.

```
AWS IAM Roles Anywhere  ← "I trust certs signed by this CA; map to this role"
        ↑
   SPIRE / SPIFFE        ← "This pod is who it says it is; here's its cert"
        ↑
   Linkerd (mesh)        ← "All traffic between these pods is encrypted and identified"
```

**Linkerd** handles in-cluster mTLS automatically. Every meshed pod already has a SPIFFE-compatible
identity. You'll understand what an SVID *is* by working through the mesh first.

**SPIRE** is a full SPIFFE implementation. It issues X.509 SVIDs to workloads via a local Unix
socket. The app calls the socket, gets its cert, and hands that cert to AWS.

**IAM Roles Anywhere** is the AWS STS integration for on-prem workloads. You register SPIRE's
CA as a trust anchor. AWS validates the cert chain and issues temporary credentials scoped to an
IAM role. The role trust policy can be locked to a specific SPIFFE ID.

---

## Why IAM Roles Anywhere, not OIDC

OIDC federation requires AWS to reach your OIDC discovery endpoint to validate JWT tokens. The
cluster is on-prem. That means exposing your JWKS on a public URL (S3 bucket, typically) as a
workaround. It works but it's a kludge.

IAM Roles Anywhere is purely certificate-based. The workload presents its cert to AWS STS.
AWS validates the chain against a trust anchor you registered. No inbound connection to your
cluster. Designed for exactly this topology.

---

## What changes for the platform

Today:
```
Crossplane → creates IAM user → generates access key → writes to Secret → mounted at /bindings/
```

After:
```
Crossplane → creates IAM role (with SPIFFE ID condition) → writes role ARN to binding Secret
SPIRE      → issues SVID to pod at /run/spire/agent.sock
Sidecar    → exchanges SVID for STS creds → writes to /bindings/<type>/credentials
App        → reads AWS credentials file, calls S3/DynamoDB/RDS — same path, different source
```

The app-facing service binding path doesn't change. The platform swaps what's behind it.

---

## Scope

| Offering | Auth mechanism | Changes |
|---|---|---|
| `XObjectStorage` | IAM Roles Anywhere | Replace static key with role ARN + SPIRE sidecar |
| `XNoSql` | IAM Roles Anywhere | Same as above |
| `XSql` (RDS) | IAM DB Auth + Roles Anywhere | IAM role grants `rds-db:connect`; no password |
| `XSql` (in-cluster Postgres) | Linkerd mTLS | No AWS auth; mesh enforces identity |
| `XCache` (in-cluster Redis) | Linkerd mTLS | No AWS auth; mesh enforces identity |
| `XCache` (ElastiCache) | IAM Roles Anywhere | Same as XObjectStorage pattern |
| `XTopic` | NATS JWT auth (separate) | Out of scope for this plan |
| `XSubscription` | NATS JWT auth (separate) | Out of scope for this plan |
| `XWordpress` | Out of scope | — |

---

## Roadmap

---

### Phase 1 — Service mesh (prerequisite)

SPIFFE and SPIRE are easier to understand once you've seen SVIDs in action. Linkerd gives
you that for free inside the cluster. Do this first.

Follow [`docs/service-mesh.md`](service-mesh.md). The full plan is there.

**Exit criteria before moving on:**
- Every platform namespace has `linkerd.io/inject: enabled`
- `linkerd viz edges -n my-vinyl` shows mTLS between pods
- You can run `linkerd identity -n my-vinyl deploy/my-vinyl-api` and read the SPIFFE ID in the cert's URI SAN field

That last one is important. Read the cert. Understand what `spiffe://cluster.local/ns/my-vinyl/sa/my-vinyl-api`
means. That's the format. Trust domain + namespace + service account.

---

### Phase 2 — SPIRE: understand the model

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

---

### Phase 3 — Install SPIRE

**Install:**

```bash
# Add SPIRE helm repo
helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/
helm repo update

# Inspect the values before applying
helm show values spiffe/spire > /tmp/spire-values.yaml
```

Manifests live in `cluster/spire/`. Use the hardened chart — it sets sane RBAC defaults.

Minimal values to understand:

```yaml
# cluster/spire/spire-values.yaml
global:
  spire:
    trustDomain: homelab.local     # your trust domain — appears in every SPIFFE ID
    clusterName: homelab

spire-server:
  replicaCount: 1                  # single node is fine for homelab
  persistence:
    enabled: true
    storageClass: longhorn-retain  # retain the CA on pod restart

spire-agent:
  logLevel: DEBUG                  # turn down later; helpful for learning
```

**What to look at after install:**

```bash
# SPIRE server is running
k get pods -n spire

# SPIRE server logs — you'll see it bootstrapping its CA
k logs -n spire deploy/spire-server | head -50

# The server's bundle (your root CA public cert)
k exec -n spire deploy/spire-server -- \
  /opt/spire/bin/spire-server bundle show -format pem
```

Save that CA cert. You'll register it as an IAM Roles Anywhere trust anchor in Phase 5.

**Exit criteria:** SPIRE server and agents running, agents show `Attested` in server logs, bundle command returns a PEM cert.

---

### Phase 4 — Register a workload

Before any app gets an SVID, you register it. This is the step that binds a Kubernetes identity
to a SPIFFE ID.

**Create a registration entry for `my-vinyl-api`:**

```bash
k exec -n spire deploy/spire-server -- \
  /opt/spire/bin/spire-server entry create \
    -spiffeID spiffe://homelab.local/ns/my-vinyl/sa/my-vinyl-api \
    -parentID  spiffe://homelab.local/spire/agent/k8s_psat/homelab/$(k get node work-1 -o jsonpath='{.spec.providerID}') \
    -selector  k8s:ns:my-vinyl \
    -selector  k8s:sa:my-vinyl-api
```

The selectors tell SPIRE: "only pods in namespace `my-vinyl` with service account `my-vinyl-api`
can claim this SPIFFE ID." Anything else gets rejected.

**Verify the workload can fetch its SVID:**

Deploy a debug pod with the SPIRE socket mounted:

```bash
k run spire-test -n my-vinyl \
  --image=ghcr.io/spiffe/spire-agent:latest \
  --overrides='{
    "spec": {
      "serviceAccountName": "my-vinyl-api",
      "volumes": [{"name":"spire-agent-socket","hostPath":{"path":"/run/spire/agent.sock","type":"Socket"}}],
      "containers":[{
        "name":"spire-test",
        "image":"ghcr.io/spiffe/spire-agent:latest",
        "command":["sleep","3600"],
        "volumeMounts":[{"name":"spire-agent-socket","mountPath":"/run/spire/agent.sock"}]
      }]
    }
  }'

# Fetch the SVID
k exec -n my-vinyl spire-test -- \
  /opt/spire/bin/spire-agent api fetch x509 \
    -socketPath /run/spire/agent.sock

k delete pod spire-test -n my-vinyl
```

You should see a cert dump. Find the URI SAN field. It will contain
`spiffe://homelab.local/ns/my-vinyl/sa/my-vinyl-api`. That's the identity.

**Exit criteria:** SVID fetched, URI SAN matches the registered SPIFFE ID.

---

### Phase 5 — IAM Roles Anywhere: trust anchor and role

AWS needs to trust your SPIRE CA before it will accept SVIDs. You're registering the CA's
public cert as a trust anchor. No private key leaves the cluster.

**Register the trust anchor:**

```bash
# Get the SPIRE CA bundle
k exec -n spire deploy/spire-server -- \
  /opt/spire/bin/spire-server bundle show -format pem > /tmp/spire-ca.pem

# Register it in IAM Roles Anywhere
aws rolesanywhere create-trust-anchor \
  --name homelab-spire \
  --source "sourceType=CERTIFICATE_BUNDLE,sourceData={x509CertificateData=$(cat /tmp/spire-ca.pem)}" \
  --enabled
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
  --session-duration 3600 \
  --enabled
```

**Exit criteria:** Trust anchor shows `enabled: true`. Role trust policy is saved. Profile exists.
Nothing is actually called yet — that's Phase 6.

---

### Phase 6 — Wire the first workload (XObjectStorage proof-of-concept)

This is the manual proof before the platform automates it.

**The credential exchange mechanism:**

AWS provides an open-source binary called `aws_signing_helper`. It accepts an SVID cert+key,
calls `rolesanywhere.amazonaws.com`, and returns STS credentials. You can use it as a
`credential_process` provider in the AWS SDK, or run it as a sidecar that writes a
credentials file.

For the platform, the sidecar pattern is cleanest — the app just reads a file, same as today.

```
SPIRE agent socket
      ↓
aws-credentials-sidecar (runs aws_signing_helper on a refresh loop)
      ↓
/bindings/object-storage/credentials  (AWS credentials file format)
      ↓
App reads: AWS_SHARED_CREDENTIALS_FILE=/bindings/object-storage/credentials
```

**Test it manually first:**

```bash
# Download aws_signing_helper on a test pod
# https://github.com/aws/rolesanywhere-credential-helper

aws_signing_helper credential-process \
  --certificate /tmp/svid.pem \
  --private-key /tmp/svid-key.pem \
  --trust-anchor-arn $TRUST_ANCHOR_ARN \
  --profile-arn $PROFILE_ARN \
  --role-arn $ROLE_ARN
```

You get back JSON with `AccessKeyId`, `SecretAccessKey`, `SessionToken`. Those expire in one hour.

**Then verify S3 access:**

```bash
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=... \
  aws s3 ls s3://my-vinyl-assets-bucket/
```

**Exit criteria:** Manual credential exchange works. S3 access verified from a pod using an SVID.
No static key anywhere in the process.

---

### Phase 7 — Update XObjectStorage composition

The composition currently creates an IAM user and writes static keys into the binding Secret.
Replace that with:

1. **Create an IAM role** (not a user) with the SPIFFE ID condition in the trust policy
2. **Write the role ARN** (not keys) into the binding Secret under the key `role-arn`
3. **Inject the SPIRE socket** as a volume in `XApi`'s pod spec
4. **Add the credentials sidecar** to `XApi` — it runs `aws_signing_helper` on a refresh loop and writes to `/bindings/<type>/credentials`

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

// After
// Nothing changes in the app — SDK reads credentials file automatically
// AWS_SHARED_CREDENTIALS_FILE=/bindings/object-storage/credentials
```

This is the 80/20 win. The sidecar handles the SPIRE ↔ STS exchange. The app doesn't know
it's happening.

**What to update in the composition:**

- `platform/object-storage/composition.yaml` — replace `IAMUser` + `AccessKey` managed resources with `IAMRole` + trust policy
- `platform/api/composition.yaml` — add the SPIRE socket volume and the credentials sidecar when an `objectStorageRef` is present

---

### Phase 8 — Repeat for XNoSql and XSql (RDS)

Same pattern as XObjectStorage. Each gets its own IAM role, its own SPIFFE ID condition.

For RDS specifically: IAM database authentication replaces the password. The IAM role gets
`rds-db:connect` permission to a specific DB resource ARN. The app requests a short-lived
token from RDS and connects with it instead of a password. The sidecar can write this token
to `/bindings/sql/password` on a refresh loop — no app change needed.

For in-cluster Postgres: mTLS via Linkerd is sufficient. No IAM auth. The platform enforces
network identity; no credential required.

---

### Phase 9 — Automate registration entries

Today you created the SPIRE registration entry by hand in Phase 4. That doesn't scale.

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

### Phase 10 — Declared connection topology (long-term)

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
| SPIRE as Linkerd's identity backend | Replacing Linkerd's built-in CA with SPIRE as the identity issuer (optional, advanced) tightly couples the two systems. Don't do this unless you have a reason. |
| Credential sidecar pattern | Once apps rely on the credentials file path, changing the delivery mechanism requires a coordinated update. The path is stable; the mechanism underneath can change. |

---

## Concepts to know before starting Phase 3

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
