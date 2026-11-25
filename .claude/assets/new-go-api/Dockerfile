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
FROM ghcr.io/cujarrett/base-distroless:static-debian13@sha256:57d71c4d9e6e68f81b301e7e7b0c500779bce9e35c665334e8c5134822fffc0d

WORKDIR /app

COPY --from=builder /app/APP_NAME .

EXPOSE APP_PORT

ENTRYPOINT ["./APP_NAME"]
