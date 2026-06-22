# XObjectStorage

Crossplane platform primitive that provisions object storage.

Standalone resource with a lifecycle independent of any one API. Bind to an `XApi` via `objectStorageRefs`.

## What it provisions
- `public-cloud` — **AWS S3 bucket**, named `platform-{namespace}-{name}`; scoped naming lets IAM inline policies reference the exact ARN without wildcards
- `private-cloud` — *(in-cluster MinIO planned)*

The IAM Role, RolesAnywhere Profile, and binding Secret are **not** created by XObjectStorage. They are created by the `XApi` composition when the ref is declared. XObjectStorage manages only the bucket's lifecycle.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the owning workload. Used to construct the bucket name (`platform-{namespace}-{name}`) and the Namespace cost-allocation tag. |
| `dataRetention` | no | `delete` | AWS resource reclaim on XR deletion: `delete`=bucket is deleted (data unrecoverable); `retain`=bucket is orphaned in AWS (data recoverable). |

## Binding secret

Written by the `XApi` composition (not by XObjectStorage) once the IAM Role and RolesAnywhere Profile ARNs are available. Secret name equals the XR name; namespace comes from the `XApi` that references it. Mounted at `/bindings/object-storage/` (first ref), `/bindings/object-storage-1/` (second), etc.

| Key | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name (`platform-{namespace}-{ref-name}`) |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this bucket, created by XApi) |
| `profile-arn` | RolesAnywhere profile ARN (created by XApi) |

The IAM role's inline policy grants `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` scoped to the exact bucket ARN. The `aws-spiffe-helper` sidecar (injected by XApi) exchanges the pod's SVID for short-lived STS credentials and writes them as a named profile. The app reads `AWS_PROFILE_{REF_NAME_UPPER_SNAKE_CASE}` and uses the standard AWS SDK. For the full design: [`docs/workload-identity.md`](../../../docs/workload-identity.md)

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XObjectStorage
metadata:
  name: foo-assets
spec:
  parameters:
    namespace: foo
# Bucket "platform-foo-foo-assets" is created in AWS.
# Binding Secret "foo-assets" is written to namespace "foo" by the referencing XApi.
```

Then reference from an `XApi`:

```yaml
spec:
  parameters:
    objectStorageRefs:
      - name: foo-assets
```

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xobjectstorages foo-assets

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xobjectstorage foo-assets -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all keys are present (written by XApi, not XObjectStorage)
kubectl get secret foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```
