# Homelab Cluster Context

## Rules

- **Never run `git add`, `git commit`, `git push`, or any git command that writes to the index, history or remotes.** Output the commands for the user to run. Staging is part of their review. Running it for them removes that checkpoint.
- **Never add a `Co-Authored-By` trailer or a "Generated with Claude Code" line** to commit messages or PR descriptions. That includes suggested commit messages. The user alone authors commits.
- **Always give a suggested commit message** when a task needs a commit.
- **Give `git add` and the commit as two separate steps.**
  - List every file by name. Never `git add .`, `git add -A`, or a bare directory.
  - Group related files onto one `git add` line.
  - Give one `git add` and one commit message per repo. Put each repo under its own heading when more than one changed.
  - Start with a `cd` to the repo's absolute path, so the commands work when pasted from anywhere.
- **Never output a `git push` command.** The user pushes as a deliberate step.
- **`storefront-records` and `storefront-reviews` need a PR to main.** Start their commands with `git checkout -b <branch>`.
- **Read a sibling repo's `AGENTS.md` before editing that repo.**
- **Never end a YAML comment with `:`.** Editors read a trailing colon as a key and mis-colour the rest of the block. Reword it, such as `# depends on host, a .local.lab host means...`. A colon mid-line is fine, such as `# curl: raw curl without browser UA`.
- **Use `k` in commands shown in chat.** Doc files use `kubectl`.
- **Run `kubectl` and `k` directly in the terminal.** The local machine has Tailscale and a kubeconfig. Never wrap them in `ssh pi@...`.
- **When debugging, list every command as you run it.** Show the command, what it does, and why. The user is learning the workflow. Write each one inline at the moment you run it.
- **After changing XRDs or Compositions, remind the user to sync `platform-definitions`** with `argocd app sync platform-definitions --grpc-web`.
- **Use `foo`, `bar` or `baz` as placeholder names in platform READMEs and XRD examples.** Never put a real instance name, such as `nms-events` or `mattjarrett-com`, in `platform/*/README.md` or in `platform/*/xrd.yaml` description fields.
- **Write every table row and list item in full.** Never write "Same as above", "Same as XFoo pattern" or "See above". Each row stands on its own.
- **Platform READMEs and XRD descriptions say what the platform does, never how.**
  - XRD `description` fields name no infrastructure technology, such as "NATS", "Redis", "S3" or "NACK".
  - README prose names no internal resource, namespace or controller, such as "managed by NACK" or `kubectl get consumer -n nats`.
  - User-facing descriptions leave out internal naming rules, such as "uppercased to become the stream name".
  - Exception: document env var names injected into containers. App code must read them.
  - Exception: document wildcard syntax a parameter needs. Dev teams need it to set the value correctly.
  - The composition is the platform team's implementation file. Details are fine there.

### Pre-commit safety check

Before telling the user to commit, run `/security-review`. It checks the pending changes on the current branch for security issues. Once it says the changes are safe, offer a suggested commit message. Never run `git commit` yourself.

**Report length grows with risk. This overrides the skill's own output format.**

- **Clean:** one line, `Clean. No findings.` Say nothing about what was scanned, which checks passed, or why the change is low risk.
- **Anything real:** spend the words. For each finding, give the file and line, what an attacker does with it, and the fix. One concrete exploit walkthrough beats a list of categories.
- **Uncertain:** say in one sentence what would settle it.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." ([grugbrain.dev](https://grugbrain.dev/))

- **Say no.** "No" is the best weapon against complexity. Add no feature or abstraction until it earns its place.
- **Cheapest rung that works.** Before writing code, go down this ladder and stop at the first rung that solves it: skip the feature, reuse code already here, standard library, native platform feature, a dependency already installed, one line, then build the minimum.
- **Wait for a pattern to repeat three times before abstracting.** Let cut points show up in the code. Don't invent them up front.
- **80/20 solutions.** Ship 80% of the value with 20% of the code. Ugly code that works beats elegant code that is over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it. If you can't see the use, go away and think.
- **Boring, obvious code wins.** Well-named intermediate variables beat clever one-liners. They are easier to debug.
- **DRY is not a law.** A little copy-paste beats a complex abstraction built for two cases.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so. That is a signal to simplify.
- **Comments are grug too.** Two or three lines. Say why the value is what it is, or what breaks if you change it. Never restate what the code does. Cut percentile tables, rejected alternatives, and the history of how you got there.
- **Write comments as lines.** One fact per line. More than two facts become a list. Key each line by the case it covers (`Port 9500: ...`), so readers find theirs without reading the rest. Three or more flowing sentences is a defect, however accurate.

## Writing

Prose is hard for this repo's owner to read. Write **plain language** in chat replies, docs, code comments, commit messages, and UI copy in the app repos.

- **One idea per sentence.** Keep most sentences under 15 words.
- **Everyday words.** Say what a technical term means the first time it appears.
- **Who does what.** Name the actor and use active voice.
- **Lists for two or more facts.** One short line per item, starting with the thing it is about.
- **State facts directly.** A slogan ("One boundary, not two"), a "not X, Y" contrast or jargon ("thrash", "blast radius") becomes a plain statement. "Hand-made objects on this map: one, the commit" becomes "The commit is the only thing on this map a person wrote by hand."
- **Full stops, commas and brackets.** Never a spaced hyphen (` - `) doing a dash's job.
- **Friendly and easy.** Write like a helpful note to a teammate. Say what the code does and why, in positive terms.
  - "Storage records need an extra permission and nothing here reads them" becomes "Storage records are off, so app repos need one less permission."
  - Never frame a design choice as a workaround, a trade-off or a limitation.

## Documentation

Applies to every `.md` file in this repo, on top of the [Writing](#writing) rules.

- **Grug first, then depth.** Every section opens with one or two plain sentences before any table, diagram, or YAML. If a reader stops after the first line, they should still have the idea.
- **Concise > long.** One representation per idea. Never a diagram that repeats the prose, or a table that repeats the diagram.
- **One numbering scheme per doc.** If steps or phases are numbered, nothing else is. Chapters are flat `#` headings with plain titles, such as "Storage".
- **Flat hierarchy.** No wrapper heading whose only content is other headings. If a chapter holds ten things, those ten things are the chapters.
- **Every chapter does one job.** A chapter titled "where we are today" must not contain timeless explanation. Move it.
- **No meta-content.** Never document what changed from an earlier draft, critique a previous plan, or narrate the doc's own history. Same principle as the code-comment rule: state current rationale only.
- **No time-bound content.** No "tonight", "this session", "first night", no timeboxes. Say "Phases 0, 1 and 6 touch no cluster". Docs outlive the session that wrote them.
- **Index at the top** for any doc with more than three chapters: one "start here" line, then a table of every chapter. Verify every anchor resolves before finishing.
- **Link to real paths**, such as `[Api](../platform/api/)`.
- **Cross-doc links use the human title and a `./` relative path**, such as `[Platform Connections](./platform/docs/connections.md)`. The reader sees what the doc is. Deep links keep the title too: `[Platform Connections → Known limits](./platform/docs/connections.md#known-limits)`.
- **Never link to a doc under `local-only/`.** It is gitignored, so the link is dead for every reader but you.

## Overview
A 4-node k3s Kubernetes homelab, managed entirely through GitOps with ArgoCD.
Every workload is a manifest under `cluster/` or `platform/` in this repo, or in the `homelab-workspaces` repo.
GitHub repo: `https://github.com/cujarrett/homelab.git` (branch `main`).

- **Nodes:** four Raspberry Pi 5, ARM64. Always use ARM64-compatible images.
- **`ctrl-1`:** `192.168.10.100`, the k3s server.
- **`work-1`, `work-2`, `work-3`:** `192.168.10.101` to `192.168.10.103`, the k3s agents.
- **SSH:** `ssh pi@<node-ip>`.

## Reference

[Cluster](./docs/cluster.md) holds the facts about the running cluster. Read the chapter before touching what it covers.

| Before you | Read |
|---|---|
| Add, move or debug a workload, namespace or controller | [Cluster → Stack](./docs/cluster.md#stack) and [Cluster → Namespaces](./docs/cluster.md#namespaces) |
| Add or change a hostname, a DNS record or a route | [Cluster → Hostnames](./docs/cluster.md#hostnames) |
| Edit a Grafana dashboard, a Prometheus or Loki setting, or a Traefik metric query | [Cluster → Monitoring](./docs/cluster.md#monitoring) and [Dashboard Colors](./cluster/monitoring/dashboard-colors.md) |
| Resize a StatefulSet PVC | [Cluster → Resizing a StatefulSet PVC](./docs/cluster.md#resizing-a-statefulset-pvc) |
| Add an ArgoCD Application or a Helm chart source | [Cluster → AppProjects](./docs/cluster.md#appprojects) |
| Change the 1U display on `ctrl-1` | [Kiosk](./docs/kiosk/README.md) |

## Crossplane Platform

Crossplane core runs with `--enable-realtime-compositions`, set in the Helm `args` in [cluster/argocd/crossplane.yaml](./cluster/argocd/crossplane.yaml). Composite reconciliation then reacts to composed-resource changes by watch, instead of waiting for the 60s poll. Without it, a composed resource can turn Ready up to a minute before its status reaches the XR.

`platform/` defines thirteen platform types, each as `<plural>.platform.local.lab`. The canonical list is [Platform → Offerings](./platform/README.md#offerings). That list leaves out these facts:

- `Spa`: the composition generates the nginx config. App repos must not include an `nginx.conf`.
- `Wordpress`: a MariaDB StatefulSet and a WordPress Deployment. Credentials derive from the XR UID.
- `Sql`, `NoSql`, `ObjectStorage`: used by Launchpad guest demo sandboxes. `NoSql` and `ObjectStorage` stay within the AWS free tier by design.
- `ManagedSecret`: the value never becomes a Kubernetes Secret.
- `GraphApi`: nests an `Api`. It publishes its schema from the same image digest to the named `FederatedGraph`. See [Platform Graph](./platform/docs/graph.md).

[Cluster → Namespaces](./docs/cluster.md#namespaces) lists which namespaces use which XR types.

### GitOps flow for XR instances
1. For a new workspace, add its namespace in two places, then let it sync:
   - the `workloads` project `destinations` in [cluster/argocd/projects.yaml](./cluster/argocd/projects.yaml)
   - every namespace list in [cluster/kyverno/workspace-rbac.yaml](./cluster/kyverno/workspace-rbac.yaml)

   The project allows only `platform.local.lab` kinds, ConfigMap, Service and Namespace.
2. Commit XR files to a top-level directory in the `homelab-workspaces` repo, such as `mattjarrett-com/mattjarrett-com.yaml`.
3. The `xrs` ApplicationSet (`cluster/argocd/xrs-appset.yaml`) makes one ArgoCD Application per directory. Each one deploys into a namespace named after its directory.
4. ArgoCD applies the XR to the cluster.
5. Crossplane reconciles the XR and creates all composed resources.

The [homelab-workspaces README](https://github.com/cujarrett/homelab-workspaces#structure) covers the directory layout and the `namespace.yaml` requirement. XR instance files live in `homelab-workspaces/<name>/`, one directory per workspace, such as `mattjarrett-com/` and `kentjarrett-com/`. `launchpad-api` writes and deletes the short-lived `guest-*` sandbox directories. People maintain every other workspace directory by hand.

### Deleting an XR instance
Delete in this order, or data is lost.
```bash
# 1. Delete the XR. Crossplane cascade-deletes all composed resources.
kubectl delete spa <name> -n <namespace>
# or: kubectl delete wordpress <name> -n <namespace>

# 2. Remove the workspace directory from the homelab-workspaces repo and push. ArgoCD prunes the Application.
git rm -r <name>/ && git commit -m "..." && git push
```
**Never remove the file first.** That orphans the composed resources.

### Storage classes for XR PVCs
- `longhorn-retain`: for `dataRetention: retain`. The PV survives XR deletion, so data is recoverable.
- `longhorn-delete`: for `dataRetention: delete`. The PV is wiped when the XR is deleted.
- The `dataRetention` field in the WordPress XR picks which one is used.

### WordPress backup and restore
Scripts are in [scripts/wordpress/](./scripts/wordpress/). The procedure is in [WordPress Restore Guide](./docs/wordpress/README.md). Backups are kept outside the repo.

## Key Conventions
- Every app has ArgoCD `automated: { prune: true, selfHeal: true }`, so the cluster converges to the repo on its own.
- Most apps use `ServerSideApply: true`.
- Never hand-create or commit a cluster-setup Secret. Add a parameter and an `ExternalSecret` instead. See [External Secrets](./docs/external-secrets.md).
- Secrets that controllers generate (cert-manager TLS, Crossplane provider TLS, webhook CAs) hold no credential anyone chose. They stay in-cluster.
- Every `HTTPRoute` has `parentRefs: [{name: traefik-gateway, namespace: kube-system}]`. Traefik Middlewares attach as `ExtensionRef` filters.
- A host outside `*.local.lab`, `*.mattjarrett.dev`, `mattjarrett.com` and `kentjarrett.com` needs its name added to [cluster/traefik/certificates.yaml](./cluster/traefik/certificates.yaml).
- Spa compositions put `gotemplating.fn.crossplane.io/ready: "True"` on go-templating resources. This stops a false `Ready=False` on the XR.
- A new public hostname goes through `/add-cloudflare-tunnel-hostname`. The tunnel API replaces the whole config on every write, so the skill fetches it, appends, and writes it all back.

## Go App Conventions

All homelab Go services share one layout. [.claude/assets/new-go-api/](./.claude/assets/new-go-api/) holds the canonical files, and the `/new-go-api` skill scaffolds every new Go API from them.

- **Build tool:** `just`, never `make`. Run `just ci` (lint, test, build) before pushing.
- **Binary name matches the repo name.** The race detector is always on in tests.
- **Stdlib only.** Use `net/http` and `slog`, with no HTTP framework.
- **Graceful shutdown** through `signal.NotifyContext`.
- **A `/healthz` route on every app.** The Kubernetes readiness probe hits it.
- **CI:** `.github/workflows/ci.yml` runs `test`, then `build-and-push` (ARM64, to `ghcr.io/cujarrett/<repo>`), then `deploy`, which updates the image tag in `homelab-workspaces`.
- **Renovate:** `renovate.json` extends the shared preset at `github>cujarrett/homelab//.github/renovate-shared`. Policy lives in the preset.
- **Per-repo `AGENTS.md`:** each repo stands alone, so each carries the git rules, the pre-commit safety check and the grug philosophy. An agent working in that repo never sees this file.

Go apps in this workspace:
| Repo | Binary | Notes |
|---|---|---|
| `my-vinyl-api` | `my-vinyl-api` | REST API for the my-vinyl SPA |
| `sump-pump` | `bridge`, `consumer` | Monorepo. `cmd/bridge` publishes IoT readings to NATS. `cmd/consumer` reads them and exposes Prometheus metrics. `internal/event` holds the shared subjects and payload. Images stay `ghcr.io/cujarrett/sump-pump-bridge` and `-consumer` |
| `weather-exporter` | `weather-exporter` | Weather Prometheus exporter |
| `launchpad-api` | `launchpad-api` | BFF (backend for the frontend) for the Launchpad UI |
| `demo-api` | `demo-api` | Sample Api in each Launchpad guest sandbox and the platform e2e tests. Probes every binding with a real round-trip |
| `github-exporter` | `github-exporter` | Prometheus exporter for pull request, auto-merge and workflow metrics across the account's repos |
| `platform-exporter` | `platform-exporter` | Prometheus exporter for Crossplane XR, binding and pod readiness timings |
| `workload-identity-sidecar` | `workload-identity-sidecar` | Sidecar that trades a SPIFFE SVID for short-lived cloud credentials. Go code lives in `sidecar/` |
| `homelab-stats` | `homelab-stats` | Read-only JSON for the homelab section on mattjarrett.dev, built from a fixed set of Prometheus queries and the blog-stats gist |
| `temporal-controller` | `manager` | Kubebuilder controller for the `TemporalNamespace` CRD. Uses the kubebuilder `Makefile`, not `just` |
| `platform-connections-demo` | `api`, `downstream` | Monorepo for the service mesh walkthrough. `api` runs as `upstream-api`. `downstream` runs as `authorized-api` and `unauthorized-api`. Each has its own `justfile` |

## Skills

Repo skills live in [.claude/commands/](./.claude/commands/), one file per skill. List them with `ls`, because this file keeps no index of them.

## Common Commands
```bash
# Always use the full name.
# A bare "applications" also matches Crossplane's Entra applications.azuread.m.upbound.io.
# Those report SYNCED/READY, so anything filtering on Synced reads them as unhealthy.
kubectl get applications.argoproj.io -A

argocd login argocd.local.lab --username admin --insecure
argocd app sync <app-name>
```
