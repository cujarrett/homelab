FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS builder

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
FROM ghcr.io/cujarrett/base-distroless:static-debian13@sha256:76a6ba0713608e3fcca0246b7c1989bbedfcff9809cab66fb6d9388bc091938c

WORKDIR /app

COPY --from=builder /app/APP_NAME .

EXPOSE APP_PORT

ENTRYPOINT ["./APP_NAME"]
