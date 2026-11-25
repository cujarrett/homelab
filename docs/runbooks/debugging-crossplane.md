# Debugging Crossplane

Use this when an XR is not syncing or not ready. Work top-down. Each step points to the next clue.

## 1. Check the XR

```bash
kubectl get apis.platform.local.lab <name> -n <namespace>
```

| Column | What it means |
|---|---|
| `SYNCED=True` | The composition ran without errors |
| `SYNCED=False` | The composition failed. Read the conditions in step 2 |
| `READY=True` | Every composed resource is ready |
| `READY=<blank>` | Children are still provisioning or failing |

## 2. Read the XR conditions

This is usually the most direct error. Look at `reason` and `message` on any condition with `"status": "False"`.

```bash
kubectl get apis.platform.local.lab <name> -n <namespace> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## 3. Check the sub-XRs

Api composes a `Cache` sub-XR, `<name>-cache`, when the cache is on. Object storage, Sql and NoSql are separate XRs the Api names in its refs. Check those the same way.

```bash
kubectl get caches.platform.local.lab <name>-cache -n <namespace>
kubectl get caches.platform.local.lab <name>-cache -n <namespace> \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## 4. Check all managed resources

Managed resources (MRs) are the real AWS and Entra objects. Look for `SYNCED=False` or `READY=False` on any row.

```bash
kubectl get managed -A | grep <name>
```

`describe` shows Events at the bottom. They often hold the AWS API error.

```bash
kubectl describe bucket.s3.aws.m.upbound.io <mr-name> -n <namespace>
kubectl describe role.iam.aws.m.upbound.io <mr-name> -n <namespace>

# conditions only
kubectl get bucket.s3.aws.m.upbound.io <mr-name> -n <namespace> \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## 5. Check the provider pod logs

Go here when the conditions say little.

```bash
kubectl get pods -n crossplane-system | grep provider-aws
kubectl logs -n crossplane-system -l pkg.crossplane.io/revision --tail=100 | grep <name>
```

## 6. Check the Crossplane core logs

Composition pipeline errors from function-go-templating and function-environment-configs show up here.

```bash
kubectl logs -n crossplane-system -l app=crossplane --tail=100
```

## 7. Check the binding secrets

The XR can be Ready while the pod waits in an init container for a binding secret. Each binding has its own secret in the XR's namespace.

| Binding | Secret name |
|---|---|
| Object storage | `<name>-<ref>`, where `<ref>` is a name in `objectStorageRefs` |
| NoSql | `<name>-nosql` |
| Cache | `<name>-cache` |
| Sql | The Sql XR's name for `private-cloud`, `<name>-sql` for `public-cloud` |
| Managed secret | `<name>-secret-<ref>`, where `<ref>` is a name in `managedSecretRefs` |

Every binding secret has `type` and `provider` keys. The init container waits for `type`.

```bash
kubectl get secret -n <namespace>
kubectl get secret <secret-name> -n <namespace> \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```

## 8. Check the pod

Each init container is named `wait-for-<dir>-binding`. `<dir>` is `object-storage-<ref>`, `sql`, `nosql`, `cache` or `managed-secret-<ref>`. `describe` lists them.

```bash
kubectl get pods -n <namespace>
kubectl describe pod -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name> --previous   # if it crashed
kubectl logs -n <namespace> <pod-name> -c wait-for-<dir>-binding   # init container logs
kubectl logs -n <namespace> <pod-name> -c workload-identity-sidecar   # cloud credential logs
```

## Common failure patterns

| Symptom | Likely cause | Where to look |
|---|---|---|
| `SYNCED=False` on XR | Composition pipeline error | Step 2 |
| `SYNCED=False` on MR | AWS API error, such as permissions, quota or bad config | Step 4 events |
| `READY=False` on MR | AWS resource not in its desired state yet | Step 4 conditions |
| `READY=<blank>` on XR | Children still provisioning | `kubectl get managed -A \| grep <name>` |
| Pod stuck in `Init` | Binding secret missing or incomplete | Steps 7 and 8 |
| Pod `CrashLoopBackOff` | App error, not a platform error | `kubectl logs` on the main container |
| ArgoCD `SyncError: auto-sync will wipe out all resources` | The sync would delete every resource | Add `allowEmpty=true` to syncOptions |
