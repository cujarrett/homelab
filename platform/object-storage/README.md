# XObjectStorage

Crossplane platform primitive that provisions an object storage bucket and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Consumed by `XApi` when `objectStorage.enabled: true`. Can also be used standalone or by other platform compositions.

## What it provisions
- **Bucket** — cloud object storage bucket (currently AWS S3)
- **Connection Secret** — written to `spec.secretNamespace/spec.secretName` with servicebinding.io-compliant keys

## Connection secret keys

| File | Spec status | Value |
|---|---|---|
| `type` | MUST | `s3` |
| `provider` | SHOULD | `aws` |
| `uri` | well-known | Storage endpoint URL |
| `region` | non-standard | Region string |
| `bucket` | non-standard | Bucket name |
| `username` | well-known | Access key ID |
| `password` | well-known | Secret access key |

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `secretNamespace` | yes | — | Namespace to write the connection secret into |
| `secretName` | yes | — | Name for the connection secret |
| `region` | no | `us-east-1` | Cloud region for the bucket |

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XObjectStorage
metadata:
  name: my-app-object-storage
spec:
  secretName: my-app-object-storage
  secretNamespace: my-app
  region: us-east-1
```
