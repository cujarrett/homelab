# Sump Pump Monitoring via XTopic + XSubscription

Monitor sump pump power usage via a Shelly PM Mini Gen3 smart plug.
Dogfoods `XTopic` and `XSubscription` as the event backbone.

## Hardware

- Shelly PM Mini Gen3 - wired inline on the sump pump circuit
  - Native webhooks, no hub required
  - Monitoring only (no relay) — zero added risk to pump operation
  - Publishes wattage in real time over WiFi via HTTP webhook

---

## Plan

### 1. Physical setup
- [ ] Wire Shelly PM Mini Gen3 inline on sump pump circuit
- [ ] Connect to home WiFi via Shelly app (Bluetooth onboarding)
- [ ] Confirm wattage readings in Shelly app

### 2. Create the XTopic
- [x] Create `platform/xrs/topic/home-appliances.yaml`

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XTopic
metadata:
  name: home-appliances
spec:
  parameters:
    streamName: HOME-APPLIANCES
    subjects:
      - "home.appliance.>"
    retention: limits
    maxAge: "720h"   # 30 days of history
    replicas: 3
```

### 4. Create the XSubscription
- [x] Create `platform/xrs/subscription/sump-pump-monitor.yaml`

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: XSubscription
metadata:
  name: sump-pump-alert
spec:
  parameters:
    topicRef:
      name: home-appliances
    filterSubject: "home.appliance.sump-pump.>"
    deliverPolicy: new        # only care about real-time events, not replay
    ackPolicy: explicit
    ackWait: "30s"
```

### 5. Webhook → NATS bridge (XApi)
- [x] Create `platform/xrs/api/sump-pump-bridge.yaml`
- [ ] Build `ghcr.io/cujarrett/sump-pump-bridge` image (new repo) that:
  1. Receives HTTP POST webhooks from the Shelly device
  2. Normalizes wattage into events:
     - Watts > threshold (e.g. 50W) → publish `home.appliance.sump-pump.running`
     - Watts drop back to ~0W → publish `home.appliance.sump-pump.idle`
  3. Publishes to the `HOME-APPLIANCES` NATS stream
- [ ] Configure Shelly PM Mini Gen3 to POST to the bridge service URL
  - NOTE: Shelly can't validate custom CA certs — use HTTP or a NodePort; see comment in the XApi manifest

### 6. Alert consumer (XSubscription consumer service)
- [x] Create `platform/xrs/api/sump-pump-consumer.yaml`
- [ ] Build `ghcr.io/cujarrett/sump-pump-consumer` image (new repo) that:
  - Reads from the `sump-pump-alert` durable consumer
  - On `home.appliance.sump-pump.running` — POST a Grafana annotation
  - On extended idle during rain/wet season — optional alert (future)
  - XApi manifest already created (`sump-pump-consumer`)

### 7. Grafana dashboard
- [x] Create `apps/monitoring/grafana-dashboard-sump-pump.yaml`
  - Panels: current state, current watts, runs today, runs this week, power draw over time, run frequency per hour
  - Metrics: `sump_pump_running`, `sump_pump_watts`, `sump_pump_runs_total` — exposed by the bridge service

---

## Alerting ideas (future)

- **Running too long** — pump has been on for >5 min = possible jam or flooding
- **Not running at all** — during heavy rain, pump should cycle; silence = failure
- **Power anomaly** — wattage spike outside normal range = motor stress

---

## Notes

- Shelly HTTP webhook POSTs directly to the bridge XApi — no MQTT broker needed.
- `retention: limits` + `maxAge: 720h` means you can replay 30 days of pump
  events — useful for spotting seasonal patterns.
- If the bridge pod is temporarily unavailable, the Shelly webhook event is
  dropped (no retry buffer). For this use case (monitoring, not control) that
  tradeoff is acceptable.
