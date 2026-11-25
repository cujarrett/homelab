# crossplane-entra App Registration

Crossplane's Azure AD provider signs in as the Entra app registration `crossplane-entra`. Its client secret lives in the `azuread-creds` Secret in `crossplane-system`. Crossplane does not manage this app, so create it first. If it is lost or recreated, redo the four steps below.

## 1. Create the app registration

```bash
az ad app create --display-name "crossplane-entra" --sign-in-audience AzureADMyOrg
az ad sp create --id <appId-from-previous-command>
```

It needs no redirect URI, since nothing signs into it. The service principal is required. Permission grants and federated credentials attach to it.

## 2. Grant Graph API permission

```bash
az ad app permission add --id <appId> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions 18a4783c-866b-4cc7-a460-3d5e5662c884=Role
az ad app permission admin-consent --id <appId>
```

| Item | Detail |
|---|---|
| Permission | `Application.ReadWrite.OwnedBy`. |
| Who consents | A Global Administrator or Application Administrator. |
| Exit code | `admin-consent` can report success before Entra has saved the grant. Check it directly. |

```bash
az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/<sp-object-id>/appRoleAssignments"
```

An empty `value: []` means the grant has not landed yet. Wait and check again.

## 3. Create a client secret

```bash
az ad app credential reset --id <appId> --display-name "crossplane" --years 1 --query "password" -o tsv
```

- **Expiry:** set one and track it. Nothing rotates it on its own.
- **Output:** capture it straight into a shell variable. Never let it land in a file that outlives the command.

## 4. Store it in Parameter Store

External Secrets renders `azuread-creds` from this parameter. See [External Secrets](../../docs/external-secrets.md) to stage the value without it touching shell history.

```bash
aws ssm put-parameter --name /homelab/crossplane-system/azuread-credentials --type SecureString --overwrite \
  --region us-east-1 --value "$(cat local-only/eso/value.txt)" && rm -P local-only/eso/value.txt
```

The value is `{"clientId":"<app-registration-client-id>","clientSecret":"<the-secret-value>","tenantId":"<entra-tenant-id>"}`.

To rotate, follow [Rotate Secret → Entra client secret](../../scripts/rotate-secret/README.md#entra-client-secret). The provider rereads the Secret on its next reconcile, so no restart is needed.

## Owners on every Application

`crossplane-entra` can create an Entra app, but it can update or delete only apps it owns. The API never sets an owner on its own, whether the CLI or Crossplane calls it. So every `Application` a composition creates needs an explicit owner.

```yaml
spec:
  forProvider:
    owners:
      - <crossplane-entra-service-principal-object-id>
```

Without it, the app is created once and can never be changed.

## What is NOT managed here

- **`azuread-creds` value:** in Parameter Store, rendered by External Secrets. Never in Git.
- **The Entra tenant:** and who holds admin rights to grant consent.
