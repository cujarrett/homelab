---
description: Weekly review of the platform for security gaps, stuck states, unused code and drift. Writes new findings to local-only/todo.md, then offers options for the top five.
---

Review the homelab platform and write a todo list. Done means every new finding sits in
`local-only/todo.md` with evidence and a fix, and nothing is changed yet.

The owner's main goal: keep the project small enough to hold in one head.
Less code is the default fix. Removing something beats adding a guard for it.

## Scope
- `platform/` (XRDs, compositions, docs), `cluster/` (Kyverno, Argo, monitoring rules)
- `launchpad-api/render.go` and `homelab-workspaces`, where they touch platform fields
- Read `local-only/todo.md` first. An item already there is new only if the code changed since.

## Decided
Never re-raise these. Raise one only if the reason below no longer holds, and say what changed.
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
- A fix of about 75 lines for a low worst case loses to accepting the risk.

## Lenses
1. Security: tenant breakout, injection through XR fields, unchecked images or
   egress, auth rules that admit more than they claim. Say who can do it and what they get.
2. Stuck and data-loss states: Ready that lies, fields that can't change safely,
   deletes that cascade, states that raise no alert.
3. Grug: fields, branches or templates with zero uses. Count uses across
   `homelab-workspaces`, `launchpad-api` and the live cluster (`k get <kind> -A`).
   Give the line count each removal saves.
4. Consistency: the same idea spelled differently across types, XRD defaults that
   differ from template fallbacks, docs that claim more than the code enforces.

## Each finding
- One line: what is wrong, the worst case, the fix, and a link to file:line
- Mark anything not proven as "inferred"
- Rank the fixes by size, and prefer the zero-line option (accept the risk, delete it)
- Group the findings under Security, Data loss and stuck states, Simplicity, Docs
- End with "Keep as is" (what's good) and "Not reviewed"

## Then
Report the top five in about 100 words. Work through them one at a time.
For each one, give Options A, B, C and a Recommendation, and change nothing until
the owner picks.
When the owner accepts a risk or keeps something on purpose, add one line to
"Decided" in this file, with the reason.
