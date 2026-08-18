# Docs

Everything written down about this cluster. Start with [Cluster](./cluster.md) for what it is, or [Learning](./learning/) for how to get better at building it.

## Understand the cluster

| Doc | What's in it |
|---|---|
| [Cluster](./cluster.md) | The four nodes, the stack running on them, and where state lives |
| [How it was built](./how-it-was-built.md) | A record of the original build, kept as written |
| [Nothing Novel](./nothing-novel.md) | Every mechanism here, and the published pattern it came from |

## Platform

| Doc | What's in it |
|---|---|
| [Platform Connections](./platform-connections.md) | Who may call whom, and how the mesh enforces it |
| [Platform Binding](./platform-service-binding.md) | How an app gets wired to the infrastructure it asks for |
| [Workload Identity](./workload-identity.md) | How SPIRE, Crossplane, AWS and Entra combine into one identity, end to end |
| [Platform Workload Identity](./platform-workload-identity.md) | SPIFFE identity, and what proves a workload is who it claims |
| [SPIRE OIDC Federation](./spire-oidc-federation.md) | Publishing SPIRE's signing keys so AWS and Entra will trust a pod |
| [External Secrets](./external-secrets.md) | Grafana's admin login out of AWS Secrets Manager, and why only that one |
| [GitHub Tokens](./github-tokens.md) | The three fine-grained PATs behind GitOps, what each grants, and how to rotate them |

## Operate it

| Doc | What's in it |
|---|---|
| [Runbooks](./runbooks/) | Upgrades, hardware swaps, edge hardening, and debugging Crossplane |
| [Cluster backup](./cluster-backup/) | Backing up cluster state, and the script that does it |
| [WordPress](./wordpress/) | Backup, restore, and version-drift checks for the two sites |
| [Kiosk](./kiosk/) | The 1U display on `ctrl-1` and the script that drives it |
| [Postmortems](./postmortems/) | What broke, why, and what changed afterwards |

## Build and write

| Doc | What's in it |
|---|---|
| [Learning](./learning/) | The route from cloud-native history to writing controllers |
| [Blog Writing Style](./blog-writing-style.md) | Voice and structure for posts about this cluster |
| [Challenges](./challenges/) | Photos of the physical build problems worth remembering |
