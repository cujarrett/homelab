# crossplane-user IAM Policy

The Crossplane AWS provider authenticates as an IAM user (`crossplane-user`) using
long-lived access keys stored in the `aws-creds` Secret in `crossplane-system`. That user
is not managed by Crossplane itself, so it must exist before Crossplane is bootstrapped.

Full access to S3, DynamoDB, ElastiCache and RDS comes from AWS managed policies, and
Secrets Manager under `platform/` from `CrossplaneSecretsManagerManagement`. Read those in
the IAM console. This file covers role management, where the exact wording is what keeps
the keys from becoming account admin.

## Managing per-workload roles

`CrossplaneWorkloadIdentityManagement` ([aws-iam-policy.json](./aws-iam-policy.json)) lets
Crossplane manage IAM roles under the `/crossplane/` IAM path. That is how a pod reaches
AWS without holding a key.

Creating a role, and writing its policy, only succeed when the role carries the
`CrossplaneWorkloadRoleBoundary` permissions boundary
([aws-iam-boundary.json](./aws-iam-boundary.json)). A boundary caps what a role can ever
do, whatever its own policy says. Without one, anyone holding these keys could create a
role with `*:*` and become account admin. The boundary allows reads and writes of
platform-named data only: `platform-*` buckets, DynamoDB tables, secrets under
`platform/`, and cache and database connections. Every `Role` in the Api, Cache and Sql
compositions sets `permissionsBoundary` to match.

To apply on a fresh account:

```bash
aws iam create-policy \
  --policy-name CrossplaneWorkloadRoleBoundary \
  --policy-document file://cluster/crossplane/aws-iam-boundary.json

aws iam put-user-policy \
  --user-name crossplane-user \
  --policy-name CrossplaneWorkloadIdentityManagement \
  --policy-document file://cluster/crossplane/aws-iam-policy.json
```

When the boundary changes, publish a new version:

```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::550429969116:policy/CrossplaneWorkloadRoleBoundary \
  --policy-document file://cluster/crossplane/aws-iam-boundary.json \
  --set-as-default
```

A role created before the boundary existed has none, and Crossplane can no longer edit its
inline policy. Attach the boundary to it by hand:

```bash
aws iam put-role-permissions-boundary \
  --role-name <role> \
  --permissions-boundary arn:aws:iam::550429969116:policy/CrossplaneWorkloadRoleBoundary
```

## What is NOT managed here

- The `aws-creds` value, held in Parameter Store at `/homelab/crossplane-system/aws-credentials` and rendered by [External Secrets](../../docs/external-secrets.md), never in Git
- The IAM OIDC identity provider (`oidc.mattjarrett.dev`) that workload identity trust policies condition on. See [Platform Workload Identity](../../platform/docs/workload-identity.md)
