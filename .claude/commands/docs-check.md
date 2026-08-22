---
description: Verify docs against each other and against the live schema, before asking anyone to read them
---

Docs in this repo drift in eight predictable ways. Every one of them has bitten a real review.
Run this after editing anything under `docs/`, `platform/docs/`, or a `README.md`, and before
telling the user a doc is ready.

Do not report a doc as ready until every check below passes. Report failures as a list, fix
them, then re-run.

## 1. Dead file links

A doc that moves breaks every link into it, and a doc that moves breaks every link *out* of
it too, because relative paths shift under the new directory. The second kind is the one
that gets missed.

```bash
cd "$(git rev-parse --show-toplevel)"
/usr/bin/python3 - <<'EOF'
import re, pathlib
pat = re.compile(r'\]\((\.\.?/[^)]*\.md)')
bad = []
for f in pathlib.Path('.').rglob('*.md'):
    if 'node_modules' in str(f) or str(f).startswith('local-only'): continue
    for p in pat.findall(f.read_text()):
        if not (f.parent / p.split('#')[0]).resolve().is_file():
            bad.append(f'DEADFILE  {f} -> {p}')
print('\n'.join(bad) if bad else 'files ok')
EOF
```

## 2. Dead anchors

Renaming a heading silently breaks every deep link to it. A file-path check will not catch
this, because the file still exists.

```bash
cd "$(git rev-parse --show-toplevel)"
/usr/bin/python3 - <<'EOF'
import re, pathlib
pat = re.compile(r'\]\((\.\.?/[^)]*\.md)#([a-z0-9-]+)\)')
bad = []
for f in pathlib.Path('.').rglob('*.md'):
    if 'node_modules' in str(f) or str(f).startswith('local-only'): continue
    for p, a in pat.findall(f.read_text()):
        t = (f.parent / p).resolve()
        if not t.is_file():
            bad.append(f'DEADFILE    {f} -> {p}#{a}'); continue
        slugs = {re.sub(r'[^a-z0-9 -]', '', h.lower()).strip().replace(' ', '-')
                 for h in re.findall(r'^#{1,6}\s+(.*)$', t.read_text(), re.M)}
        if a not in slugs:
            bad.append(f'DEADANCHOR  {f} -> {p}#{a}')
print('\n'.join(bad) if bad else 'anchors ok')
EOF
```

## 3. Field names that do not match the schema

The worst failure, because it looks correct and costs implementation time. A doc that says
`workspace:` while [the XRD](../../platform/api/xrd.yaml) says `namespace:` sends someone
down the wrong path before they notice.

Pull every field name out of the YAML blocks in the doc and confirm each one exists in the
XRD it claims to describe.

```bash
cd "$(git rev-parse --show-toplevel)"
# every key used in a doc's YAML fences
awk '/^```yaml/,/^```$/' platform/docs/app-configuration.md | grep -oE '^[[:space:]]*[a-zA-Z][a-zA-Z0-9]*:' | tr -d ' :' | sort -u
# every property the XRD actually defines
grep -oE '^[[:space:]]+[a-zA-Z][a-zA-Z0-9]*:' platform/api/xrd.yaml | tr -d ' :' | sort -u
```

Diff those by eye. A field in the doc and not the XRD is either a proposed change, which the
doc must say plainly, or a mistake. Never leave it ambiguous.

## 4. Numbered cross-references

`see requirement 6` breaks the moment a list gains or loses an entry, and nothing warns you.

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn "equirement [0-9]\|[Oo]ption [0-9]\|rinciple [0-9]\|[Gg]ate [0-9] above" \
  docs/ platform/docs/ platform/*/README.md --include="*.md" | grep -v "^docs/runbooks/\|^docs/how-it-was-built"
```

Every hit is a defect. Replace it with the thing itself: "the requirement that a page script
cannot read a user's token", not "requirement 6".

Runbooks and build logs are excluded on purpose. A numbered step in a sequential procedure is
the content, not a reference, and flagging those trains you to ignore the check.

## 4b. Links into `local-only/`

That directory is gitignored, so any link into it is dead for every reader but you.

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rn "](.*local-only/" --include="*.md" . \
  | grep -v "^\.\?/\?local-only/\|^\.\?/\?CLAUDE\.md:\|^\.\?/\?\.claude/" || echo "none"
```

## 5. The same field described two ways

The most expensive failure, because both docs read as correct. Build the inventory first,
then compare, rather than trusting a read-through to notice.

```bash
cd "$(git rev-parse --show-toplevel)"
/usr/bin/python3 - <<'EOF'
import re, pathlib, collections
docs = list(pathlib.Path('platform/docs').glob('*.md')) + \
       list(pathlib.Path('platform').glob('*/README.md')) + \
       [pathlib.Path('platform/README.md')]
seen = collections.defaultdict(set)
for f in docs:
    for tok in re.findall(r'`([a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9\[\]]+)*)`', f.read_text()):
        seen[tok].add(str(f))
for tok, files in sorted(seen.items()):
    if len(files) > 1:
        print(f'{tok:38} {", ".join(sorted(files))}')
EOF
```

Every field appearing in more than one doc is a place two descriptions can disagree. For each
one, read both mentions and confirm they say the same thing. Watch for a field that is
optional in one doc and required in another, or that has different sub-keys in each.

Then check the docs against the schema itself, which is the only authority:

```bash
cd "$(git rev-parse --show-toplevel)"
for x in api spa; do
  echo "--- $x XRD properties ---"
  grep -oE '^[[:space:]]+[a-zA-Z][a-zA-Z0-9]*:' platform/$x/xrd.yaml | tr -d ' :' | sort -u
done
```

A field a doc uses that the XRD does not define is either a proposed change, which the doc
must label as one, or a mistake. This is how `workspace:` shipped into a doc while the schema
said `namespace:`.

## 6. Absolute claims that another doc contradicts

A doc says "never" and a second doc documents the exception. Both look right alone.

Scope this to where normative statements live: numbered requirement lists and bolded principle
bullets. Grepping all prose returns "never started" and "Nothing novel" and teaches you to
skim past it.

```bash
cd "$(git rev-parse --show-toplevel)"
grep -rnE "^([0-9]+\. |- \*\*)" platform/docs/*.md platform/README.md \
  | grep -iE "\b(never|always|nobody|nothing|every|cannot|only|no [a-z]+ )\b"
```

For every hit, ask two questions. Does another doc describe a case where this is false? And
is there a CEL rule, Kyverno policy, or schema shape that makes it true? A claim with neither
an exception nor an enforcement is a wish, so either soften it or add the check.

Both failure modes are real here. "Nobody types an `aud`" was contradicted by the off-platform
section three headings later. "A frontend has one backend" had nothing enforcing it.

## 7. Behaviour one doc changed and another still describes

When a design changes, the doc you edited is correct and every doc that mentioned the old
behaviour is now lying. Grep for the removed thing by name across everything, not just the
docs you touched.

```bash
cd "$(git rev-parse --show-toplevel)"
# replace with whatever the change removed or renamed
for term in connectionPosture entra.enabled apiProxies allowedCallers; do
  echo "--- $term ---"
  grep -rn "$term" --include="*.md" docs/ platform/ CLAUDE.md 2>/dev/null || echo "none"
done
```

A hit inside a "what to build" list is fine, because it names something being removed. So is a
hit in a README describing what is actually deployed, when the change is designed but not
shipped yet.

That second case is only safe if the design doc says so in its first line. Two docs describing
the same field differently, with nothing marking one as the target and the other as today, is
the defect - a reader cannot tell which is real. Check for that sentence before accepting the
mismatch.

A hit in prose describing behaviour that has already shipped elsewhere is always a defect.

## 8. One subject per doc

When two docs cover adjacent ground, one gets updated and the other does not.

- [platform/docs/app-configuration.md](../../platform/docs/app-configuration.md) - what a team declares
- [platform/docs/connections.md](../../platform/docs/connections.md) - how the mesh enforces it
- [platform/docs/workload-identity.md](../../platform/docs/workload-identity.md) - how a pod proves who it is
- [platform/docs/service-binding.md](../../platform/docs/service-binding.md) - how credentials reach the pod

If a fact appears in two of them, delete it from one and link instead. If a doc has grown a
section belonging to another's subject, move it rather than cross-referencing both ways.
