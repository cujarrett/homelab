---
description: Verify host-to-pod probe connectivity after any Cilium change or k3s upgrade, before merging a Renovate PR or trusting a values edit
---

Kubelet probes travel from a node's host namespace to a local pod, and that path is fragile:
it broke once because two NetworkPolicy controllers were fighting, and Cilium 1.20.x cannot
attach its SNAT program on this kernel at all. When it breaks, pods stay `NotReady` forever
while serving traffic perfectly - see
[Kubelet Probe Outage postmortem](../../docs/postmortem-kubelet-probe-outage.md).

Run this after any Cilium version bump, Cilium values change, or k3s upgrade.

## 1. Confirm the running agent picked up the config

Cilium reads `cilium-config` at startup. A values-only change does **not** restart the
DaemonSet, so the ConfigMap and the running agent can disagree indefinitely. Read the flag
back from the agent, never from the ConfigMap:

```bash
CIL=$(kubectl get pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=work-3 -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n kube-system $CIL -c cilium-agent | grep -E "enable-bpf-masquerade|enable-wireguard"
```

If it disagrees with [cilium.yaml](../../cluster/argocd/cilium.yaml), force the rollout:
`kubectl rollout restart ds/cilium -n kube-system`. A DaemonSet reporting `4/4 ready` proves
nothing - unrestarted pods are ready too. Check pod start times against the change.

## 2. Confirm host routing and that k3s is not enforcing policy

`Host: BPF` is required; `Host: Legacy` means BPF host routing was disabled. There must also
be no kube-router jump rules - k3s re-enables its policy controller if
`disable-network-policy` is lost from `/etc/rancher/k3s/config.yaml` on the server.

```bash
for NODE in ctrl-1 work-1 work-2 work-3; do
  C=$(kubectl get pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
  echo -n "$NODE "; kubectl exec -n kube-system $C -- cilium status | grep "^Routing"
  echo -n "  kube-router jumps: "; kubectl exec -n kube-system $C -- iptables -t filter -L OUTPUT -n | grep -c KUBE-ROUTER
done
```

Every node must show `Host: BPF` and `0` jumps.

## 3. Confirm a real probe reaches a policy-selected pod

Use a pod **with** a NetworkPolicy - that is the case that breaks. A pod without one passes
even when the datapath is broken, so it proves nothing.

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: cnicheck-policy, namespace: default}
spec:
  podSelector: {matchLabels: {app: cnicheck}}
  ingress:
    - from: [{namespaceSelector: {}}]
      ports: [{port: 80, protocol: TCP}]
EOF
kubectl run cnicheck --image=nginx:alpine --restart=Never --labels=app=cnicheck \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"work-3"}}}'
kubectl wait --for=condition=ready pod/cnicheck --timeout=120s
IP=$(kubectl get pod cnicheck -o jsonpath='{.status.podIP}')
ssh pi@192.168.10.103 "curl -s --max-time 4 -o /dev/null -w '%{http_code}\n' http://$IP:80/"
kubectl delete pod cnicheck; kubectl delete netpol cnicheck-policy
```

`200` means the path is healthy - safe to merge. A hang or `000` means it is broken; trace it
and do not merge:

```bash
kubectl exec -n kube-system $CIL -- timeout 8 cilium monitor --type drop -v
```

`identity world->...` on the probe port means the host mark is being lost - check step 2 for
kube-router jumps first, since that is the known cause. For deeper digging, `cilium config
Debug=Enable` is runtime-settable (no restart) and `cilium monitor -v -v` then names the
identity decision directly; set it back to `Disable` afterwards.
