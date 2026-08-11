# USER, UIDs and runAsNonRoot

A container image can say who its process should run as. Kubernetes can also say
who it should run as, and can refuse to start a container it is not satisfied
with. Those two mechanisms disagree in one specific way, and that disagreement is
what broke the Api rollout.

The short version: **`USER app` and `USER 65532` behave identically at runtime,
but only one of them lets Kubernetes enforce `runAsNonRoot`.**

| Chapter | What it covers |
|---|---|
| [What USER does](#what-user-does) | The Dockerfile instruction, and what "root" means in a container |
| [Why a name is not enough](#why-a-name-is-not-enough) | The rule that caused the failure |
| [runAsNonRoot vs runAsUser](#runasnonroot-vs-runasuser) | Two different controls people mix up |
| [How to check an image](#how-to-check-an-image) | And the check that lies to you |
| [Fixing it](#fixing-it) | The composition override, and the app-repo alternative |
| [Why the platform is the right place](#why-the-platform-is-the-right-place) | Guaranteed centrally, not requested per repo |
| [Why 65532](#why-65532) | Where the number comes from, and why not 100 |
| [Why the ports moved to 8080](#why-the-ports-moved-to-8080) | Privileged ports, and the capability this avoids |
| [Where this bites next](#where-this-bites-next) | Pod Security Admission |

## What USER does

`USER` in a Dockerfile sets the uid the container's main process runs as. Without
it, that process runs as uid 0 — root.

```dockerfile
FROM alpine
RUN adduser -D -u 100 app
USER app          # or: USER 100
```

Root inside a container is not root on the node. It is uid 0 inside a namespace,
with a restricted capability set, usually unable to touch the host. But it is
still the worst starting point for an attacker who lands code execution: uid 0
owns every file in the image, and any capability the runtime left in place is
available to it.

Running as a non-root uid removes that. A process as uid 100 cannot write files
owned by root, cannot use capabilities scoped to uid 0, and has to work much
harder to do anything interesting after an RCE.

## Why a name is not enough

`USER app` and `USER 100` produce the same running process. The difference is
what a *third party* can tell about the image without running it.

Names live in `/etc/passwd` **inside the image**. `app` means nothing until
something opens that file and resolves it. The container runtime does that at
start time — it has the filesystem mounted, so it can.

The kubelet cannot. When it is deciding whether to honour `runAsNonRoot: true`,
it has the image *config* — a small JSON blob with a `User` field — and no
mounted filesystem to resolve a name against. `User: "app"` could be uid 0 for
all it knows. Someone could ship an image where `app` is deliberately uid 0.

So the kubelet refuses, and the container never starts:

```
container has runAsNonRoot and image has non-numeric user (app),
cannot verify user is non-root
```

The status is `CreateContainerConfigError`. It is not a warning and not a
crashloop — the container is never created at all. A Deployment rollout stalls
with the old pods still serving, which is why this failed safe.

`USER 65532` needs no resolution. The kubelet reads the number, sees it is not
zero, and starts the container.

## runAsNonRoot vs runAsUser

Two separate controls, and the distinction matters when choosing a fix.

`runAsNonRoot: true` is an **assertion**. It does not choose a uid. It says "fail
if this would run as root" and leaves the image's own `USER` in charge. That is
what you want when images legitimately differ — it enforces the property without
dictating the number.

`runAsUser: 65532` is an **override**. It ignores the image's `USER` entirely and
forces that uid. It always satisfies the kubelet, because it is a number in the
pod spec with nothing to resolve.

Override looks like the easy fix and usually is not. A uid the image was not
built for gets a filesystem it does not own. If the image did
`chown -R app:app /app` and the binary is mode 0700, forcing a different uid
means the process cannot read its own binary. Whether it works is luck.

This is why the [Api composition](../../platform/api/composition.yaml) sets
neither: the images disagree on the number — alpine builds use 100, distroless
uses 65532 — so any single `runAsUser` would hand one of them a filesystem owned
by the other.

## How to check an image

The image config is the only thing that matters, because it is the only thing the
kubelet sees:

```bash
docker pull -q --platform linux/arm64 <image>
docker inspect -f '{{.Config.User}}' <image>
```

- a number → fine
- a name → `runAsNonRoot` will refuse it
- empty → the image runs as root and never satisfies `runAsNonRoot`

**The check that lies to you:**

```bash
kubectl exec deploy/foo -c api -- id -u    # prints 100
```

That is the *resolved* uid, after the runtime read `/etc/passwd`. It prints 100
for `USER app` and for `USER 100` alike, so it cannot distinguish the case that
breaks from the case that works. It is the check that missed this before the
rollout — a running container has already done the resolution the kubelet
could not.

Two more things it hides: a distroless image has no shell, so `exec` fails for an
unrelated reason and looks like a different problem; and `id -u` tells you
nothing about what a *rebuilt* image would do.

## Fixing it

Two places this can be fixed, and the platform one turned out to be better.

**In the composition (what was done).** Set `runAsUser` in the pod spec. It
overrides whatever the image declares, so the kubelet has a number in front of it
and never has to resolve anything:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
```

The usual objection is file ownership — force a uid the image was not built for
and the process may not be able to read its own binary. That was checked rather
than assumed, and it does not apply here. Every app binary is root-owned mode
0755:

```
-rwxr-xr-x 1 0 0 11546880 /app/weather-exporter
```

World-executable, so no image needs to own the uid it runs as. `weather-exporter`
was run directly as both uid 100 and uid 65532 with a read-only root and a tmpfs
`/tmp`, and started cleanly both times. The `aws-spiffe-helper` sidecar was
checked the same way — `spire-agent` and `aws_signing_helper` are both 0755 and
execute fine as 65532.

One consequence worth knowing: uid 65532 has no `/etc/passwd` entry in the alpine
images. Nothing here cares, but software that calls `getpwuid()` or Go's
`user.Current()` would fail, and that is the thing to check before assuming this
trick generalises.

**In the app repos (not needed, but still correct).** The one-line change is to
number the user that already exists:

```dockerfile
RUN addgroup -S app && adduser -S app -G app
USER 100          # was: USER app
```

Keep the `adduser` line — the account still needs to exist. Nothing about the
running process changes, and no `chown` is needed because the uid is unchanged.

These five declare a named user. They no longer block anything, since the
composition overrides them, but numbering them would let each image keep its own
identity and passwd entry:

| Repo | Image |
|---|---|
| `my-vinyl-api` | `ghcr.io/cujarrett/my-vinyl-api` |
| `sump-pump-bridge` | `ghcr.io/cujarrett/sump-pump-bridge` |
| `sump-pump-consumer` | `ghcr.io/cujarrett/sump-pump-consumer` |
| `weather-exporter` | `ghcr.io/cujarrett/weather-exporter` |
| `aws-spiffe-helper` | `ghcr.io/cujarrett/aws-spiffe-helper` |

These already declare `USER 65532` and were never affected:
`launchpad-api`, `platform-connections-demo-api`,
`platform-connections-demo-downstream`.

For new images, create the account at 65532 rather than relabelling a lower one —
see [The Dockerfile number is a different decision](#the-dockerfile-number-is-a-different-decision).
It is the conventional non-root uid, matches `gcr.io/distroless/*:nonroot`, and
sits well outside any range a base image assigns to a real account.

## Why the platform is the right place

A per-repo fix depends on every Dockerfile getting it right, forever, including
ones not written yet. A composition fix holds regardless of what an app image
declares — an app that ships `USER app`, or no `USER` at all, still runs as a
non-root uid because the pod spec says so.

That is the general shape of a platform control: the property is guaranteed
centrally rather than requested politely of each team. The app repos stay free to
declare whatever they like; it simply stops being load-bearing.

The tradeoff is that the override is blunt. It assumes no image genuinely needs
its own uid — true here because every binary is world-executable, and worth
re-checking if an image ever ships files chowned to a specific user.

## Why 65532

Nothing in Kubernetes requires this number. Any uid that is not 0 satisfies
`runAsNonRoot`. 65532 is a convention, and conventions are worth following when
the alternative is picking arbitrarily.

It comes from Google's distroless images, whose `:nonroot` variants ship a
`nonroot` account at uid 65532. It sits just below 65534 (`nobody`), high enough
that no base image's `adduser` will ever hand the same number to a real account —
alpine's `adduser -S` counts down from 999, Debian's from 100. So a uid picked
here cannot silently collide with one the image created for itself.

Three of the images already used it, because they build on
`gcr.io/distroless/static-debian12:nonroot`. Choosing 65532 for the override made
those a no-op and only moved the alpine ones.

**Why not 100**, which is what the alpine images already ran as: it would have
been equally valid, and it would have kept `/etc/passwd` resolving inside those
images. The reason against it is the collision risk in reverse — 100 is squarely
inside the range `adduser` allocates from, so a future image could legitimately
assign uid 100 to some other account, and the override would then run the process
as an identity that means something unintended inside that image. 65532 has no
such meaning anywhere.

Either way one family of images runs as a uid with no passwd entry. That only
matters to software that calls `getpwuid()` or Go's `user.Current()`, and nothing
here does.

### The Dockerfile number is a different decision

Two numbers, two questions, and they do not have to match.

**In the pod spec** the number is an override, applied from outside to an image
that may declare anything. Pick one that cannot mean something else inside any
image — 65532.

**In a Dockerfile** the number names an account that image actually has. The five
repos here already create one with `adduser -S app`, which lands on uid 100, so
the minimal correct fix is to name it:

```dockerfile
RUN addgroup -S app && adduser -S app -G app
USER 100          # was: USER app
```

Writing `USER 65532` there instead would declare a uid with nothing behind it —
no passwd entry, no group, no home — so `getpwuid()` fails and anyone running the
image outside Kubernetes gets an identity-less user. The change was only ever
about making the declaration machine-readable; changing which account it points at
is a second change earning nothing.

The consequence is that the image says 100 and the pod runs 65532, because the
composition overrides it. For a **new** image, close that gap by moving the
account rather than relabelling it:

```dockerfile
RUN addgroup -S app && adduser -S -u 65532 app -G app
USER 65532
```

Then the image and the cluster agree and passwd resolves in both.

## Why the ports moved to 8080

Separate problem from USER, same root cause: **ports below 1024 are privileged**.
Binding one has always required root, and on Linux the specific privilege is the
`CAP_NET_BIND_SERVICE` capability.

nginx listens on 80. Run it as uid 65532 with `capabilities: drop: [ALL]` and the
bind fails — the process has neither root nor the one capability that would
substitute for it. So the listener moved to 8080, which any uid may bind.

The alternative was to keep port 80 and add the capability back:

```yaml
capabilities:
  drop: [ALL]
  add: [NET_BIND_SERVICE]
```

That works, and it is what the WordPress composition will have to do, because
Apache starts as root by design in order to bind 80 and drop privileges itself.
For the Spa it was the wrong trade: handing back a capability to avoid changing a
number visible only inside the pod.

Nothing outside the pod noticed. The Service still publishes port 80 and only its
`targetPort` moved, so the Ingress, the tunnel, and every URL are unchanged:

```
Ingress -> Service :80 -> targetPort 8080 -> container :8080
```

The one thing that had to move with it was the mesh policy. Istio's
`AuthorizationPolicy` and `PeerAuthentication` `portLevelMtls` both refer to the
**workload** port, not the Service port, so both had to become 8080. Worth
knowing how that fails: an `ALLOW` policy denies anything its rules do not match,
and a missed `portLevelMtls` exception leaves the port `STRICT` and refuses
plaintext from unmeshed Traefik. Both are outages, not bypasses — the mistake
fails closed.

## Where this bites next

Pod Security Admission's `restricted` level **requires** `runAsNonRoot: true`.
Because the composition now sets that *and* a numeric `runAsUser`, Api workloads
already satisfy it — the five named-user images are no longer a blocker for
labelling those namespaces `restricted`.

The Spa and WordPress compositions have not been through this yet. WordPress will
not pass regardless: `wordpress:*-apache` starts as root by design so it can bind
port 80 and drop to `www-data` itself, which is why it is planned for `baseline`
rather than `restricted`.

Worth knowing about the weaker fallback: with `capabilities: drop: [ALL]`,
`allowPrivilegeEscalation: false` and `readOnlyRootFilesystem: true`, even a root
process has no capabilities to use and nowhere to write. That is most of the
practical containment. What `runAsNonRoot` adds on top is *enforcement* — the
guarantee that a future image which silently runs as root gets caught instead of
quietly starting.
