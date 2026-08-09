# Kubernetes the Hard Way

CKAD covers the object model. The hard way teaches the control plane, which CKAD never did.

Source: <https://github.com/kelseyhightower/kubernetes-the-hard-way>

**The Linux underneath** — do this first, or alongside the PKI work. Everything the hard way asks you to assemble by hand is a Linux primitive wearing a Kubernetes name.

- Processes — `/proc`, `ps -eo`, signals, exit codes
- Namespaces and cgroups — `unshare -Urnm`, `lsns`, then `cat /proc/<pid>/cgroup` on a running Pi container. This is what a "container" actually is.
- systemd — units, `journalctl -u`, `systemctl cat`. Real material already exists: `getty@tty1.service` on `ctrl-1` and the k3s units.

**Setup** — do not do this on the live cluster. Use VMs (Multipass or Lima on the Mac), or one spare Pi plus VMs. The current version of the guide targets a single machine with a few VMs, which fits.

**PKI and etcd**

- Generate every cert by hand; understand why each CN and SAN exists
- Stand up etcd, then use `etcdctl` to read a Secret straight out of the store, unencrypted. That one moment changes how Secrets feel forever.

**Control plane and node bootstrap**

- apiserver, controller-manager, scheduler as raw systemd units — where the systemd reading pays off
- kubelet TLS bootstrap, RBAC for node identity, kubeconfig anatomy
- containerd and CNI by hand; compare against what Cilium does automatically

**Rebuild kubectl reflexes**

Twenty minutes a day, no docs:

```
kubectl get -o jsonpath / -o custom-columns / --sort-by
kubectl explain <resource>.spec --recursive
kubectl api-resources / kubectl api-versions
kubectl auth can-i --as system:serviceaccount:...
kubectl get --raw /api/v1/namespaces/default/pods
kubectl debug / kubectl port-forward / kubectl cp
```

Then run `kubectl get spa -A -o yaml` against the homelab and read it as an API object, not as "my app".

**Check yourself** — two questions, no docs:

- Delete the scheduler from the hard-way cluster and predict, before looking, exactly what breaks and what does not.
- Explain why `pkill chromium` does not change the kiosk URL on `ctrl-1`, in terms of process parentage and the shell's `while` loop.
