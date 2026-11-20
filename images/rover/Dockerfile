# Rover with the supergraph plugin already installed.
# PR routers use it to build their schema.
# The stock image downloads the plugin, and PR router pods have no internet.
FROM ghcr.io/apollographql/rover:1.0.1@sha256:1e55c1aa335ae9a94200c35b1478c83889be67173808a384fcb181b8fc8ac338

# PR routers build with this version. Bump it here to upgrade.
# renovate: datasource=github-releases depName=apollographql/federation-rs extractVersion=^supergraph@v(?<version>.+)$
ARG SUPERGRAPH_VERSION=2.15.7

ENV APOLLO_ELV2_LICENSE=accept \
    APOLLO_TELEMETRY_DISABLED=true \
    APOLLO_ROVER_ALLOW_AUTOMATIC_DOWNLOAD=false \
    SUPERGRAPH_VERSION=${SUPERGRAPH_VERSION}

RUN rover plugin install supergraph@=${SUPERGRAPH_VERSION}
