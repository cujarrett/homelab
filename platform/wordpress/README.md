# Wordpress

A Wordpress is a self-contained WordPress site with its own MariaDB database.

## What it provisions

| Piece | What it does |
|---|---|
| Database | MariaDB with its own volume. Credentials come from the XR UID, so no secret lives in Git. |
| WordPress | Apache and PHP, with a volume for `wp-content` (uploads, themes, plugins). The first run seeds `wp-content` from the image. |
| Route | HTTPS on `host`. Login is rate limited. `xmlrpc.php` and direct PHP paths are blocked. |
| Network rules | WordPress reaches only its database, DNS and the internet. The database accepts only its own WordPress pod. |
| Encryption | Traffic to the database is encrypted. The database refuses any caller without a workload identity. |
| Code editor | Off (`DISALLOW_FILE_EDIT`). Plugin and theme installs and updates still work from the admin UI. |

Your workspace owns the namespace through its `namespace.yaml`.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `host` | yes | - | Hostname clients call. Must match `siteurl` and `home` in the database. Changing it needs a database search-replace. |
| `size` | no | `sm` | Compute for WordPress and MariaDB. See the size tiers below. |
| `storageSize` | no | `10Gi` | `wp-content` volume size. |
| `dbStorageSize` | no | `5Gi` | Database volume size. |
| `replicas` | no | `1` | WordPress replicas. |
| `dataRetention` | no | `retain` | `retain` keeps the data after the XR is deleted. `delete` wipes it. |

### Size tiers

| Size | WP CPU request/limit | WP Memory request/limit | DB CPU request/limit | DB Memory request/limit |
|---|---|---|---|---|
| `sm` | 50m / 1000m | 640Mi / 640Mi | 50m / 500m | 288Mi / 288Mi |
| `md` | 100m / 1500m | 1280Mi / 1280Mi | 50m / 500m | 288Mi / 288Mi |
| `lg` | 150m / 2000m | 2Gi / 2Gi | 100m / 1000m | 1Gi / 1Gi |

## Example instance

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: Wordpress
metadata:
  name: foo
  namespace: foo
spec:
  parameters:
    host: foo.example.com
    storageSize: "10Gi"
    dbStorageSize: "1Gi"
    size: sm
    dataRetention: retain
```

Instance files live in [`homelab-workspaces/`](https://github.com/cujarrett/homelab-workspaces).
