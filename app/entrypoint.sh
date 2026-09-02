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

term() {
  trap - INT TERM EXIT
  if [ -n "${PIDS}" ]; then
    kill ${PIDS} 2>/dev/null || true
    wait ${PIDS} 2>/dev/null || true
  fi
}
trap term INT TERM EXIT

DOMAIN="${DOMAIN//$'\r'/}"
ACME_EMAIL="${ACME_EMAIL//$'\r'/}"
USER="${USER//$'\r'/}"
PASSWORD="${PASSWORD//$'\r'/}"
ENV_USER="$USER"
ENV_PASSWORD="$PASSWORD"

require DOMAIN
require ACME_EMAIL
require USER
require PASSWORD

NAIVE_ENABLED="${NAIVE_ENABLED:-1}"
MIERU_ENABLED="${MIERU_ENABLED:-1}"
TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-1}"
VLESS_ENABLED="${VLESS_ENABLED:-1}"
MIERU_PORT_RANGE="${MIERU_PORT_RANGE:-40000-40010}"
TELEGRAM_PORT="${TELEGRAM_PORT:-48291}"
TELEGRAM_STATS_PORT="${TELEGRAM_STATS_PORT:-8888}"
TELEGRAM_EE_DOMAIN="${TELEGRAM_EE_DOMAIN:-www.google.com}"
VLESS_PORT="${VLESS_PORT:-59684}"
VLESS_DEST="${VLESS_DEST:-www.cloudflare.com}"
VLESS_FP="${VLESS_FP:-edge}"
case "$VLESS_FP" in
  chrome|firefox|safari|ios|android|edge|360|qq|random|randomized) ;;
  *) VLESS_FP=edge ;;
esac

mkdir -p "${DATA}/caddy" "${DATA}/vless" "${DATA}/teleproxy" "${DATA}/www" \
  /var/run/mita /var/lib/mita
chmod 777 /var/run/mita /var/lib/mita || true

if [ -f "$STATE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$STATE"
  set +a
fi

USER="$ENV_USER"
PASSWORD="$ENV_PASSWORD"
TELEPROXY_SECRET="${TELEPROXY_SECRET:-$(rand_hex 16)}"
PUBLIC_IP="$(detect_ip)"
[ -n "${PUBLIC_IP}" ] || PUBLIC_IP="UNKNOWN"

umask 077
cat >"$STATE" <<EOF
TELEPROXY_SECRET=${TELEPROXY_SECRET}
EOF
chmod 600 "$STATE"

export DOMAIN ACME_EMAIL USER PASSWORD PUBLIC_IP
export NAIVE_ENABLED MIERU_ENABLED TELEGRAM_ENABLED VLESS_ENABLED
export MIERU_PORT_RANGE
export TELEPROXY_SECRET TELEGRAM_PORT TELEGRAM_EE_DOMAIN TELEGRAM_STATS_PORT
export VLESS_PORT VLESS_DEST VLESS_FP

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
  cat >"${DATA}/teleproxy/config.toml" <<EOF
port = ${TELEGRAM_PORT}
external_port = ${TELEGRAM_PORT}
stats_port = ${TELEGRAM_STATS_PORT}
http_stats = true
workers = 1
direct = true
domain = "${TELEGRAM_EE_DOMAIN}"

[[secret]]
key = "${TELEPROXY_SECRET}"
EOF
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
  }
}

${DOMAIN} {
  encode gzip
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
    handle {
      root * ${ROOT}/decoy
      file_server
    }
  }
}
EOF

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
  teleproxy --config "${DATA}/teleproxy/config.toml" --allow-skip-dh &
  PIDS="${PIDS} $!"
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
