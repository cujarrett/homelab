---
description: Pre-pull the AdGuard image on ctrl-1 before merging a Renovate PR, to avoid ImagePullBackOff caused by the DNS chicken-and-egg with the Recreate rollout strategy
---

AdGuard runs on `ctrl-1` with `strategy: Recreate` and `hostPort: 53`. Because `ctrl-1`'s `/etc/resolv.conf` points only at `127.0.0.1` (AdGuard itself), the Recreate strategy kills the old pod before the new one starts - leaving the node with no DNS and unable to pull the new image from Docker Hub.

**Always pre-pull the new image on `ctrl-1` before merging the Renovate PR.**

## Steps

1. Find the new image tag from the open Renovate PR (e.g. `v0.107.74`).

2. Pre-pull the image on `ctrl-1`:

```bash
ssh pi@192.168.10.100 "sudo ctr -n k8s.io image pull docker.io/adguard/adguardhome:<new-tag>"
```

3. Verify the image is present:

```bash
ssh pi@192.168.10.100 "sudo ctr -n k8s.io image ls | grep adguardhome"
```

4. Merge the Renovate PR. ArgoCD will sync, Recreate will kill the old pod, and the new pod will start immediately from the cached image - no DNS required.

5. Confirm healthy:

```bash
k get pods -n adguard
k get app adguard -n argocd
```
