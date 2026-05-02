# ctrl-1 k3s Memory Tuning

Applied manually via SSH — not managed by GitOps.

## What was done

### 1. Go GC tuning

File: `/etc/systemd/system/k3s.service.d/override.conf` on ctrl-1

```ini
[Service]
Environment=GOGC=50
```

Makes Go GC trigger at 1.5x live heap instead of 2x (default GOGC=100).
GC runs ~2x as often, keeping memory lower at the cost of slightly more CPU
(k3s sits at ~5% CPU — plenty of headroom on Pi 5).

**Note:** `target-ram-mb` was attempted as a `kube-apiserver-arg` but k3s v1.34
does not support that flag — it causes k3s to fail to start. Do not use it.

## Why

k3s server process was consuming ~2.6Gi RSS after 23 days of uptime.
Go's GC doesn't eagerly return freed memory to the OS; this tuning reduces
how large the heap grows between GC cycles.

## How to apply (if re-applying after a node rebuild)

```bash
ssh pi@192.168.10.100

sudo mkdir -p /etc/systemd/system/k3s.service.d
sudo tee /etc/systemd/system/k3s.service.d/override.conf << 'EOF'
[Service]
Environment=GOGC=50
EOF

sudo systemctl daemon-reload
# Use k3s-killall.sh + start — systemctl restart fails if containerd-shims are running
sudo k3s-killall.sh && sudo systemctl start k3s
```

API server is unavailable for ~60-120s. Workloads on workers keep running.

## How to revert

```bash
ssh pi@192.168.10.100
sudo rm /etc/systemd/system/k3s.service.d/override.conf
sudo systemctl daemon-reload
sudo k3s-killall.sh && sudo systemctl start k3s
```

## Observed results

| When | k3s RSS | Available |
|---|---|---|
| Before (23d uptime, no tuning) | ~2.6Gi | 3.5Gi |
| After restart + GOGC=50 | ~0.5Gi (fresh start) | 6.4Gi |
