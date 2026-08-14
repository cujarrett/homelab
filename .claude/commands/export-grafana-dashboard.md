---
description: Sync a Grafana dashboard saved in the UI back to its ConfigMap in the repo. Pass the full dashboard URL as the argument.
argument: '<grafana-dashboard-url>'
---

Sync the Grafana dashboard at `$ARGUMENTS` to its ConfigMap in the repo.

**Format note:** The Grafana API always returns v1 (`panels`-based) format - this is what Grafana provisioning expects in ConfigMaps. The Grafana UI "Export" button produces v2 (`elements`-based) format which fails provisioning. Always fetch from the API, never from the UI export dialog.

## Steps

### 1. Extract the UID

The URL format is: `https://grafana.local.lab/d/<uid>/<slug>?...`

Extract the `<uid>` segment (e.g. `homelab-kiosk`, `web-traffic`, `homelab-mbp`).

### 2. Fetch the dashboard JSON and write the ConfigMap

Run this in one shot - it fetches from the API, finds the matching ConfigMap, and writes the updated file directly:

```bash
python3 - << 'EOF'
import subprocess, json, sys, re

uid = "<uid>"  # ← replace with extracted UID

# Fetch from Grafana API
result = subprocess.run(
    ["curl", "-sk", f"https://grafana.local.lab/api/dashboards/uid/{uid}"],
    capture_output=True, text=True, check=True
)
d = json.loads(result.stdout)
dash = d["dashboard"]
dash.pop("id", None)
dash.pop("version", None)

# Find the ConfigMap file
grep = subprocess.run(
    ["grep", "-rl", f'"uid": "{uid}"', "cluster/monitoring/"],
    capture_output=True, text=True
)
cm_file = grep.stdout.strip()
if not cm_file:
    print(f"ERROR: No ConfigMap found for uid={uid}", file=sys.stderr)
    sys.exit(1)

# Replace the JSON block (everything after `|-`)
with open(cm_file) as f:
    content = f.read()

match = re.search(r'^(.*\.json: \|-\n)', content, re.MULTILINE)
if not match:
    print("ERROR: Could not find the JSON block marker in ConfigMap", file=sys.stderr)
    sys.exit(1)

header = content[:match.end()]
json_str = json.dumps(dash, indent=2)
indented = "\n".join("    " + line for line in json_str.splitlines())

with open(cm_file, "w") as f:
    f.write(header + indented + "\n")

print(f"Updated {cm_file}")
EOF
```

### 3. Apply to cluster

```bash
k apply -f cluster/monitoring/<dashboard-configmap>.yaml
```

Grafana hot-reloads provisioned dashboards - no restart needed. Open the dashboard URL and confirm it loads correctly before committing.

### 4. Check `"instant": true` for kiosk dashboards

First check whether this dashboard is in the kiosk playlist:

```bash
grep '<uid>' cluster/monitoring/grafana-playlist-kiosk.yaml
```

If it is, verify all stat panel targets have `"instant": true` - range queries on stat panels crash the Pi on the kiosk display:

```bash
grep -c '"instant"' cluster/monitoring/<dashboard-configmap>.yaml
```

If any stat panels are missing it, add `"instant": true` to their targets manually.

### 5. Check panel colors

A panel edited in the UI comes back with Grafana's default thresholds - base `green`, `red` at 80 - so a plain count round-trips as a green tile. Green, yellow and red are reserved for health; every other value uses the blue/purple family. Read [Dashboard Colors](../../cluster/monitoring/dashboard-colors.md) and fix any panel that drifted.

```bash
grep -n '"color"' cluster/monitoring/<dashboard-configmap>.yaml
```
