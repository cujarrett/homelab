---
description: Render all XApi workspaces against the current composition to catch template errors and breaking changes before pushing. Requires Docker running locally.
---

Run `crossplane render` for every XApi workspace against the current composition. Report any failures clearly.

**Prerequisite:** Docker must be running. The render command pulls and runs `function-go-templating` as a container.

```bash
crossplane render \
  ../homelab-workspaces/my-vinyl/my-vinyl-api.yaml \
  platform/api/composition.yaml \
  local-only/render-functions.yaml

crossplane render \
  ../homelab-workspaces/sump-pump/sump-pump-bridge.yaml \
  platform/api/composition.yaml \
  local-only/render-functions.yaml

crossplane render \
  ../homelab-workspaces/sump-pump/sump-pump-consumer.yaml \
  platform/api/composition.yaml \
  local-only/render-functions.yaml

crossplane render \
  ../homelab-workspaces/sump-pump/weather-exporter.yaml \
  platform/api/composition.yaml \
  local-only/render-functions.yaml
```

For each render:
- If it exits 0, summarise any Deployment changes vs what is currently running (diff the volumeMounts, initContainers, env blocks)
- If it exits non-zero, show the error and explain what in the composition caused it
