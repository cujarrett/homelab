# XObjectStorage

Provisions object storage and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Consumed by `XApi` when `objectStorage.enabled: true`. Can also be used standalone.

## What it provisions
- **S3 Bucket** — tagged with XR name and namespace for ABAC
- **IAM User** — path `/crossplane/`, tagged to match the bucket
- **AccessKey** — credentials written to the binding secret
- **UserPolicyAttachment** — attaches shared `CrossplaneObjectStorageABAC` policy
- **Binding Secret** — written to namespace derived from XR name

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `region` | no | `us-east-1` | Cloud region for the bucket |
| `environment` | no | `test` | Pass-through from `XApi`|

## Binding secret

The secret name equals the XR name; the namespace is derived by stripping `-object-storage` from the XR name. No caller input needed in either case.

| Key | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name |
| `region` | Region string |
| `username` | Access key ID |
| `password` | Secret access key |

The app authenticates to S3 using `username`/`password`, read from `/bindings/object-storage/username` and `/bindings/object-storage/password` at runtime. `type: s3` means the app uses the S3 protocol — compatible with both AWS S3 (`provider: aws`) and future in-cluster MinIO (`provider: in-cluster`).

## Example

Name the XR `{namespace}-object-storage` and the Secret is written to namespace `{namespace}` automatically:

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XObjectStorage
metadata:
  name: foo-object-storage
spec:
  region: us-east-1
# Secret "foo-object-storage" is written to namespace "foo" automatically.
```

## IAM Design

Each XR gets a dedicated IAM user tagged with `App` (XR name) and `Namespace` (`spec.claimRef.namespace` — empty for standalone XRs, populated when the XR is created by `XApi`). A single shared policy (`CrossplaneObjectStorageABAC`) grants S3 access only when the bucket's tags match the user's tags — so credentials for one instance cannot access another's bucket, and no bucket ARNs are hard-coded.

```
IAM User (crossplane/foo-object-storage)
  tags: App=foo-object-storage, Namespace=foo
    │
    └─ CrossplaneObjectStorageABAC
         condition: aws:ResourceTag/App == ${aws:PrincipalTag/App}
                    aws:ResourceTag/Namespace == ${aws:PrincipalTag/Namespace}
                         ↓
                    S3 Bucket (same tags)
```

- One policy covers all instances — no per-bucket inline policy
- `crossplane-user` only needs `iam:AttachUserPolicy`, not `iam:PutUserPolicy`

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xobjectstorages foo-object-storage

# AWS managed resources (bucket, IAM user, access key, policy attachment)
kubectl get managed | grep foo-object-storage

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xobjectstorage foo-object-storage -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all 6 keys are present with correct values
kubectl get secret foo-object-storage -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```
