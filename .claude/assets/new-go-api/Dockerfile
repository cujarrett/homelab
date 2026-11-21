FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:eb61c3873c97416fff0116553fff65d67a3549f72e11d9758849a689cdd8b523 AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.version=0.1.0" -o APP_NAME .

# ---- runtime ----
# The platform base image carries the OS layer and its CVE fixes. See images/README.md in the homelab repo.
FROM ghcr.io/cujarrett/base-distroless:static-debian13@sha256:723f8ed3b1060cf54014601bbb883e79f184bb949dcf85e19b209a69d6979ed9

WORKDIR /app

COPY --from=builder /app/APP_NAME .

EXPOSE APP_PORT

ENTRYPOINT ["./APP_NAME"]
