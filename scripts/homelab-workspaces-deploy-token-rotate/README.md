# homelab-workspaces-deploy-token-rotate

Rotates the PAT that CI in 10 app repos uses to bump image tags in `homelab-workspaces`. See
[GitHub Tokens](../../docs/github-tokens.md) for the full picture.

```bash
# regenerate homelab-workspaces-deploy on GitHub, then:
./homelab-workspaces-deploy-token-rotate.sh   # paste the token when prompted
```
The prompt reads with echo off and the token never touches shell history. Retry any repo that
503s (GitHub's secrets API is occasionally flaky):
```bash
gh secret set HOMELAB_PAT -R cujarrett/<repo> --body "<token>"
```
