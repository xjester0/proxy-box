#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/proxy-box
DATA=/data
CADDYFILE="${DATA}/Caddyfile"
STATE="${DATA}/state.env"
PIDS=""

enabled() {
  case "${1:-1}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

rand_hex() {
  openssl rand -hex "${1:-16}"
}

detect_ip() {
  local ip
  ip=$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://ifconfig.co/ip 2>/dev/null \
    || curl -4 -fsS --connect-timeout 5 --max-time 10 https://icanhazip.com 2>/dev/null \
    || true)
  ip=$(printf '%s' "$ip" | tr -d '[:space:]')
  if [ -n "$ip" ]; then
    printf '%s' "$ip"
    return
  fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

require() {
  local name=$1
  if [ -z "${!name:-}" ]; then
    echo "set ${name} in env" >&2
    exit 1
  fi
}

esc_caddy() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

esc_json() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

wait_http() {
  local url=$1
  local i=0 code
  while [ "$i" -lt 50 ]; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 "$url" 2>/dev/null || true)
    case "$code" in
      2*|3*|401|403) return 0 ;;
    esac
    i=$((i + 1))
    sleep 0.2
  done
  return 1
}

term() {
  trap - INT TERM EXIT
  if [ -n "${PIDS}" ]; then
    kill ${PIDS} 2>/dev/null || true
    wait ${PIDS} 2>/dev/null || true
  fi
}
trap term INT TERM EXIT

DOMAIN="${DOMAIN//$'\r'/}"
DOMAIN=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
ACME_EMAIL="${ACME_EMAIL//$'\r'/}"
USER="${USER//$'\r'/}"
PASSWORD="${PASSWORD//$'\r'/}"
ENV_USER="$USER"
ENV_PASSWORD="$PASSWORD"
ENV_TPROXY_SECRET=$(printf '%s' "${TPROXY_SECRET:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

require DOMAIN
require ACME_EMAIL
require USER
require PASSWORD

NAIVE_ENABLED="${NAIVE_ENABLED:-1}"
MIERU_ENABLED="${MIERU_ENABLED:-1}"
TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-1}"
VLESS_ENABLED="${VLESS_ENABLED:-1}"
MIERU_PORT_RANGE="${MIERU_PORT_RANGE:-40000-40010}"
TELEGRAM_STATS_PORT="${TELEGRAM_STATS_PORT:-8888}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_MAX_CONNECTIONS="${MTPROXY_MAX_CONNECTIONS:-4096}"
VLESS_PORT="${VLESS_PORT:-59684}"
VLESS_DEST="${VLESS_DEST:-www.cloudflare.com}"
VLESS_FP="${VLESS_FP:-edge}"
case "$VLESS_FP" in
  chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
  *) VLESS_FP=edge ;;
esac

mkdir -p "${DATA}/caddy" "${DATA}/vless" "${DATA}/tproxy" "${DATA}/mtproxy" \
  "${DATA}/zot/store" "${DATA}/www" \
  /var/run/mita /var/lib/mita
if ! id mita >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/mita --shell /usr/sbin/nologin mita || true
fi
chown mita:mita /var/run/mita /var/lib/mita 2>/dev/null || chmod 777 /var/run/mita /var/lib/mita || true

if [ -f "$STATE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$STATE"
  set +a
fi

USER="$ENV_USER"
PASSWORD="$ENV_PASSWORD"
if printf '%s' "$ENV_TPROXY_SECRET" | grep -Eq '^[0-9a-f]{32}$'; then
  TPROXY_SECRET="$ENV_TPROXY_SECRET"
else
  TPROXY_SECRET="${TPROXY_SECRET:-${TELEPROXY_SECRET:-}}"
  TPROXY_SECRET=$(printf '%s' "$TPROXY_SECRET" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  if ! printf '%s' "$TPROXY_SECRET" | grep -Eq '^[0-9a-f]{32}$'; then
    TPROXY_SECRET="$(rand_hex 16)"
  fi
fi
PUBLIC_IP="$(detect_ip)"
[ -n "${PUBLIC_IP}" ] || PUBLIC_IP="UNKNOWN"

umask 077
cat >"$STATE" <<EOF
TPROXY_SECRET=${TPROXY_SECRET}
EOF
chmod 600 "$STATE"

export DOMAIN ACME_EMAIL USER PASSWORD PUBLIC_IP
export NAIVE_ENABLED MIERU_ENABLED TELEGRAM_ENABLED VLESS_ENABLED
export MIERU_PORT_RANGE
export TPROXY_SECRET TELEGRAM_STATS_PORT
export VLESS_PORT VLESS_DEST VLESS_FP

cat >"${DATA}/zot/config.json" <<EOF
{
  "distSpecVersion": "1.1.1",
  "storage": { "rootDirectory": "${DATA}/zot/store" },
  "http": {
    "address": "127.0.0.1",
    "port": "5000"
  },
  "log": { "level": "info" },
  "extensions": {
    "search": { "enable": true },
    "ui": { "enable": true }
  }
}
EOF

if enabled "$VLESS_ENABLED"; then
  cfg="${DATA}/vless/config.json"
  envf="${DATA}/vless/client.env"
  need=0
  if [ ! -f "$cfg" ]; then need=1
  elif ! grep -q "\"${VLESS_DEST}\"" "$cfg"; then need=1
  elif ! grep -q "\"port\": ${VLESS_PORT}" "$cfg"; then need=1
  elif [ ! -f "$envf" ]; then need=1
  elif grep -q '^pbk=$' "$envf" || grep -q 'pbk=&' "$envf"; then need=1
  fi
  if [ "$need" -eq 1 ]; then
    KEYS=$(xray x25519)
    PRIVATE=$(printf '%s\n' "$KEYS" | awk -F': *' '/^[Pp]rivate[Kk]ey|^Private key/{print $2; exit}')
    PUBLIC=$(printf '%s\n' "$KEYS" | awk -F': *' '/^Password \(PublicKey\)|^Password:|^Public[Kk]ey|^Public key/{print $2; exit}')
    if [ -z "$PRIVATE" ] || [ -z "$PUBLIC" ]; then
      echo "x25519 parse failed:" >&2
      printf '%s\n' "$KEYS" >&2
      exit 1
    fi
    UUID=$(xray uuid)
    SHORT_ID=$(dd if=/dev/urandom bs=4 count=1 2>/dev/null | xxd -p | tr -d '\n')
    cat >"$cfg" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${VLESS_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${VLESS_DEST}:443",
        "xver": 0,
        "serverNames": ["${VLESS_DEST}"],
        "privateKey": "${PRIVATE}",
        "shortIds": ["", "${SHORT_ID}"]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
JSON
    LINK="vless://${UUID}@HOST:${VLESS_PORT}?type=tcp&security=reality&pbk=${PUBLIC}&fp=${VLESS_FP}&sni=${VLESS_DEST}&sid=${SHORT_ID}&flow=xtls-rprx-vision#HOST"
    printf '%s\n' \
      "uuid=${UUID}" "pbk=${PUBLIC}" "sid=${SHORT_ID}" "sni=${VLESS_DEST}" \
      "port=${VLESS_PORT}" "flow=xtls-rprx-vision" "fp=${VLESS_FP}" "link=${LINK}" >"$envf"
    echo "generated vless reality dest=${VLESS_DEST} port=${VLESS_PORT} fp=${VLESS_FP}"
  elif [ -f "$envf" ]; then
    uuid=$(sed -n 's/^uuid=//p' "$envf")
    pbk=$(sed -n 's/^pbk=//p' "$envf")
    sid=$(sed -n 's/^sid=//p' "$envf")
    sni=$(sed -n 's/^sni=//p' "$envf")
    port=$(sed -n 's/^port=//p' "$envf")
    flow=$(sed -n 's/^flow=//p' "$envf")
    if [ -n "$uuid" ] && [ -n "$pbk" ]; then
      LINK="vless://${uuid}@HOST:${port}?type=tcp&security=reality&pbk=${pbk}&fp=${VLESS_FP}&sni=${sni}&sid=${sid}&flow=${flow}#HOST"
      printf '%s\n' \
        "uuid=${uuid}" "pbk=${pbk}" "sid=${sid}" "sni=${sni}" \
        "port=${port}" "flow=${flow}" "fp=${VLESS_FP}" "link=${LINK}" >"$envf"
    fi
  fi
fi

if enabled "$MIERU_ENABLED"; then
  cat >"${DATA}/mita.json" <<EOF
{
  "portBindings": [
    {"portRange": "${MIERU_PORT_RANGE}", "protocol": "TCP"},
    {"portRange": "${MIERU_PORT_RANGE}", "protocol": "UDP"}
  ],
  "users": [
    {"name": "$(esc_caddy "$USER")", "password": "$(esc_caddy "$PASSWORD")"}
  ],
  "loggingLevel": "INFO",
  "mtu": 1400
}
EOF
fi

if enabled "$TELEGRAM_ENABLED"; then
  umask 077
  cat >"${DATA}/tproxy/config.json" <<EOF
{
  "public_hostname": "$(esc_json "$DOMAIN")",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_upstream": "http://127.0.0.1:5000",
  "profiles_file": "${DATA}/tproxy/profiles.json",
  "enable_pprof": false
}
EOF
  cat >"${DATA}/tproxy/profiles.json" <<EOF
{
  "profiles": [
    {
      "name": "default",
      "secret": "${TPROXY_SECRET}",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "https"
    }
  ]
}
EOF
  chmod 600 "${DATA}/tproxy/config.json"
  chmod 400 "${DATA}/tproxy/profiles.json"

  tmp=$(mktemp -d)
  if curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp/proxy-secret" https://core.telegram.org/getProxySecret \
     && curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp/proxy-multi.conf" https://core.telegram.org/getProxyConfig \
     && [ "$(wc -c < "$tmp/proxy-secret")" -eq 128 ]; then
    mv "$tmp/proxy-secret" "${DATA}/mtproxy/proxy-secret"
    mv "$tmp/proxy-multi.conf" "${DATA}/mtproxy/proxy-multi.conf"
  else
    echo "mtproxy config download failed, using cache if present" >&2
  fi
  rm -rf "$tmp"
  if [ ! -f "${DATA}/mtproxy/proxy-secret" ] || [ ! -f "${DATA}/mtproxy/proxy-multi.conf" ]; then
    echo "mtproxy proxy-secret/proxy-multi.conf missing" >&2
    exit 1
  fi
  chmod 600 "${DATA}/mtproxy/proxy-secret" "${DATA}/mtproxy/proxy-multi.conf"
fi

ACCESS_HASH=$(caddy hash-password --plaintext "$PASSWORD" | tail -1)

NAIVE_BLOCK=""
if enabled "$NAIVE_ENABLED"; then
  NAIVE_BLOCK=$(cat <<EOF
    forward_proxy {
      basic_auth $(esc_caddy "$USER") $(esc_caddy "$PASSWORD")
      hide_ip
      hide_via
      probe_resistance $(esc_caddy "$DOMAIN")
    }
EOF
)
fi

if enabled "$TELEGRAM_ENABLED"; then
  SITE_PROXY=$(cat <<'EOF'
    handle {
      reverse_proxy 127.0.0.1:8080 {
        transport http {
          response_header_timeout 40s
        }
      }
    }
EOF
)
else
  SITE_PROXY=$(cat <<'EOF'
    handle {
      reverse_proxy 127.0.0.1:5000
    }
EOF
)
fi

cat >"$CADDYFILE" <<EOF
{
  order forward_proxy before reverse_proxy
  email $(esc_caddy "$ACME_EMAIL")
  acme_ca https://acme-v02.api.letsencrypt.org/directory
  storage file_system {
    root /data/caddy
  }
  admin off
  servers {
    protocols h1 h2
    timeouts {
      read_header 10s
      read_body 60s
    }
  }
}

${DOMAIN} {
  encode zstd gzip
  header Strict-Transport-Security "max-age=31536000; includeSubDomains"
  route {
    handle /access* {
      basic_auth {
        $(esc_caddy "$USER") ${ACCESS_HASH}
      }
      header Cache-Control "no-store"
      root * ${DATA}/www
      rewrite * /access.html
      file_server
    }
${NAIVE_BLOCK}
${SITE_PROXY}
  }
}
EOF

zot serve "${DATA}/zot/config.json" &
PIDS="${PIDS} $!"
if ! wait_http "http://127.0.0.1:5000/v2/"; then
  echo "zot not ready on 127.0.0.1:5000" >&2
  exit 1
fi

if enabled "$MIERU_ENABLED"; then
  mita run &
  PIDS="${PIDS} $!"
  i=0
  while [ "$i" -lt 50 ] && [ ! -S /var/run/mita/mita.sock ]; do
    i=$((i + 1)); sleep 0.2
  done
  if [ ! -S /var/run/mita/mita.sock ]; then
    echo "mita socket not ready" >&2
    exit 1
  fi
  mita apply config "${DATA}/mita.json"
  mita start
fi

if enabled "$TELEGRAM_ENABLED"; then
  if command -v nft >/dev/null 2>&1; then
    cat >/etc/tproxy-server/firewall.nft <<NFT
table inet tproxy_backend {
  chain local_backend {
    type filter hook input priority -10; policy accept;
    iifname != "lo" tcp dport { 2398, ${TELEGRAM_STATS_PORT} } drop
  }
}
NFT
    nft delete table inet tproxy_backend 2>/dev/null || true
    if ! nft -f /etc/tproxy-server/firewall.nft; then
      echo "nft tproxy_backend failed; cap_add NET_ADMIN and drop 2398/${TELEGRAM_STATS_PORT} on the host" >&2
    fi
  fi
  mtproto-proxy \
    -p "${TELEGRAM_STATS_PORT}" \
    -H 2398 \
    -S "${TPROXY_SECRET}" \
    --aes-pwd "${DATA}/mtproxy/proxy-secret" \
    "${DATA}/mtproxy/proxy-multi.conf" \
    -M "${MTPROXY_WORKERS}" \
    -C "${MTPROXY_MAX_CONNECTIONS}" &
  PIDS="${PIDS} $!"
  tproxy-server -config "${DATA}/tproxy/config.json" &
  PIDS="${PIDS} $!"
  if ! wait_http "http://127.0.0.1:8081/healthz"; then
    echo "tproxy-server not ready on 127.0.0.1:8081" >&2
    exit 1
  fi
fi

if enabled "$VLESS_ENABLED"; then
  xray run -c "${DATA}/vless/config.json" &
  PIDS="${PIDS} $!"
fi

bash "${ROOT}/gen-access.sh"

echo "proxy-box up  domain=${DOMAIN}  ip=${PUBLIC_IP}  access=https://${DOMAIN}/access"
caddy run --config "$CADDYFILE" --adapter caddyfile &
PIDS="${PIDS} $!"
wait -n || true
exit 1
