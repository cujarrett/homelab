# Rover with the supergraph plugin built in. PR routers compose their schema with it.
# The stock image downloads the plugin on first use, and PR router pods have no internet.
# The plugin version must match federation_version in platform/federated-graph/composition-pr.yaml.
FROM ghcr.io/apollographql/rover:1.0.1@sha256:1e55c1aa335ae9a94200c35b1478c83889be67173808a384fcb181b8fc8ac338

ENV APOLLO_ELV2_LICENSE=accept \
    APOLLO_TELEMETRY_DISABLED=true \
    APOLLO_ROVER_ALLOW_AUTOMATIC_DOWNLOAD=false

RUN rover plugin install supergraph@=2.15.6
