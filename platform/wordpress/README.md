# XWordPressPlatform Platform

Crossplane composition that deploys a self-contained WordPress site with MariaDB.

## What it provisions
- **Namespace** — isolated per app
- **MariaDB PVC** — persistent storage for the database
- **MariaDB StatefulSet + Service** — database backend; credentials derived from the XR UID (no secrets in Git)
- **WordPress PVC** — persistent storage for `wp-content` (uploads, themes, plugins)
- **WordPress Deployment + Service** — Apache/PHP WordPress container; seeds `wp-content` from the image on first run
- **Ingress** — Traefik `websecure` with cert-manager TLS

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `host` | yes | — | Ingress hostname. Must match WordPress `siteurl`/`home` in the DB — changing requires a DB search-replace. |
| `storageSize` | no | `10Gi` | `wp-content` PVC size (uploads, themes, plugins) |
| `dbStorageSize` | no | `5Gi` | MariaDB PVC size |
| `replicas` | no | `1` | WordPress pod replicas |
| `cpuRequest` | no | `500m` | CPU reserved for the WordPress container |
| `cpuLimit` | no | `1000m` | Max CPU (burst for image resize/thumbnail generation) |
| `memoryRequest` | no | `256Mi` | RAM reserved for the WordPress container |
| `memoryLimit` | no | `512Mi` | Max RAM before OOMKill |
| `dataRetention` | no | `retain` | `retain` — keep PV on XR delete (uses `longhorn` StorageClass). `delete` — wipe PV on XR delete (uses `longhorn-delete` StorageClass). |

## Example instance

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XWordPressPlatform
metadata:
  name: my-site
  namespace: my-site
spec:
  parameters:
    host: my-site.example.com
    storageSize: "10Gi"
    dbStorageSize: "1Gi"
    dataRetention: retain
```

Instance files live in [`platform/xrs/wordpress/`](../xrs/wordpress/).
