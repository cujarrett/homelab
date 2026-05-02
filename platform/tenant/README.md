# Tenant

A tenant is a directory under `tenants/` at the repo root. ArgoCD creates one Application per tenant directory via the `xrs` ApplicationSet.

## Repo layout

```
tenants/
  foo/
    .gitkeep       ← permanent git anchor; keeps the directory alive when all yaml files are removed
    namespace.yaml ← plain Namespace — remove to deprovision tenant
    api.yaml       ← XApi (optional)
    spa.yaml       ← XSpa (optional)
```

The `.gitkeep` file prevents a race condition: if the directory disappears from git, ArgoCD cannot render the desired state and the Application finalizer cannot fire cleanly, leaving Crossplane resources orphaned.

## namespace.yaml

A plain Kubernetes Namespace. No Crossplane required.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: foo
```

Add `ResourceQuota`, `LimitRange`, or `RoleBinding` manifests to the same directory as needed.

## Lifecycle

```bash
# Add a workload
git add tenants/foo/api.yaml && git commit -m "add foo api" && git push

# Remove a workload — ArgoCD prunes XApi, Crossplane cascade-deletes composed resources
git rm tenants/foo/api.yaml && git commit -m "remove foo api" && git push

# Deprovision the full tenant — remove namespace.yaml; leave .gitkeep
git rm tenants/foo/namespace.yaml && git commit -m "deprovision foo" && git push
# ArgoCD finalizer fires: deletes all managed resources, then deletes the Application

# Optional cosmetic cleanup after everything is gone
git rm tenants/foo/.gitkeep && git commit -m "clean up foo" && git push
```

## Operations

```bash
# Confirm namespace exists
kubectl get namespace foo

# List all ArgoCD Applications (one per tenant)
kubectl get applications -n argocd
```
