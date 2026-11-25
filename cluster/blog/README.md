# blog

The Ghost blog at `blog.mattjarrett.dev`, served through Cloudflare Tunnel.

| File | Holds |
|---|---|
| `ghost.yaml` | Namespace, PVC, Deployment, Service, HTTPRoute |
| `ghost-backup.yaml` | CronJob that runs `ghost-backup.py` daily at 02:00 |
| `ghost-backup.py` | Fetches published posts from the Ghost Content API and commits them to GitHub |
| `kustomization.yaml` | Puts `ghost-backup.py` into the `ghost-backup-script` ConfigMap |

## Backup

Posts back up daily to [cujarrett/blog-backups](https://github.com/cujarrett/blog-backups). Each post gets its own folder. Image `src` links point to the local copies, so each folder stands alone.

```
posts/
  my-post-slug/
    index.md      ← YAML frontmatter + HTML body
    images/
      2024/01/
        photo.jpg
```

### Secrets

Both keys come from AWS Parameter Store through [External Secrets](../../docs/external-secrets.md). Write the parameter to change one. ESO updates the Secret within the hour.

| Key | Parameter | Where to get it |
|---|---|---|
| `content-api-key` | `/homelab/blog/content-api-key` | Ghost Admin → Settings → Integrations → your integration → Content API Key |
| `github-token` | `/homelab/blog/backup-github-token` | GitHub → Settings → Developer settings → Fine-grained tokens → `cujarrett/blog-backups` → Contents: Read and write |

### Manual test run

```bash
kubectl create job ghost-backup-test --from=cronjob/ghost-backup -n blog
kubectl logs -n blog -l job-name=ghost-backup-test -f
kubectl delete job ghost-backup-test -n blog
```
