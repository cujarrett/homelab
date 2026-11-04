# Upgrading k3s

Each node gets the new k3s binary swapped in place, then a service restart. Set one version
variable and paste the blocks in order. `ctrl-1` goes first, then the agents one at a time.

The install script is skipped on purpose. It rewrites the systemd unit and drops any flag you
forget. A binary swap leaves the unit, its flags and its drop-ins alone.

| Chapter | What it covers |
|---|---|
| [Pre-flight](#pre-flight) | Checks before touching any node |
| [Upgrading the nodes](#upgrading-the-nodes) | Drain, swap, restart, uncordon, one node at a time |
| [Verification](#verification) | Checks that catch silent breakage |
| [Known traps](#known-traps) | Failures seen before, and how to spot them fast |
| [Rollback](#rollback) | Moving a node back to the previous version |

---

## Pre-flight

Set the target version. This is the only line you edit each time.

```bash
export K3S_VERSION=v1.37.2+k3s1
```

Check the release is final and see which bundled components it bumps. Traefik, CoreDNS and
containerd bumps are what break this cluster. The Kubernetes version itself rarely does.

```bash
gh release view $K3S_VERSION --repo k3s-io/k3s --json isPrerelease -q .isPrerelease   # must print false
gh release view $K3S_VERSION --repo k3s-io/k3s | grep -iE 'traefik|coredns|containerd|flannel|kube-router'
```

`true` means k3s has not promoted the release yet. Stop and wait. Empty component output means
the notes are not filled in yet. Wait for those too.

Confirm the cluster can lose a node. Every Longhorn volume must read `healthy`, because a
degraded volume has no spare replica.

```bash
kubectl get nodes -o wide
kubectl get volumes.longhorn.io -n longhorn-system --no-headers -o custom-columns=R:.status.robustness | sort | uniq -c
kubectl get applications.argoproj.io -A
```

---

## Upgrading the nodes

Paste this function once into your shell. It works in zsh and bash.

```bash
upgrade_node() {
  local node=$1 ip=$2 svc=$3
  local url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}"

  kubectl cordon "$node"
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=300s || return 1

  ssh "pi@$ip" "set -e; cd /tmp
    curl -sfLo k3s-arm64 $url/k3s-arm64
    curl -sfL $url/sha256sum-arm64.txt | grep ' k3s-arm64\$' | sha256sum -c
    sudo install -m 755 k3s-arm64 /usr/local/bin/k3s
    rm k3s-arm64
    sudo systemctl restart $svc" || return 1

  echo "waiting for $node to report $K3S_VERSION"
  until [ "$(kubectl get node "$node" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)" = "$K3S_VERSION" ]; do sleep 5; done
  kubectl wait --for=condition=Ready "node/$node" --timeout=300s
  ssh "pi@$ip" "systemctl show $svc -p NRestarts"
  kubectl uncordon "$node"
}
```

The `ssh` block runs on the node and replaces the k3s binary.

- **`set -e; cd /tmp`:** stop at the first failure and work in a scratch folder.
- **First `curl`:** downloads the new k3s binary for ARM64.
- **Second `curl` line:** fetches the release's checksum list and keeps the `k3s-arm64` line. `sha256sum -c` then checks the download against it. A corrupt or partial file stops everything here.
- **`install -m 755`:** copies the binary over `/usr/local/bin/k3s` and makes it executable.
- **`rm`:** cleans up the download.
- **`systemctl restart $svc`:** restarts `k3s` or `k3s-agent`, so it runs the new binary.
- **`|| return 1`:** if any step fails, the function stops. The node stays cordoned and nothing gets uncordoned.

Your shell fills in `$url` and `$svc` before sending the command. The `\$` reaches the node as
`$`, which tells `grep` to match only a line ending in `k3s-arm64`.

Then run one node at a time. Run the [Verification](#verification) checks after each one.
Before the next node, wait until the Longhorn line reads only `healthy`.

```bash
upgrade_node ctrl-1 192.168.10.100 k3s
```

```bash
upgrade_node work-1 192.168.10.101 k3s-agent
```

```bash
upgrade_node work-2 192.168.10.102 k3s-agent
```

```bash
upgrade_node work-3 192.168.10.103 k3s-agent
```

What to expect:

- **API outage on ctrl-1:** `kubectl` fails for about a minute while it restarts. The wait loop rides it out. Running pods and public sites stay up.
- **Slow drain:** Longhorn's `instance-manager` refuses eviction for a minute or two. That is normal.
- **`NRestarts` above 0:** the service is crash-looping even if the node shows Ready. Check `journalctl -u k3s` on the node for the `Shutdown request received` line.

---

## Verification

Run these after each node.

```bash
kubectl get nodes -o wide

# Running but not ready. A 0/1 Running pod passes a plain "grep -v Running".
kubectl get pods -A --no-headers | awk '{split($3,a,"/"); if ($4=="Running" && a[1]!=a[2]) print}'

# Two running pods on one address. Expect no output. See Known traps.
kubectl get pods -A --field-selector status.phase=Running -o \
  jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | grep '^10\.42\.' | sort | uniq -d

kubectl get pods -A --no-headers | grep -vE "Running|Completed"
kubectl get applications.argoproj.io -A
kubectl get volumes.longhorn.io -n longhorn-system --no-headers -o custom-columns=R:.status.robustness | sort | uniq -c

for u in \
  https://mattjarrett.com \
  https://kentjarrett.com \
  https://mattjarrett.dev \
  https://blog.mattjarrett.dev \
  https://myvinyl.mattjarrett.dev \
  https://jspollock.mattjarrett.dev \
  https://launchpad.mattjarrett.dev \
  https://connections.mattjarrett.dev \
  https://graph.mattjarrett.dev \
  https://argocd.local.lab \
  https://grafana.local.lab \
  https://prometheus.local.lab \
  https://longhorn.local.lab \
  https://adguard.local.lab
do echo "$u $(curl -sk --netrc-optional -o /dev/null -w '%{http_code}' $u --max-time 10 -A 'Mozilla/5.0')"
done
```

Reading the URL check:

- **200 or 302:** up. Prometheus and AdGuard redirect their own root.
- **401 on prometheus or longhorn:** your `~/.netrc` entry is missing. They sit behind basicAuth.
- **503 on a Spa:** a mesh pod is in ReplicaSet backoff for up to five minutes after uncordon. See [Postmortem: istiod Drain Outage](../postmortems/postmortem-istiod-drain-outage.md).

Then confirm `longhorn-manager` and both WordPress deployments are Ready. They sit behind
NetworkPolicies, so they catch dropped kubelet probes. See
[Kubelet Probe Outage](../postmortems/postmortem-kubelet-probe-outage.md).

---

## Known traps

**Traefik CRDs fail to adopt.** k3s bundles Traefik and bumps its chart across releases. If the
CRDs lack Helm ownership metadata, the install job fails and the Traefik DaemonSet is removed.
All ingress goes down. The symptom is `helm-install-traefik*` jobs in `CrashLoopBackOff` and no
`traefik` DaemonSet.

```bash
kubectl get crd -o name | grep 'traefik\.io' | xargs -I{} kubectl label {} app.kubernetes.io/managed-by=Helm --overwrite
kubectl get crd -o name | grep 'traefik\.io' | xargs -I{} kubectl annotate {} meta.helm.sh/release-name=traefik-crd meta.helm.sh/release-namespace=kube-system --overwrite
kubectl delete job -n kube-system helm-install-traefik helm-install-traefik-crd
```

**Duplicate pod IPs.** Restarting k3s on ctrl-1 without a drain can give two pods one IP. The
loser shows `Running` but `0/1`, with no restarts. The duplicate-IP check in Verification finds
it. Delete the newer pod so it gets a fresh address. Flushing ARP does not fix it.

---

## Rollback

Set the previous version and run the same function on the node.

```bash
export K3S_VERSION=v1.37.1+k3s1
upgrade_node work-1 192.168.10.101 k3s-agent
```

Roll back agents before `ctrl-1`, so no agent runs newer than the server.

---

## Related Docs

- [Cluster](../cluster.md): current stack and hardware
- [Kubelet Probe Outage](../postmortems/postmortem-kubelet-probe-outage.md): why several checks above exist
