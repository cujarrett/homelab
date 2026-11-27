---
description: Weekly review of the platform by five reviewers (security, Kubernetes API, CNCF, developer, grug). Writes new findings to local-only/todo.md, then offers options for the top five.
---

Review the homelab platform and write a todo list. Done means every new finding sits in
`local-only/todo.md` with evidence and a fix, and nothing is changed yet.

## Goal
A lean internal developer platform (IDP), built the way a Fortune 100 platform team would
build it on CNCF projects, at grug size.
- Kubernetes is the core. Every offering is a Kubernetes resource and behaves like one.
- Small enough to hold in one head. Less code is the default fix.
- Removing something beats adding a guard for it.
- Lean wins ties. Process or code for a scale this cluster will never see is not a finding.

## Scope
- `platform/` (XRDs, compositions, docs), `cluster/` (Kyverno, Argo, monitoring rules)
- `launchpad-api/render.go` and `homelab-workspaces`, where they touch platform fields
- The live cluster, read-only
- Memory sizes belong to `/memory-review`. Leave them out.

## Start
Line 3 of `local-only/todo.md` reads `Last review: <date> <sha>`.
- No such line: review everything.
- Otherwise review only what changed since.
  ```bash
  git log --stat <sha>..HEAD -- platform cluster
  git -C ../launchpad-api log --oneline --since=<date> -- render.go
  git -C ../homelab-workspaces log --oneline --since=<date>
  ```
- Delete every checked item. Git history holds the fix.
- An open item is raised again only when its linked file changed since `<sha>`.
  Check with `git log <sha>..HEAD -- <file>`.

## Actors
Every security finding names one.
- Guest: clicks in Launchpad. `launchpad-api` sets every field and size of a guest XR.
- Tenant team: writes XR fields in its own workspace. Today that is the owner.
- Workload: code running in a pod, inside the mesh.

## Decided
Never re-raise these. Raise one only if the reason below no longer holds, and say what changed.
Delete a line when the thing it covers leaves the code.
- Declared egress unchecked: guests cannot set egress fields, and only the owner writes workspace XRs.
- No quota or replica caps: launchpad-api fixes guest sizes, and slots cap the count.
- DB passwords from the XR UID: the mesh lets only the bound app reach the database.
- xrs ApplicationSet can cascade-delete: only WordPress holds data, its volumes are retain, and a revert restores the rest.
- No Longhorn snapshots: 3 replicas cover a dead disk, and WordPress, Ghost and Grafana have backups or live in git.
- Ready stays hard-coded on Topic, Subscription, FederatedGraph and the held Api Deployment: kept small on purpose.
- Public-cloud Sql and Cache: the owner keeps the public cloud flavors. Their IAM scope is still fair game.
- Spa userAuth and entraApp: unused, kept as a proof of concept for Launchpad.
- Renovate chart bumps automerge unreviewed: the 7-day wait is the defence.
- Stuck-state alerts wait 15m: the longest normal sync is 5 minutes, and the longest XR start is 3 minutes.
- A graph router admits any meshed caller that declares it: both graphs already serve the same data on a `local.lab` host.
- Five AWS provider pods for about 10 AWS objects: guest sandboxes need every provider live, and ctrl-1 has the memory.
- The k3s `GOMEMLIMIT` on ctrl-1: it saves about 2Gi, and live data sits under half the cap.
- A Spa answers 200 with the app shell for an unknown path with no dot: the page holds nothing private, and the `$probe` rule covers the alert's words.

## Reviewers
Five people read the same code. Run each as its own pass, and finish one before the next.
Each pass forgets the others, so two reviewers may disagree. Write both down.

1. Security engineer: tenant breakout, injection through XR fields, unchecked images or
   egress, auth rules that admit more than they claim. Say which actor does it and what they get.
2. Kubernetes API reviewer: does each XRD behave like a good Kubernetes resource?
   - Ready and status conditions that tell the truth
   - Fields that cannot change safely, with no validation rule to stop the change
   - References to other resources that nothing checks
   - XRD defaults that differ from template fallbacks
   - Deletes that cascade, and states that raise no alert
   - The same idea spelled differently across types
3. CNCF maintainer: is this the upstream documented pattern?
   - Hand-built code that a project already in the cluster does natively
   - Deprecated APIs, flags and package sources
   - A setting that fights the project's default with no reason written
4. Developer at a large company: uses the platform with no way to ask the owner.
   - A field whose description does not say what to put in it
   - A failure that does not say what to fix
   - Docs that claim more than the code enforces
5. Grug: fields, branches or templates with zero uses. Give the line count each removal saves.
   ```bash
   k get <plural>.platform.local.lab -A -o yaml | grep -c '<field>:'
   grep -rn '<field>' ../homelab-workspaces ../launchpad-api/render.go | wc -l
   ```
   Also list every hand-set number that replaces a default: worker and processor counts,
   intervals, hand-grown lists. Read the live value beside each one.
   - No reason written: a finding. Deleting the setting is the first fix to offer.
   - A limit within 20% of live use: a finding. Raise it or delete it, never tighten it.

## Each finding
- Two or three sentences: what is wrong, the worst case, the smallest fix, and a link to file:line
- Number it on from the highest number in the todo
- Mark anything not proven as "inferred"
- Rank the fixes by size, and prefer the zero-line option (accept the risk, delete it)
- A fix of about 75 lines for a low worst case loses to accepting the risk
- Group the findings under Security, Data loss and stuck states, Simplicity, Docs
- End with "Keep as is" (what's good) and "Not reviewed"
- Set line 3 to `Last review: <today> <HEAD sha>`

## Then
Pick the top five by worst case. Ties go to the smaller fix.
Prove each one first, with `crossplane render`, a live `k get` or a server-side dry run.
An item that stays inferred gives its place to the next one.

Report the top five in about 100 words. Work through them one at a time.
For each one, give Options A, B, C and a Recommendation, and change nothing until
the owner picks.
When the owner accepts a risk or keeps something on purpose, add one line to
"Decided" in this file, with the reason.
