# github-token-rotate

Rotates the Launchpad API's GitHub token. [GitHub Tokens](../../docs/github-tokens.md) says what it is for.

```bash
./github-token-rotate.sh
```

It lists what uses the token and opens GitHub's token page. Regenerate the token there and paste it. Then the script runs these steps.

1. Checks the value can push to `homelab-workspaces`. Warns if it can also open pull requests.
2. Writes it to AWS Secrets Manager.
3. Restarts `launchpad-api` and watches its log for GitHub 401s.

- Downtime: Launchpad gets 401s for about a minute, from regenerating until the restart ends.
- Safety: the token is read with echo off. It never reaches shell history or the process list.
