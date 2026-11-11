FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS builder

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
FROM ghcr.io/cujarrett/base-go:static-debian13

WORKDIR /app

COPY --from=builder /app/APP_NAME .

EXPOSE APP_PORT

ENTRYPOINT ["./APP_NAME"]
