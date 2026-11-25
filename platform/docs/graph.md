# Platform Graph

Every team ships its own small GraphQL API. A router joins them into one API, and clients see one schema. Joining takes one YAML file.

[Fortune 100 Internal Developer Platform patterns, learned on a homelab. Nothing novel.](../../docs/nothing-novel.md)

## How a change moves

`test` and `prod` are two fixed variants. Each lives in its own namespace, `graph-test` or `graph-prod`, with its router and subgraphs. Both routers are LAN and Tailscale only. Nobody publishes a schema by hand.

1. A PR changes `schema.graphql` beside the resolvers. CI runs `rover subgraph check` against `test`. CODEOWNERS requests the platform team. Branch protection requires the check.
2. Merge to main builds the ARM64 image with signed build provenance. Kargo sees it and writes its digest into `graph-test/<subgraph>.yaml` in `homelab-workspaces`.
3. ArgoCD syncs. Kyverno checks the image's provenance. Crossplane renders the subgraph. The test Apollo operator reads the schema from that image and publishes it to `test`. GraphOS composes, and the router reloads.
4. Kargo checks both schemas against `prod` and queries the test router. A person clicks Promote, and Kargo writes the digests into `graph-prod/<subgraph>.yaml`.
5. Prod repeats step 3 with its own Apollo operator and key. Rollback is promoting an older Freight in Kargo.

Facts about that flow.

| Topic | Detail |
|---|---|
| Local development | `rover dev --graph-ref storefront-homelab@test` composes your laptop's subgraph with everything test already publishes |
| The check | Composes the proposed schema against every other subgraph in the variant. A change to a `@key` another team extends fails on your PR, not theirs |
| Operation checks | Compare against operations the variant saw in the last 7 days (Developer plan) |
| A composition failure | The router keeps serving its last good supergraph. The error shows on the `SupergraphSchema` status |
| CI | Never publishes a schema, never touches the cluster, never writes to `homelab-workspaces`. Kargo moves every digest |

## Federation in five minutes

A GraphQL API publishes a **schema**, a typed list of everything it can answer. Federation lets several teams each own part of one schema, without clients knowing.

| Term | Meaning |
|---|---|
| Subgraph | One team's service and its schema |
| Composition | Merging every subgraph schema into one **supergraph schema**. It fails loudly if two subgraphs disagree |
| Router | The one endpoint clients call. It plans the query, calls the subgraphs it needs, and joins one response |
| Variant | One environment of a graph in GraphOS, written `storefront-homelab@test` |

Subgraphs link through an **entity**, a type split across services and joined on a key.

```graphql
# records subgraph, owns the type
type Record @key(fields: "id") {
  id: ID!
  title: String!
  artist: String!
}

# reviews subgraph, adds a field to a type it does not own
type Record @key(fields: "id") {
  id: ID!
  reviews: [Review!]!
}
```

A client asks for `title` and `reviews` in one query. The router calls both services. Neither service knows the other exists.

## Design

The schema lives with the code that serves it and ships inside the image. It reaches the registry only from the image a pod runs. Everything else follows from that rule.

| Layer | Owns | Does |
|---|---|---|
| A team | The schema and resolvers | Writes one `GraphApi` file |
| Crossplane | The conventions | Writes the Apollo `Subgraph`, the workload, the mesh policy and the labels |
| The Apollo operator | The registry and the router | Reads `/schema.graphql` from the deployed image, publishes it, reloads the router |
| GraphOS | Composition | Refuses subgraphs that disagree, keeps history, checks changes against real traffic |

## Decisions

Three decisions shape schema management.

### 1. Where the schema file lives

| Aspect | Detail |
|---|---|
| Picked | With the service. One commit moves schema and resolvers, so they cannot drift |
| Review | CODEOWNERS on `schema.graphql` puts the graph team on every schema PR in every repo |
| Cost | Review quality depends on branch protection in every repo |

### 2. How the schema reaches the registry

| Aspect | Detail |
|---|---|
| Picked | The Apollo operator reads it from the deployed image. The registry never advertises a field nobody serves |
| Bonus | Apollo maintains the router Deployment |
| Cost | Needs a paid plan, and the operator's Kinds are still alpha |
| Platform | The operator ships a `linux/arm64` image. The router runs a rebuild of Apollo's image, because Apollo's aborts on the Pi's 16K-page kernel |

### 3. Governance of schema changes

| Aspect | Detail |
|---|---|
| Picked | Checks plus code owners. Review happens where the code already is |
| Cost | The graph team sees changes only where it is a code owner |
| Later | Schema proposals and linting. See [TODO](#todo) |

## The offerings

Two platform Kinds in `platform.local.lab`. Teams never apply an `apollographql.com` Kind. The `workloads` AppProject does not allow them.

| Kind | Who creates it | What it means |
|---|---|---|
| `GraphApi` | A team | "Run this image as a subgraph of that graph" |
| `FederatedGraph` | The platform team, one per environment | "Here is the endpoint clients call" |

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: FederatedGraph
metadata:
  name: storefront
  namespace: graph-test
spec:
  parameters:
    graphRef: storefront-homelab@test
    host: graph-test.local.lab
    replicas: 1
```

It lists no subgraphs. A team joins by merging its own file, never by editing the platform team's.

## What a team writes

```yaml
apiVersion: platform.local.lab/v1alpha1
kind: GraphApi
metadata:
  name: records
  namespace: graph-test
spec:
  parameters:
    graph: storefront
    image: ghcr.io/cujarrett/storefront-records@sha256:4f1c...   # digest, written by Kargo
    size: sm
```

`GraphApi` takes four parameters: `graph`, `image`, `size` and `replicas`. `sqlRef`, `cache` and `consumes` arrive when a real subgraph needs one.

These are fixed by convention, never a field.

| Convention | Value |
|---|---|
| Schema location | `/schema.graphql` inside the image |
| Image reference | A digest, never a tag |
| Port | `8080`, the `Api` default |
| Endpoint | `http://<name>.<namespace>.svc.cluster.local/graphql`, from the Service the nested `Api` creates |
| Ingress | None. The router is the only front door |
| Allowed caller | The `FederatedGraph` router in the same namespace |
| Labels | `platform.local.lab/graph: <graph>` and `platform.local.lab/environment: <namespace>`. Apollo's selectors have no namespace field, so the environment label keeps each graph in its own namespace |

## What gets rendered

| Platform Kind | Renders |
|---|---|
| `GraphApi` | An `Api` XR with no `host`. An Apollo `Subgraph` with `schema.ociImage` set to the same image digest, the endpoint and both labels |
| `FederatedGraph` | A `SupergraphSchema` selecting both labels, with `partial: false` and `deletionPolicy: KeepVariant`. A `Supergraph` reading `schema.resource`, with introspection off and a global rate limit. A LAN `HTTPRoute` when `host` is set, and the router's mesh objects |

`GraphApi` nests an `Api`, the way `Api` nests a `Cache`. Bindings, sizing, mesh, metrics and identity all carry over.

## Promoting in Kargo

Kargo at [kargo.local.lab](https://kargo.local.lab/project/kargo-storefront) is the only tool a team needs to reach prod. Each card is a stage.

| You see | Meaning |
|---|---|
| Freight | One pair of subgraph images that ran together, named by an alias such as `opining-abalone` |
| Middle of a card | The Freight that stage runs now |
| Left badge, Verifying | Checks are running. They finish within five minutes |
| Left badge, Ready | Checks passed. That Freight can go to prod |
| Left badge, Failed | A check failed. Click the card, open Verifications, and read which one |
| Right badge, Healthy | The stage's app is up |
| ⚠ on Select | That Freight has not passed test. Kargo offers a manual approval. Leave it and fix the cause |

Each check has its own fix.

| Check | Fails when | Fix |
|---|---|---|
| `prod-schema-check` | a schema breaks composition with prod, or breaks an operation prod clients send | change `schema.graphql` and merge. The new Freight runs the checks again |
| `test-router-query` | the test router cannot answer a query that joins both subgraphs | check the test router at `graph-test.local.lab` |
| either, after exactly five minutes | an image fails [Image Provenance](./image-provenance.md), so the check never started. A Discord alert names the policy | merge a change to main so a new image builds, then click Reverify on the stage |

## PR environments

Each open subgraph PR gets its own router. It serves all of test, with the PR's subgraph swapped in. GraphOS never sees it.

| Part | How it works |
|---|---|
| Image | The shared [subgraph workflow](../../.github/workflows/subgraph.yml) builds it and tags it `pr-<number>-<commit>`. Kargo picks up only `sha-` tags. Subgraph repos call that workflow and hold no build steps |
| Environment | The `graph-pr` ApplicationSet in [graph-pr-appset.yaml](../../cluster/argocd/graph-pr-appset.yaml) polls GitHub for open PRs every minute. ArgoCD applies [pr-chart](../federated-graph/pr-chart/) into `graph-pr-<subgraph>-<number>` |
| Chart | The namespace, a `FederatedGraph` using the `federated-graph-pr` Composition, and a `GraphApi` that runs the PR's image and publishes nothing |
| Subgraph list | The `federated-graph-pr` Composition copies every subgraph's name, image and address from the `Subgraph` objects in `graph-test`. It swaps in the PR's subgraph. A PR on `reviews` gets `records` from test |
| Supergraph | The router pod mounts each image as a read-only volume. Nothing in them runs. An init container runs Rover from [images/rover](../../images/rover/) to join every `/schema.graphql` into one file |
| Traffic | The router calls the PR's subgraph in the PR namespace, and test's pods for the rest |
| Test changes | A promotion changes a digest, so the router restarts with the new schemas |
| On the PR | One comment names the namespace, links the Argo app and gives the query command. Each commit updates it |
| Cleanup | Closing the PR deletes the namespace |
| Calls into test | Test admits the router's ServiceAccount from any `graph-pr-*` namespace. PR code itself can't call test |
| PR builds | Kyverno lets `refs/pull/` builds run only in `graph-pr-*` namespaces |
| Authors | Only authors in the ApplicationSet `selector` get an environment. A fork PR gets none |

## Protecting the graph

Each control fails closed.

| Threat | Control | Where |
|---|---|---|
| A schema change breaks the graph | the PR check fails. The router keeps the last good supergraph | CI, GraphOS |
| An unreviewed schema merges | branch protection requires a PR and the check. CODEOWNERS requests a review | GitHub |
| A person publishes a schema | no person holds Contributor. Observer is enough for local work | GraphOS roles |
| An unreviewed image runs in test or prod | Kyverno admits only images the repo's CI built and signed on `main` | Kyverno |
| An unsigned image's schema is published without its pod running | Kyverno checks the same signature on `spec.schema.ociImage.reference` of every `Subgraph` | Kyverno |
| A schema is changed by hand in the cluster | teams apply only `platform.local.lab` Kinds. No human holds write on Apollo Kinds | ArgoCD AppProject, RBAC |
| A test compromise publishes to prod | prod has its own operator and key, watching only `graph-prod` | operator install |
| An operator key is stolen | only its operator's ServiceAccount can read it. CI holds its own key | Parameter Store, RBAC, GitHub |

Subgraphs keep STRICT mTLS from their nested `Api`. `FederatedGraph` renders the router's `Sidecar` and the `ServiceEntry` objects for GraphOS. See [Platform Connections](./connections.md).

## What a request costs

The Developer plan bills $5 per million router requests after a $50 credit, with no spend limit. Few callers can reach a router, so the bill stays at zero.

| Guard | Detail |
|---|---|
| LAN only | Neither router has a public hostname |
| One public caller | The demo's backend, capped at 60 router requests a minute. That is under $1 a month |
| Backups | The page's `Spa` has the platform's per-IP rate limit, and every backend call passes through it. Every router sets `traffic_shaping.router.global_rate_limit` |

## The demo

`graph.mattjarrett.dev` walks the five steps of [How a change moves](#how-a-change-moves) on a map of the cluster and GraphOS, in the shape of [launchpad's how-it-works](https://launchpad.mattjarrett.dev/how-it-works).

| Part | What it does |
|---|---|
| Run it | Two fixed queries, one button each. The response shows the query plan, which subgraph answered, and each subgraph's prod digest and last schema commit |
| Live, right now | The same digests, the last merged PR and the last schema commit, from GitHub |
| Backend | An `Api` with one endpoint per query and one for the live rows. Past 30 calls a minute per query it serves the last answer. It reads GitHub every ten minutes. Nothing the public sends reaches the router or GitHub |
| Code | [platform-graph-demo](https://github.com/cujarrett/platform-graph-demo), under `spa/` and `backend/`. It deploys to the `platform-graph-demo` namespace |

## Foundations to install

Everything here comes before the first subgraph.

| Foundation | Where |
|---|---|
| GraphOS org on the Developer plan, graph `storefront-homelab`, variants `test` and `prod` | apollographql.com |
| Two operator API keys, test and prod, from `rover api-key create <ORG_ID> operator <NAME>` | Parameter Store, each rendered to its operator's namespace by an `ExternalSecret` |
| Operator Helm chart `registry-1.docker.io/apollograph/operator-chart`, installed twice. The prod install sets `installCRDs: false` and `rbac.create: false`. The chart's CRDs ship empty lists the API server drops, so the Application needs `ignoreDifferences` on them | [apollo-operator-test.yaml](../../cluster/argocd/apollo-operator-test.yaml) and [apollo-operator-prod.yaml](../../cluster/argocd/apollo-operator-prod.yaml) |
| The operator's namespace in the ESO store `conditions` | [store.yaml](../../cluster/external-secrets/store.yaml) |
| Crossplane RBAC for `apollographql.com` Kinds | [rbac.yaml](../../cluster/crossplane/rbac.yaml) |
| `graph-test` and `graph-prod` in the `workloads` project destinations and every namespace list of the workspace RBAC policy | [projects.yaml](../../cluster/argocd/projects.yaml), [workspace-rbac.yaml](../../cluster/kyverno/workspace-rbac.yaml) |
| A GraphOS key that can run checks, as an Actions secret | each subgraph repo |
| Kyverno `ImageValidatingPolicy` checking each subgraph repo's `main` build signatures on images in both lanes, for pods and Apollo `Subgraph` resources | `cluster/kyverno/` |
| `graph.mattjarrett.dev` tunnel entry for the demo page, before its cert. The backend sits behind the page's `apiProxies` and needs no hostname | `/add-cloudflare-tunnel-hostname` |

## Known limits

| Limit | Detail |
|---|---|
| Alpha operator | Its Kinds are `v1alpha2` and `v1alpha4`. Expect breaking upgrades |
| Shared CRDs | The test operator's Application owns the CRDs and ClusterRoles prod uses. Deleting it deletes every `Subgraph` and `Supergraph` in both lanes. Keep its name |
| Start order | An operator that starts before its RoleBindings exist gets 403 on its watches and never recovers. Its CRs show no status. Restart the pod. This happens on every fresh install |
| No user authorization | Anyone on the LAN can query any field. See [TODO](#todo) |
| Router key Secret | The operator writes a graph API key Secret into each router namespace. It is controller-generated, so it stays out of ESO |
| Thin operation checks | The demo's backend is the only client, so checks protect a few fixed queries |
| CI keys are Graph Admin | On the Developer plan a key has one role, and it can publish. A leaked `storefront-records` key could publish over `reviews`. Each repo holds its own key, so a leak is traced and rotated in one place |

## TODO

Each item builds on a working demo.

| Item | Plan |
|---|---|
| User authorization | JWT on the router with Entra as issuer, then `@authenticated` and `@requiresScopes` on fields |
| Schema governance | Proposals for shared types, `@contact` on every subgraph, linting in checks. See [decision 3](#3-governance-of-schema-changes) |
| Router fleet | Internal, partner and canary routers reading one variant |
| More clusters | Each cluster's operator publishes its own subgraphs with `partial: true` |

## Reference

| Concept | Link |
|---|---|
| Federation entities | [apollographql.com/docs/federation/entities](https://www.apollographql.com/docs/federation/entities) |
| Apollo GraphOS Operator | [apollographql.com/docs/apollo-operator](https://www.apollographql.com/docs/apollo-operator) |
| Operator `Subgraph` | [resources/subgraph](https://www.apollographql.com/docs/apollo-operator/resources/subgraph) |
| Operator `SupergraphSchema` | [resources/supergraphschema](https://www.apollographql.com/docs/apollo-operator/resources/supergraphschema) |
| Operator `Supergraph` | [resources/supergraph](https://www.apollographql.com/docs/apollo-operator/resources/supergraph) |
| Rover dev | [rover/commands/dev](https://www.apollographql.com/docs/rover/commands/dev) |
| Schema checks | [schema-management/checks](https://www.apollographql.com/docs/graphos/platform/schema-management/checks) |
| Member roles | [access-management/member-roles](https://www.apollographql.com/docs/graphos/platform/access-management/member-roles) |
| Kyverno image validation | [ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/) |
| GraphOS pricing | [apollographql.com/pricing](https://www.apollographql.com/pricing) |
| Demo repo pattern | [platform-connections-demo](https://github.com/cujarrett/platform-connections-demo) |
