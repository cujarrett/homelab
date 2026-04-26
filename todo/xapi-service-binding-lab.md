# XApi Service Binding Lab

## Goal

Get `XApi` to a state where an API owner sets `objectStorage.enabled: true` or `cache.enabled: true` in their XR and gets fully working infrastructure integrations — no IAM setup, no secret management, no volume mount configuration. Plumbing included.

Platform compositions live in `platform/`. ArgoCD manages them via the `platform-xrs` ApplicationSet.

## One-Time AWS Setup (ABAC IAM)

### Step 1 — Create the `CrossplaneObjectStorageABAC` managed policy

IAM → Policies → Create Policy → JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ABACObjectStorageAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::*",
        "arn:aws:s3:::*/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/App": "${aws:PrincipalTag/App}",
          "aws:ResourceTag/Namespace": "${aws:PrincipalTag/Namespace}"
        }
      }
    }
  ]
}
```

Name: `CrossplaneObjectStorageABAC`

A user tagged `App=foo-object-storage, Namespace=foo` can only access buckets with the same tags. No bucket ARNs are hard-coded.

### Step 2 — Grant `crossplane-user` ABAC management permissions

IAM → Users → `crossplane-user` → Add inline policy → JSON (replace both `YOUR_ACCOUNT_ID` placeholders with your 12-digit AWS account ID):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GetOrListUsersAnyPath",
      "Effect": "Allow",
      "Action": [
        "iam:GetUser",
        "iam:ListAttachedUserPolicies"
      ],
      "Resource": "arn:aws:iam::YOUR_ACCOUNT_ID:user/*"
    },
    {
      "Sid": "ManageUsersUnderCrossplanePath",
      "Effect": "Allow",
      "Action": [
        "iam:CreateUser",
        "iam:DeleteUser",
        "iam:TagUser",
        "iam:UntagUser",
        "iam:ListUserTags"
      ],
      "Resource": "arn:aws:iam::YOUR_ACCOUNT_ID:user/crossplane/*"
    },
    {
      "Sid": "ManageAccessKeys",
      "Effect": "Allow",
      "Action": [
        "iam:CreateAccessKey",
        "iam:DeleteAccessKey",
        "iam:ListAccessKeys"
      ],
      "Resource": "arn:aws:iam::YOUR_ACCOUNT_ID:user/crossplane/*"
    },
    {
      "Sid": "AttachABACPolicyOnly",
      "Effect": "Allow",
      "Action": [
        "iam:AttachUserPolicy",
        "iam:DetachUserPolicy"
      ],
      "Resource": "arn:aws:iam::YOUR_ACCOUNT_ID:user/crossplane/*",
      "Condition": {
        "ArnEquals": {
          "iam:PolicyARN": "arn:aws:iam::YOUR_ACCOUNT_ID:policy/CrossplaneObjectStorageABAC"
        }
      }
    }
  ]
}
```

Name: `CrossplaneABACManagement`

> **Note:** `GetUser` and `ListAttachedUserPolicies` must target `user/*` (not `user/crossplane/*`). The provider calls these to observe a user before it exists, so the resource ARN has no path prefix yet. All mutating actions remain scoped to `user/crossplane/*`.

### Step 3 — Add the ABAC policy ARN to the existing EnvironmentConfig

The `XObjectStorage` composition reads the ABAC policy ARN from the `aws-platform-config` EnvironmentConfig. Add it there (replacing `YOUR_ACCOUNT_ID` with your 12-digit AWS account ID):

```bash
kubectl patch environmentconfig aws-platform-config --type=merge -p \
  '{"data":{"abacPolicyArn":"arn:aws:iam::YOUR_ACCOUNT_ID:policy/CrossplaneObjectStorageABAC"}}'
```

This is the only place the policy ARN appears in the cluster. Compositions read from it; nothing in Git references it.

## Phase 1 — Object Storage Binding with ABAC

### 1a — Apply XObjectStorage XRD and composition

The XObjectStorage XRD and composition live in `platform/object-storage/`. The composition creates four managed resources per XR:

| Resource | What it does |
|---|---|
| `Bucket` | S3 bucket tagged `App={xr-name}` and `Namespace={claim namespace}` |
| `User` | IAM user at path `/crossplane/`, same tags — scopes ABAC to this app |
| `AccessKey` | Scoped to the composed User; `username`/`password` promoted to the XR connection secret |
| `UserPolicyAttachment` | Attaches the shared ABAC policy — ARN read from the `aws-platform-config` EnvironmentConfig |

Secret placement is fully platform-derived: the secret name equals the XR name; the namespace is derived by stripping `-object-storage` from the XR name. No caller input required.

```bash
kubectl apply -f platform/object-storage/xrd.yaml
kubectl apply -f platform/object-storage/composition.yaml
kubectl apply -f platform/api/xrd.yaml
kubectl apply -f platform/api/composition.yaml
```

### 1b — Push platform-api-starter to GitHub (CI builds the image)

`platform-api-starter` is a Go service at `~/Developer/platform-api-starter`. The CI workflow at `.github/workflows/ci.yaml` builds and pushes `ghcr.io/cujarrett/platform-api-starter:main` on every push to `main`.

```bash
cd ~/Developer/platform-api-starter

# One-time: create repo at github.com/cujarrett/platform-api-starter (public),
# then initialize and push:
git init
git add .
git commit -m "initial"
git remote add origin https://github.com/cujarrett/platform-api-starter.git
git push -u origin main
```

CI will run automatically (~3–4 min for ARM64 build). Watch it at:
`https://github.com/cujarrett/platform-api-starter/actions`

**After the first CI run completes**, make the GHCR package public so k3s nodes can pull it without credentials:
> GitHub → github.com/cujarrett → Packages → `platform-api-starter` → Package settings → Change visibility → Public

Then proceed to 1c.

### 1c — Apply the XApi

```bash
# XR file is managed by ArgoCD via the xrs-appset
kubectl apply -f platform/xrs/api/platform-api-starter.yaml

# Watch the object-storage sub-XR converge (~30s)
kubectl get xobjectstorage platform-api-starter-object-storage -w

# Verify all 6 binding keys are present in the secret
kubectl get secret platform-api-starter-object-storage -n platform-api-starter \
  -o jsonpath='{.data}' \
  | python3 -c "
import sys, json, base64
for k, v in sorted(json.load(sys.stdin).items()):
    print(f'{k}: {base64.b64decode(v).decode()}')
"
# Expected keys: type, provider, bucket, region, username, password
```

### 1d — Verify the API is wired and S3 works

```bash
# Wait for the pod to be Running (init container waits for the binding secret first)
kubectl get pods -n platform-api-starter -w

# Port-forward to the API
kubectl port-forward -n platform-api-starter svc/platform-api-starter 8080:80 &

# Readiness — should return {"status":"ok"} once binding is mounted
curl -s http://localhost:8080/ready | python3 -m json.tool

# Upload an object
curl -s -X PUT http://localhost:8080/objects/hello.txt \
  --data-binary "hello from platform-api-starter" \
  | python3 -m json.tool

# List objects
curl -s http://localhost:8080/objects | python3 -m json.tool

# Download the object
curl -s http://localhost:8080/objects/hello.txt

# Delete it
curl -s -X DELETE http://localhost:8080/objects/hello.txt

kill %1  # stop port-forward
```

**Bonus — verify ABAC cross-app isolation:**

Deploy a second XApi (e.g. `platform-api-starter-2`) and confirm its S3 credentials cannot access `platform-api-starter`'s bucket. The tag mismatch should produce `AccessDenied` from S3.

Clean up: `kubectl delete xapi platform-api-starter`

## Phase 2 — Cache Binding (Environment-Aware) ✅

Already implemented. `XApi` forks on `spec.environment`:
- `test` (default) → in-cluster Redis (Deployment + Service + Secret, no AWS cost, no wait)
- `prod` → delegates to `XCache`, which provisions an ElastiCache ReplicationGroup

### Test `test` path with in-cluster Redis

```bash
kubectl apply -f platform/cache/xrd.yaml
kubectl apply -f platform/cache/composition.yaml

# Add cache to the platform-api-starter XR (edit platform/xrs/api/platform-api-starter.yaml)
# then apply:
kubectl apply -f platform/xrs/api/platform-api-starter.yaml

# test renders in-cluster Redis + Secret directly — should be ready in seconds
kubectl get secret platform-api-starter-cache -n platform-api-starter \
  -o jsonpath='{.data}' \
  | python3 -c "
import sys, json, base64
for k, v in sorted(json.load(sys.stdin).items()):
    print(f'{k}: {base64.b64decode(v).decode()}')
"
# Expected keys: type, provider, host, port
```

Clean up: `kubectl delete xapi platform-api-starter`

### Test prod path with ElastiCache (optional — ~$0.02/hr while running)

> **TODO:** Verify ElastiCache connection detail key names before relying on this path.
> The `ReplicationGroup` provider publishes connection details (host/port) into the pipeline,
> but the exact key names depend on the upbound provider version. After provisioning, check:
> ```bash
> kubectl get secret platform-api-starter-cache-rg-conn -n platform-api-starter \
>   -o jsonpath='{.data}' \
>   | python3 -c "import sys,json,base64; [print(k) for k in json.load(sys.stdin)]"
> ```
> If the keys don't match `host`/`port`, update the binding Secret template in
> `platform/cache/composition.yaml` accordingly.

```bash
# Edit platform/xrs/api/platform-api-starter.yaml:
#   environment: prod
#   cache:
#     enabled: true
kubectl apply -f platform/xrs/api/platform-api-starter.yaml

# ElastiCache takes ~10 min to provision
kubectl get xcache test-api-cache -w

# Once ready, verify binding secret keys
kubectl get secret platform-api-starter-cache -n platform-api-starter \
  -o jsonpath='{.data}' \
  | python3 -c "
import sys, json, base64
for k, v in sorted(json.load(sys.stdin).items()):
    print(f'{k}: {base64.b64decode(v).decode()}')
"
# Expected keys: type, provider, host, port
```

Clean up immediately after testing: `kubectl delete xapi platform-api-starter`

## Phase 3 — Wire my-vinyl-api

- [ ] Update `local-only/xrs/api/my-vinyl.yaml` to set `objectStorage.enabled: true`
- [ ] Confirm my-vinyl-api reads binding files on each use, not cached at startup (see credential rotation notes in `todo/crossplane-service-binding.md`)
- [ ] Deploy and verify real S3 operations work end-to-end through the app
- [ ] Add `cache.enabled: true` if the app needs cache

## Phase 4 — Graduate to Git ✅

Platform compositions are already in `platform/` and managed by ArgoCD. No migration needed.

## Future Improvements

- **`publishConnectionDetailsTo`**: XRs currently use `writeConnectionSecretToRef` to write connection secrets directly to the app namespace. `publishConnectionDetailsTo` is the newer Crossplane API and enables plugging in external stores (Vault, ESO) without changing XR specs. Note: because composite XRs are cluster-scoped, `publishConnectionDetailsTo` requires a properly configured `StoreConfig` to target the app namespace — `writeConnectionSecretToRef` is simpler and correct until an external store is needed.
- **XObjectStorage test path**: Currently always provisions S3 regardless of `environment`. An in-cluster MinIO option (parallel to in-cluster Redis for XCache) would complete the test story.

## Troubleshooting

**`username`/`password` missing from binding secret:**
All managed resources must be Ready before the `AccessKey` MR promotes credentials to the XR connection secret. Check:
```bash
kubectl get managed -l crossplane.io/composite=platform-api-starter-object-storage
```
All should show `SYNCED=True READY=True`. The `abac-policy-attachment` is often the last to settle.

**ABAC denying access despite correct credentials:**
Verify both the bucket and IAM user have matching `App` and `Namespace` tags:
```bash
aws s3api get-bucket-tagging --bucket $BUCKET
aws iam list-user-tags --user-name crossplane/platform-api-starter-object-storage
```

**Init container stuck waiting:**
The binding secret doesn't exist yet — the XObjectStorage XR is still reconciling. Check:
```bash
kubectl describe xobjectstorage platform-api-starter-object-storage
```

**`AttachUserPolicy` denied for `crossplane-user`:**
Verify the `CrossplaneObjectStorageABAC` policy ARN in the `AttachABACPolicyOnly` condition exactly matches the ARN from Step 1. The `ArnEquals` condition is an exact match.

**ElastiCache cost concern:**
Delete the XApi immediately: `kubectl delete xapi platform-api-starter`. Crossplane cascade-deletes the ElastiCache cluster. Verify in the AWS Console that the cluster is gone before walking away.
