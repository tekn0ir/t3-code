# CLIProxyAPI image built from the src/cliproxyapi fork.
#
# Build context is the submodule, not the repo root (keeps src/t3code out of the context):
#   docker build -f docker/cliproxyapi/Dockerfile src/cliproxyapi \
#     --build-arg VERSION=$(git -C src/cliproxyapi describe --tags --always) \
#     --build-arg COMMIT=$(git -C src/cliproxyapi rev-parse --short HEAD)
#
# Runtime layout matches upstream (and deploy/cliproxyapi):
#   /CLIProxyAPI/CLIProxyAPI   binary (WORKDIR)
#   /root/.cli-proxy-api       OAuth account logins (persistent volume)
#   /CLIProxyAPI/logs          request/app logs
# The Deployment passes -config pointing at a writable copy of the config Secret.

FROM golang:1.26-bookworm AS builder

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*

COPY go.mod go.sum ./
RUN go mod download

COPY . .

ARG VERSION=dev
ARG COMMIT=none
ARG BUILD_DATE=unknown

RUN CGO_ENABLED=1 GOOS=linux go build -buildvcs=false \
      -ldflags="-s -w -X 'main.Version=${VERSION}' -X 'main.Commit=${COMMIT}' -X 'main.BuildDate=${BUILD_DATE}'" \
      -o ./CLIProxyAPI ./cmd/server/

FROM debian:bookworm-slim

ARG VERSION=dev
ARG COMMIT=none
LABEL org.opencontainers.image.source="https://github.com/tekn0ir/t3-code" \
      org.opencontainers.image.description="CLIProxyAPI (tekn0ir fork)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}"

ENV TZ=Europe/Stockholm

RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && echo "${TZ}" > /etc/timezone \
 && mkdir -p /CLIProxyAPI/logs /root/.cli-proxy-api

COPY --from=builder /app/CLIProxyAPI /CLIProxyAPI/CLIProxyAPI
COPY config.example.yaml /CLIProxyAPI/config.example.yaml

WORKDIR /CLIProxyAPI

# 8317 API + management UI; 54545 Claude and 1455 Codex OAuth callbacks (used via port-forward).
EXPOSE 8317 54545 1455

CMD ["./CLIProxyAPI"]
