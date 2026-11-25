# cluster/

ArgoCD manages everything here. The bootstrap app-of-apps applies every Application manifest in `cluster/argocd/`, without recursing.

```
cluster/
  argocd/       ← Every ArgoCD Application manifest lives here. Always.
  <app>/        ← Raw manifests for apps that need them. Not every app has one.
```

## Which file an app gets

| The app needs | It gets |
|---|---|
| Name, path and namespace only | A row in [cluster-apps.yaml](argocd/cluster-apps.yaml), with no file of its own |
| A Helm chart, a second source or its own `ignoreDifferences` | A hand-written Application in `cluster/argocd/` |
| Pure Helm with no extra manifests | Only its Application file. No subfolder |

## When does an app get a subfolder?

An app gets a subfolder when it needs raw Kubernetes manifests that Helm values can't express, such as a `Certificate`, `ServiceMonitor`, `Ingress` or custom `ConfigMap`. Its Application uses ArgoCD multi-source to point at both the chart and the subfolder.

```yaml
sources:
  - repoURL: https://some-helm-repo/
    chart: some-chart
  - repoURL: https://github.com/cujarrett/homelab.git
    path: cluster/<app>       # raw manifests go here
```
