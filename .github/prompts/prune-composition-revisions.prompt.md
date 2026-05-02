---
agent: agent
description: Delete stale Crossplane composition revisions, keeping the latest 3 per composition
---

Delete all but the latest 3 CompositionRevisions for each composition in the cluster:

```bash
for comp in spa-composition wordpressplatform-composition xapi xcache xobjectstorage xsubscription xtopic; do
  count=$(kubectl get compositionrevision -l crossplane.io/composition-name=$comp --no-headers 2>/dev/null | wc -l | tr -d ' ')
  delete=$((count - 3))
  if [ "$delete" -gt 0 ]; then
    revisions=$(kubectl get compositionrevision -l crossplane.io/composition-name=$comp \
      --no-headers --sort-by='.spec.revision' | awk '{print $1}' | head -n "$delete")
    echo "$revisions" | while read -r rev; do kubectl delete compositionrevision "$rev"; done
  fi
done
```

After running, verify with:
```bash
k get compositionrevision --no-headers \
  -o custom-columns='COMP:.metadata.labels.crossplane\.io/composition-name,REV:.spec.revision' \
  | sort | awk '{count[$1]++} END {for (c in count) print count[c], c}'
```

Note: Crossplane 2.2 does not support `revisionHistoryLimit` on the Composition spec — cleanup must be done manually.
