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
FROM ghcr.io/cujarrett/base-distroless:static-debian13@sha256:a359c6ce58f19d70594119fa4d2233f0d27d93bce787328a4936fd1f995cc779

WORKDIR /app

COPY --from=builder /app/APP_NAME .

EXPOSE APP_PORT

ENTRYPOINT ["./APP_NAME"]
