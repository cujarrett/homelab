# eso-reader IAM Policy

External Secrets Operator authenticates as an IAM user (`eso-reader`) using long-lived access keys
stored in the `aws-eso-creds` Secret in `external-secrets`. That user is not managed by Crossplane —
it must exist before ESO can sync anything.

This file is the source of truth for what that user must be allowed to do. If the user is ever
recreated, apply the policy below.

The account ID is resolved at apply time rather than written here, matching
[crossplane-user IAM Policy](../crossplane/aws-iam-policy.md).

---

## Attached managed policies

None. `eso-reader` has exactly one inline policy and no managed policies — it can read the homelab
secret and do nothing else in the account.

---

## Inline policy: ESOReadHomelab

Grants read-only access to secrets under the `homelab/` name prefix. No write, no delete, no
listing of secrets outside the prefix, and no access to S3, DynamoDB, IAM or RolesAnywhere — this
user is deliberately unrelated to `crossplane-user`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadHomelabSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:<account-id>:secret:homelab/*"
    }
  ]
}
```

To apply — idempotent, safe to re-run. `ACCT` is resolved from the caller so no account ID is ever
typed or committed:

```bash
ACCT=$(aws sts get-caller-identity --query Account --output text)

aws iam put-user-policy --user-name eso-reader --policy-name ESOReadHomelab \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"ReadHomelabSecrets\",
      \"Effect\": \"Allow\",
      \"Action\": [\"secretsmanager:GetSecretValue\", \"secretsmanager:DescribeSecret\"],
      \"Resource\": \"arn:aws:secretsmanager:us-east-1:${ACCT}:secret:homelab/*\"
    }]
  }"
```

Verify:

```bash
aws iam get-user-policy --user-name eso-reader --policy-name ESOReadHomelab
```

## What is NOT managed here

- The `aws-eso-creds` Secret in `external-secrets` — created manually, never stored in Git. It is
  one of only two hand-seeded Secrets in the cluster; the other is `aws-creds` in
  `crossplane-system`
- The access keys themselves — minted with `aws iam create-access-key` and read straight into the
  Secret, never written to a file that survives the command
- The `homelab/cluster` secret in Secrets Manager and its contents — created and seeded by hand,
  see [External Secrets Operator](../../docs/external-secrets.md)
