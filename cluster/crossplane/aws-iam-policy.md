# crossplane-user IAM Policy

The Crossplane AWS provider authenticates as an IAM user (`crossplane-user`) using
long-lived access keys stored in the `aws-creds` Secret in `crossplane-system`. That user
is not managed by Crossplane itself — it must exist before Crossplane is bootstrapped.

This file is the source of truth for what that user must be allowed to do. If the user is
ever recreated, apply all policies below.

---

## Attached managed policies

| Policy ARN | Purpose |
|---|---|
| `arn:aws:iam::aws:policy/AmazonS3FullAccess` | S3 bucket create/delete for `ObjectStorage` |
| `arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess` | DynamoDB table create/delete for `NoSql` |
| `arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess` | ElastiCache cluster create/delete for `Cache (cloud)` |

---

## Inline policy: CrossplaneWorkloadIdentityManagement

Grants the permissions needed to manage per-workload IAM roles. Scoped to the
`/crossplane/` IAM path — no permission to touch roles outside that path.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageRolesUnderCrossplanePath",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRoleTags",
        "iam:UpdateAssumeRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::*:role/crossplane/*"
    }
  ]
}
```

To apply (idempotent — safe to re-run):

```bash
aws iam put-user-policy \
  --user-name crossplane-user \
  --policy-name CrossplaneWorkloadIdentityManagement \
  --policy-document file://cluster/crossplane/aws-iam-policy.json
```

## What is NOT managed here

- The `aws-creds` Secret in `crossplane-system` — created manually, never stored in Git. It is one of only two hand-seeded Secrets in the cluster; the other is `aws-eso-creds`, described in [External Secrets](../../docs/external-secrets.md)
- The IAM OIDC identity provider (`oidc.mattjarrett.dev`) that workload identity trust policies condition on — see [Platform Workload Identity](../../docs/platform-workload-identity.md)
