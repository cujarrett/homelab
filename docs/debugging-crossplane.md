# Debugging Crossplane

A layered workflow for diagnosing why an XR isn't syncing or ready. Work top-down — each layer reveals the next clue.

## 1. Start at the top — check the XR

```bash
kubectl get xapi <name>
```

| Column | What it means |
|---|---|
| `SYNCED=True` | Composition ran without errors |
| `SYNCED=False` | Composition failed — check XR events/conditions |
| `READY=True` | All composed resources are ready |
| `READY=<blank>` | Readiness not yet propagated — children still provisioning or failing |

## 2. Read the XR conditions

```bash
kubectl get xapi <name> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

Look for `"reason"` and `"message"` on any condition where `"status": "False"`. This is usually the most direct error message.

Example output for a composition pipeline error:
```json
[
  {
    "type": "Synced",
    "status": "False",
    "reason": "ReconcileError",
    "message": "cannot compose resources: pipeline step \"go-templating\": ..."
  }
]
```

## 3. Check the sub-XRs

XApi composes an `XObjectStorage` sub-XR. Check it directly:

```bash
kubectl get xobjectstorage <name>-object-storage
kubectl get xobjectstorage <name>-object-storage \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## 4. Check all managed resources

Managed resources (MRs) are the actual AWS objects. List everything owned by the XR:

```bash
kubectl get managed | grep <name>
```

Look for `SYNCED=False` or `READY=False` on any row. Then drill in:

```bash
# Describe gives you Events at the bottom — often has the AWS API error
kubectl describe bucket.s3.aws.upbound.io <mr-name>
kubectl describe user.iam.aws.upbound.io <mr-name>
kubectl describe accesskey.iam.aws.upbound.io <mr-name>
kubectl describe userpolicyattachment.iam.aws.upbound.io <mr-name>
```

Or get just the conditions on a specific MR type:

```bash
kubectl get bucket.s3.aws.upbound.io <mr-name> \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

## 5. Check the provider pod logs

If conditions are unhelpful, go to the provider itself:

```bash
# Find the provider pod
kubectl get pods -n crossplane-system | grep upbound-provider-aws

# Tail logs — filter to your resource name
kubectl logs -n crossplane-system -l pkg.crossplane.io/revision --tail=100 | grep <name>
```

## 6. Check the Crossplane core logs

For composition pipeline errors (function-go-templating, function-patch-and-transform):

```bash
kubectl logs -n crossplane-system -l app=crossplane --tail=100
```

## 7. Check the binding secret

If the XR says Ready but the pod won't start, the init container may be waiting on the binding secret:

```bash
# Does the secret exist?
kubectl get secret <name>-object-storage -n <name>

# If it exists, does it have all 6 keys?
kubectl get secret <name>-object-storage -n <name> \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```

Expected keys: `type`, `provider`, `bucket`, `region`, `username`, `password`

## 8. Check the pod

```bash
kubectl get pods -n <name>
kubectl describe pod -n <name> <pod-name>
kubectl logs -n <name> <pod-name> --previous   # if it crashed
kubectl logs -n <name> <pod-name> -c init-object-storage   # init container logs
```

---

## Common failure patterns

| Symptom | Likely cause | Where to look |
|---|---|---|
| `SYNCED=False` on XR | Composition pipeline error | XR conditions (step 2) |
| `SYNCED=False` on MR | AWS API error (permissions, quota, invalid config) | MR describe events (step 4) |
| `READY=False` on MR | AWS resource not yet in desired state | MR conditions (step 4) |
| `READY=<blank>` on XR | Children still provisioning | `kubectl get managed \| grep <name>` |
| Pod stuck in `Init` | Binding secret missing or incomplete | Step 7 + step 8 init container logs |
| Pod `CrashLoopBackOff` | App error, not a platform error | `kubectl logs` on the main container |
| ArgoCD `SyncError: auto-sync will wipe out all resources` | Would delete all resources — add `allowEmpty=true` to syncOptions | ArgoCD app details |

## Worked example

Starting point:

```
NAME                   SYNCED   READY   COMPOSITION   AGE
platform-api-starter   False            xapi          5m52s
```

`SYNCED=False` means the composition pipeline failed. Start at step 2:

```bash
kubectl get xapi platform-api-starter \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

Read the `message` on the `Synced` condition — it will tell you which pipeline step failed and why. If the error mentions a managed resource (e.g. `bucket`, `user`), jump to step 4 and describe that MR. If it mentions a function (e.g. `go-templating`), check Crossplane core logs (step 6).
