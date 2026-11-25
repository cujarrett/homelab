# crossplane-user IAM Policy

The Crossplane AWS provider signs in as the IAM user `crossplane-user`. Its access keys live in the `aws-creds` Secret in `crossplane-system`. Crossplane does not manage this user, so create it before bootstrapping Crossplane.

| Access | Granted by |
|---|---|
| S3, DynamoDB, ElastiCache, RDS | Full access through AWS managed policies. |
| Secrets Manager under `platform/` | `CrossplaneSecretsManagerManagement`. |
| Role management | Covered below. Its exact wording stops the keys from becoming account admin. |

## Managing per-workload roles

`CrossplaneWorkloadIdentityManagement` ([aws-iam-policy.json](./aws-iam-policy.json)) lets Crossplane manage IAM roles under the `/crossplane/` path. Those roles let a pod reach AWS without a key.

| Topic | Detail |
|---|---|
| Attached, not inline | A user's inline policies may total only 2048 bytes. |
| Boundary required | Creating a role or writing its policy works only with the `CrossplaneWorkloadRoleBoundary` permissions boundary ([aws-iam-boundary.json](./aws-iam-boundary.json)). |
| What a boundary does | It caps a role, whatever the role's own policy says. Without it, these keys could create a `*:*` role. |
| What it allows | `platform-*` buckets, secrets under `platform/`, any DynamoDB table, and cache and database connections. |
| Compositions | Every `Role` in the Api, Cache and Sql compositions sets a matching `permissionsBoundary`. |

To apply on a fresh account:

```bash
aws iam create-policy \
  --policy-name CrossplaneWorkloadRoleBoundary \
  --policy-document file://cluster/crossplane/aws-iam-boundary.json

aws iam create-policy \
  --policy-name CrossplaneWorkloadIdentityManagement \
  --policy-document file://cluster/crossplane/aws-iam-policy.json

aws iam attach-user-policy \
  --user-name crossplane-user \
  --policy-arn arn:aws:iam::550429969116:policy/CrossplaneWorkloadIdentityManagement
```

When the boundary or the role policy changes, publish a new version:

```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::550429969116:policy/CrossplaneWorkloadRoleBoundary \
  --policy-document file://cluster/crossplane/aws-iam-boundary.json \
  --set-as-default
```

A role with no boundary blocks Crossplane from editing its inline policy. Attach the boundary by hand:

```bash
aws iam put-role-permissions-boundary \
  --role-name <role> \
  --permissions-boundary arn:aws:iam::550429969116:policy/CrossplaneWorkloadRoleBoundary
```

## What is NOT managed here

- **`aws-creds` value:** in Parameter Store at `/homelab/crossplane-system/aws-credentials`, rendered by [External Secrets](../../docs/external-secrets.md). Never in Git.
- **IAM OIDC provider:** `oidc.mattjarrett.dev`, which workload identity trust policies check. See [Platform Workload Identity](../../platform/docs/workload-identity.md).
