FROM nginx:1.31-alpine@sha256:7fc0fb4af7bf006aeb31aea88069976060f8f0a0a86b667126742cc17f4e31ae
# nginx rebuilds its tag weeks after Alpine ships a fix.
# Upgrading here takes the fix on the next nightly build.
RUN apk upgrade --no-cache
