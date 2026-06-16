# cluster/

Everything here is managed by ArgoCD. The bootstrap app-of-apps recurses `cluster/argocd/` on startup and discovers all Application manifests automatically.

## Structure

```
cluster/
  argocd/       ← Every ArgoCD Application manifest lives here. Always.
  <app>/        ← Raw manifests for apps that need them. Not every app has one.
```

## When does an app get a subfolder?

An app gets a subfolder under `cluster/` when it needs **raw Kubernetes manifests** that can't be expressed in Helm values alone — things like `Certificate`, `ServiceMonitor`, `Ingress`, or custom `ConfigMap` resources.

Those apps use ArgoCD's multi-source feature, pointing at both the Helm chart and the subfolder:

```yaml
sources:
  - repoURL: https://some-helm-repo/
    chart: some-chart
  - repoURL: https://github.com/cujarrett/homelab.git
    path: cluster/<app>       # raw manifests go here
```

If an app is **pure Helm with no extra manifests**, it only needs its Application file in `cluster/argocd/`. No subfolder.
