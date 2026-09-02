FROM golang:1.25-bookworm AS caddy
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
ARG FORWARDPROXY_REF=naive
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.5
WORKDIR /build
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    /go/bin/xcaddy build \
      --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_REF}

FROM debian:bookworm-slim AS bins
ARG TARGETARCH
ARG MITA_VERSION=3.36.0
ARG XRAY_VERSION=25.12.8
ARG TELEPROXY_VERSION=4.16.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /out
RUN set -eu; \
    curl -fsSL -o /tmp/mita.deb \
      "https://github.com/enfein/mieru/releases/download/v${MITA_VERSION}/mita_${MITA_VERSION}_${TARGETARCH}.deb"; \
    dpkg-deb -x /tmp/mita.deb /tmp/mita; \
    cp "$(find /tmp/mita -type f -name mita | head -1)" /out/mita; \
    chmod +x /out/mita; \
    test -x /out/mita
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) xray_zip=Xray-linux-64.zip ;; \
      arm64) xray_zip=Xray-linux-arm64-v8a.zip ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${xray_zip}"; \
    unzip -o /tmp/xray.zip xray -d /out; \
    chmod +x /out/xray
RUN set -eu; \
    curl -fsSL -o /out/teleproxy \
      "https://github.com/teleproxy/teleproxy/releases/download/v${TELEPROXY_VERSION}/teleproxy-linux-${TARGETARCH}"; \
    chmod +x /out/teleproxy

FROM debian:bookworm-slim
LABEL org.opencontainers.image.title="proxy-box" \
      org.opencontainers.image.description="NaiveProxy, mieru, Teleproxy and VLESS Reality"
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl openssl qrencode xxd iproute2 procps \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/proxy-box /data /var/run/mita /var/lib/mita

COPY --from=caddy /build/caddy /usr/local/bin/caddy
COPY --from=bins /out/mita /usr/local/bin/mita
COPY --from=bins /out/xray /usr/local/bin/xray
COPY --from=bins /out/teleproxy /usr/local/bin/teleproxy
COPY app/ /opt/proxy-box/

RUN chmod +x /opt/proxy-box/entrypoint.sh /opt/proxy-box/gen-access.sh /usr/local/bin/*

ENV XDG_DATA_HOME=/data \
    XDG_CONFIG_HOME=/data \
    NAIVE_ENABLED=1 \
    MIERU_ENABLED=1 \
    TELEGRAM_ENABLED=1 \
    VLESS_ENABLED=1

VOLUME ["/data"]
EXPOSE 80 443
ENTRYPOINT ["/opt/proxy-box/entrypoint.sh"]
