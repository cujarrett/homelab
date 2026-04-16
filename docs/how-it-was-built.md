# K3s Lab Plan

<details>
<summary><strong>Contents</strong></summary>

| Section |
|---|
| [Architecture](#architecture) |
| [Node IPs](#node-ips) |
| [1 — Hardware & OS Setup](#node-reference) |
| [2 — Install k3s on ctrl-1](#k3s-install) |
| [3 — Join Worker Nodes](#worker-nodes) |
| [4 — Verify Cluster Health](#cluster-health) |
| [5 — Configure Traefik](#traefik) |
| [6 — DNS: /etc/hosts](#dns-hosts) |
| [7 — Cert-Manager](#cert-manager) |
| [8 — Longhorn](#longhorn) |
| [9 — Argo CD](#argocd) |
| [10 — Prometheus + Grafana](#prometheus-grafana) |
| [11 — Grafana Kiosk](#grafana-kiosk) |
| [12 — AdGuard Home](#adguard) |
| [13 — Tailscale (Remote Access)](#tailscale) |
| [14 — Crossplane](#crossplane) |

</details>

## Architecture

```
            ┌─────────────────────────────────────────────────────┐
            │                    INTERNET (WAN)                   │
            └────────────────────────┬────────────────────────────┘
                                     │ fiber
            ┌────────────────────────┴────────────────────────────┐
            │    Ubiquiti UDR7  (HVAC room)  192.168.1.1          │
            │   Gateway · Firewall · DHCP · DNS · UniFi Ctrl      │
            │   VLAN 1: 192.168.1.0/24   (home devices)           │
            │   VLAN 10: 192.168.10.0/24 (k3s cluster) ─────────┐ │
            └──────┬────────────────────────────────────────────┼─┘
                   │ LAN 1                                      │
            ┌──────┴──────────────────────────────────────┐     │
            │  Unmanaged patch switch (HVAC room)         │     │
            └──┬──────────┬──────────┬───────────┬────────┘     │
               │          │          │           │              │
          U7 LITE AP  U7 LITE AP  Existing   GS305PP (rack) ← VLAN 10
          (office)    (bedroom)   switch     5-port 83W PoE
          VLAN 1      VLAN 1                 ┌──┬──┬──┬──┐
                                             │  │  │  │  │
                                             └──┴──┴──┴──┘
                                              │  │  │  │
                                           ctrl-1 w-1 w-2  w-3
                                          .10.100 .101 .102 .103
                                           k3s    k3s  k3s  k3s
                                           server agent agent agent

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

---

## Node IPs

| Device | Hostname | IP | Role |
|---|---|---|---|
| UDR7 | `gateway` | `192.168.1.1` | Router / firewall / DHCP / DNS |
| U7 LITE AP #1 | `ap-office` | `192.168.1.2` | WiFi main floor |
| U7 LITE AP #2 | `ap-bedroom` | `192.168.1.3` | WiFi upstairs |
| Raspberry Pi 5 #1 | `ctrl-1` | `192.168.10.100` | k3s server (controller) |
| Raspberry Pi 5 #2 | `work-1` | `192.168.10.101` | k3s agent (worker) |
| Raspberry Pi 5 #3 | `work-2` | `192.168.10.102` | k3s agent (worker) |
| Raspberry Pi 5 #4 | `work-3` | `192.168.10.103` | k3s agent (worker) |

---

<a id="node-reference"></a>
## 1 — Hardware & OS Setup

All 4 nodes fully prepped: NVMe boot, static IPs, open-iscsi, cgroups, kernel modules, Longhorn dir.

```bash
ssh pi@192.168.10.100   # ctrl-1
ssh pi@192.168.10.101   # work-1
ssh pi@192.168.10.102   # work-2
ssh pi@192.168.10.103   # work-3
```

---

<a id="k3s-install"></a>
## 2 — Install k3s on ctrl-1

K3s is a lightweight, CNCF-certified Kubernetes distribution built for resource-constrained environments. It ships as a single ~100 MB binary, uses roughly half the RAM of standard Kubernetes, and bundles Traefik, CoreDNS, and a Helm controller out of the box — making it a natural fit for Raspberry Pi hardware.

```bash
ssh pi@192.168.10.100

curl -sfL https://get.k3s.io | sh -s - server \
  --write-kubeconfig-mode 644 \
  --disable servicelb \
  --disable local-storage \
  --tls-san 192.168.10.100 \
  --tls-san ctrl-1.local.lab \
  --node-name ctrl-1
```

Verify:

```bash
sudo systemctl status k3s
sudo kubectl get nodes
# Expected: ctrl-1  Ready  control-plane,master
```

Get the node token (needed for workers):

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Copy kubeconfig to laptop — run these on your Mac, not ctrl-1:

```bash
# On your Mac
mkdir -p ~/.kube
scp pi@192.168.10.100:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/192.168.10.100/g' ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

Install tools on your Mac:

```bash
brew install kubectl helm
```


---

<a id="worker-nodes"></a>
## 3 — Join Worker Nodes

A single-node cluster has limited CPU, RAM, and no redundancy. Adding three workers distributes pod scheduling across all four Pis, keeps the control-plane node free for Kubernetes management traffic, and means workloads can survive a single node going down.

Replace `<NODE_TOKEN>` with the token from step 2.

```bash
# work-1
ssh pi@192.168.10.101
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.10.100:6443 \
  K3S_TOKEN=<NODE_TOKEN> sh -s - agent --node-name work-1

# work-2
ssh pi@192.168.10.102
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.10.100:6443 \
  K3S_TOKEN=<NODE_TOKEN> sh -s - agent --node-name work-2

# work-3
ssh pi@192.168.10.103
curl -sfL https://get.k3s.io | K3S_URL=https://192.168.10.100:6443 \
  K3S_TOKEN=<NODE_TOKEN> sh -s - agent --node-name work-3
```

Verify from laptop:

```bash
kubectl get nodes -o wide
# All 4 nodes should show Ready
```

Label workers:

```bash
kubectl label node work-1 node-role.kubernetes.io/worker=worker
kubectl label node work-2 node-role.kubernetes.io/worker=worker
kubectl label node work-3 node-role.kubernetes.io/worker=worker
```


---

<a id="cluster-health"></a>
## 4 — Verify Cluster Health

Before layering in any infrastructure, confirm the cluster baseline is solid. Pods need to schedule across workers, DNS must resolve service names, and pod-to-pod networking must work — these are the foundations that everything else depends on. Catching problems here is far easier than debugging them after six more components are installed.

```bash
kubectl get pods -n kube-system
# All pods Running or Completed

kubectl create deployment nginx-test --image=nginx --replicas=3
kubectl get pods -o wide   # Should spread across worker nodes
kubectl delete deployment nginx-test

kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local
# Should return an IP in 10.43.x.x range
```


---

<a id="traefik"></a>
## 5 — Configure Traefik (Ingress)

Every service deployed in the cluster is only reachable from inside the cluster by default. Traefik is the ingress controller — it listens on ports 80/443 of each node and routes incoming HTTP/HTTPS traffic to the correct pod based on the `Host` header (e.g., `grafana.local.lab → grafana pod`). K3s bundles Traefik automatically, but we configure it to bind to the host ports directly so requests from your Mac actually reach the cluster.

k3s ships Traefik automatically. Configure it to bind host ports directly:

```bash
kubectl apply -f apps/traefik/helmchartconfig.yaml
kubectl rollout status daemonset traefik -n kube-system
```

Test with the whoami app:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
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
spec:
  ports:
    - port: 80
  selector:
    app: whoami
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami
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

sudo sh -c 'echo "192.168.10.100  whoami.local.lab" >> /etc/hosts'
curl http://whoami.local.lab

kubectl delete ingress whoami && kubectl delete service whoami && kubectl delete deployment whoami

# Remove the temporary /etc/hosts entry
sudo sed -i '' '/whoami\.local\.lab/d' /etc/hosts
```


---

<a id="dns-hosts"></a>
## 6 — DNS: /etc/hosts for Now (AdGuard Home in Step 12)

Service hostnames like `longhorn.local.lab` need to resolve to the cluster IP (`192.168.10.100`) before a browser or `curl` can reach them. UniFi Network 10.2 doesn't support wildcard DNS records, so while the cluster is being built, your Mac's `/etc/hosts` file is the simplest workaround. AdGuard Home (step 12) replaces this permanently for all devices on the network.

UniFi Network 10.2 does not support wildcard local DNS records. AdGuard Home runs on the cluster and serves `*.local.lab → 192.168.10.100` for any device that uses it as a DNS server.

**Phase 1 (now):** Add all service hostnames to your Mac's `/etc/hosts` upfront so you never have to think about it again as each service comes online:

```bash
sudo sh -c 'cat >> /etc/hosts << "EOF"
192.168.10.100  adguard.local.lab
192.168.10.100  traefik.local.lab
192.168.10.100  longhorn.local.lab
192.168.10.100  argocd.local.lab
192.168.10.100  grafana.local.lab
192.168.10.100  prometheus.local.lab
192.168.10.100  alertmanager.local.lab
192.168.10.100  wordpress.local.lab
EOF'
```

Phase 2 (deploy AdGuard Home and replace `/etc/hosts`) is covered in step 12 once the cluster is fully built out.


---

<a id="cert-manager"></a>
## 7 — Install Cert-Manager

HTTPS requires TLS certificates. Without them, every browser request to a cluster service shows a security warning, and tools like the ArgoCD CLI and Helm can refuse to talk to untrusted endpoints. Cert-Manager automates requesting, issuing, and renewing certificates — from Let's Encrypt for public-facing services and from a self-signed local CA for internal `*.local.lab` services — so you never have to manage cert expiry manually.

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set prometheus.enabled=true

kubectl get pods -n cert-manager
# cert-manager, cert-manager-cainjector, cert-manager-webhook — all Running
```

Create issuers:

```bash
# Edit apps/cert-manager/issuers.yaml first — update your-email@example.com
kubectl apply -f apps/cert-manager/issuers.yaml
```

Trust the CA on your laptop:

```bash
kubectl get secret local-lab-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > local-lab-ca.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain local-lab-ca.crt
```


---

<a id="longhorn"></a>
## 8 — Install Longhorn (Storage)

By default, Kubernetes pod storage is ephemeral — any data written to disk is lost when a pod restarts or moves to a different node. Longhorn provides distributed block storage backed by the NVMe SSDs on each Raspberry Pi. It automatically replicates volumes across nodes (3× by default), so a disk failure or node loss doesn't destroy your data. Without Longhorn (or similar), stateful workloads like databases and Grafana dashboards can't safely persist anything.

### Pre-flight

Run the preflight check from `ctrl-1` to confirm all nodes are ready:

```bash
ssh pi@192.168.10.100
kubectl create namespace longhorn-system --kubeconfig /etc/rancher/k3s/k3s.yaml
curl -sSfL -o longhornctl https://github.com/longhorn/cli/releases/download/v1.11.1/longhornctl-linux-arm64
chmod +x longhornctl
./longhornctl check preflight --kubeconfig /etc/rancher/k3s/k3s.yaml
exit
```

Expected errors and fixes — run on **all 4 nodes**:

| Error | Fix |
|---|---|
| `cryptsetup is not installed` | `sudo apt install -y cryptsetup` |
| `nfs is not loaded` | `sudo modprobe nfs` |
| `dm_crypt is not loaded` | `sudo modprobe dm_crypt` |

Fix script (run once per node, or loop from your Mac):

```bash
for NODE in 192.168.10.100 192.168.10.101 192.168.10.102 192.168.10.103; do
  ssh pi@$NODE "sudo apt install -y cryptsetup && \
    sudo modprobe nfs dm_crypt && \
    echo -e 'nfs\ndm_crypt' | sudo tee /etc/modules-load.d/longhorn.conf"
done
```

The `modules-load.d` file makes `nfs` and `dm_crypt` load automatically after a reboot. Re-run the preflight after to confirm all errors are gone.

Install:

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath="/var/lib/longhorn" \
  --set defaultSettings.defaultReplicaCount=3 \
  --set defaultSettings.storageMinimalAvailablePercentage=15

kubectl get pods -n longhorn-system
# Takes 2-3 min
```

Set Longhorn as default StorageClass if not already:

```bash
kubectl patch storageclass longhorn -p \
  '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Expose the UI:

```bash
kubectl apply -f apps/longhorn/ingress.yaml
```


---

<a id="argocd"></a>
## 9 — Install Argo CD (GitOps)

Managing a cluster by running `kubectl apply` by hand doesn't scale and leaves no audit trail of what changed and when. Argo CD implements GitOps: it watches this GitHub repo and automatically syncs any changes you push to the cluster. The Git history becomes a full audit log, rollbacks are a `git revert` away, and the cluster's desired state is always defined as code — never just whatever was last typed into a terminal.

The `apps/` and `platform/` directory structure already exists in this repo — use this repo as your GitOps source, or copy the files to a dedicated `homelab-gitops` repo.

Install Argo CD:

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.ingress.enabled=false

kubectl rollout status deployment argocd-server -n argocd
```

Get initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Expose UI:

```bash
kubectl apply -f apps/argocd/ingress.yaml
```

Connect GitHub repo and create root app:

Generate a GitHub PAT at **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**. Scope it to only this repo with these permissions:
- **Contents** — Read-only (ArgoCD reads files from the repo)
- **Metadata** — Read-only (required by all fine-grained tokens)

That's it. ArgoCD only needs to clone/pull; it never pushes.

```bash
brew install argocd
argocd login argocd.local.lab --username admin --password <INITIAL_PASSWORD> --grpc-web

argocd repo add https://github.com/<YOUR_USERNAME>/homelab.git \
  --username <YOUR_USERNAME> \
  --password <GITHUB_PAT>

# Edit apps/argocd/bootstrap.yaml first — update repoURL with your GitHub username
kubectl apply -f apps/argocd/bootstrap.yaml
```

Change admin password and delete initial secret:

```bash
argocd account update-password \
  --current-password <INITIAL_PASSWORD> \
  --new-password <YOUR_NEW_PASSWORD>
kubectl -n argocd delete secret argocd-initial-admin-secret
```


---

<a id="prometheus-grafana"></a>
## 10 — Install Prometheus + Grafana + Alertmanager

Without observability you're flying blind — you won't know a node is running out of memory until pods start crashing, or a disk is filling up until Longhorn starts refusing writes. Prometheus scrapes real-time metrics from every node and pod; Grafana visualizes them in pre-built dashboards; Alertmanager fires notifications when thresholds are breached. Together they give you the full picture of what the cluster is doing at any moment.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=5Gi \
  --set grafana.adminPassword="<YOUR_GRAFANA_PASSWORD>" \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=5Gi \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.searchNamespace=ALL

kubectl get pods -n monitoring   # Takes 3-5 min
```

Expose Grafana and Prometheus:

```bash
kubectl apply -f apps/monitoring/ingresses.yaml
```


---

<a id="grafana-kiosk"></a>
## 11 — Grafana Kiosk on 1U Display

A rack with no display is just a box. The 1U LCD mounted in the rack can show a live Grafana cluster-health dashboard so you can see CPU, memory, and disk usage at a glance without opening a laptop. This turns the display from decorative hardware into a useful at-a-glance status panel.

Connect the 1U display to `ctrl-1` via micro-HDMI.

```bash
ssh pi@192.168.10.100

# Add grafana.local.lab to ctrl-1's own hosts file (needed for the kiosk browser)
# Also add to the cloud-init template so it survives reboots
echo '192.168.10.100  grafana.local.lab' | sudo tee -a /etc/hosts
sudo sed -i '/^::1 localhost/a 192.168.10.100  grafana.local.lab' /etc/cloud/templates/hosts.debian.tmpl

sudo apt install -y --no-install-recommends \
  xserver-xorg x11-xserver-utils xinit chromium unclutter

cat > ~/kiosk.sh << 'SCRIPT'
#!/bin/bash
xset s off && xset -dpms && xset s noblank
unclutter -idle 1 -root &
while true; do
  chromium \
    --noerrdialogs --disable-infobars --kiosk --incognito \
    --disable-translate --disable-features=TranslateUI \
    --ignore-certificate-errors \
    --force-device-scale-factor=1 \
    --window-size=1424,280 \
    "https://grafana.local.lab/d/homelab-kiosk/homelab-kiosk?orgId=1&refresh=10s&kiosk"
  sleep 2
done
SCRIPT
chmod +x ~/kiosk.sh

# Pi 5: force X to use the modesetting driver on the HDMI output,
# and set correct physical dimensions for the 6.91" 1424×280 display
# (EDID incorrectly reports 432×243mm causing Chromium to miscalculate viewport)
sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/99-pi5.conf > /dev/null << EOF
Section "Device"
    Identifier "Modesetting"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card1"
EndSection

Section "Monitor"
    Identifier "HDMI-1"
    DisplaySize 172 34
EndSection
EOF

echo '~/kiosk.sh' > ~/.xinitrc
echo '[[ -z $DISPLAY && $(tty) == /dev/tty1 ]] && startx -- -nocursor' >> ~/.bash_profile

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOF | sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I \$TERM
EOF
sudo systemctl daemon-reload && sudo systemctl restart getty@tty1
```

Enable anonymous Grafana viewer access for the kiosk — run this on your machine:

```bash
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --reuse-values \
  --set 'grafana.grafana\.ini.auth\.anonymous.enabled=true' \
  --set 'grafana.grafana\.ini.auth\.anonymous.org_role=Viewer'
```

**Grafana 12 note:** Dashboard-level permissions override org-level roles. Even with anonymous viewer access enabled, the kiosk dashboard will return 403 until you explicitly grant the Viewer role on it. Run this once after the helm upgrade:

```bash
# Get Grafana admin password
GRAFANA_PASS=$(kubectl get secret -n monitoring monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d)

curl -s -u "admin:${GRAFANA_PASS}" \
  -X POST "https://grafana.local.lab/api/dashboards/uid/homelab-kiosk/permissions" \
  -H "Content-Type: application/json" \
  -d '{"items":[{"role":"Viewer","permission":1}]}'
```


---

## Security Checklist


---

<a id="adguard"></a>
## 12 — AdGuard Home (Replace /etc/hosts with Wildcard DNS)

`/etc/hosts` only works on your machine. Any other device on the network — a phone, a tablet, another laptop — can't resolve `*.local.lab`. AdGuard Home is a DNS server that runs in the cluster and serves a wildcard rewrite (`*.local.lab → 192.168.10.100`) to every device that uses it for DNS.

This cluster does not use MetalLB — Traefik uses `hostPort` for HTTP/HTTPS (ports 80/443 directly on `ctrl-1`). AdGuard uses the same pattern: `hostPort: 53` pinned to `ctrl-1` (`192.168.10.100`), so DNS resolves at the same IP as your ingress. The admin UI is exposed via Ingress through Traefik as normal.

### Create the manifest

The manifest lives at [apps/adguard/adguard.yaml](apps/adguard/adguard.yaml). ArgoCD's root app recurses the `apps/` directory, so no additional ArgoCD Application is needed — committing the file is enough.

### Apply

ArgoCD will sync automatically on push. To apply manually:

```bash
kubectl apply -f apps/adguard/adguard.yaml
kubectl rollout status deployment/adguard-home -n adguard
```

### Complete the setup wizard

AdGuard requires a one-time setup wizard before it accepts DNS queries. Hit the setup UI directly on port 3000 (before Ingress routes to port 80):

```bash
# Port-forward to reach the setup wizard
kubectl port-forward -n adguard deployment/adguard-home 3000:3000
```

Open `http://localhost:3000` and complete the wizard:
1. Click **Get Started**
2. Leave listen interfaces as defaults → **Next**
3. Note the admin interface will move to port 80 after setup → **Next**
4. Set an admin username and password → **Next** → **Open Dashboard**

After the wizard, the admin UI is available at `https://adguard.local.lab` (once DNS is working — until then, port-forward to port 80).

### Configure DNS rewrite

In the AdGuard admin UI:
1. **Filters → DNS rewrites → Add DNS rewrite**
   - Domain: `*.local.lab`
   - IP: `192.168.10.100`
2. **Settings → DNS settings → Upstream DNS servers**: set `https://dns10.quad9.net/dns-query`
3. (Optional) **Filters → DNS blocklists**: disable all lists if you only want DNS rewriting without ad blocking

### Point your network at AdGuard

In **UniFi Network → Settings → Networks → your LAN → DHCP**:
- DNS Server 1: `192.168.10.100`
- DNS Server 2: `1.1.1.1` (fallback for when ctrl-1 is rebooting)

Reconnect any device to pick up the new DNS, or wait for DHCP lease renewal.

### Update ctrl-1's own DNS

`ctrl-1` also needs to resolve `*.local.lab`. Add AdGuard as its nameserver:

```bash
ssh pi@192.168.10.100
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
# Lock it so dhclient doesn't overwrite it
sudo chattr +i /etc/resolv.conf
```

### Trust the local CA on your devices

The TLS cert for `*.local.lab` is signed by your local cert-manager CA. Browsers will warn until you install and trust it:

**machine:**
```bash
# Export the CA cert
kubectl get secret -n cert-manager local-lab-ca-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/local-lab-ca.crt
# Import and trust
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/local-lab-ca.crt
```

**iPhone/iPad:** AirDrop the `.crt` file to the device → Settings will prompt to install the profile → go to **Settings → General → VPN & Device Management** and install it → **Settings → General → About → Certificate Trust Settings** and enable full trust.

### Clean up /etc/hosts

Once `*.local.lab` resolves correctly from your machine:

```bash
# Verify AdGuard is resolving correctly first
dig grafana.local.lab @192.168.10.100

# Then remove the /etc/hosts entries
sudo sed -i '' '/\.local\.lab/d' /etc/hosts
```


---

<a id="longhorn-backups"></a>

<a id="tailscale"></a>
## 13 — Tailscale (Remote Access)

Without this, `kubectl`, `ssh`, and `*.local.lab` only work when you're on the home network. Tailscale creates an encrypted mesh VPN — no port forwarding, no exposed firewall ports, works from any network. Install it on `ctrl-1` as a subnet router so your Mac can reach the entire `192.168.10.0/24` cluster subnet remotely.

### Create a Tailscale account

Sign up at [tailscale.com](https://tailscale.com) — free tier supports up to 100 devices.

### Install on ctrl-1

```bash
ssh pi@192.168.10.100
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-routes=192.168.10.0/24 --accept-dns=false
```

The `--accept-dns=false` prevents Tailscale from overwriting ctrl-1's DNS (it already points at itself via AdGuard).

Copy the auth URL printed to stdout and open it in a browser to approve the device.

### Approve subnet route in Tailscale admin

In the [Tailscale admin console](https://login.tailscale.com/admin/machines):
1. Find `ctrl-1` → **Edit route settings**
2. Enable `192.168.10.0/24`

### Install on your Mac

```bash
brew install --cask tailscale
```

Open Tailscale from the menu bar → sign in → **Enable subnet routes** when prompted (or via Tailscale menu → **Use exit node / subnets**).

### Configure split DNS

In the [Tailscale admin console](https://login.tailscale.com/admin/dns) → **Nameservers → Add nameserver → Custom**:
- Nameserver: `192.168.10.100`
- Restrict to domain: `local.lab`

This makes `*.local.lab` resolve via AdGuard only for that domain, leaving all other DNS unaffected.

### Verify

```bash
# Disconnect from home WiFi or use a hotspot, then:
ssh pi@192.168.10.100
kubectl get nodes
curl -sk https://adguard.local.lab -o /dev/null -w "%{http_code}"
```


---

<a id="crossplane"></a>
## 14 — Install Crossplane

Running `helm install` for each app works fine for a handful of services, but it doesn't give you a reusable, self-service API. Crossplane extends Kubernetes so you can define infrastructure (databases, apps, DNS records, cloud resources) as custom Kubernetes resources — the same declarative model you use for Deployments and Services. This is the foundation that makes the `XWordPressPlatform` XR in step 16 possible.

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable && helm repo update

helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace

kubectl get pods -n crossplane-system
```

Install functions:

```bash
kubectl apply -f apps/crossplane/providers.yaml
kubectl get functions   # Wait for HEALTHY: True — both function-patch-and-transform and function-go-templating
```

Grant Crossplane RBAC to compose native Kubernetes resources:

```bash
kubectl apply -f apps/crossplane/rbac.yaml
```
