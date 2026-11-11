FROM nginx:1.31-alpine@sha256:713fc2ebfd92e8217db451477182ee91944b123d2b1ee9fd5a8c6e91ca6c3a11
# nginx rebuilds its tag weeks after Alpine ships a fix.
# Upgrading here takes the fix on the next nightly build.
RUN apk upgrade --no-cache
