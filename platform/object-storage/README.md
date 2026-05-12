# XObjectStorage

Provisions object storage and exposes connection details as a [servicebinding.io](https://servicebinding.io)-compliant Secret.

Standalone resource with a lifecycle independent of any one API. Bind to an `XApi` via `objectStorageRef.name`.

See also: [`XSql`](../sql/README.md) · [`XNoSql`](../nosql/README.md) · [`XCache`](../cache/README.md) · [`XApi`](../api/README.md)

## What it provisions
- **Object storage bucket** — scoped to this XR instance; credentials cannot access another instance's bucket
- **Binding Secret** — written to the explicit `namespace` parameter; contains everything the app needs to connect

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `namespace` | yes | — | Namespace to write the binding Secret into. |
| `region` | no | `us-east-1` | Cloud region for the bucket |

## Binding secret

The secret name equals the XR name; the namespace comes from the explicit `namespace` parameter.

| Key | Value |
|---|---|
| `type` | `s3` |
| `provider` | `aws` |
| `bucket` | Bucket name |
| `region` | Region string |
| `username` | Access key ID |
| `password` | Secret access key |

The app authenticates to S3 using `username`/`password`, read from `/bindings/object-storage/username` and `/bindings/object-storage/password` at runtime.

## Example

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XObjectStorage
metadata:
  name: foo-assets
spec:
  parameters:
    namespace: foo
# Secret "foo-assets" is written to namespace "foo".
```

Then reference from an `XApi`:

```yaml
spec:
  parameters:
    objectStorageRef:
      name: foo-assets
```

Instance files live in [`homelab-tenants/`](../../../homelab-tenants/).

## Operations

```bash
# XR status — SYNCED=composition ran, READY=all children healthy
kubectl get xobjectstorages foo-assets

# Detailed conditions — shows exactly WHY something is not ready
kubectl get xobjectstorage foo-assets -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Binding secret — confirm all 6 keys are present with correct values
kubectl get secret foo-assets -n foo \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```
