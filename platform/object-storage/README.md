# ObjectStorage

An object store for files. It lives on its own, apart from any one Api. Bind it to an `Api` with `objectStorageRefs`.

## What it provisions

- `public-cloud`: an **AWS S3 bucket** named `platform-{namespace}-{name}`.
- `private-cloud`: *(in-cluster MinIO planned)*.

ObjectStorage owns only the bucket. The referencing `Api` creates the access role and binding when it declares the ref.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `dataRetention` | no | `delete` | What happens to the bucket when the XR is deleted: `delete`=bucket is deleted (data unrecoverable); `retain`=bucket stays in AWS (data recoverable). |

## Binding secret

The referencing `Api` writes the Secret, named `{api-name}-{ref-name}`, in the Api's namespace. It mounts at `/bindings/object-storage-{ref-name}/`.

| Key | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name (`platform-{namespace}-{ref-name}`) |
| `region` | `us-east-1` |
| `role-arn` | IAM role ARN (scoped to this bucket, created by Api) |

The app reads `AWS_PROFILE_OBJECT_STORAGE_<REF>` and uses the standard AWS SDK. Full design: [Platform Workload Identity](../docs/workload-identity.md).

- **Reach:** this bucket only.
- **Actions:** `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: ObjectStorage
metadata:
  name: foo-assets
  namespace: foo
spec:
  parameters:
# Bucket "platform-foo-foo-assets" is created in AWS.
# Binding Secret "{api-name}-foo-assets" is written to namespace "foo" by the referencing Api.
```

Then reference it from an `Api`:

```yaml
spec:
  parameters:
    objectStorageRefs:
      - name: foo-assets
```

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).

## Operations

```bash
# XR status. SYNCED=composition ran, READY=all children healthy
kubectl get objectstorages foo-assets -n foo

# Detailed conditions, showing why something is not ready
kubectl get objectstorage foo-assets -n foo -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret, to confirm every key is present (written by Api, not ObjectStorage)
# Secret is named {api-name}-{ref-name}, e.g. foo-foo-assets for Api "foo" + ref "foo-assets"
kubectl get secret foo-foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```
