My homelab journey

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
      │        ├─> [Raspberry Pi 5 Node 1]  (8GB Controller Node)
      │        │
      │        ├─> [Raspberry Pi 5 Node 2]  (8GB Worker)
      │        │
      │        ├─> [Raspberry Pi 5 Node 3]  (8GB Worker)
      │        │
      │        └─> [Raspberry Pi 5 Node 4]  (8GB Worker)
      │
      ├─> [Office Wall Jack] → [PoE Injector] → [U7 LITE Access Point]  (Main Floor Wi-Fi)
      │
      ├─> [Master Bedroom Closet Wall Jack] → [PoE Injector] → [U7 LITE Access Point]  (Upstairs Wi-Fi)
      │
      ├─> [Philips Hue Bridge Pro]
```
