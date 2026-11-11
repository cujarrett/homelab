# github-token-rotate

Rotates the Launchpad API's GitHub token. See [GitHub Tokens](../../docs/github-tokens.md) for what
it is for.

```bash
./github-token-rotate.sh
```

It lists what uses the token and opens GitHub's token page so you can regenerate it. Then it:

1. Checks the pasted value can push to `homelab-workspaces`, and warns if it can also open pull requests.
2. Writes it to AWS Secrets Manager.
3. Restarts `launchpad-api` so it fetches the new value, checks the new pod has it, then watches the API log for GitHub 401s.

Launchpad gets 401s from GitHub between regenerating the token and the restart finishing, usually about a minute.

The token is read with echo off and never appears in shell history or the process list.
