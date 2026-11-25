# Rover with the supergraph plugin already installed.
# PR routers use it to build their schema.
# The stock image downloads the plugin, and PR router pods have no internet.
FROM ghcr.io/apollographql/rover:1.1.0@sha256:7600b94f64e1cdc59759de18968985857878cfeccd44ebba2f9e7f15210f620c

# PR routers build with this version. Bump it here to upgrade.
# renovate: datasource=github-releases depName=apollographql/federation-rs extractVersion=^supergraph@v(?<version>.+)$
ARG SUPERGRAPH_VERSION=2.15.7

ENV APOLLO_ELV2_LICENSE=accept \
    APOLLO_TELEMETRY_DISABLED=true \
    APOLLO_ROVER_ALLOW_AUTOMATIC_DOWNLOAD=false \
    SUPERGRAPH_VERSION=${SUPERGRAPH_VERSION}

RUN rover plugin install supergraph@=${SUPERGRAPH_VERSION}
