# Homelab

This homelab is a small multi-node Raspberry Pi cluster built to learn K3s Kubernetes and [Kubernetes Resource Model (KRM)](krm) and [Crossplane](crossplane). The focus is on platform engineering, GitOps workflows, and using Kubernetes as a control plane for infrastructure rather than just running containers.

[krm]: https://github.com/kubernetes/design-proposals-archive/blob/main/architecture/resource-management.md
[crossplane]: https://www.crossplane.io/

The goal is to build, break, and rebuild a simple but realistic platform while learning how modern cloud-native infrastructure actually works.

## Network Topology

```md
[Fiber Internet]
      │
      ▼
[Fiber → Fiber ONT]
      │
      ▼
[UDR7 UniFi Dream Router 7]  <- Main router / firewall / DHCP / gateway
      │
      ├─> [TL-SG1008MP Switch]  <- Dedicated homelab switch (isolates lab traffic)
               │
               ├─> [Raspberry Pi 5 8GB Node 1]  (Controller Node)
               │
               ├─> [Raspberry Pi 5 8GB Node 2]  (Worker)
               │
               ├─> [Raspberry Pi 5 8GB Node 3]  (Worker)
               │
               └─> [Raspberry Pi 5 8GB Node 4]  (Worker)
```

## Parts

| Category | Item | Qty |
|----------|------|-----|
| Rack | GeeekPi DeskPi RackMate T0 Plus 10" 4U Cabinet | 1 |
| Rack | GeeekPi 10" 2U Rack Mount for Raspberry Pi | 1 |
| Rack | 10" Rack Mount PDU 4 Outlet 1U w/ Surge Protection | 1 |
| Display | GeeekPi 6.91" 1U Rack Mount LCD Touch Screen (1424x280) | 1 |
| Compute | Raspberry Pi 5 8GB | 4 |
| Compute | GeeekPi P31 M.2 NVMe PoE+ HAT w/ Active Cooler (Pi 5) | 4 |
| Compute | 256GB M.2 2230 NVMe SSD | 4 |
| Networking | TP-Link TL-SG1008MP 8-Port Gigabit PoE+ Switch | 1 |
| Cooling | 120mm PWM Fan top | 1 |
| Cooling | 80mm PWM Fan bottom | 2 |
| Cooling | USBC Thermal Fan Controller | 1 |
