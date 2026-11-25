# Dashboard Colors

Green, yellow and red mean health, and nothing else uses them. That way a wall of dashboards reads from across the room.

## The rule

Health colors answer "is something wrong?". Every other panel answers "how much?" and gets a cool color.

| Case | Rule |
|---|---|
| Health ramp | Green, yellow, orange, red. Only on panels that say something is fine, degrading or broken. |
| Magnitude | The blue and purple family. For counts, rates, durations, bytes, money and uptime. |
| Never green | A number that is never "bad". A green pod count trains the eye to ignore green. |

## The palette

The two families never overlap.

| Family | Colors | Used for |
|---|---|---|
| Health | `green` → `yellow` → `orange` → `red` | Up/down, ready/not ready, saturation, error rate and capacity remaining. |
| Magnitude | `blue`, `purple`, `light-blue`, `dark-blue`, `light-purple`, `super-light-blue`, `continuous-BlPu`, `continuous-purples` | Plain values, and per-site or per-series identity colors. |
| Neutral | `text` | A value with no scale. A name, an ID, or a state that is neither good nor bad. |

Multi-series time series on `palette-classic` are exempt. That palette says "which series", not "how healthy". The exemption ends once a series color is set by hand. A hand-set `fixedColor` follows the rule, unless the series is a status (2xx/3xx/4xx/5xx, mTLS vs plaintext).

## What counts as health

Ask one question. Could this panel's color ever mean "go look at the cluster"?

Health, so the ramp applies:

| Kind | Examples |
|---|---|
| Ready counts | Certs ready, deployments available, nodes ready, ArgoCD synced. |
| Failure counts where only zero is good | Failed pods, out-of-sync apps, terminating namespaces, released PVs. |
| Saturation against a ceiling | CPU %, memory %, PVC usage, disk usage. |
| Rates with a budget | Error rate, 5xx rate, success rate, reconcile errors. |
| Capacity against a hard limit | Guest workspaces against the five fixed slots. |
| Latency against a target | p99 over a threshold. |

Not health, so blue and purple apply:

| Kind | Examples |
|---|---|
| Totals | Pod count, ArgoCD app count, PVC count, guest resource count. |
| Throughput with no budget | Requests per hour, reconciles/s, runs per hour. |
| Durations that only grow | Node uptime, time since last outage, pod age. |
| Physical readings | Watts, rainfall, cost. |
| Neutral state | Pump idle vs running. |
| Rankings | Longest-lived anything. |

## Picking a color

The panel type sets the mechanism. The rule above sets the family.

| Panel | Health | Magnitude |
|---|---|---|
| `stat` | `thresholds` mode with green/yellow/red steps | `color: { mode: fixed, fixedColor: blue }`, no thresholds |
| `bargauge`, `gauge` | `thresholds` mode with green/yellow/red steps | `continuous-BlPu` |
| Table cell background | threshold steps on the field override | `continuous-BlPu` on the field override |
| `timeseries` | explicit `fixedColor` per status series | `palette-classic`, or explicit blue/purple per series |

Stat panels with `colorMode: background` color the whole tile, so they matter most. A solid green tile is the strongest "all fine" signal on the wall.

## The default that bites

A stat panel with no `color` block gets Grafana's default thresholds: base `green`, `red` at 80. A new count panel then shows a meaningless solid green tile, and turns red at 80.

Always set `color` on a magnitude panel. Delete the inherited `thresholds` block too, so the intent is clear in the JSON.

## Auditing

This prints every panel's color config across all dashboards.

```bash
cd cluster/monitoring
python3 - <<'EOF'
import glob, json, yaml
for f in sorted(glob.glob('grafana-dashboard-*.yaml')):
    dash = json.loads(list(yaml.safe_load(open(f))['data'].values())[0])
    print('##', f)
    def walk(panels):
        for p in panels:
            if p.get('type') == 'row':
                walk(p.get('panels', [])); continue
            d = p.get('fieldConfig', {}).get('defaults', {})
            steps = [f"{s.get('value')}:{s.get('color')}" for s in d.get('thresholds', {}).get('steps', [])]
            print(f"  [{p.get('type')}] {p.get('title')!r} mode={d.get('color', {}).get('mode')} {steps}")
    walk(dash.get('panels', []))
EOF
```

Look for two things: a magnitude panel with `green`, and a health panel that drifted to blue.
