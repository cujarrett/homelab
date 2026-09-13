# blog

Ghost blog running at `blog.mattjarrett.dev` via Cloudflare Tunnel.

## Files

| File | Purpose |
|---|---|
| `ghost.yaml` | Namespace, PVC, Deployment, Service, Ingress |
| `ghost-backup.yaml` | CronJob that runs `ghost-backup.py` daily at 02:00 |
| `ghost-backup.py` | Fetches published posts from Ghost Content API and commits them to GitHub |
| `kustomization.yaml` | Wires `ghost-backup.py` into the `ghost-backup-script` ConfigMap |

## Backup

Posts are backed up daily to [github.com/cujarrett/blog-backups](https://github.com/cujarrett/blog-backups).

Each post gets its own folder:
```
posts/
  my-post-slug/
    index.md      ← YAML frontmatter + HTML body
    images/
      2024/01/
        photo.jpg
```

Image `src` attributes in `index.md` are rewritten to relative paths so the files are self-contained.

### Secrets

Both keys come from AWS Parameter Store through External Secrets - see [External Secrets](../../docs/external-secrets.md). To change one, write the parameter; ESO updates the Secret within the hour.

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
