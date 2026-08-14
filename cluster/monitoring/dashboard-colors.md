# Dashboard Colors

> **The one idea (grug):** green, yellow and red mean health. Nothing else is allowed to use them, so a wall of dashboards can be read from across the room.

## Index

| Chapter | What's in it |
|---|---|
| [The rule](#the-rule) | the whole philosophy in three lines |
| [The palette](#the-palette) | which colors exist and what each one is for |
| [What counts as health](#what-counts-as-health) | the test for whether a panel gets the health ramp |
| [Picking a color](#picking-a-color) | the decision, panel type by panel type |
| [The default that bites](#the-default-that-bites) | why a new panel is accidentally green |
| [Auditing](#auditing) | listing every panel color in one command |

## The rule

Health colors answer one question - *is something wrong?* Every other panel answers *how much?*, and gets a cool color instead.

- Health ramp - green, yellow, orange, red - only on panels that say something is fine, degrading, or broken.
- Magnitude - counts, rates, durations, bytes, money, uptime - uses the blue/purple family.
- A number that is never "bad" is never green. A green pod count trains the eye to ignore green.

## The palette

Two families, no overlap.

| Family | Colors | Used for |
|---|---|---|
| Health | `green` → `yellow` → `orange` → `red` | up/down, ready/not ready, saturation, error rate, capacity remaining |
| Magnitude | `blue`, `purple`, `light-blue`, `dark-blue`, `light-purple`, `super-light-blue`, `continuous-BlPu`, `continuous-purples` | any plain value, and per-site or per-series identity colors |

Neutral `text` is fine for a value with no scale at all - a name, an ID, a state that is neither good nor bad.

Multi-series time series on `palette-classic` are exempt. That palette is categorical - it reads as *which series*, not *how healthy* - and rewriting it everywhere buys nothing. The exemption ends the moment a series color is set explicitly: a hand-assigned `fixedColor` follows the rule like everything else, unless the series **is** a status (2xx/3xx/4xx/5xx, mTLS vs plaintext).

## What counts as health

One test: could this panel's color ever mean *go look at the cluster*?

Health, so the ramp applies:

- Ready / not ready counts - certs ready, deployments available, nodes ready, ArgoCD synced
- Failure counts where zero is the only good number - failed pods, out-of-sync apps, terminating namespaces, released PVs
- Saturation against a ceiling - CPU %, memory %, PVC usage, disk usage
- Rates with a budget - error rate, 5xx rate, success rate, reconcile errors
- Capacity against a hard limit - guest workspaces against the five fixed slots
- Latency against a target - p99 over a threshold is a problem

Not health, so blue/purple applies:

- Totals and inventories - pod count, ArgoCD app count, PVC count, guest resource count
- Throughput with no budget - requests per hour, reconciles/s, runs per hour
- Durations that only grow - node uptime, time since last outage, pod age
- Physical readings - watts, rainfall, cost
- State that is neither good nor bad - pump idle vs running
- Rankings and leaderboards - longest-lived anything

## Picking a color

Panel type decides the mechanism; the rule above decides the family.

| Panel | Health | Magnitude |
|---|---|---|
| `stat` | `thresholds` mode with green/yellow/red steps | `color: { mode: fixed, fixedColor: blue }`, no thresholds |
| `bargauge`, `gauge` | `thresholds` mode with green/yellow/red steps | `continuous-BlPu` |
| Table cell background | threshold steps on the field override | `continuous-BlPu` on the field override |
| `timeseries` | explicit `fixedColor` per status series | `palette-classic`, or explicit blue/purple per series |

Stat panels using `colorMode: background` carry the color across the whole tile, so they are the ones that matter most - a solid green tile is the strongest "all fine" signal on the wall.

## The default that bites

A stat panel with no `color` block falls back to Grafana's default thresholds - base `green`, `red` at 80. So a brand-new "count of things" panel renders as a solid green tile that means nothing, and an unrelated value of 80 turns it red.

Always set `color` explicitly on a magnitude panel. Deleting the inherited `thresholds` block at the same time keeps the intent obvious in the JSON.

## Auditing

Print every panel's color config across all dashboards, then read the list against the rule:

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

Two things to look for: a magnitude panel carrying `green`, and a health panel that drifted to blue.
