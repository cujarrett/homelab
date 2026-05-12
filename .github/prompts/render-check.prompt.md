---
agent: agent
description: Render all XApi tenants against the current composition to catch template errors and breaking changes before pushing. Requires Docker running locally.
---

Run `crossplane render` for every XApi tenant against the current composition. Report any failures clearly.

**Prerequisite:** Docker must be running. The render command pulls and runs `function-go-templating` as a container.

```bash
cd /Users/matt-jarrett/Developer/homelab-group/homelab

crossplane render \
  ../homelab-tenants/my-vinyl/my-vinyl-api.yaml \
  platform/api/composition.yaml \
  .github/prompts/render-functions.yaml

crossplane render \
  ../homelab-tenants/sump-pump/sump-pump-bridge.yaml \
  platform/api/composition.yaml \
  .github/prompts/render-functions.yaml

crossplane render \
  ../homelab-tenants/sump-pump/sump-pump-consumer.yaml \
  platform/api/composition.yaml \
  .github/prompts/render-functions.yaml

crossplane render \
  ../homelab-tenants/sump-pump/weather-exporter.yaml \
  platform/api/composition.yaml \
  .github/prompts/render-functions.yaml
```

For each render:
- If it exits 0, summarise any Deployment changes vs what is currently running (diff the volumeMounts, initContainers, env blocks)
- If it exits non-zero, show the error and explain what in the composition caused it
