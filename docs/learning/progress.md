# Learning Progress

Tracks calibrated level per topic and the next grill question, so a session can pick up cold. Update it at the end of each session — don't batch.

## Sequence

1. Go fundamentals - **in progress**, via [learning-go](https://github.com/cujarrett/learning-go)
2. Controllers - **in progress**, via [Controllers](./controllers.md)
3. Crossplane - not started, blocked on (2)
4. Entra / authz - not started, no dependency

## Go fundamentals

Level: module 01 of six done - pointers, copies and nil. Wrote `Rename`/`RenameCopy` and saw why a value receiver's write is dead, filled a caller-owned struct through an `out *Server`, and got `NoteOr` right by branching on `s.Note == nil` rather than on the value, which is the case most people miss.

Gap: everything from module 02 on - slices sharing a backing array, maps, errors as values, receivers and interfaces, struct tags. Dereferencing still reads as syntax rather than as a thing being done.

Next question: given `for _, s := range servers { s.Active = true }`, say what that does and why, then say what changes if `servers` is `[]*Server` instead of `[]Server`.

## Controllers

Level: built and deployed one. Wrote a CRD from Go structs, a reconcile loop with drift correction, ownership labels, pruning, a finalizer, watches with map functions, status conditions and events, namespaced RBAC with a matching cache scope, and tests against the fake client. Comfortable with the reconcile-as-a-loop model and why a watch is a cluster-wide list.

Gap: Go itself is still the friction, now being worked directly - see Go fundamentals below. Also untouched: `Owns()` and ownerReference garbage collection, since the mirror deliberately cannot use them.

Next question: point at a controller that creates a Deployment in its own namespace and ask what `Owns()` buys that a manual `Watches` plus map function would not.

## Crossplane

Level: correctly identifies that a provider replaces a hand-authored controller. Gap: how an XRD/Composition maps to real controller logic - XR vs MR, what a provider does with a rendered Composition.

Next question: point at a real Composition in `platform/` and ask which parts are "the controller logic" and which the provider gives for free.

## Entra / authz

Level: zero, not yet calibrated beyond "don't know."

Next question: why can't one App Registration cleanly serve as both client and resource once a second client needs the same API?
