# Homelab

This homelab is a small multi-node Raspberry Pi cluster built to learn K3s Kubernetes and Crossplane in a real hardware environment. The focus is on platform engineering, GitOps workflows, and using Kubernetes as a control plane for infrastructure rather than just running containers.

The goal is to build, break, and rebuild a simple but realistic platform while learning how modern cloud-native infrastructure actually works.

## Network Topology

```md
[Fiber Internet]
      │
      ▼
[Fiber → Ethernet Box]
      │
      ▼
[UDR7 UniFi Dream Router 7]  <- Main router / firewall / DHCP / gateway
      │
      ├─> [TL-SG1008MP Switch]  <- Dedicated homelab switch (isolates lab traffic)
      │        │
      │        ├─> [Raspberry Pi 5 8GB Node 1]  (Controller Node)
      │        │
      │        ├─> [Raspberry Pi 5 8GB Node 2]  (Worker)
      │        │
      │        ├─> [Raspberry Pi 5 8GB Node 3]  (Worker)
      │        │
      │        └─> [Raspberry Pi 5 8GB Node 4]  (Worker)
      │
      ├─> [Main Floor Wall Jack] → [PoE Injector] → [U7 LITE Access Point]  (Main Floor Wi-Fi)
      │
      ├─> [Upstairs Wall Jack] → [PoE Injector] → [U7 LITE Access Point]  (Upstairs Wi-Fi)
      │
      ├─> [Philips Hue Bridge Pro]
```

## Hardware Inventory

| Category | Item | Qty |
|----------|------|-----|
| Rack | GeeekPi DeskPi RackMate T0 Plus 10" 4U Cabinet | 1 |
| Rack | GeeekPi 10" 2U Rack Mount for Raspberry Pi | 1 |
| Rack | 10" Rack Mount PDU 4 Outlet 1U w/ Surge Protection | 1 |
| Display | GeeekPi 6.91" 1U Rack Mount LCD Touch Screen (1424x280) | 1 |
| Compute | Raspberry Pi 5 8GB | 4 |
| Compute | GeeekPi P31 M.2 NVMe PoE+ HAT w/ Active Cooler (Pi 5) | 4 |
| Compute | Dell 256GB M.2 2230 NVMe SSD (Class 35) | 4 |
| Networking | TP-Link TL-SG1008MP 8-Port Gigabit PoE+ Switch | 1 |
| Networking | Cat6 Ethernet Cable 6FT | 1 |
| Networking | Cat6 Ethernet Cables 0.5FT (10-Pack) | 1 |
| Cooling | be quiet! Pure Wings 3 120mm PWM Fan | 2 |
| Cooling | Coolerguys Thermal Fan Controller (Rev. 4) | 1 |
| Cables | 1FT C13 Power Cable | 1 |
| Cables | Micro HDMI to HDMI 2.1 Cable (1FT, 48Gbps) | 1 |
| Cables | USB-A to DC 5.5x2.1mm 5V Barrel Cable (3FT) | 1 |
