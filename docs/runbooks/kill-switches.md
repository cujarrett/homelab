# Kill switches

Something is going wrong. A bill is climbing, a key leaked, or a bad change is spreading. Kill the platform's key for that service first, then find the cause. Nothing new gets created or changed until the key works again.

## AWS

Kill every key Crossplane signs in with. Undo with the same loop and `--status Active`.

```bash
for k in $(aws iam list-access-keys --user-name crossplane-user --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam update-access-key --user-name crossplane-user --access-key-id "$k" --status Inactive
done
```

Running RDS and ElastiCache still bill. List the XRs that own them, as `namespace/name`.

```bash
kubectl get sqls.platform.local.lab -A -o jsonpath='{range .items[?(@.spec.parameters.backend=="public-cloud")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
kubectl get apis.platform.local.lab -A -o jsonpath='{range .items[?(@.spec.parameters.cache.backend=="public-cloud")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

- Delete each one, such as `kubectl delete sql foo -n bar`. Then remove its file from Git, or ArgoCD puts it back.
- With the key killed, Crossplane can't delete the AWS side. Turn the key back on until the XRs are gone, or delete the instances in the AWS console.
- In the AWS console, an RDS instance has the Sql XR's name. An ElastiCache group is `crossplane-<namespace>-<name>-cache`, or starts `xp-` when that is over 40 characters.
- [Cost Explorer](https://console.aws.amazon.com/cost-management/home#/cost-explorer) shows which service is spending.
- Budget: at 100% of the `Primary Budget`, AWS attaches `KillSwitchDenyAll` to `crossplane-user`. Undo with `aws iam detach-user-policy --user-name crossplane-user --policy-arn arn:aws:iam::550429969116:policy/KillSwitchDenyAll`.

## Apollo GraphOS

[Apollo Studio](https://studio.apollographql.com/) → the graph → Settings → API Keys → revoke. Test and prod each have their own key, so one lane can stop alone.

Undo: create a new key and put it in `/homelab/apollo-operator-<lane>/apollo-api-key`.

## Temporal Cloud

The `TemporalCloudSpend` alert fires while anything was billed in the last 24 hours. It reports the 30-day total and sends a new message at every $5.

[Temporal Cloud](https://cloud.temporal.io/) → Settings → Service Accounts → `homelab-platform` → revoke its API key.

Undo: create a new key and put it in `/homelab/temporal-cloud/api-key`.

Running workers still spend. Cut them off too. Every WorkflowSpace drops its route out, so no worker can reach Temporal Cloud. Undo with `"true"`.

```bash
kubectl patch environmentconfig aws-platform-config --type=merge -p '{"data":{"temporalCloudEnabled":"false"}}'
```

List the XRs that still own a Temporal Cloud namespace, as `namespace/name`.

```bash
kubectl get workflowspaces.platform.local.lab -A -o jsonpath='{range .items[?(@.spec.parameters.backend=="public-cloud")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```

Delete each one, such as `kubectl delete workflowspace foo -n bar`. With the key killed, temporal-controller can't delete the Temporal Cloud side, so delete it in the console too.

## Cloudflare

Two tokens, one per job. Rolling a token kills the old value at once.

| Token | Kill it at | While it is dead |
|---|---|---|
| cert-manager API token | [Cloudflare API tokens](https://dash.cloudflare.com/profile/api-tokens) → the token → Roll | Certificates stop renewing. Current ones work until they expire |
| Tunnel token | Cloudflare dashboard → Networking → Tunnels → the tunnel → Overview → Refresh token | No new connector can join. Connectors already running keep serving |

Refreshing leaves every open connection up, including one a stranger opened with the old token. Drop them all. Every public hostname goes offline until the undo.

The prompt takes a Cloudflare API token with Account → Cloudflare Tunnel → Edit. Create one at [Cloudflare API tokens](https://dash.cloudflare.com/profile/api-tokens) → Create Token → Custom token, and delete it afterwards.

```bash
CREDS=$(kubectl get secret cloudflare-tunnel-token -n cloudflare -o jsonpath='{.data.tunnel-token}' | base64 -d | base64 -d)
ACCOUNT_ID=$(jq -r .a <<<"$CREDS"); TUNNEL_ID=$(jq -r .t <<<"$CREDS"); unset CREDS
read -rs CF_TOKEN
curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/connections" \
  -H "Authorization: Bearer $CF_TOKEN"; unset CF_TOKEN
```

Undo: paste the new value with the Cloudflare lines in [Rotate Secret](../../scripts/rotate-secret/README.md#pasted-from-a-vendor-page). The tunnel line restarts `cloudflared` with it.

## Entra

Turn off the sign-in Crossplane uses. Crossplane can no longer create or change Entra apps. Apps that already exist keep signing users in. Undo with `accountEnabled=true`.

```bash
APP=$(az ad app list --display-name crossplane-entra --query '[0].appId' -o tsv)
az ad sp update --id "$APP" --set accountEnabled=false
```

A leaked secret needs a new one too. Follow [Rotate Secret → Entra client secret](../../scripts/rotate-secret/README.md#entra-client-secret).

## GitHub

Each row stops one thing that writes to a repo. Suspend an App at [Installed GitHub Apps](https://github.com/settings/installations) → the App → Configure → Suspend.

| To stop | Do this | Undo |
|---|---|---|
| Renovate merging updates | Run [Automerge Stop](../../scripts/automerge-stop/) | Unsuspend Renovate on the same page |
| Image tag bumps and Kargo promotions reaching `homelab-workspaces` | Suspend `homelab-workspaces-deployer` | Unsuspend it on the same page |
| CI commits reaching `homelab` | Suspend `cujarrett-homelab-deployer` | Unsuspend it on the same page |
| Launchpad writing guest sandbox directories | Regenerate `homelab-workspaces-launchpad` at [GitHub fine-grained tokens](https://github.com/settings/personal-access-tokens) and close the page | Run [GitHub Token Rotate](../../scripts/github-token-rotate/) |

A leaked App key needs deleting too. Follow [GitHub Tokens → Revoking a key](../github-tokens.md#revoking-a-key).

## Public-cloud Sql, cache and workflow spaces

- Already off outside the e2e suite, by [public-cloud-backends.yaml](../../cluster/kyverno/public-cloud-backends.yaml).
- A public-cloud workflow space is deleted after 2 hours, by [public-cloud-time-limit.yaml](../../cluster/kyverno/public-cloud-time-limit.yaml).
