# Image Provenance

Only images built from main can run. PR environments also run pull request builds.

This meets [SLSA](https://slsa.dev/spec/v1.2/build-track-basics) Build Level 3, an industry scale for how far you can trust a build.

| Level | Requires | How it is met here |
|---|---|---|
| 1 | The build says how it made the image | The build record names the repo, commit, branch and workflow |
| 2 | A hosted build service signs that record | GitHub runs the build on a fresh machine and signs the record |
| 3 | The build steps can't forge or change that record | The platform owns the build steps, and a workload repo can't change them |

## Building an image

Call the platform's shared workflow from the workload repo's CI.

```yaml
jobs:
  build:
    if: github.ref == 'refs/heads/main'
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
    uses: cujarrett/homelab/.github/workflows/build-image.yml@main
    with:
      image: ghcr.io/cujarrett/foo
      tags: |
        ghcr.io/cujarrett/foo:sha-${{ github.sha }}
      cache-scope: foo
```

| Topic | Detail |
|---|---|
| What you get | The image, a signed build record and a package list (SBOM) |
| Pull requests | Set `check-only: true`. It builds and pushes nothing |
| Other inputs | See [build-image.yml](../../.github/workflows/build-image.yml) |

## How a build works

The workload repo holds the Dockerfile. The platform holds the steps that build it.

1. **The workload repo's CI calls the platform's shared `build-image.yml`.** It runs on a fresh GitHub ARM machine and checks out the commit that started the run.
2. **Docker runs the workload's Dockerfile**, line by line. Most start `FROM` a platform base image, such as `base-distroless` or `base-nginx`.
3. **It pushes the image to ghcr.io** with each tag the workload repo passed. The registry gives it a digest, a fingerprint of its exact contents.
4. **GitHub signs a build record** for that digest. The record names the workload repo, the commit, the branch and the workflow that built it.
5. **It lists every package in the image** (the SBOM) and signs that list too.
6. **Both signed records are stored** in ghcr.io, next to the image.

With `check-only: true`, steps 1 and 2 run and nothing is pushed.

## What the cluster checks

The cluster reads the signed build record for every `ghcr.io/cujarrett/` image, image volumes included, before a pod starts. A failed check blocks the pod. An Api, Spa or GraphApi may name only a `ghcr.io/cujarrett/` image, so every app image is checked.

| Field in the record | Must be |
|---|---|
| Signer | The platform's `build-image.yml`, from main of the homelab repo |
| Repo | The repo with the same name as the image |
| Branch | Main. In `graph-pr-*` namespaces, a pull request build passes too |

The rules live in [image-provenance.yaml](../../cluster/kyverno/image-provenance.yaml).

## Adding an image

- **Image named after its repo:** nothing to do.
- **Image named differently:** add it to `repoFor` in the policy. Example: repo `bar` builds `bar-api`.

## Checking an image by hand

```bash
gh attestation verify oci://ghcr.io/cujarrett/foo:sha-abc123 \
  -o cujarrett \
  --signer-workflow cujarrett/homelab/.github/workflows/build-image.yml
```
