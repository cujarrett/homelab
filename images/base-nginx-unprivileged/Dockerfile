FROM nginxinc/nginx-unprivileged:1.31-alpine@sha256:b5047b9b76845eac124358373c6852377c52e4b05834a47647e955dd91cb8f1e
# nginx rebuilds its tag weeks after Alpine ships a fix.
# Upgrading here takes the fix on the next nightly build.
USER root
RUN apk upgrade --no-cache
# The upstream image runs as uid 101, so nginx needs no root.
USER 101
