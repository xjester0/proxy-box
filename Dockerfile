FROM golang:1.25-bookworm AS caddy
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
ARG FORWARDPROXY_REF=naive
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.5
WORKDIR /build
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    /go/bin/xcaddy build \
      --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@${FORWARDPROXY_REF}

FROM golang:1.25-bookworm AS tproxy
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
RUN git clone --depth 1 https://github.com/telegramdesktop/tproxy-server.git .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags="-s -w" -o /tproxy-server ./cmd/tproxy-server

FROM debian:bookworm AS mtproxy
ARG TARGETARCH
ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_CHECKSUM=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655
RUN test "${TARGETARCH}" = "amd64"
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl make gcc g++ libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL -o mtproxy.tar.gz \
      "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
 && echo "${MTPROXY_CHECKSUM}  mtproxy.tar.gz" | sha256sum -c - \
 && tar -xzf mtproxy.tar.gz --strip-components=1 \
 && make -j"$(nproc)" \
 && test -x objs/bin/mtproto-proxy

FROM debian:bookworm-slim AS bins
ARG TARGETARCH
ARG MITA_VERSION=3.36.0
ARG XRAY_VERSION=25.12.8
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

FROM ghcr.io/project-zot/zot:v2.1.2 AS zot

FROM debian:bookworm-slim
LABEL org.opencontainers.image.title="proxy-box" \
      org.opencontainers.image.description="NaiveProxy, mieru, tproxy-server and VLESS Reality"
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl openssl qrencode xxd iproute2 procps \
      libssl3 zlib1g nftables \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/proxy-box /data /var/run/mita /var/lib/mita /etc/tproxy-server

COPY --from=caddy /build/caddy /usr/local/bin/caddy
COPY --from=tproxy /tproxy-server /usr/local/bin/tproxy-server
COPY --from=mtproxy /src/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY --from=bins /out/mita /usr/local/bin/mita
COPY --from=bins /out/xray /usr/local/bin/xray
COPY --from=zot /usr/bin/zot /usr/local/bin/zot
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
