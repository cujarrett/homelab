---
name: export-grafana-dashboard
description: Export a Grafana dashboard from the live cluster and update its ConfigMap in the repo. Pass the full dashboard URL as the argument.
argument-hint: '<grafana-dashboard-url>'
---

Export the Grafana dashboard at `$input` and update its ConfigMap file in the repo.

## Steps

### 1. Extract the UID

The URL format is: `https://grafana.local.lab/d/<uid>/<slug>?...`

Extract the `<uid>` segment (e.g. `service-mesh`, `homelab-kiosk`, `web-traffic`).

### 2. Fetch the dashboard JSON via the API

Run this in the terminal, replacing `<uid>`:

```bash
curl -sk "https://grafana.local.lab/api/dashboards/uid/<uid>" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
dash = d['dashboard']
dash.pop('id', None)
dash.pop('version', None)
print(json.dumps(dash, indent=2))
" | pbcopy
```

- Use `https://` and `-k` — `http://` returns 404 (self-signed cert)
- This strips `id` (DB row ID) and `version` (managed by provisioning) before copying
- The API returns the classic `panels`-based format — do NOT use the Grafana UI export dialogs, they produce the new `elements` format which fails provisioning

### 3. Find the matching ConfigMap file

```bash
grep -rl '"uid": "<uid>"' cluster/monitoring/
```

### 4. Replace the JSON in the ConfigMap

The ConfigMap structure is:

```yaml
data:
  <name>.json: |-
    {   <-- replace everything from here down
```

Replace all content after `|-` with the clipboard JSON, indented **4 spaces**.

### 5. Apply and verify

```bash
k apply -f cluster/monitoring/<dashboard-configmap>.yaml
```

Grafana hot-reloads provisioned dashboards — no restart needed. Open the dashboard in the browser and confirm it loads before committing.

### 6. Check stat panels for `"instant": true`

Dashboards on the kiosk playlist must use `"instant": true` on all stat panel targets to avoid heavy range queries crashing the Pi. After updating, verify:

```bash
grep -c '"instant"' cluster/monitoring/<dashboard-configmap>.yaml
```

If new stat panels were added without it, add `"instant": true` to their targets manually.
