# homelab-deploy-token-rotate

Rotates the PAT that `platform-exporter` and `secret-mirror-controller` use to push straight to
`homelab`. See [GitHub Tokens](../../docs/github-tokens.md) for the full picture.

```bash
# regenerate homelab-deploy on GitHub, then:
./homelab-deploy-token-rotate.sh   # paste the token when prompted
```
The prompt reads with echo off and the token never touches shell history.
