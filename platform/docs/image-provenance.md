# Image Provenance

Only images built from main can run. PR environments also run pull request builds.
This meets SLSA Build Level 3.

[SLSA](https://slsa.dev/spec/v1.2/build-track-basics) is an industry scale for how far you can trust a build.

- **Level 1:** the build says how it made the image.
- **Level 2:** a hosted build service signs that record.
- **Level 3:** the build steps can't forge or change that record.

## Building an image

Call the platform's shared workflow from your repo's CI.

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

- **What you get:** the image, a signed build record and a package list (SBOM).
- **Pull requests:** set `check-only: true`. It builds and pushes nothing.
- **Other inputs:** see [build-image.yml](../../.github/workflows/build-image.yml).

## How a build works

Your repo holds the Dockerfile. The platform holds the steps that build it.

1. **Your repo's CI calls the platform's shared `build-image.yml`.** It runs on a fresh GitHub ARM machine.
2. **It checks out your repo** at the commit that started the run.
3. **Docker runs your Dockerfile**, line by line. Most start `FROM` a platform base image, such as `base-go` or `base-spa`.
4. **It pushes the image to ghcr.io** with each tag you passed. The registry gives it a digest, a fingerprint of its exact contents.
5. **GitHub signs a build record** for that digest. The record names your repo, the commit, the branch and the workflow that built it.
6. **It lists every package in the image** (the SBOM) and signs that list too.
7. **Both signed records are stored** in ghcr.io, next to the image.

With `check-only: true`, steps 1 to 3 run and nothing is pushed.

## What the cluster checks

The cluster reads the signed build record for every `ghcr.io/cujarrett/` image before a pod starts.
Image volumes are checked too. A failed check blocks the pod.

- **Signer:** the platform's `build-image.yml`, from main of the homelab repo.
- **Repo:** the repo with the same name as the image.
- **Branch:** main. In `graph-pr-*` namespaces, a pull request build passes too.

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

## Why this is Level 3

- **GitHub runs the build** on a fresh machine.
- **GitHub signs the build record.**
- **The platform owns the build steps.** An app repo can't change them.
