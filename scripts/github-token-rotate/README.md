# github-token-rotate

Rotates any of the three GitHub tokens. See [GitHub Tokens](../../docs/github-tokens.md) for what
each one is for.

```bash
./github-token-rotate.sh
```

It asks which token you are rotating, lists what uses it, and opens GitHub's token page so you can regenerate it. Then it:

1. Checks the pasted value is the token you picked, and refuses a wrong one before writing anywhere.
2. Writes it to the Kubernetes Secret or to every repo's Actions secret.
3. Tests it. For the Launchpad token it watches the API log for GitHub 401s. For a CI token it
   reruns any deploy that failed on the old one and waits for the result.

The token is read with echo off and never appears in shell history or the process list.
