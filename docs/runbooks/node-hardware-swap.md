# Node Hardware Swap

Moving a node onto new Raspberry Pi 5 hardware by swapping the NVMe SSD across. The OS,
k3s state, and all configuration move with the SSD — no reinstall required. Written from
the ctrl-1 8GB to 16GB upgrade; the procedure is the same for any node.

Steps 1 through 11 apply to every node. [If the node is ctrl-1](#if-the-node-is-ctrl-1)
covers what the control plane adds on top — read it first if that is the node you are
swapping.

**Estimated time:** 2–3 hours. Most of it is waiting, not active work.

---

## Risk Analysis

Read this before touching anything.

### Critical risks (can leave you hosed)

**EEPROM boot order on new board**
New Pi 5 boards ship set to boot from SD card, not NVMe. If you slot the SSD in before
setting the boot order, the new board will fail to boot and you'll need an SD card to
recover. Solve this first, before any downtime.

**UniFi DHCP reservation tied to MAC address**
`192.168.10.100` is reserved for ctrl-1's current MAC. The new board has a different MAC.
If you boot the new board without updating the reservation, it gets a random IP, the
workers lose the API server, and `kubectl` stops working. Update the reservation before
first boot.

### Non-critical risks (annoying but recoverable)

**`smsc95xx.macaddr` in cmdline.txt**
The current `/boot/firmware/cmdline.txt` contains a `smsc95xx.macaddr` parameter
left over from a previous Pi model. This parameter is ignored on Pi 5 (which uses PCIe
ethernet, not USB smsc95xx). It is harmless and can be removed after migration if desired.

**Workloads pinned to the node**
Anything with a `nodeSelector` for this node stays down for the whole swap, because there
is nowhere else for it to schedule. Check before you start:

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
```

---

## Pre-work (do this days before, zero downtime)

### 1. Prepare the micro SD card

You need a micro SD card to boot Pi OS Lite on the new board so you can read the MAC
address and set the EEPROM boot order. A 16GB card is fine (even a dashcam card works —
just put it back when done).

Flash Pi OS Lite (64-bit) onto the card using **Raspberry Pi Imager** on your Mac:
- Download: https://www.raspberrypi.com/software/
- Choose: Raspberry Pi OS Lite (64-bit)
- In the imager settings (gear icon): set hostname `ctrl-1-new`, enable SSH, set
  username `pi` and a password you'll remember
- Flash to the micro SD card

This card is only used for steps 1 and 2. You will not need it on migration day.

### 2. Get the new board's MAC address

**Switch port problem:** Your switch only has 4 ports (all occupied). You need a free port
to connect the new board temporarily. Easiest option: drain work-3 first, unplug it to
free a port, do steps 2-3, then plug work-3 back in and uncordon it. The cluster runs
fine on 2 workers for the ~5 minutes this takes.

```bash
kubectl drain work-3 --ignore-daemonsets --delete-emptydir-data --grace-period=30
# unplug work-3 ethernet, plug in new board ethernet
```

Insert the SD card into the new Pi 5 board (no NVMe attached yet), connect ethernet and
power on. Wait ~30 seconds then SSH in:

```bash
ssh pi@ctrl-1-new.local  # or find the IP in your UniFi client list
ip link show eth0 | grep link/ether
# e.g. link/ether d8:3a:dd:xx:xx:xx
```

Write it down. You'll need it in step 4.

### 3. Set NVMe boot order on new board (while on SD card)

Still SSH'd into the new board on the SD boot, set the boot order to NVMe first:

```bash
sudo raspi-config
# Advanced Options → Boot Order → NVMe/USB Boot (option B2 or similar)
# Alternatively:
sudo rpi-eeprom-config --edit
# Change BOOT_ORDER=0xf41 to BOOT_ORDER=0xf16  (NVMe first, then SD, then USB)
# Save and reboot to apply
```

Confirm it took:
```bash
sudo rpi-eeprom-config | grep BOOT_ORDER
# Should show 0xf16 or similar with NVMe (6) first
```

Power off the new board, remove the SD card, and set the board aside. Return the micro SD
card to wherever it came from. The new board is now ready to boot from NVMe.

**Restore work-3:** unplug the new board, plug work-3 ethernet back in, then:
```bash
kubectl uncordon work-3
```

### 4. Update UniFi DHCP reservation

In the UniFi controller:
- Network → Settings → DHCP → Fixed IPs (or Client Overrides depending on version)
- Find the entry for `192.168.10.100` / `ctrl-1`
- Update the MAC address to the new board's MAC from step 1

**Do this before migration day.** It takes effect immediately — the reservation will be
waiting for the new board when it first boots.

### 5. Save the k3s token

You'll need this if you ever add a new worker or rebuild a node.

```bash
ssh pi@192.168.10.100 "sudo cat /var/lib/rancher/k3s/server/token"
```

Store it somewhere safe outside the cluster (password manager, etc.).

---

## Migration Day

### 6. Drain ctrl-1

Move all moveable workloads off ctrl-1 to minimize disruption during downtime.

```bash
kubectl drain ctrl-1 --ignore-daemonsets --delete-emptydir-data --grace-period=30
```

DaemonSet pods (Traefik, Promtail, Longhorn node-exporter, etc.) will stay — that's
expected. The `--ignore-daemonsets` flag skips them.

Verify workers took the load:
```bash
kubectl get pods -A -o wide | grep ctrl-1
# Only DaemonSet pods should remain
```

### 7. Cordon ctrl-1 (prevent new scheduling)

Already done by drain, but confirm:
```bash
kubectl get node ctrl-1
# Should show SchedulingDisabled
```

### 8. Power off ctrl-1 and swap the NVMe SSD

```bash
ssh pi@192.168.10.100 "sudo poweroff"
```

This cleanly stops k3s before powering down. Wait for the board to fully power off
(green activity LED stops), then:

1. **Unplug the ethernet cable from the old board** — you only have 4 switch ports, so
   the cable moves to the new board
2. Remove the NVMe SSD from the old Pi 5
3. Slot it into the new Pi 5 16GB
4. Before powering on: press the M.2 card firmly into the slot and confirm the screw is
   seated — a loose NVMe will not be detected at boot
5. **Plug the ethernet cable into the new board**

### 9. Boot new board

Connect ethernet, power on. The new board will:
- Boot from NVMe (EEPROM set in step 2)
- Use existing OS, hostname `ctrl-1`, all config intact
- Get IP `192.168.10.100` from UniFi (reservation updated in step 3)
- Start k3s automatically (it's `systemctl enable`d)

Watch for it to come up:
```bash
# From your Mac — wait ~60s then:
kubectl get node ctrl-1
# Should show Ready (may take 2-3 minutes)
```

If it doesn't come up after 3 minutes, SSH in and check:
```bash
ssh pi@192.168.10.100 "sudo journalctl -u k3s -n 50"
```

Also confirm the NVMe was detected:
```bash
ssh pi@192.168.10.100 "lsblk | grep nvme"
# Should show nvme0n1 — if blank, the SSD is not seated properly
```

**If the board doesn't boot at all** (no SSH, no IP in UniFi): plug in a monitor and
keyboard to see the boot output. Most likely cause is EEPROM boot order not set
correctly (step 3). Re-slot the SSD into the old board to restore the cluster while
you debug.

### 10. Uncordon ctrl-1

```bash
kubectl uncordon ctrl-1
```

### 11. Re-authenticate Tailscale

```bash
ssh pi@192.168.10.100 "sudo tailscale up --advertise-routes=192.168.10.0/24 --accept-dns=false"
```

This will print an auth URL. Open it in a browser and log in. Once authenticated,
off-network access (`kubectl` via Tailscale, `*.local.lab`) resumes.

Then go to the **Tailscale admin console** (https://login.tailscale.com/admin/machines) and
delete the old stale `ctrl-1` entry — the new board registers as a new device, so you'll
have two entries until you remove the old one. Also re-approve the subnet route
(`192.168.10.0/24`) on the new device entry if subnet approval is required in your tailnet.

---

## Verification

```bash
# Cluster health
kubectl get nodes
# All 4 nodes Ready, ctrl-1 shows new kernel/uptime

# ArgoCD apps green
kubectl get app -n argocd --no-headers | awk '{print $1, $2, $3}'
# All Synced Healthy

# Longhorn storage node recovered
kubectl get node -n longhorn-system
# ctrl-1 schedulable, no degraded volumes

# AdGuard Home back up (DNS for *.local.lab)
kubectl get pods -n adguard
# 1/1 Running

# Verify memory improvement
kubectl top node ctrl-1
# Should show ~16GB capacity vs ~7.5GB before

# Tailscale
tailscale status | grep ctrl-1
```

---

## If the node is ctrl-1

ctrl-1 is the k3s server, the Tailscale subnet router, and the only node AdGuard and the
kiosk can run on. Three things apply on top of the steps above.

**DNS is down for the whole swap.** AdGuard is pinned to ctrl-1 by `nodeSelector`, so
`*.local.lab` stops resolving the moment it drains — ArgoCD, Grafana, and Longhorn UIs
included. External sites still work through the UniFi fallback resolver at `1.1.1.1`.

**Tailscale needs re-authenticating.** Registration is tied to the board, so the node key
does not survive new hardware. Run `tailscale up` after boot and re-approve the
`192.168.10.0/24` subnet route in the admin console. Until then, off-network `kubectl` and
`*.local.lab` are broken. The cluster itself is unaffected — workers reach the API server
at `192.168.10.100` directly, not over Tailscale.

**The kiosk needs its X config.** `/etc/X11/xorg.conf.d/99-pi5.conf` is not in Git and is
not on the SSD if the SSD was reimaged. If the display comes back black, recreate it from
[CLAUDE.md](../../CLAUDE.md) before debugging anything else.

Swapping a worker instead skips all three.
