FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.version=0.1.0" -o APP_NAME .

# ---- runtime ----
FROM alpine:3.21

RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY --from=builder /app/APP_NAME .

USER app

EXPOSE APP_PORT

ENTRYPOINT ["./APP_NAME"]
