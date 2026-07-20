# Wordpress

Crossplane composition that deploys a self-contained WordPress site with MariaDB.

## What it provisions
- **MariaDB PVC** — persistent storage for the database
- **MariaDB StatefulSet + Service** — database backend; credentials derived from the XR UID (no secrets in Git)
- **WordPress PVC** — persistent storage for `wp-content` (uploads, themes, plugins)
- **WordPress Deployment + Service** — Apache/PHP WordPress container; seeds `wp-content` from the image on first run
- **Ingress** — Traefik `websecure` with cert-manager TLS

The namespace is owned by the tenant — created by `namespace.yaml` in the tenant directory.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `host` | yes | — | Ingress hostname. Must match WordPress `siteurl`/`home` in the DB — changing requires a DB search-replace. |
| `size` | no | `sm` | Resource tier for WordPress and MariaDB containers. See table below. |
| `storageSize` | no | `10Gi` | `wp-content` PVC size (uploads, themes, plugins) |
| `dbStorageSize` | no | `5Gi` | MariaDB PVC size |
| `replicas` | no | `1` | WordPress pod replicas |
| `dataRetention` | no | `retain` | `retain` — keep PV on XR delete (uses `longhorn-retain` StorageClass). `delete` — wipe PV on XR delete (uses `longhorn-delete` StorageClass). |

### Size tiers

| Size | WP CPU request/limit | WP Memory request/limit | DB CPU request/limit | DB Memory request/limit |
|---|---|---|---|---|
| `sm` | 100m / 500m | 256Mi / 512Mi | 100m / 500m | 256Mi / 512Mi |
| `md` | 250m / 1500m | 512Mi / 1024Mi | 100m / 500m | 256Mi / 512Mi |
| `lg` | 500m / 2000m | 1Gi / 2Gi | 200m / 1000m | 512Mi / 1Gi |

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

Instance files live in [`homelab-workspaces/`](../../../homelab-workspaces/).
