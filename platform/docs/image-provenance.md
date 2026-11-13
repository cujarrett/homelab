# Image Provenance

Only images built from main can run.
This meets SLSA Build Level 3.

[SLSA](https://slsa.dev/spec/v1.2/levels) is an industry scale for how far you can trust a build.

- **Level 1:** the build says how it made the image.
- **Level 2:** a hosted build service signs that record.
- **Level 3:** the build steps can't forge or change that record.

## Building an image

Call the shared workflow from your repo's CI.

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

## What the cluster checks

The cluster checks every `ghcr.io/cujarrett/` image before a pod starts.
A failed check blocks the pod.

- **Signer:** `build-image.yml` on homelab main.
- **Repo:** the repo with the same name as the image.
- **Branch:** main.

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
- **Homelab owns the build steps.** An app repo can't change them.
