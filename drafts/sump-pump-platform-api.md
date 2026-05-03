# My Sump Pump Now Has a Platform API

**And it definitely didn't need one.**

My basement has a sump pump. The reasonable solution to "has it been running?" is a $9.54 float sensor alarm. The answer I went with was a NATS JetStream stream.

I spent $9.54.

---

### The Hardware

The [Shelly PM Mini Gen3](https://www.shelly.com/en-us/products/shop/shelly-pm-mini-gen3) is a Wi-Fi power monitor that clamps around a wire and reports wattage over a local HTTP API. Setup is five minutes — unless you run the wire *alongside* the clamp instead of *through* it, in which case it's longer and you'll feel appropriately humbled.

Once correctly installed: 0W at idle, ~350W when the pump kicks on. Clean signal.

---

### The Architecture

```mermaid
flowchart LR
    Shelly(["Shelly PM Mini Gen3"]):::hw
    Bridge["sump-pump-bridge<br/><i>XApi</i>"]:::svc
    Topic[["HOME-APPLIANCES<br/><i>XTopic</i>"]]:::msg
    Sub[/"sump-pump-monitor<br/><i>XSubscription</i>"/]:::msg
    Consumer["sump-pump-consumer<br/><i>XApi</i>"]:::svc
    Prom[("Prometheus")]:::obs
    Grafana["Grafana"]:::obs

    Shelly -->|"GET ?apower=350"| Bridge
    Bridge --> Topic
    Topic --> Sub
    Sub --> Consumer
    Consumer --> Prom
    Prom --> Grafana

    classDef hw   fill:#d97706,stroke:#92400e,color:#fff
    classDef svc  fill:#2563eb,stroke:#1e40af,color:#fff
    classDef msg  fill:#7c3aed,stroke:#5b21b6,color:#fff
    classDef obs  fill:#059669,stroke:#065f46,color:#fff
```

Every node in that diagram is a Crossplane composite resource — a YAML file I committed to git. The stream is an `XTopic`. The APIs are `XApi` instances. The durable consumer is an `XSubscription`. Crossplane provisions everything behind them.

I don't deploy containers anymore. I request capabilities.

**But why `XTopic` and `XSubscription`?** I'd built `XApi` and `XWordPressPlatform` already. What I didn't have was a platform-native event bus — a way for a team to say "I want a stream" or "I want a subscription on that stream" without knowing anything about NATS JetStream, NACK CRs, or `DeliverPolicy`. So I built the abstractions. Then I needed something real to test them with.

A sump pump runs in my basement. It seemed like a reasonable use case.

*Are these XRDs or CRDs?* Both, technically. An XRD is what *you* define — the schema and contract for your platform API. When Crossplane processes it, it registers the corresponding CRD in the cluster automatically. A CRD is a Kubernetes primitive. An XRD is your platform's API. Nobody consuming the platform needs to know NATS exists underneath. That's the point.

---

### One Wrinkle

The Shelly is on VLAN 1. The cluster is on VLAN 10. `sump-pump-bridge.local.lab` wouldn't resolve.

One API call fixed it:

```bash
curl -X POST http://<shelly-ip>/rpc/Wifi.SetConfig \
  -d '{"config":{"sta":{"nameserver":"192.168.10.100"}}}'
# {"restart_required":false}
```

AdGuard Home runs in the cluster and serves DNS for `*.local.lab`. Point the Shelly at it and everything resolves correctly across VLANs. The cluster handles its own DNS. It was always going to be the nameserver. It just took a flooded basement to make that obvious.

---

### The Result

Open Grafana. Look at the overnight graph. Vertical line at 2:47 AM. The pump ran. Everything is fine. Go back to sleep.

Is this overkill for a sump pump? Profoundly. But the platform was already there — Crossplane, NATS, the monitoring stack. Adding the sump pump was five YAML files and a commit. More importantly: the event bus now has a real producer and a real consumer running against it. Not a unit test. Not a synthetic load generator. A basement appliance that runs when it rains.

That's the thing about building a platform API: the second use case costs almost nothing. The third will too.

The configuration is in [GitHub](https://github.com/cujarrett/homelab) if you want to wire up your own appliances.
