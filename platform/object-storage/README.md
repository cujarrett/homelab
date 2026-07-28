# ObjectStorage

Crossplane platform primitive that provisions object storage.

Standalone resource with a lifecycle independent of any one API. Bind to an `Api` via `objectStorageRefs`.

## What it provisions
- `public-cloud` — **AWS S3 bucket**, named `platform-{namespace}-{name}`; scoped naming lets IAM inline policies reference the exact ARN without wildcards
- `private-cloud` — *(in-cluster MinIO planned)*

The IAM Role, RolesAnywhere Profile, and binding Secret are **not** created by ObjectStorage. They are created by the `Api` composition when the ref is declared. ObjectStorage manages only the bucket's lifecycle.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the owning workload. Used to construct the bucket name (`platform-{namespace}-{name}`) and the Namespace cost-allocation tag. |
| `dataRetention` | no | `delete` | AWS resource reclaim on XR deletion: `delete`=bucket is deleted (data unrecoverable); `retain`=bucket is orphaned in AWS (data recoverable). |

## Binding secret

Written by the `Api` composition (not by ObjectStorage) once the RolesAnywhere Profile ARN is available. Secret name is `{api-name}-{ref-name}`; namespace comes from the `Api` that references it. Mounted at `/bindings/object-storage/` (first ref), `/bindings/object-storage-1/` (second), etc.

| Key | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name (`platform-{namespace}-{ref-name}`) |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this bucket, created by Api) |
| `profile-arn` | RolesAnywhere profile ARN (created by Api) |

The IAM role's inline policy grants `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` scoped to the exact bucket ARN. The `aws-spiffe-helper` sidecar (injected by Api) exchanges the pod's SVID for short-lived STS credentials and writes them as a named profile. The app reads `AWS_PROFILE_{REF_NAME_UPPER_SNAKE_CASE}` and uses the standard AWS SDK. For the full design: [Platform Engineering: Workload Identity](../../docs/platform-engineering-workload-identity.md)

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: ObjectStorage
metadata:
  name: foo-assets
spec:
  parameters:
    namespace: foo
# Bucket "platform-foo-foo-assets" is created in AWS.
# Binding Secret "{api-name}-foo-assets" is written to namespace "foo" by the referencing Api.
```

Then reference from an `Api`:

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
kubectl get objectstorages foo-assets

# Detailed conditions — shows exactly WHY something is not ready
kubectl get objectstorage foo-assets -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all keys are present (written by Api, not ObjectStorage)
# Secret is named {api-name}-{ref-name}, e.g. foo-foo-assets for Api "foo" + ref "foo-assets"
kubectl get secret foo-foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```
