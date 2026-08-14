# crossplane-entra App Registration

Crossplane's Azure AD provider authenticates as its own Entra app registration
(`crossplane-entra`), via a client secret in the `azuread-creds` Secret in
`crossplane-system`. Not managed by Crossplane itself — must exist first. If it's ever
lost or recreated, redo the four steps below.

## 1. Create the app registration

```bash
az ad app create --display-name "crossplane-entra" --sign-in-audience AzureADMyOrg
az ad sp create --id <appId-from-previous-command>
```

No redirect URI — this is a backend app, nothing signs into it. The service principal
is required; without it there's nothing for a permission grant or federated credential
to attach to later.

## 2. Grant Graph API permission

```bash
az ad app permission add --id <appId> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role
az ad app permission admin-consent --id <appId>
```

That's `Application.ReadWrite.OwnedBy`. Needs a Global Administrator or Application
Administrator to run `admin-consent`.

`admin-consent` can report success before the grant actually exists — Entra's own
replication lag. Don't trust the exit code; check directly:

```bash
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/<sp-object-id>/appRoleAssignments"
```

Empty `value: []` means it hasn't landed yet. Wait and recheck.

## 3. Create a client secret

```bash
az ad app credential reset --id <appId> --display-name "crossplane" --years 1 --query "password" -o tsv
```

Set an expiry and track it somewhere — no rotation automation on this side yet. Capture
the output straight into a shell variable; never let it land in a file that outlives
the command.

## 4. Create the Kubernetes Secret

```bash
kubectl create secret generic azuread-creds -n crossplane-system \
  --from-literal=credentials='{"clientId":"<app-registration-client-id>","clientSecret":"<the-secret-value>","tenantId":"<entra-tenant-id>"}'
```

---

## Heads up for whoever builds the composition later

`crossplane-entra` can create Entra apps but not delete or update them, unless each one
is created with an explicit owner. The API — CLI or Crossplane, doesn't matter who's
driving — never assigns an owner on its own; only the interactive Entra portal does
that, as something the web page adds, not the API itself. So every `Application` the
future composition creates needs:

```yaml
spec:
  forProvider:
    owners:
      - <crossplane-entra-service-principal-object-id>
```

Skip it and the registration can be created once, then never touched again.

## What is NOT managed here

- The `azuread-creds` Secret — created manually, never stored in Git, same bootstrap
  pattern as `aws-creds` (see [aws-iam-policy.md](./aws-iam-policy.md)).
- The Entra tenant itself, and who holds admin rights to grant consent.
