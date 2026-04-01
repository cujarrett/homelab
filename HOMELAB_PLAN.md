# Homelab Kubernetes Setup

Hardware: 4x Raspberry Pi 5 (1 controller, 3 workers), NVMe storage, PoE switch, 10" rack, touch display

Software: k3s, Traefik, Cert-Manager, Longhorn, Argo CD, Crossplane, Prometheus, Grafana, Alertmanager

Domain: local.lab (internal) + public WordPress site

---

<details>
<summary>Table of Contents</summary>

1. [Architecture Overview](#1-architecture-overview)
2. [Setup Sequence and Dependencies](#2-setup-sequence-and-dependencies)
3. [Initial Network Setup](#3-initial-network-setup)
4. [Hardware Setup](#4-hardware-setup)
5. [Installing k3s on the Controller Node](#5-installing-k3s-on-the-controller-node)
6. [Joining Worker Nodes](#6-joining-worker-nodes)
7. [Verifying Cluster Health](#7-verifying-cluster-health)
8. [Installing Traefik and Testing Ingress](#8-installing-traefik-and-testing-ingress)
9. [Installing Cert-Manager and Setting Up HTTPS](#9-installing-cert-manager-and-setting-up-https)
10. [Installing Longhorn for Distributed Storage](#10-installing-longhorn-for-distributed-storage)
11. [Installing Argo CD and Connecting to GitHub](#11-installing-argo-cd-and-connecting-to-github)
12. [Installing Prometheus + Grafana + Alertmanager](#12-installing-prometheus--grafana--alertmanager)
13. [Setting Up a Grafana Dashboard for the 1U Display](#13-setting-up-a-grafana-dashboard-for-the-1u-display)
14. [Installing Crossplane](#14-installing-crossplane)
15. [Creating a First XRD — WordPress Platform](#15-creating-a-first-xrd--wordpress-platform)
16. [Making WordPress Publicly Accessible (Securely)](#16-making-wordpress-publicly-accessible-securely)
17. [Security Best Practices](#17-security-best-practices)
18. [Troubleshooting](#18-troubleshooting)
19. [Post-Install Checklist](#19-post-install-checklist)
20. [What to Build Next](#20-what-to-build-next)

</details>

---

## 1. Architecture Overview

### 1.1 What We're Building

A Kubernetes cluster on four Raspberry Pi 5 devices. This setup includes:

- A **Kubernetes cluster** (k3s) with one controller and three workers.
- **Ingress routing** (Traefik) so you can reach services by name (`grafana.local.lab`).
- **Automatic HTTPS** certificates (Cert-Manager + Let's Encrypt).
- **Distributed persistent storage** (Longhorn) across NVMe drives.
- **GitOps** (Argo CD) — every change flows through Git.
- **Observability** (Prometheus, Grafana, Alertmanager) — full metrics and alerting.
- **Platform engineering** (Crossplane) — self-service infrastructure via Kubernetes APIs.
- A **public WordPress site** deployed through the platform layer securely exposed from your home lab.

### 1.2 Conceptual Diagram

```
                         ┌─────────────────────────────────────────┐
                         │           HOME NETWORK (WiFi)           │
                         │       Your laptop / phone / etc.        │
                         └──────────────┬──────────────────────────┘
                                        │
                                        │ Home Router
                                        │ (DHCP for home devices,
                                        │  port-forward 80/443
                                        │  to cluster VIP)
                                        │
                         ┌──────────────┴──────────────────────────┐
                         │                     PoE Switch          │
                         │  Provides power + network to all Pis    │
                         └───┬────────┬────────┬────────┬──────────┘
                             │        │        │        │
                        ┌────┴───┐┌───┴────┐┌──┴─────┐┌─┴───────┐
                        │ Pi 5   ││ Pi 5   ││ Pi 5   ││ Pi 5    │
                        │ ctrl-1 ││ work-1 ││ work-2 ││ work-3  │
                        │ NVMe   ││ NVMe   ││ NVMe   ││ NVMe    │
                        │ k3s    ││ k3s    ││ k3s    ││ k3s     │
                        │ server ││ agent  ││ agent  ││ agent   │
                        └────────┘└────────┘└────────┘└─────────┘

Kubernetes Layers (logical):
┌─────────────────────────────────────────────────────────────────┐
│  Platform Layer   │ Crossplane XRDs, Compositions               │
├───────────────────┼─────────────────────────────────────────────┤
│  GitOps Layer     │ Argo CD watches GitHub, auto-deploys        │
├───────────────────┼─────────────────────────────────────────────┤
│  Observability    │ Prometheus, Grafana, Alertmanager           │
├───────────────────┼─────────────────────────────────────────────┤
│  Ingress + TLS    │ Traefik + Cert-Manager (Let's Encrypt)      │
├───────────────────┼─────────────────────────────────────────────┤
│  Storage Layer    │ Longhorn (replicated across NVMe drives)    │
├───────────────────┼─────────────────────────────────────────────┤
│  Cluster Layer    │ k3s (lightweight Kubernetes)                │
├───────────────────┼─────────────────────────────────────────────┤
│  Hardware Layer   │ 4× Raspberry Pi 5 + NVMe + PoE + Switch     │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 Key Kubernetes Concepts (Quick Reference)

If you have never used Kubernetes before, here are the concepts you will encounter throughout this guide:

| Concept | What it is |
|---|---|
| **Node** | A physical or virtual machine in the cluster (your Pis) |
| **Pod** | The smallest deployable unit — one or more containers running together |
| **Deployment** | Declares "I want N replicas of this Pod running" |
| **Service** | A stable network endpoint that routes traffic to Pods |
| **Ingress** | Rules that route external HTTP/HTTPS traffic to Services |
| **Namespace** | A logical partition inside the cluster (like folders) |
| **PersistentVolume (PV)** | A piece of storage in the cluster |
| **PersistentVolumeClaim (PVC)** | A request for storage by a Pod |
| **Helm Chart** | A package of Kubernetes manifests (like `apt` for K8s) |
| **CRD (Custom Resource Definition)** | Extending Kubernetes with new resource types |

---

## 2. Setup Sequence and Dependencies

### 2.1 Required Order (Strict)

These steps have hard dependencies — each one blocks the next. Do them in this order.

```
Step 1 ── Router IP reservation
           └─ Must happen BEFORE powering on any Pi.
              If DHCP assigns random IPs first, you'll have to SSH in
              just to set the static IP you wanted from the start.

Step 2 ── PoE switch assembled and uplinked to router
           └─ Physical power + network for every Pi. Nothing works without it.

Step 3 ── Flash OS → assemble Pi hardware → first boot
           └─ Each Pi must be reachable over SSH before anything else can happen.

Step 4 ── Static IPs + hostnames + OS prereqs on ALL 4 nodes
           └─ k3s will fail or become unreachable if node IPs change after install.
              All prereqs (open-iscsi, kernel modules, cgroups) must be in place
              before k3s is installed.

Step 5 ── k3s installed on ctrl-1 (controller)
           └─ Produces the node token and API server address that workers need.

Step 6 ── k3s agents joined on work-1, work-2, work-3
           └─ Requires the token from Step 5 and a reachable API server.

Step 7 ── Traefik (ingress controller)
           └─ Must exist before any service is reachable by hostname.

Step 8 ── Cert-Manager
           └─ Must exist before any HTTPS Ingress resources work.

Step 9 ── Longhorn (distributed storage)
           └─ Must exist before any workload that needs a PersistentVolumeClaim (PVC).
              Argo CD, Prometheus, Grafana, and WordPress all need PVCs.
```

### 2.2 Flexible / Choose Your Own Adventure (After Step 9)

Once the cluster has ingress, TLS, and storage, the remaining sections are independent. Install them in any order, or skip what you don't need yet.

| Section | Hard dependency | Can you skip it? |
|---|---|---|
| **Argo CD** (§11) | Cluster + Traefik + Cert-Manager + Longhorn | Yes — you can apply manifests manually. Only needed for GitOps. |
| **Prometheus + Grafana + Alertmanager** (§12) | Cluster + Traefik + Longhorn | Yes — observability is useful but not required for apps to run. |
| **Grafana dashboard on 1U display** (§13) | Grafana running | Yes — cosmetic. |
| **Crossplane** (§14) | Cluster | Yes — only needed for the platform-engineering / self-service layer. |
| **WordPress XRD** (§15) | Crossplane | Yes — depends on Crossplane. |
| **Public WordPress** (§16) | WordPress deployed + Cert-Manager (Let's Encrypt) + port-forward on router | Yes — optional public exposure. |

> **Recommended path if you're new:** Complete steps 1–9 first and verify a healthy cluster before continuing. Once `kubectl get nodes` shows all four nodes `Ready` and a test app is reachable via HTTPS at `*.local.lab`, the hard part is done.

---

## 3. Initial Network Setup

### 2.1 Router Configuration

**Before touching the Raspberry Pis**, configure your home router to reserve IP addresses and set up networking.

#### Step 1: Access Your Router
1. Find your router's IP address:
   ```bash
   ip route | grep default
   # Usually shows: default via 192.168.1.1
   ```
2. Open browser and go to your router's IP (usually `192.168.1.1` or `192.168.0.1`)
3. Log in with admin credentials (often printed on router label)

#### Step 2: Reserve IP Range for Kubernetes Nodes
1. Navigate to **DHCP Settings** or **LAN Settings**
2. Find the **DHCP Range** setting
3. Change it to exclude `192.168.1.100-110`:
   - **Before:** `192.168.1.2` to `192.168.1.254`
   - **After:** `192.168.1.2` to `192.168.1.99`
4. Save settings

#### Step 3: Note Your Network Details
Write down these values (you'll need them later):
- **Router IP:** `192.168.1.1` (your gateway)
- **DNS Server:** Usually same as router IP
- **Network:** `192.168.1.0/24` (adjust if different)

### 2.2 Pi-hole DNS Setup

Set up Pi-hole **before** configuring the Kubernetes nodes so DNS resolution works from day one.

#### Router Hosts File (Simpler)
Add entries to your router's custom DNS/hosts:
```
192.168.1.100  grafana.local.lab
192.168.1.100  traefik.local.lab
192.168.1.100  argocd.local.lab
192.168.1.100  longhorn.local.lab
192.168.1.100  wordpress.local.lab
```

### 2.3 Planned IP Addresses

| Device | Hostname | IP Address | Role |
|---|---|---|---|
| Raspberry Pi 5 #1 | `ctrl-1` | `192.168.1.100` | k3s server (controller) |
| Raspberry Pi 5 #2 | `work-1` | `192.168.1.101` | k3s agent (worker) |
| Raspberry Pi 5 #3 | `work-2` | `192.168.1.102` | k3s agent (worker) |
| Raspberry Pi 5 #4 | `work-3` | `192.168.1.103` | k3s agent (worker) |

---

## 3. Hardware Setup (After Network Configuration)

Now that your router is configured and IPs are reserved, set up the physical hardware and configure static networking.

### 3.1 Parts Checklist

- [ ] 4× Raspberry Pi 5 Model B (4 GB or 8 GB RAM)
- [ ] 4× M.2 2230 NVMe drives (256GB each - sufficient for OS + Longhorn storage)
- [ ] 4× Combined PoE+NVMe HAT for Pi 5 (your purchased HAT with both functions)
- [ ] 1× PoE switch (at least 5 ports, 1 for uplink to router)
- [ ] 4× Ethernet cables
- [ ] 1× 10″ rack
- [ ] 1× 1U touch display
- [ ] 1× USB-to-M.2 adapter (for flashing NVMe drives) **OR** alternative setup method below

### 3.2 Assemble the Hardware

1. **Attach your combined PoE+NVMe HAT** to each Pi 5 according to the manufacturer's instructions. Insert the M.2 2230 NVMe drive into the M.2 slot.
2. **Mount each Pi** in the 10″ rack.
3. **Connect Ethernet** from each Pi to the PoE switch.
4. **Connect the PoE switch** uplink port to your home router.
5. **Mount the 1U touch display** in the rack.

### 3.3 Flash USB Drive and Setup First Pi

We'll set up each Pi sequentially using your 31GB USB 3.0 drive (/dev/disk4).

**Your USB Drive:** USB DISK 3.0, 31GB, USB 3.0 - perfect for this setup!

#### Step 1: Download Raspberry Pi Imager

Download from: https://www.raspberrypi.com/software/

#### Step 2: Flash USB Drive for First Pi (ctrl-1)

1. **Open Raspberry Pi Imager** on your MacBook
2. **Choose Device** → **Raspberry Pi 5**
3. **Choose OS** → **Raspberry Pi OS other** → **Raspberry Pi OS Lite (64-bit)**
4. **Choose Storage** → Select **USB DISK 3.0 (31 GB)** (/dev/disk4)
5. **Click Next**, then **Edit Settings** (⚙ icon):

**General tab:**
| Setting | Value |
|---|---|
| Enable SSH | ✅ Yes |
| Set username and password | ✅ Username: `pi`, Password: [your choice] |
| Set hostname | `ctrl-1` |
| Configure wireless LAN | ❌ Skip (using Ethernet) |
| Set locale | ✅ Set timezone |

**Services tab:**
| Setting | Value |
|---|---|
| Enable SSH | ✅ Use password authentication |

6. **Click Save**, then **Yes** to apply settings
7. **Click Yes** to continue (will erase USB drive)
8. **Wait for flashing** to complete (~5-10 minutes)

#### Step 3: Boot First Pi (ctrl-1) from USB

1. **Physical connections:**
   - Connect USB drive to **blue USB 3.0 port** on Pi 5
   - Connect Ethernet cable from Pi to PoE switch
   - Connect PoE switch uplink to your router
   - Install NVMe drive in M.2 slot (can do while Pi is running)

2. **Power on:**
   - Turn on PoE switch (powers Pi via Ethernet)
   - Wait 2-3 minutes for first USB boot

3. **Find Pi's IP address:**
   ```bash
   # From your MacBook, scan for the Pi
   nmap -sn 192.168.1.0/24 | grep -B 2 "Raspberry"
   # Or check your router's admin panel for new device
   ```

4. **SSH into Pi:**
   ```bash
   ssh pi@<PI_IP_ADDRESS>
   # Example: ssh pi@192.168.1.50
   ```

#### Step 4: Clone USB to NVMe

Once SSH'd into the Pi:

```bash
# Check available drives
lsblk
# You should see:
# sda = USB drive (boot drive)
# nvme0n1 = NVMe M.2 drive

# Clone USB drive to NVMe (takes ~15-20 minutes)
sudo dd if=/dev/sda of=/dev/nvme0n1 bs=4M status=progress

# Expand NVMe partition to use full 256GB
sudo raspi-config --expand-rootfs

# Change boot order to NVMe first
sudo raspi-config
# Navigate: Boot Options → Boot Order → USB/Network Boot → NVMe/USB Boot

# Shutdown and remove USB drive
sudo shutdown -h now
```

#### Step 5: Test NVMe Boot and Set Static IP

1. **Remove USB drive** from Pi
2. **Power on Pi** - should now boot from NVMe (faster!)
3. **SSH back in** and configure static IP:

```bash
# Set static IP for ctrl-1
sudo nmcli con mod "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.100/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "192.168.1.1"

# Restart networking
sudo nmcli con down "Wired connection 1"
sudo nmcli con up "Wired connection 1"

# Test - should now be accessible at static IP
```

#### Step 6: Repeat for Remaining Pis

1. **Reflash USB drive** with Pi Imager:
   - Change hostname to `work-1` (then `work-2`, `work-3`)
   - Same SSH settings
2. **Move USB to next Pi** and repeat Steps 3-5
3. **Set static IPs:** 192.168.1.101, 192.168.1.102, 192.168.1.103

#### Method B: Single microSD + Sequential Setup

If you have one microSD card (32GB+):

1. **Flash microSD** with Raspberry Pi OS Lite 64-bit
2. **Setup first Pi (ctrl-1):**
   - Boot from microSD, configure network/SSH
   - Install NVMe drive, clone microSD to NVMe
   - Switch boot order to NVMe, shutdown
3. **Repeat for other Pis** using same microSD
4. **Final step:** Configure unique hostnames and IPs on each Pi

#### Method C: Direct NVMe (If you get USB-to-M.2 adapter)

Standard method if you can get a USB-to-M.2 adapter ($15-25):

1. Connect NVMe to computer via adapter
2. Flash directly with Pi Imager
3. Install flashed NVMe drives in Pis

> **Why enable SSH?** These are headless servers (no monitor/keyboard). SSH is how you will manage them.

### 3.4 First Boot and Network Configuration

Steps depend on your setup method:

**If using Method A (USB Boot + Clone):**
1. **First boot:** Boot from USB drives, SSH in, clone to NVMe
2. **Second boot:** Boot from NVMe drives
3. **Configure networking:** Set static IPs as shown below

**If using Method B (microSD Sequential):**
1. Set up each Pi one at a time using the microSD
2. After cloning to NVMe and switching boot order, configure networking

**If using Method C (Direct NVMe Flash):**
1. Install pre-flashed NVMe drives
2. Boot directly from NVMe
3. Configure networking

#### Find Your Pis on the Network

```bash
# Scan for Raspberry Pis on your network
nmap -sn 192.168.1.0/24 | grep -B 2 "Raspberry"
```

#### SSH and Configure Static IPs

#### 3.4.1 Set Static IP on Each Node

Edit the network configuration. On Raspberry Pi OS (Bookworm and later), networking is managed by **NetworkManager**:

```bash
# Show current connections
sudo nmcli con show

# Set static IP (replace values for each node)
# For ctrl-1:
sudo nmcli con mod "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.100/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "192.168.1.1"

# Restart networking
sudo nmcli con down "Wired connection 1"
sudo nmcli con up "Wired connection 1"
```

Repeat for each node with its respective IP (101, 102, 103).

> **Why static IPs?** If a Pi's IP changes after a DHCP lease renewal, Kubernetes will lose contact with that node. Static IPs ensure the cluster stays healthy across reboots.

After setting static IPs, reconnect via the new IPs:

```bash
ssh pi@192.168.1.100   # ctrl-1
ssh pi@192.168.1.101   # work-1
ssh pi@192.168.1.102   # work-2
ssh pi@192.168.1.103   # work-3
```

### 3.5 Set Hostnames

On each Pi, set the hostname to match your plan:

```bash
# On ctrl-1:
sudo hostnamectl set-hostname ctrl-1

# On work-1:
sudo hostnamectl set-hostname work-1

# (Repeat for work-2, work-3)
```

### 3.6 Update the OS and Install Prerequisites

Run this on **every** node:

```bash
sudo apt update && sudo apt upgrade -y

# Install packages needed by k3s and Longhorn
sudo apt install -y \
  curl \
  open-iscsi \
  nfs-common \
  jq \
  util-linux

# Enable and start iscsid (required by Longhorn)
sudo systemctl enable iscsid
sudo systemctl start iscsid
```

> **Why `open-iscsi`?** Longhorn uses iSCSI to attach distributed block storage to Pods. Without it, Longhorn volumes won't mount.

### 3.7 Prepare Longhorn Storage Directory

Since we're booting from NVMe, create a dedicated directory for Longhorn storage. On **every** node:

```bash
# Create Longhorn storage directory
sudo mkdir -p /var/lib/longhorn

# Set proper ownership (longhorn will run as root)
sudo chown root:root /var/lib/longhorn

# Verify we have space available
df -h /
```

> **Storage Location:** Longhorn will use `/var/lib/longhorn` on each node's NVMe drive. Since the entire OS is on NVMe, you get maximum performance for both system and storage operations.

### 3.8 Configure Kernel Modules and Settings

k3s and its components need certain kernel modules. On **every** node:

```bash
# Enable required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k3s.conf
br_netfilter
overlay
iscsi_tcp
EOF

sudo modprobe br_netfilter
sudo modprobe overlay
sudo modprobe iscsi_tcp

# Enable IP forwarding (required for Pod networking)
cat <<EOF | sudo tee /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
```

> **Why these settings?** `br_netfilter` allows iptables to see bridged traffic (Pod-to-Pod communication). `ip_forward` lets your nodes route traffic between Pods on different nodes.

### 3.9 Enable cgroups (Memory and CPU limits)

Raspberry Pi OS may not enable cgroups by default. Kubernetes uses cgroups to enforce resource limits on containers.

```bash
# Check current cmdline
cat /boot/firmware/cmdline.txt
```

If `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory` is NOT present, add it:

```bash
# Append cgroup settings (keep everything on ONE line)
sudo sed -i 's/$/ cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt

# Verify
cat /boot/firmware/cmdline.txt
```

**Reboot all nodes:**

```bash
sudo reboot
```

> **Why cgroups?** Without cgroups, Kubernetes cannot enforce resource requests and limits. Pods could consume all memory on a node and crash everything.

### 3.9 Verify Network Connectivity

Before installing k3s, test that all networking is working properly:

**Test 1: Static IPs and SSH connectivity**
```bash
# From your laptop, test SSH to all nodes
ssh pi@192.168.1.100  # ctrl-1
ssh pi@192.168.1.101  # work-1
ssh pi@192.168.1.102  # work-2
ssh pi@192.168.1.103  # work-3
```

**Test 2: DNS Resolution**
```bash
# From any Pi, test DNS resolution
nslookup google.com
nslookup grafana.local.lab  # Should resolve to 192.168.1.100
```

**Test 3: Node-to-Node Connectivity**
```bash
# From ctrl-1, ping all worker nodes
ping -c 2 192.168.1.101
ping -c 2 192.168.1.102
ping -c 2 192.168.1.103
```

**Test 4: Internet Connectivity**
```bash
# Test outbound internet (needed for k3s installation)
curl -I https://k3s.io
```

### 3.10 Hardware Preparation Checklist

- [ ] All 4 Pis assembled with NVMe + PoE HATs
- [ ] All 4 NVMe drives flashed with Raspberry Pi OS Lite 64-bit and installed
- [ ] SSH enabled on all nodes
- [ ] Static IPs configured (100, 101, 102, 103)
- [ ] Hostnames set (ctrl-1, work-1, work-2, work-3)
- [ ] OS updated on all nodes
- [ ] `open-iscsi`, `nfs-common`, and prerequisites installed
- [ ] Longhorn storage directory created at `/var/lib/longhorn`
- [ ] Kernel modules loaded (`br_netfilter`, `overlay`, `iscsi_tcp`)
- [ ] IP forwarding enabled
- [ ] cgroups enabled in boot config
- [ ] All nodes rebooted

---

## 4. Installing k3s on the Controller Node

### 4.1 What is k3s?

**k3s** is a lightweight, CNCF-certified Kubernetes distribution built by Rancher (now SUSE). It packages the Kubernetes control plane (API server, scheduler, controller-manager, etcd) into a single binary. It is fully compatible with standard Kubernetes — `kubectl`, Helm, and all standard Kubernetes resources work identically.

### 4.2 Install k3s Server

SSH into your controller node:

```bash
ssh pi@192.168.1.100
```

Install k3s:

```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode 644 \
  --disable servicelb \
  --disable local-storage \
  --tls-san 192.168.1.100 \
  --tls-san ctrl-1.local.lab \
  --node-name ctrl-1
```

**What each flag does:**

| Flag | Purpose |
|---|---|
| `--write-kubeconfig-mode 644` | Makes the kubeconfig file readable without `sudo` |
| `--disable servicelb` | Disables the built-in ServiceLB (we'll use Traefik's approach or MetalLB) |
| `--disable local-storage` | Disables the default local-path provisioner (we'll use Longhorn instead) |
| `--tls-san 192.168.1.100` | Adds the IP as a valid Subject Alternative Name on the API server's TLS certificate |
| `--tls-san ctrl-1.local.lab` | Also allows connecting via hostname |
| `--node-name ctrl-1` | Sets a human-readable node name |

> **Why disable `servicelb` and `local-storage`?** We want to use Longhorn for storage (better: replicated, distributed) and manage load balancing ourselves. Disabling the built-in components avoids conflicts.

### 4.3 Verify k3s Is Running

```bash
# Check the service
sudo systemctl status k3s

# Verify with kubectl (k3s installs it automatically)
sudo kubectl get nodes
```

Expected output:

```
NAME     STATUS   ROLES                  AGE   VERSION
ctrl-1   Ready    control-plane,master   30s   v1.xx.x+k3s1
```

### 4.4 Get the Node Token

Worker nodes need a **token** to authenticate and join the cluster. This token is stored on the controller:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

**Save this token** — you will need it in the next section.

> **Why a token?** This is a security measure. Without the correct token, a rogue device on your network cannot join the cluster.

### 4.5 Copy kubeconfig to Your Laptop

You will want to manage the cluster from your laptop, not by SSH-ing into the controller every time.

On your **laptop** (macOS):

```bash
# Create the .kube directory if it doesn't exist
mkdir -p ~/.kube

# Copy the kubeconfig from the controller
scp pi@192.168.1.100:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Edit the kubeconfig — change the server address from 127.0.0.1 to the controller's IP
sed -i '' 's/127.0.0.1/192.168.1.100/g' ~/.kube/config

# Restrict permissions (security best practice)
chmod 600 ~/.kube/config
```

Install `kubectl` on your laptop if you haven't:

```bash
# macOS with Homebrew
brew install kubectl

# Verify connection
kubectl get nodes
```

You should see `ctrl-1` in the `Ready` state.

### 4.6 Install Helm (on your laptop)

Helm is the package manager for Kubernetes. Most tools in this guide are installed via Helm charts.

```bash
brew install helm

# Verify
helm version
```

---

## 5. Joining Worker Nodes

### 5.1 Why Worker Nodes?

The controller runs the Kubernetes "brain" (API server, scheduler, etc.). Worker nodes run your actual applications. Spreading workloads across 3 workers gives you:

- **Capacity** — more CPU and memory for your apps.
- **Resilience** — if one worker fails, Kubernetes reschedules Pods to the others.
- **Realistic practice** — production clusters always have multiple workers.

### 5.2 Install k3s Agent on Each Worker

SSH into each worker node and run the following command. Replace `<NODE_TOKEN>` with the token from Section 4.4.

**On work-1 (`192.168.1.101`):**

```bash
ssh pi@192.168.1.101

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.100:6443 \
  K3S_TOKEN=<NODE_TOKEN> \
  sh -s - agent \
  --node-name work-1
```

**On work-2 (`192.168.1.102`):**

```bash
ssh pi@192.168.1.102

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.100:6443 \
  K3S_TOKEN=<NODE_TOKEN> \
  sh -s - agent \
  --node-name work-2
```

**On work-3 (`192.168.1.103`):**

```bash
ssh pi@192.168.1.103

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.100:6443 \
  K3S_TOKEN=<NODE_TOKEN> \
  sh -s - agent \
  --node-name work-3
```

**What each environment variable does:**

| Variable/Flag | Purpose |
|---|---|
| `K3S_URL` | Tells the agent where to find the k3s API server |
| `K3S_TOKEN` | Authenticates this node to the cluster |
| `--node-name` | Sets a human-readable name |

### 5.3 Verify All Workers Joined

From your **laptop**:

```bash
kubectl get nodes -o wide
```

Expected output:

```
NAME     STATUS   ROLES                  AGE   VERSION        INTERNAL-IP     OS-IMAGE                        KERNEL-VERSION   CONTAINER-RUNTIME
ctrl-1   Ready    control-plane,master   10m   v1.xx.x+k3s1  192.168.1.100   Debian GNU/Linux 12 (bookworm)  6.x.x-v8+       containerd://x.x.x
work-1   Ready    <none>                 2m    v1.xx.x+k3s1  192.168.1.101   Debian GNU/Linux 12 (bookworm)  6.x.x-v8+       containerd://x.x.x
work-2   Ready    <none>                 1m    v1.xx.x+k3s1  192.168.1.102   Debian GNU/Linux 12 (bookworm)  6.x.x-v8+       containerd://x.x.x
work-3   Ready    <none>                 30s   v1.xx.x+k3s1  192.168.1.103   Debian GNU/Linux 12 (bookworm)  6.x.x-v8+       containerd://x.x.x
```

All four nodes should show **`Ready`**.

### 5.4 Label Worker Nodes

Labels help Kubernetes schedule workloads. Mark the workers with a `node-role` label:

```bash
kubectl label node work-1 node-role.kubernetes.io/worker=worker
kubectl label node work-2 node-role.kubernetes.io/worker=worker
kubectl label node work-3 node-role.kubernetes.io/worker=worker
```

Now `kubectl get nodes` will show `worker` in the ROLES column for each worker.

---

## 6. Verifying Cluster Health

### 6.1 Why Verify?

Before installing anything else, confirm the foundation is solid. A misconfigured cluster will cause cascading failures in every layer above it.

### 6.2 Check System Pods

k3s runs essential services (CoreDNS, metrics-server, Traefik) as Pods in the `kube-system` namespace:

```bash
kubectl get pods -n kube-system
```

All pods should be `Running` or `Completed`. If any are in `CrashLoopBackOff` or `Pending`, troubleshoot before proceeding (see [Section 17: Troubleshooting](#17-troubleshooting)).

### 6.3 Test Pod Scheduling Across Nodes

Deploy a test workload to verify Pods can schedule on workers:

```bash
kubectl create deployment nginx-test --image=nginx --replicas=3

# Wait a moment, then check
kubectl get pods -o wide
```

You should see 3 nginx pods spread across your worker nodes. The `-o wide` flag shows which node each Pod is running on.

### 6.4 Test DNS Resolution Inside the Cluster

Kubernetes has an internal DNS service (CoreDNS). Every Service gets a DNS name. Let's verify it works:

```bash
kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
```

Expected output should show an IP in the `10.43.x.x` range (the Service CIDR).

### 6.5 Test Pod-to-Pod Communication

```bash
# Create a simple service
kubectl expose deployment nginx-test --port=80

# Test from inside the cluster
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://nginx-test.default.svc.cluster.local
```

You should see the default nginx welcome page HTML.

### 6.6 Clean Up Test Resources

```bash
kubectl delete deployment nginx-test
kubectl delete service nginx-test
```

### 6.7 Cluster Health Checklist

- [ ] All 4 nodes show `Ready`
- [ ] All `kube-system` pods are `Running`
- [ ] Pods schedule across all worker nodes
- [ ] CoreDNS resolves internal names
- [ ] Pod-to-Pod communication works
- [ ] Test resources cleaned up

---

## 7. Installing Traefik and Testing Ingress

### 7.1 What Is Ingress?

**Ingress** is how external HTTP/HTTPS traffic reaches your applications inside Kubernetes. Without Ingress, your apps are only accessible inside the cluster's virtual network.

An **Ingress Controller** is the component that actually handles the traffic routing. Think of it as a smart reverse proxy that reads Kubernetes Ingress resources and configures itself automatically.

### 7.2 Why Traefik?

k3s ships with Traefik by default. Traefik:
- Auto-discovers Kubernetes Ingress resources
- Supports automatic HTTPS via Let's Encrypt
- Has an excellent dashboard
- Is lightweight and fast
- Is the default in k3s (so it's well-tested with this setup)

> **Note:** k3s installed Traefik automatically as part of the server installation. However, since we disabled `servicelb`, we need to configure Traefik to bind directly to host ports or use a specific approach for LoadBalancer services.

### 7.3 Configure Traefik with a NodePort / HostPort Approach

Since we don't have a cloud load balancer, we'll configure Traefik to use `hostPort` so it listens directly on ports 80 and 443 on every node.

Create a Traefik HelmChartConfig to customize the built-in Traefik:

```bash
# SSH into the controller or apply via kubectl from your laptop
cat <<EOF | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        hostPort: 80
      websecure:
        hostPort: 443
    service:
      type: ClusterIP
    deployment:
      kind: DaemonSet
    tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
EOF
```

**What this does:**

| Setting | Purpose |
|---|---|
| `hostPort: 80/443` | Traefik listens directly on ports 80 and 443 on each node |
| `type: ClusterIP` | We don't need an external LoadBalancer service |
| `kind: DaemonSet` | Runs Traefik on every node (so any node can receive traffic) |
| `tolerations` | Allows Traefik to also run on the controller node |

Wait for Traefik to restart:

```bash
kubectl rollout status daemonset traefik -n kube-system
```

### 7.4 Test Ingress with a Simple App

Deploy a test application:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: default
spec:
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: whoami
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - host: whoami.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: whoami
                port:
                  number: 80
EOF
```

**What we just created:**
1. **Deployment** — 2 replicas of a simple "whoami" web server that shows request info.
2. **Service** — A stable ClusterIP that load-balances across the 2 Pods.
3. **Ingress** — Tells Traefik: "When someone requests `whoami.local.lab`, send traffic to the `whoami` Service."

### 7.5 Test From Your Laptop

Add the DNS entry if you haven't already:

```bash
# On macOS — edit /etc/hosts
sudo sh -c 'echo "192.168.1.100  whoami.local.lab" >> /etc/hosts'
```

Test:

```bash
curl http://whoami.local.lab
```

You should see output like:

```
Hostname: whoami-xxxxx-xxxxx
IP: 127.0.0.1
IP: 10.42.x.x
RemoteAddr: 10.42.x.x:xxxxx
GET / HTTP/1.1
Host: whoami.local.lab
...
```

### 7.6 Clean Up (Optional)

You can keep the whoami app for testing or remove it:

```bash
kubectl delete ingress whoami
kubectl delete service whoami
kubectl delete deployment whoami
```

### 7.7 Enable the Traefik Dashboard (Optional)

The Traefik dashboard shows all routes, middlewares, and services:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: traefik-dashboard
  namespace: kube-system
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - host: traefik.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api@internal
                port:
                  number: 80
EOF
```

> **Note:** You may need to configure the Traefik dashboard via HelmChartConfig instead of a plain Ingress. Check the Traefik documentation for the exact settings for your version.

### 7.8 Ingress Checklist

- [ ] Traefik DaemonSet running on all nodes
- [ ] Ports 80 and 443 accessible from your laptop
- [ ] Test app deploys and responds via `whoami.local.lab`
- [ ] (Optional) Traefik dashboard accessible

---

## 8. Installing Cert-Manager and Setting Up HTTPS

### 8.1 What Is Cert-Manager?

**Cert-Manager** automates the creation, renewal, and management of TLS certificates in Kubernetes. It can request certificates from **Let's Encrypt** (free, trusted by all browsers) and automatically renew them before they expire.

### 8.2 Why HTTPS?

- **Encryption** — Traffic between your browser and the cluster is encrypted.
- **Trust** — Browsers show a green lock instead of security warnings.
- **Realistic** — Every production platform uses HTTPS. Learning it now means your skills transfer directly.
- **Required for public WordPress** — Let's Encrypt gives you real, browser-trusted certificates for free.

### 8.3 Install Cert-Manager

```bash
# Add the Jetstack Helm repo
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install Cert-Manager with CRDs
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set prometheus.enabled=true
```

> **Why `crds.enabled=true`?** Cert-Manager extends Kubernetes with custom resources (`Certificate`, `Issuer`, `ClusterIssuer`). The CRDs (Custom Resource Definitions) must be installed for these to work.

Verify installation:

```bash
kubectl get pods -n cert-manager
```

All 3 pods should be `Running`:
- `cert-manager`
- `cert-manager-cainjector`
- `cert-manager-webhook`

### 8.4 Create a Staging ClusterIssuer (For Testing)

Let's Encrypt has strict rate limits on production certificates. Always test with their **staging** environment first:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            class: traefik
EOF
```

> **Replace `your-email@example.com`** with your actual email. Let's Encrypt uses this to send expiration warnings.

### 8.5 Create a Production ClusterIssuer

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: traefik
EOF
```

### 8.6 Create a Self-Signed ClusterIssuer (For `local.lab`)

Let's Encrypt cannot issue certificates for private domains like `local.lab` (it requires DNS validation for public domains). For internal services, we'll use a **self-signed CA**:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-lab-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: local-lab-ca
  secretName: local-lab-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-lab-ca-issuer
spec:
  ca:
    secretName: local-lab-ca-secret
EOF
```

**What this creates:**
1. A self-signed issuer to bootstrap the process.
2. A CA (Certificate Authority) certificate for `local.lab`.
3. A CA-based issuer that can sign certificates for any `*.local.lab` domain.

> **To avoid browser warnings:** Export the CA certificate and install it in your macOS Keychain as a trusted root. Your browser will then trust all `*.local.lab` certificates:

```bash
# Extract the CA certificate
kubectl get secret local-lab-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > local-lab-ca.crt

# Trust it on macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain local-lab-ca.crt
```

### 8.7 Test HTTPS with the Whoami App

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami-tls
spec:
  replicas: 2
  selector:
    matchLabels:
      app: whoami-tls
  template:
    metadata:
      labels:
        app: whoami-tls
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami-tls
spec:
  ports:
    - port: 80
  selector:
    app: whoami-tls
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami-tls
  annotations:
    cert-manager.io/cluster-issuer: local-lab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - whoami.local.lab
      secretName: whoami-tls-cert
  rules:
    - host: whoami.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: whoami-tls
                port:
                  number: 80
EOF
```

Test:

```bash
# If you trusted the CA cert earlier, this should work without -k
curl https://whoami.local.lab

# If you haven't trusted the CA, use -k to skip certificate verification
curl -k https://whoami.local.lab
```

Clean up:

```bash
kubectl delete ingress whoami-tls
kubectl delete service whoami-tls
kubectl delete deployment whoami-tls
```

### 8.8 Cert-Manager Checklist

- [ ] Cert-Manager pods running in `cert-manager` namespace
- [ ] `letsencrypt-staging` ClusterIssuer created
- [ ] `letsencrypt-prod` ClusterIssuer created
- [ ] `local-lab-ca-issuer` ClusterIssuer created
- [ ] CA certificate trusted on your laptop (optional but recommended)
- [ ] HTTPS test app works

---

## 9. Installing Longhorn for Distributed Storage

### 9.1 What Is Longhorn?

**Longhorn** is a lightweight, distributed block storage system for Kubernetes. It:

- Replicates data across multiple nodes (so if one Pi dies, your data survives)
- Provides **PersistentVolumes** that Pods can use for databases, file storage, etc.
- Has a web UI for managing volumes, backups, and replicas
- Is a CNCF Sandbox project

### 9.2 Why Distributed Storage?

Without Longhorn, if a Pod's data lives on one node's disk and that node fails, **the data is gone**. Longhorn replicates data across your NVMe drives so that Kubernetes can reschedule the Pod to a different node and the data follows it.

### 9.3 Pre-Flight Check

Longhorn provides a pre-flight script to verify your nodes are ready:

```bash
# Run from your laptop
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/prerequisite/longhorn-iscsi-installation.yaml
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/prerequisite/longhorn-nfs-installation.yaml

# Check environment
curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/master/scripts/environment_check.sh | bash
```

All checks should pass (we installed the prerequisites in Section 3.6).

### 9.4 Install Longhorn

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath="/mnt/nvme" \
  --set defaultSettings.defaultReplicaCount=3 \
  --set defaultSettings.storageMinimalAvailablePercentage=15
```

**What each setting does:**

| Setting | Purpose |
|---|---|
| `defaultDataPath="/mnt/nvme"` | Tells Longhorn to store data on the NVMe drives we mounted |
| `defaultReplicaCount=3` | Each volume is replicated to 3 nodes (all workers) |
| `storageMinimalAvailablePercentage=15` | Prevents Longhorn from filling the disk beyond 85% |

Wait for Longhorn to be ready:

```bash
kubectl rollout status deployment longhorn-driver-deployer -n longhorn-system
kubectl get pods -n longhorn-system
```

All pods should be `Running`. This may take 2–3 minutes.

### 9.5 Make Longhorn the Default StorageClass

```bash
# Check current storage classes
kubectl get storageclass

# Longhorn should already be default. If not:
kubectl patch storageclass longhorn -p \
  '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

> **Why a default StorageClass?** When a Pod requests persistent storage (PVC) without specifying a StorageClass, Kubernetes uses the default. Setting Longhorn as default means all PVCs automatically use replicated NVMe storage.

### 9.6 Expose the Longhorn UI

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
  namespace: longhorn-system
  annotations:
    cert-manager.io/cluster-issuer: local-lab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - longhorn.local.lab
      secretName: longhorn-tls-cert
  rules:
    - host: longhorn.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: longhorn-frontend
                port:
                  number: 80
EOF
```

Add `longhorn.local.lab` to your `/etc/hosts` if not already done, then visit: `https://longhorn.local.lab`

### 9.7 Test Persistent Storage

Create a test PVC and Pod:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-storage
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh", "-c", "echo 'Longhorn works!' > /data/test.txt && cat /data/test.txt && sleep 3600"]
      volumeMounts:
        - mountPath: /data
          name: test-vol
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-pvc
EOF
```

Verify:

```bash
# Check the PVC is Bound
kubectl get pvc test-pvc

# Check the Pod logs
kubectl logs test-storage
# Should output: Longhorn works!

# In the Longhorn UI, you should see a new volume with 3 replicas
```

Clean up:

```bash
kubectl delete pod test-storage
kubectl delete pvc test-pvc
```

### 9.8 Longhorn Checklist

- [ ] Longhorn pods running in `longhorn-system`
- [ ] Longhorn is the default StorageClass
- [ ] Data path set to `/mnt/nvme`
- [ ] Replica count set to 3
- [ ] Longhorn UI accessible at `https://longhorn.local.lab`
- [ ] Test PVC created and bound
- [ ] Test Pod reads/writes data successfully
- [ ] Test resources cleaned up

---

## 10. Installing Argo CD and Connecting to GitHub

### 10.1 What Is Argo CD?

**Argo CD** is a GitOps continuous delivery tool for Kubernetes. It watches a Git repository and automatically synchronizes the desired state (Kubernetes manifests in Git) with the actual state (what's running in the cluster).

### 10.2 Why GitOps?

| Approach | What happens |
|---|---|
| **Without GitOps** | You run `kubectl apply` manually. No history, no rollback, no review. |
| **With GitOps** | You commit YAML to Git. Argo CD detects the change and applies it. Full history, code review via PRs, and instant rollback by reverting a commit. |

### 10.3 Create a GitOps Repository

On GitHub, create a new repository for your cluster manifests:

1. Go to https://github.com/new
2. Repository name: `homelab-gitops` (or whatever you prefer)
3. Make it **private**
4. Initialize with a README
5. Clone it to your laptop:

```bash
git clone git@github.com:<YOUR_USERNAME>/homelab-gitops.git
cd homelab-gitops
```

Create a basic directory structure:

```bash
mkdir -p apps/{argocd,traefik,longhorn,cert-manager,monitoring,wordpress,crossplane}
mkdir -p platform/{xrds,compositions,claims}
```

```
homelab-gitops/
├── apps/
│   ├── argocd/          # Argo CD's own config (manages itself)
│   ├── traefik/         # Traefik customizations
│   ├── longhorn/        # Longhorn configs
│   ├── cert-manager/    # Certs and issuers
│   ├── monitoring/      # Prometheus + Grafana
│   ├── wordpress/       # WordPress deployment
│   └── crossplane/      # Crossplane setup
└── platform/
    ├── xrds/            # CompositeResourceDefinitions
    ├── compositions/    # Compositions
    └── claims/          # Claims (what users request)
```

Commit and push:

```bash
git add .
git commit -m "Initial directory structure"
git push origin main
```

### 10.4 Install Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.ingress.enabled=false
```

> **Why `server.insecure=true`?** We terminate TLS at the Traefik level (via Cert-Manager), not at the Argo CD server level. This avoids double TLS.

Wait for it to be ready:

```bash
kubectl rollout status deployment argocd-server -n argocd
```

### 10.5 Get the Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Save this password. The username is `admin`.

### 10.6 Expose Argo CD UI

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: local-lab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - argocd.local.lab
      secretName: argocd-tls-cert
  rules:
    - host: argocd.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
```

Add `argocd.local.lab` to `/etc/hosts`, then visit: `https://argocd.local.lab`

Log in with `admin` and the password from the previous step.

### 10.7 Install the Argo CD CLI (Optional but recommended)

```bash
brew install argocd

# Login
argocd login argocd.local.lab --username admin --password <PASSWORD> --grpc-web
```

### 10.8 Connect Your GitHub Repository

**Option A: Via the UI**

1. In Argo CD, go to **Settings** → **Repositories** → **Connect Repo**
2. Choose **HTTPS** or **SSH**
3. Enter your repo URL: `https://github.com/<YOUR_USERNAME>/homelab-gitops.git`
4. For a private repo, provide credentials (a GitHub Personal Access Token)

**Option B: Via CLI**

```bash
argocd repo add https://github.com/<YOUR_USERNAME>/homelab-gitops.git \
  --username <YOUR_USERNAME> \
  --password <GITHUB_PAT>
```

> **Security Note:** Use a **GitHub Personal Access Token** with only `repo` scope. Never use your GitHub password. You can create one at: `https://github.com/settings/tokens`

### 10.9 Create Your First Argo CD Application

Create an "App of Apps" pattern — one Argo CD Application that manages all other Applications:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<YOUR_USERNAME>/homelab-gitops.git
    targetRevision: main
    path: apps
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

**What this does:**

| Setting | Purpose |
|---|---|
| `path: apps` | Watches the `apps/` directory in your Git repo |
| `directory.recurse: true` | Looks in all subdirectories |
| `automated.prune: true` | Deletes resources removed from Git |
| `automated.selfHeal: true` | Reverts manual changes to match Git |
| `CreateNamespace=true` | Auto-creates namespaces as needed |

### 10.10 Change Your Admin Password

```bash
argocd account update-password \
  --current-password <INITIAL_PASSWORD> \
  --new-password <YOUR_NEW_PASSWORD>

# Delete the initial secret (it's no longer needed)
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### 10.11 Argo CD Checklist

- [ ] Argo CD pods running in `argocd` namespace
- [ ] UI accessible at `https://argocd.local.lab`
- [ ] Admin password changed
- [ ] GitHub repository connected
- [ ] Root Application created
- [ ] `homelab-gitops` repo structure committed and pushed
- [ ] Argo CD CLI installed (optional)

---

## 11. Installing Prometheus + Grafana + Alertmanager

### 11.1 What Is Observability?

**Observability** is the ability to understand what's happening inside your cluster by examining its outputs: **metrics**, **logs**, and **traces**.

| Component | Role |
|---|---|
| **Prometheus** | Scrapes and stores time-series metrics (CPU, memory, requests, etc.) |
| **Grafana** | Visualizes metrics with beautiful dashboards |
| **Alertmanager** | Routes alerts (e.g., "Node is down") to notification channels (email, Slack, etc.) |

### 11.2 Install the kube-prometheus-stack

The `kube-prometheus-stack` Helm chart installs Prometheus, Grafana, Alertmanager, and a bunch of pre-configured dashboards and alerting rules — all in one shot:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=5Gi \
  --set grafana.adminPassword="REDACTED" \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=5Gi \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.searchNamespace=ALL
```

> **Replace `YourSecurePassword`** with a real password for Grafana.

**What each setting does:**

| Setting | Purpose |
|---|---|
| `retention=30d` | Keep 30 days of metrics history |
| `storageSpec...storage=20Gi` | Prometheus stores data on a 20 GB Longhorn volume |
| `alertmanager...storage=5Gi` | Alertmanager gets its own persistent storage |
| `grafana.persistence.enabled=true` | Grafana dashboards and settings survive restarts |
| `sidecar.dashboards.enabled=true` | Auto-discovers ConfigMaps containing dashboards |
| `searchNamespace=ALL` | Finds dashboards in any namespace |

Wait for all pods to be ready:

```bash
kubectl get pods -n monitoring
# This can take 3-5 minutes
```

### 11.3 Expose Grafana

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: local-lab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - grafana.local.lab
      secretName: grafana-tls-cert
  rules:
    - host: grafana.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-grafana
                port:
                  number: 80
EOF
```

Add `grafana.local.lab` to `/etc/hosts`, then visit: `https://grafana.local.lab`

Log in with:
- **Username:** `admin`
- **Password:** The password you set during installation

### 11.4 Expose Prometheus (Optional)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: local-lab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - prometheus.local.lab
      secretName: prometheus-tls-cert
  rules:
    - host: prometheus.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-kube-prometheus-prometheus
                port:
                  number: 9090
EOF
```

### 11.5 Expose Alertmanager (Optional)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: alertmanager
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: local-lab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - alertmanager.local.lab
      secretName: alertmanager-tls-cert
  rules:
    - host: alertmanager.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-kube-prometheus-alertmanager
                port:
                  number: 9093
EOF
```

### 11.6 Key Pre-Built Dashboards

The kube-prometheus-stack includes many dashboards out of the box. Find them in Grafana under **Dashboards** → **Browse**:

| Dashboard | What it shows |
|---|---|
| **Kubernetes / Compute Resources / Cluster** | CPU, memory, network for the whole cluster |
| **Kubernetes / Compute Resources / Node** | Per-node resource usage (great for Pi monitoring) |
| **Kubernetes / Compute Resources / Namespace (Pods)** | Per-namespace breakdown |
| **Node Exporter / Nodes** | Detailed node hardware metrics (temperature!) |
| **CoreDNS** | DNS query rates and latency |
| **Kubernetes / Networking / Cluster** | Network I/O across the cluster |

### 11.7 Configure Alert Notifications (Optional)

Configure Alertmanager to send alerts to a Slack channel or email:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
  labels:
    alertmanager: monitoring-kube-prometheus-alertmanager
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      receiver: 'default'
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
    receivers:
      - name: 'default'
        # Uncomment and configure one of the following:
        # slack_configs:
        #   - api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
        #     channel: '#homelab-alerts'
        #     send_resolved: true
        # email_configs:
        #   - to: 'your-email@example.com'
        #     from: 'alertmanager@local.lab'
        #     smarthost: 'smtp.gmail.com:587'
        #     auth_username: 'your-email@gmail.com'
        #     auth_password: 'app-password'
EOF
```

### 11.8 Observability Checklist

- [ ] All pods running in `monitoring` namespace
- [ ] Grafana accessible at `https://grafana.local.lab`
- [ ] Can log in and see pre-built dashboards
- [ ] Prometheus accessible at `https://prometheus.local.lab` (optional)
- [ ] Alertmanager accessible at `https://alertmanager.local.lab` (optional)
- [ ] Persistent storage working for Prometheus and Grafana
- [ ] (Optional) Alert notifications configured

---

## 12. Setting Up a Grafana Dashboard for the 1U Display

### 12.1 Concept

Your 10″ rack has a 1U touch display. We'll set it up to show a dedicated Grafana dashboard — a real-time "NOC screen" for your home lab.

### 12.2 Configure the 1U Display

The 1U touch display needs to connect to one of the Pis (or directly to your network). The simplest approach:

**Option A: Connect the display to the controller Pi (`ctrl-1`)**

1. Connect the display to `ctrl-1` via HDMI (Pi 5 has micro-HDMI ports).
2. Install a minimal desktop environment and Chromium:

```bash
# SSH into ctrl-1
ssh pi@192.168.1.100

# Install minimal GUI components
sudo apt install -y --no-install-recommends \
  xserver-xorg \
  x11-xserver-utils \
  xinit \
  chromium-browser \
  unclutter

# Create an auto-start script
cat <<'SCRIPT' | sudo tee /home/pi/kiosk.sh
#!/bin/bash
xset s off
xset -dpms
xset s noblank
unclutter -idle 1 -root &
chromium-browser \
  --noerrdialogs \
  --disable-infobars \
  --kiosk \
  --incognito \
  --disable-translate \
  --disable-features=TranslateUI \
  "https://grafana.local.lab/d/YOUR_DASHBOARD_ID/your-dashboard?orgId=1&refresh=10s&kiosk"
SCRIPT

chmod +x /home/pi/kiosk.sh
```

> **Replace `YOUR_DASHBOARD_ID`** with the actual dashboard ID from Grafana (found in the URL when viewing the dashboard).

3. Configure auto-login and auto-start:

```bash
# Create .xinitrc
echo '/home/pi/kiosk.sh' > /home/pi/.xinitrc

# Auto-start X on login
echo '[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && startx -- -nocursor' >> /home/pi/.bash_profile

# Enable auto-login on tty1
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOF | sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I \$TERM
EOF

sudo systemctl daemon-reload
sudo systemctl restart getty@tty1
```

### 12.3 Create a Dedicated Kiosk Dashboard

In Grafana:

1. Click **+** → **New Dashboard**
2. Add panels focusing on key metrics for a at-a-glance view:

**Recommended panels for a 10″ display (1024×600 or similar):**

| Panel | Query/Metric | Visualization |
|---|---|---|
| Cluster CPU % | `sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) / sum(rate(node_cpu_seconds_total[5m])) * 100` | Gauge |
| Cluster Memory % | `sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes) * 100` | Gauge |
| Node Status | `kube_node_status_condition{condition="Ready",status="true"}` | Stat (4 values) |
| Pod Count | `count(kube_pod_info)` | Stat |
| CPU by Node | `sum by (instance)(rate(node_cpu_seconds_total{mode!="idle"}[5m]))` | Bar chart |
| Network I/O | `sum(rate(node_network_receive_bytes_total[5m]))` | Time series |
| Disk Usage | `(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes * 100` | Gauge per node |
| Pi Temperature | `node_hwmon_temp_celsius` | Stat with thresholds |

3. Set the dashboard time range to "Last 1 hour" with auto-refresh every 10 seconds.
4. Click the **Share** icon → **Link** → Copy the URL.
5. Add `&kiosk` to the URL to enter kiosk mode (hides the Grafana chrome).

### 12.4 Grafana Anonymous Access (For the Kiosk)

To avoid login prompts on the display:

```bash
# Update the Helm values to enable anonymous access for the local dashboard
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values \
  --set grafana."grafana\.ini".auth.anonymous.enabled=true \
  --set grafana."grafana\.ini".auth.anonymous.org_role=Viewer
```

> **Security Note:** This gives anyone on your network read-only access to Grafana without logging in. This is acceptable for a home lab but would be inappropriate in a production environment. The Viewer role cannot modify dashboards or settings.

### 12.5 Display Checklist

- [ ] 1U display connected to `ctrl-1` via HDMI
- [ ] Chromium kiosk mode configured
- [ ] Auto-login and auto-start working
- [ ] Dedicated cluster overview dashboard created
- [ ] Kiosk URL working with `&kiosk` parameter
- [ ] Anonymous viewer access enabled in Grafana
- [ ] Display shows live dashboard after reboot

---

## 13. Installing Crossplane

### 13.1 What Is Crossplane?

**Crossplane** extends Kubernetes so you can define, compose, and consume infrastructure using the Kubernetes API. Instead of writing Terraform or clicking in a console, you declare what you want as Kubernetes resources.

**Key concepts:**

| Concept | What it is |
|---|---|
| **Provider** | A plugin that knows how to manage a specific type of infrastructure (AWS, GCP, Helm, Kubernetes) |
| **Managed Resource** | A Kubernetes resource that represents an external resource (e.g., an S3 bucket) |
| **CompositeResourceDefinition (XRD)** | Defines a new custom API (e.g., "WordPressPlatform") |
| **Composition** | Implements the XRD — what infrastructure to create when someone requests a WordPressPlatform |
| **Claim (XRC)** | A user's request: "I want a WordPressPlatform named my-blog" |

### 13.2 Why Crossplane in a Home Lab?

Crossplane is the foundation of **platform engineering**. By learning Crossplane, you learn:
- How to build self-service platforms (developers request infrastructure via Git)
- How to abstract complexity (hide Helm charts, database configs, etc. behind simple APIs)
- How to compose multiple resources into a single request

### 13.3 Install Crossplane

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace
```

Wait for it to be ready:

```bash
kubectl get pods -n crossplane-system
# Wait for crossplane and crossplane-rbac-manager to be Running
```

### 13.4 Install the Helm Provider

The Helm Provider allows Crossplane to install Helm charts as managed resources. This is perfect for a home lab — you can compose Helm releases (WordPress, databases, etc.) into platform abstractions.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-helm:v0.19.0
EOF
```

Wait for the provider to be healthy:

```bash
kubectl get providers
# STATUS should show HEALTHY: True
```

### 13.5 Install the Kubernetes Provider

The Kubernetes Provider lets Crossplane create raw Kubernetes resources (Deployments, Services, Ingresses, etc.):

```bash
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1
EOF
```

### 13.6 Configure Provider Credentials

Both providers need permission to interact with the cluster. Create a `ProviderConfig` for each:

```bash
# Create a ServiceAccount for Crossplane providers
cat <<EOF | kubectl apply -f -
apiVersion: helm.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity
---
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity
EOF
```

Grant the providers cluster-admin access (needed to manage resources across namespaces):

```bash
# Get the ServiceAccount names created by the providers
HELM_SA=$(kubectl get providers provider-helm -o jsonpath='{.status.currentRevision}')
K8S_SA=$(kubectl get providers provider-kubernetes -o jsonpath='{.status.currentRevision}')

kubectl create clusterrolebinding provider-helm-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=crossplane-system:${HELM_SA}

kubectl create clusterrolebinding provider-kubernetes-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=crossplane-system:${K8S_SA}
```

> **Security Note:** In production, you would use more granular RBAC. For a home lab, cluster-admin simplifies setup.

### 13.7 Crossplane Checklist

- [ ] Crossplane pods running in `crossplane-system`
- [ ] Helm Provider installed and healthy
- [ ] Kubernetes Provider installed and healthy
- [ ] ProviderConfigs created for both providers
- [ ] Provider ServiceAccounts have needed RBAC

---

## 14. Creating a First XRD — WordPress Platform

### 14.1 What Are We Building?

A **self-service WordPress platform**. The goal: a developer (or you) says "I want a WordPress site called my-blog" and Crossplane automatically:

1. Deploys WordPress via Helm
2. Deploys a MariaDB database via Helm
3. Creates a Longhorn PersistentVolumeClaim
4. Creates an Ingress with TLS
5. Wires everything together

### 14.2 The Architecture

```
Developer files a Claim:          Crossplane creates:
┌────────────────────┐           ┌────────────────────────────┐
│ WordPressPlatform  │  ──────>  │ Helm Release: WordPress    │
│  name: my-blog     │           │ Helm Release: MariaDB      │
│  host: blog.local  │           │ PVC: 10Gi on Longhorn      │
│  .lab              │           │ Ingress: blog.local.lab    │
└────────────────────┘           │ TLS Certificate            │
                                 └────────────────────────────┘
```

### 14.3 Define the XRD (CompositeResourceDefinition)

This defines the **API** — what fields a user can set when requesting a WordPress site:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xwordpressplatforms.platform.local.lab
spec:
  group: platform.local.lab
  names:
    kind: XWordPressPlatform
    plural: xwordpressplatforms
  claimNames:
    kind: WordPressPlatform
    plural: wordpressplatforms
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                parameters:
                  type: object
                  properties:
                    host:
                      type: string
                      description: "The hostname for the WordPress site (e.g., blog.local.lab)"
                    storageSize:
                      type: string
                      default: "10Gi"
                      description: "Storage size for WordPress data"
                    dbStorageSize:
                      type: string
                      default: "5Gi"
                      description: "Storage size for the database"
                    replicas:
                      type: integer
                      default: 1
                      description: "Number of WordPress replicas"
                  required:
                    - host
              required:
                - parameters
EOF
```

**What this creates:**
- A new Kubernetes resource type: `WordPressPlatform` (the claim) and `XWordPressPlatform` (the composite)
- The API has four fields: `host` (required), `storageSize`, `dbStorageSize`, and `replicas`

### 14.4 Define the Composition

The Composition is the **implementation** — what Crossplane should create when someone files a WordPressPlatform claim:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: wordpressplatform-composition
  labels:
    crossplane.io/xrd: xwordpressplatforms.platform.local.lab
spec:
  compositeTypeRef:
    apiVersion: platform.local.lab/v1alpha1
    kind: XWordPressPlatform
  resources:
    - name: wordpress
      base:
        apiVersion: helm.crossplane.io/v1beta1
        kind: Release
        spec:
          forProvider:
            chart:
              name: wordpress
              repository: https://charts.bitnami.com/bitnami
              version: "24.0.4"
            namespace: wordpress
            values:
              replicaCount: 1
              persistence:
                enabled: true
                size: 10Gi
                storageClass: longhorn
              mariadb:
                enabled: true
                primary:
                  persistence:
                    enabled: true
                    size: 5Gi
                    storageClass: longhorn
              ingress:
                enabled: true
                ingressClassName: traefik
                hostname: ""
                tls: true
                annotations:
                  cert-manager.io/cluster-issuer: local-lab-ca-issuer
              wordpressUsername: admin
              wordpressPassword: ""
              wordpressEmail: admin@local.lab
          providerConfigRef:
            name: default
      patches:
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.host
          toFieldPath: spec.forProvider.values.ingress.hostname
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.storageSize
          toFieldPath: spec.forProvider.values.persistence.size
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.dbStorageSize
          toFieldPath: spec.forProvider.values.mariadb.primary.persistence.size
        - type: FromCompositeFieldPath
          fromFieldPath: spec.parameters.replicas
          toFieldPath: spec.forProvider.values.replicaCount
        - type: FromCompositeFieldPath
          fromFieldPath: metadata.name
          toFieldPath: metadata.name
          transforms:
            - type: string
              string:
                fmt: "wordpress-%s"
                type: Format
EOF
```

> **Important:** The `wordpressPassword` in the Composition above is empty — you should generate a secret and patch it in. For a home lab, you can set an initial password here, but for anything more, use Kubernetes Secrets and Crossplane's secret references.

### 14.5 File a Claim — Create Your First WordPress Site

```bash
cat <<EOF | kubectl apply -f -
apiVersion: platform.local.lab/v1alpha1
kind: WordPressPlatform
metadata:
  name: my-blog
  namespace: default
spec:
  parameters:
    host: wordpress.local.lab
    storageSize: "10Gi"
    dbStorageSize: "5Gi"
    replicas: 1
EOF
```

Watch Crossplane create everything:

```bash
# Watch the claim
kubectl get wordpressplatform my-blog -w

# Watch Helm releases
kubectl get releases -w

# Watch pods in the wordpress namespace
kubectl get pods -n wordpress -w
```

### 14.6 Access Your WordPress Site

Add `wordpress.local.lab` to `/etc/hosts`:

```bash
sudo sh -c 'echo "192.168.1.100  wordpress.local.lab" >> /etc/hosts'
```

Visit: `https://wordpress.local.lab`

Complete the WordPress setup wizard. Login at: `https://wordpress.local.lab/wp-admin`

### 14.7 Commit to GitOps

Save the XRD, Composition, and Claim to your GitOps repo:

```bash
cd ~/homelab-gitops

# Save XRD
cat > platform/xrds/wordpress-xrd.yaml << 'YAMLEOF'
# (paste the XRD YAML from Section 14.3)
YAMLEOF

# Save Composition
cat > platform/compositions/wordpress-composition.yaml << 'YAMLEOF'
# (paste the Composition YAML from Section 14.4)
YAMLEOF

# Save Claim
cat > platform/claims/my-blog-claim.yaml << 'YAMLEOF'
# (paste the Claim YAML from Section 14.5)
YAMLEOF

git add .
git commit -m "Add WordPress platform XRD, Composition, and first claim"
git push origin main
```

Now Argo CD will manage these resources via Git.

### 14.8 WordPress Platform Checklist

- [ ] XRD (`xwordpressplatforms.platform.local.lab`) created
- [ ] Composition created
- [ ] Claim filed (`my-blog`)
- [ ] WordPress pods running in `wordpress` namespace
- [ ] MariaDB pods running
- [ ] PVCs bound on Longhorn
- [ ] WordPress accessible at `https://wordpress.local.lab`
- [ ] WordPress admin login works
- [ ] Manifests committed to `homelab-gitops` repo

---

## 15. Making WordPress Publicly Accessible (Securely)

### 15.1 The Challenge

You want your WordPress site reachable from the internet (e.g., `blog.yourdomain.com`), but you **do NOT** want to expose your entire home network.

### 15.2 Architecture for Public Access

```
Internet
   │
   ▼
┌─────────────────────────┐
│  Cloudflare (DNS + CDN  │   ← Free tier, DDoS protection
│  + Proxy)               │
└────────────┬────────────┘
             │ HTTPS (origin certificate)
             ▼
┌─────────────────────────┐
│  Cloudflare Tunnel      │   ← Outbound-only connection from your cluster
│  (cloudflared)          │      No port forwarding needed!
└────────────┬────────────┘
             │ Internal
             ▼
┌─────────────────────────┐
│  Traefik Ingress        │
│  → WordPress Service    │
└─────────────────────────┘
```

> **Why Cloudflare Tunnel?** Traditional port forwarding exposes your home IP and opens your router to attacks. Cloudflare Tunnel creates an **outbound-only** connection from your cluster to Cloudflare's edge. Your home IP stays hidden, and you get free DDoS protection.

### 15.3 Prerequisites

1. **Own a domain** (e.g., `yourdomain.com`). You can buy one from Cloudflare, Namecheap, Google Domains, etc.
2. **Create a free Cloudflare account** at https://cloudflare.com
3. **Add your domain to Cloudflare** and update your domain registrar's nameservers to Cloudflare's.

### 15.4 Create a Cloudflare Tunnel

1. In the Cloudflare dashboard, go to **Zero Trust** → **Networks** → **Tunnels**
2. Click **Create a tunnel**
3. Name it: `homelab`
4. Choose the **Cloudflared** connector type
5. Copy the **tunnel token** — you'll need it next

### 15.5 Deploy cloudflared in Your Cluster

```bash
# Create a secret with the tunnel token
kubectl create namespace cloudflare
kubectl create secret generic cloudflare-tunnel-token \
  --namespace cloudflare \
  --from-literal=tunnel-token="<YOUR_TUNNEL_TOKEN>"

# Deploy cloudflared
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare
spec:
  replicas: 2
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - run
            - --token
            - \$(TUNNEL_TOKEN)
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: cloudflare-tunnel-token
                  key: tunnel-token
          resources:
            limits:
              memory: 128Mi
              cpu: 100m
            requests:
              memory: 64Mi
              cpu: 50m
EOF
```

### 15.6 Configure the Tunnel Route

In the Cloudflare dashboard:

1. Go to your tunnel's configuration
2. Add a **Public Hostname**:
   - **Subdomain:** `blog`
   - **Domain:** `yourdomain.com`
   - **Type:** `HTTP`
   - **URL:** `wordpress.wordpress.svc.cluster.local:80`

This tells Cloudflare: when someone visits `blog.yourdomain.com`, route the traffic through the tunnel to your WordPress Service inside the cluster.

### 15.7 Get a Real Let's Encrypt Certificate

For the public-facing WordPress, use the production Let's Encrypt issuer:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wordpress-public
  namespace: wordpress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - blog.yourdomain.com
      secretName: wordpress-public-tls
  rules:
    - host: blog.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: wordpress
                port:
                  number: 80
EOF
```

> **Note:** If you're using Cloudflare Tunnel with Cloudflare's proxy (orange cloud), Cloudflare handles TLS termination at their edge. The connection from Cloudflare Tunnel to your cluster can use HTTP internally via the `svc.cluster.local` address. The Ingress above is useful if you also want direct HTTPS access within your network.

### 15.8 Test Public Access

1. From a device **outside** your home network (e.g., your phone on cellular data):
2. Visit: `https://blog.yourdomain.com`
3. You should see your WordPress site with a valid HTTPS certificate

### 15.9 Harden WordPress for Public Access

Since this is publicly accessible, apply these security measures:

```bash
# Install the WordPress security plugin (via WP-CLI or admin dashboard):
# - Wordfence or Sucuri Security
# - Limit Login Attempts Reloaded
# - Disable XML-RPC (if not needed)

# Add rate limiting via Traefik middleware:
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: wordpress
spec:
  rateLimit:
    average: 50
    burst: 100
    period: 1m
EOF
```

### 15.10 Public Access Checklist

- [ ] Domain registered and DNS on Cloudflare
- [ ] Cloudflare Tunnel created
- [ ] `cloudflared` running in the cluster (2 replicas)
- [ ] Tunnel route configured in Cloudflare dashboard
- [ ] WordPress accessible at `https://blog.yourdomain.com`
- [ ] HTTPS certificate valid
- [ ] WordPress security plugins installed
- [ ] Rate limiting configured
- [ ] Tested from an external network

---

## 16. Security Best Practices

### 16.1 Network Security

- [ ] **Do NOT expose ports directly** — Use Cloudflare Tunnel for public access instead of port forwarding
- [ ] **Firewall each Pi** — Allow only SSH (22), Kubernetes API (6443), and kubelet (10250):

```bash
# On each node:
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 6443/tcp    # Kubernetes API
sudo ufw allow 10250/tcp   # Kubelet
sudo ufw allow 8472/udp    # Flannel VXLAN (k3s networking)
sudo ufw allow 51820/udp   # WireGuard (k3s networking, if used)
sudo ufw allow 80/tcp      # Traefik HTTP
sudo ufw allow 443/tcp     # Traefik HTTPS
sudo ufw enable
```

- [ ] **Isolate the lab on a VLAN** (advanced) — If your router supports it, put the Pis on a separate VLAN from your home devices

### 16.2 SSH Security

- [ ] **Use SSH keys instead of passwords:**

```bash
# On your laptop — generate a key if you don't have one
ssh-keygen -t ed25519 -C "homelab"

# Copy to each Pi
ssh-copy-id -i ~/.ssh/id_ed25519 pi@192.168.1.100
ssh-copy-id -i ~/.ssh/id_ed25519 pi@192.168.1.101
ssh-copy-id -i ~/.ssh/id_ed25519 pi@192.168.1.102
ssh-copy-id -i ~/.ssh/id_ed25519 pi@192.168.1.103
```

- [ ] **Disable password authentication** on each Pi:

```bash
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

### 16.3 Kubernetes Security

- [ ] **Use namespaces** to isolate workloads (already doing this)
- [ ] **Apply NetworkPolicies** to restrict Pod-to-Pod traffic:

```bash
# Example: Allow only WordPress to talk to its database
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-wordpress-to-mariadb
  namespace: wordpress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mariadb
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: wordpress
      ports:
        - port: 3306
EOF
```

- [ ] **Use RBAC** — Don't give everything `cluster-admin`. Create specific roles for specific tasks
- [ ] **Scan images** — Use Trivy to scan container images for vulnerabilities:

```bash
brew install aquasecurity/trivy/trivy
trivy image wordpress:latest
```

- [ ] **Keep k3s updated:**

```bash
# Check current version
kubectl version

# Update on controller
curl -sfL https://get.k3s.io | sh -

# Update on workers (same command, they auto-detect the agent mode)
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.1.100:6443 \
  K3S_TOKEN=<TOKEN> sh -
```

### 16.4 Secrets Management

- [ ] **Never commit secrets to Git** — Use Sealed Secrets or External Secrets Operator
- [ ] Install **Sealed Secrets** (optional but recommended):

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system

# Install kubeseal CLI
brew install kubeseal

# Encrypt a secret
kubectl create secret generic my-secret \
  --dry-run=client \
  --from-literal=password=super-secret \
  -o yaml | kubeseal --format yaml > sealed-secret.yaml

# Now sealed-secret.yaml is safe to commit to Git
```

### 16.5 Backup Strategy

- [ ] **Back up etcd** (the cluster database):

```bash
# On the controller node
sudo k3s etcd-snapshot save --name manual-backup
# Snapshots are saved to /var/lib/rancher/k3s/server/db/snapshots/
```

- [ ] **Back up Longhorn volumes** — Use the Longhorn UI to configure scheduled backups to an NFS share or S3-compatible storage
- [ ] **Back up your GitOps repo** — It's on GitHub, so it's already backed up. But consider enabling branch protection rules.

### 16.6 Security Checklist Summary

- [ ] SSH keys only (no passwords)
- [ ] Firewall (UFW) on all nodes
- [ ] No public port forwarding (use Cloudflare Tunnel)
- [ ] NetworkPolicies restricting traffic
- [ ] Secrets encrypted (Sealed Secrets)
- [ ] Container images scanned for vulnerabilities
- [ ] k3s kept up to date
- [ ] etcd snapshots scheduled
- [ ] Longhorn backup configured
- [ ] Grafana anonymous access limited to Viewer role

---

## 17. Troubleshooting

### 17.1 Node Not Joining the Cluster

**Symptoms:** `kubectl get nodes` doesn't show the worker.

**Checks:**

```bash
# On the worker node, check the k3s-agent service
sudo systemctl status k3s-agent
sudo journalctl -u k3s-agent -f

# Common issues:
# 1. Wrong token → re-copy from controller: sudo cat /var/lib/rancher/k3s/server/node-token
# 2. Network issue → ping the controller: ping 192.168.1.100
# 3. Port blocked → check firewall: sudo ufw status
# 4. Time drift → install NTP: sudo apt install -y chrony
```

### 17.2 Pods Stuck in Pending

**Symptoms:** `kubectl get pods` shows `Pending` indefinitely.

```bash
# Check why:
kubectl describe pod <POD_NAME>

# Common causes:
# - Insufficient resources → kubectl describe node <NODE> | grep -A 5 "Allocated"
# - No available PV → kubectl get pvc (check if PVCs are Bound)
# - Node selector/taint issue → kubectl get nodes --show-labels
```

### 17.3 Pods in CrashLoopBackOff

**Symptoms:** Pod keeps restarting.

```bash
# Check logs:
kubectl logs <POD_NAME> --previous

# Common causes:
# - Misconfigured environment variables
# - Database connection issues
# - Missing secrets or ConfigMaps
# - Image doesn't support ARM64 (check with: docker manifest inspect <IMAGE>)
```

### 17.4 Ingress Not Working

**Symptoms:** `curl http://yourapp.local.lab` returns connection refused or 404.

```bash
# Check Traefik pods
kubectl get pods -n kube-system | grep traefik

# Check if Ingress is created
kubectl get ingress --all-namespaces

# Check Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik

# Common causes:
# - /etc/hosts not updated on your laptop
# - Ingress host doesn't match the URL you're using
# - Traefik not listening on the correct port → check hostPort config
# - Service name/port wrong in the Ingress spec
```

### 17.5 Longhorn Volume Issues

**Symptoms:** PVC stuck in `Pending`, or volume degraded in Longhorn UI.

```bash
# Check PVC status
kubectl get pvc --all-namespaces

# Check Longhorn pods
kubectl get pods -n longhorn-system

# Check node storage
kubectl get nodes.longhorn.io -n longhorn-system -o yaml

# Common causes:
# - NVMe not mounted → ssh into node, run df -h /mnt/nvme
# - iscsid not running → sudo systemctl status iscsid
# - Not enough space → check Longhorn UI for disk usage
# - Only 2 nodes available but 3 replicas requested
```

### 17.6 Cert-Manager Certificate Not Issuing

**Symptoms:** Certificate stays in `Not Ready` state.

```bash
# Check certificate status
kubectl get certificates --all-namespaces
kubectl describe certificate <NAME> -n <NAMESPACE>

# Check certificate requests
kubectl get certificaterequest --all-namespaces

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Common causes:
# - ClusterIssuer not created or misconfigured
# - For Let's Encrypt: HTTP-01 challenge can't be reached (port 80 not forwarded)
# - For self-signed: CA secret doesn't exist
```

### 17.7 Argo CD Sync Failures

**Symptoms:** Application shows `OutOfSync` or `SyncFailed`.

```bash
# Check app status
argocd app get <APP_NAME>

# Check sync details
argocd app sync <APP_NAME> --dry-run

# Common causes:
# - YAML syntax errors in Git
# - CRDs not installed yet (apply CRDs before resources that use them)
# - Namespace doesn't exist (enable CreateNamespace in syncOptions)
# - GitHub credentials expired
```

### 17.8 High CPU/Memory on a Pi

```bash
# Check resource usage per node
kubectl top nodes

# Check resource usage per pod
kubectl top pods --all-namespaces --sort-by=memory

# Check Pi temperature (overheating causes throttling)
vcgencmd measure_temp
# If > 80°C, improve cooling

# Common solutions:
# - Add resource limits to pods
# - Move heavy workloads to specific nodes using nodeSelector
# - Reduce Prometheus retention period
# - Reduce Longhorn replica count from 3 to 2 for non-critical volumes
```

### 17.9 General Debugging Workflow

```
1. What's broken?
   └── kubectl get pods --all-namespaces | grep -v Running

2. Why is it broken?
   └── kubectl describe pod <POD_NAME> -n <NAMESPACE>

3. What does the app say?
   └── kubectl logs <POD_NAME> -n <NAMESPACE>

4. What does the node say?
   └── kubectl describe node <NODE_NAME>

5. What does the system say?
   └── ssh into node → journalctl -u k3s (or k3s-agent) -f

6. Is it a network issue?
   └── kubectl run -it debug --image=busybox --rm -- sh
       → nslookup kubernetes.default
       → wget -qO- http://<service>.<namespace>.svc.cluster.local
```

---

## 18. Post-Install Checklist

### Infrastructure Layer

- [ ] 4 Raspberry Pi 5 nodes assembled and racked
- [ ] NVMe drives formatted and mounted on all nodes
- [ ] PoE networking operational
- [ ] Static IPs assigned to all nodes
- [ ] SSH key-based access configured
- [ ] OS updated and prerequisites installed
- [ ] cgroups and kernel modules configured

### Kubernetes Layer

- [ ] k3s server running on `ctrl-1`
- [ ] 3 worker nodes joined and `Ready`
- [ ] `kubectl` working from your laptop
- [ ] Helm installed on your laptop
- [ ] Worker nodes labeled

### Networking & Ingress Layer

- [ ] Traefik running as DaemonSet on all nodes
- [ ] Ports 80 and 443 accessible
- [ ] `local.lab` DNS resolving (via `/etc/hosts` or DNS server)
- [ ] Ingress routing verified with test app

### TLS & Certificates

- [ ] Cert-Manager installed and running
- [ ] Self-signed CA created for `local.lab`
- [ ] CA certificate trusted on your laptop
- [ ] Let's Encrypt staging and production issuers created
- [ ] HTTPS verified for internal services

### Storage

- [ ] Longhorn installed and all nodes participating
- [ ] Default StorageClass set to Longhorn
- [ ] Longhorn UI accessible
- [ ] PVC creation and binding verified
- [ ] Replica count set to 3

### GitOps

- [ ] `homelab-gitops` GitHub repository created
- [ ] Directory structure committed
- [ ] Argo CD installed and UI accessible
- [ ] GitHub repository connected to Argo CD
- [ ] Root Application created (App of Apps)
- [ ] Admin password changed

### Observability

- [ ] Prometheus, Grafana, and Alertmanager running
- [ ] Grafana accessible and dashboards loading
- [ ] Persistent storage for metrics data
- [ ] 1U display showing live dashboard
- [ ] (Optional) Alert notifications configured

### Platform Engineering

- [ ] Crossplane installed
- [ ] Helm and Kubernetes providers installed
- [ ] WordPress XRD created
- [ ] WordPress Composition created
- [ ] WordPress site deployed via Claim
- [ ] WordPress accessible internally

### Public Access

- [ ] Domain registered and on Cloudflare
- [ ] Cloudflare Tunnel running in cluster
- [ ] WordPress accessible publicly
- [ ] DDoS protection active via Cloudflare
- [ ] No ports forwarded on home router

### Security

- [ ] SSH passwords disabled
- [ ] Firewall (UFW) active on all nodes
- [ ] NetworkPolicies applied
- [ ] Secrets management configured
- [ ] etcd backup scheduled
- [ ] Longhorn backup configured

---

## 19. What to Build Next

### 19.1 Rancher — Cluster Management UI (Recommended Next)

**What:** Rancher is a complete multi-cluster management platform. It provides a beautiful UI for managing your k3s cluster, viewing workloads, managing RBAC, and more.

**Why:** While `kubectl` is powerful, a UI makes it easier to explore and learn. Rancher also teaches you about multi-cluster management patterns.

```bash
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.local.lab \
  --set ingress.tls.source=secret \
  --set replicas=1

# Create the TLS Ingress
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rancher
  namespace: cattle-system
  annotations:
    cert-manager.io/cluster-issuer: local-lab-ca-issuer
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - rancher.local.lab
      secretName: rancher-tls-cert
  rules:
    - host: rancher.local.lab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rancher
                port:
                  number: 80
EOF
```

### 19.2 Event Bus — Apache Kafka

**What:** Kafka is a distributed event streaming platform. It enables event-driven architectures where services communicate asynchronously.

**Why:** Event-driven architecture is a core pattern in modern platforms. Running Kafka in your lab teaches you about:
- Producers and consumers
- Topics and partitions
- Event schemas (Avro, Protobuf)
- Event sourcing and CQRS patterns

**Getting Started:**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm install kafka bitnami/kafka \
  --namespace kafka \
  --create-namespace \
  --set kraft.enabled=true \
  --set controller.replicaCount=3 \
  --set persistence.storageClass=longhorn \
  --set persistence.size=10Gi
```

**Project Ideas:**
- Build a service that publishes WordPress post events to Kafka
- Create a consumer that sends Slack notifications for new posts
- Build an audit log service that stores all events

### 19.3 Federated GraphQL / Supergraph

**What:** A federated GraphQL API (supergraph) composes multiple GraphQL services (subgraphs) into a single unified API.

**Why:** This is a real pattern used by companies like Netflix, Expedia, and Walmart. It teaches:
- API gateway patterns
- Schema composition
- Service-to-service communication
- Developer experience design

**Architecture:**

```
Client (browser/app)
       │
       ▼
┌─────────────────┐
│  Apollo Router   │  ← Supergraph gateway
│  (Graph Router)  │
└───┬───┬───┬─────┘
    │   │   │
    ▼   ▼   ▼
┌─────┐┌─────┐┌─────┐
│ Blog ││Users││Stats│   ← Subgraph services
│ API  ││ API ││ API │
└─────┘└─────┘└─────┘
```

**Getting Started:**

1. Deploy Apollo Router in your cluster
2. Build subgraph services (Node.js, Go, or Python)
3. Create a supergraph schema that composes them
4. Expose via Traefik at `graph.local.lab`

```bash
# Example: Deploy Apollo Router
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apollo-router
  namespace: graph
spec:
  replicas: 2
  selector:
    matchLabels:
      app: apollo-router
  template:
    metadata:
      labels:
        app: apollo-router
    spec:
      containers:
        - name: router
          image: ghcr.io/apollographql/router:v1.x.x
          ports:
            - containerPort: 4000
          env:
            - name: APOLLO_ROUTER_CONFIG_PATH
              value: /config/router.yaml
          volumeMounts:
            - name: config
              mountPath: /config
      volumes:
        - name: config
          configMap:
            name: router-config
EOF
```

### 19.4 CI/CD Pipeline — Tekton or GitHub Actions

**What:** Add a CI/CD pipeline that builds container images, runs tests, and pushes them to a registry.

**Options:**
- **Tekton** — Kubernetes-native CI/CD (runs in your cluster)
- **GitHub Actions** — Cloud-based CI/CD (simpler to start)
- **Harbor** — Private container registry (store your own images)

### 19.5 Service Mesh — Linkerd or Istio

**What:** A service mesh adds observability, security, and reliability features to Pod-to-Pod communication transparently.

**Why:** Learn about:
- Mutual TLS (mTLS) between services
- Traffic splitting (canary deployments)
- Retries and circuit breaking
- Per-request metrics

> **Recommendation:** Start with **Linkerd** — it's much lighter than Istio and runs well on Raspberry Pi.

### 19.6 Policy Engine — Kyverno or OPA Gatekeeper

**What:** Enforce policies on what can and cannot be deployed in your cluster.

**Examples:**
- "All containers must have resource limits"
- "No `latest` tags allowed"
- "All Pods must have labels"

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace
```

### 19.7 Suggested Build Order

| Order | Component | Difficulty | Builds On |
|---|---|---|---|
| 1 | Rancher | Easy | Existing cluster |
| 2 | Sealed Secrets | Easy | GitOps workflow |
| 3 | Kyverno | Medium | Security practices |
| 4 | Tekton CI/CD | Medium | GitOps, container building |
| 5 | Kafka | Medium | Longhorn storage |
| 6 | Linkerd | Medium | Existing services |
| 7 | GraphQL Supergraph | Hard | Custom services, ingress |
| 8 | Multi-cluster (2nd k3s cluster) | Hard | Everything above |

### 19.8 Learning Resources

| Topic | Resource |
|---|---|
| Kubernetes | [kubernetes.io/docs](https://kubernetes.io/docs/) |
| k3s | [docs.k3s.io](https://docs.k3s.io/) |
| Crossplane | [docs.crossplane.io](https://docs.crossplane.io/) |
| Argo CD | [argo-cd.readthedocs.io](https://argo-cd.readthedocs.io/) |
| Platform Engineering | [platformengineering.org](https://platformengineering.org/) |
| CNCF Landscape | [landscape.cncf.io](https://landscape.cncf.io/) |
| Apollo GraphQL | [apollographql.com/docs](https://www.apollographql.com/docs/) |
| Kafka | [kafka.apache.org/documentation](https://kafka.apache.org/documentation/) |

---

## Appendix A: Quick Reference — All Hostnames and URLs

| Service | Internal URL | Notes |
|---|---|---|
| Kubernetes API | `https://192.168.1.100:6443` | Used by `kubectl` |
| Traefik Dashboard | `https://traefik.local.lab` | Ingress routes viewer |
| Longhorn UI | `https://longhorn.local.lab` | Storage management |
| Argo CD | `https://argocd.local.lab` | GitOps dashboard |
| Grafana | `https://grafana.local.lab` | Metrics dashboards |
| Prometheus | `https://prometheus.local.lab` | Raw metrics query |
| Alertmanager | `https://alertmanager.local.lab` | Alert routing |
| WordPress | `https://wordpress.local.lab` | Internal access |
| WordPress (public) | `https://blog.yourdomain.com` | Via Cloudflare Tunnel |
| Rancher | `https://rancher.local.lab` | Cluster management |

## Appendix B: Quick Reference — SSH Connections

```bash
ssh pi@192.168.1.100   # ctrl-1 (controller)
ssh pi@192.168.1.101   # work-1
ssh pi@192.168.1.102   # work-2
ssh pi@192.168.1.103   # work-3
```

## Appendix C: Quick Reference — Essential kubectl Commands

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes -o wide
kubectl top nodes

# All resources in a namespace
kubectl get all -n <namespace>

# Logs
kubectl logs <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous    # crashed container
kubectl logs <pod> -n <namespace> -f             # streaming

# Debugging
kubectl describe pod <pod> -n <namespace>
kubectl exec -it <pod> -n <namespace> -- sh
kubectl run debug --image=busybox --rm -it -- sh

# Port forwarding (quick access without Ingress)
kubectl port-forward svc/grafana 3000:80 -n monitoring
kubectl port-forward svc/argocd-server 8080:443 -n argocd

# Resource usage
kubectl top pods --all-namespaces --sort-by=memory
kubectl top pods --all-namespaces --sort-by=cpu
```

## Appendix D: Complete `/etc/hosts` Entry

Add this to `/etc/hosts` on your laptop:

```
# Homelab Kubernetes Cluster
192.168.1.100  ctrl-1 ctrl-1.local.lab
192.168.1.101  work-1 work-1.local.lab
192.168.1.102  work-2 work-2.local.lab
192.168.1.103  work-3 work-3.local.lab

# Cluster Services
192.168.1.100  traefik.local.lab
192.168.1.100  argocd.local.lab
192.168.1.100  grafana.local.lab
192.168.1.100  prometheus.local.lab
192.168.1.100  alertmanager.local.lab
192.168.1.100  longhorn.local.lab
192.168.1.100  wordpress.local.lab
192.168.1.100  rancher.local.lab
```

---

*This guide was generated as a starting point. Kubernetes evolves fast — always check the official documentation for the latest versions and best practices. Happy building!*
