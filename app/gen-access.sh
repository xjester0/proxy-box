#!/usr/bin/env bash
set -euo pipefail

ROOT=/opt/proxy-box
OUT="${DATA:-/data}/www/access.html"
VLESS_ENV="${DATA:-/data}/vless/client.env"

enabled() {
  case "${1:-1}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

html_esc() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

uri_block() {
  local esc label
  esc=$(html_esc "$1")
  label=$(html_esc "${2:-Скопировать}")
  printf '<div class="uri"><code>%s</code><button type="button" data-copy="%s">%s</button></div>\n' "$esc" "$esc" "$label"
}

qr_img() {
  local payload=$1 alt=${2:-QR}
  local qr_file qr_b64
  qr_file=$(mktemp)
  if qrencode -o "$qr_file" -t PNG -s 5 -m 1 "$payload" 2>/dev/null; then
    qr_b64=$(base64 -w0 "$qr_file")
    printf '<img class="qr" src="data:image/png;base64,%s" alt="%s" width="168" height="168">\n' "$qr_b64" "$(html_esc "$alt")"
  fi
  rm -f "$qr_file"
}

mkdir -p "$(dirname "$OUT")"

DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-UNKNOWN}"
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
MIERU_PORT_RANGE="${MIERU_PORT_RANGE:-40000-40010}"
VLESS_PORT="${VLESS_PORT:-59684}"

CARDS=""
PORTS="80/tcp, 443/tcp"

if enabled "${NAIVE_ENABLED:-1}"; then
  naive_link="https://${USER}:${PASSWORD}@${DOMAIN}"
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">HTTPS · 443</p><h2>NaiveProxy</h2></div></header>
  <div class=\"split\">
    <div>
      $(uri_block "$naive_link")
    </div>
    $(qr_img "$naive_link" "NaiveProxy")
  </div>
</article>"
fi

if enabled "${MIERU_ENABLED:-1}"; then
  mieru_link="mierus://${USER}:${PASSWORD}@${PUBLIC_IP}?profile=default&port=${MIERU_PORT_RANGE}&protocol=TCP&port=${MIERU_PORT_RANGE}&protocol=UDP&mtu=1400&multiplexing=MULTIPLEXING_HIGH"
  PORTS="${PORTS}, ${MIERU_PORT_RANGE}/tcp+udp"
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">TCP/UDP · $(html_esc "$MIERU_PORT_RANGE")</p><h2>mieru</h2></div></header>
  <div class=\"split\">
    <div>
      $(uri_block "$mieru_link")
    </div>
    $(qr_img "$mieru_link" "mieru")
  </div>
</article>"
fi

if enabled "${TELEGRAM_ENABLED:-1}"; then
  tg_http="https://t.me/webproxy?server=${DOMAIN}&secret=${TPROXY_SECRET}"
  tg_app="tg://webproxy?server=${DOMAIN}&secret=${TPROXY_SECRET}"
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">WEB · 443</p><h2>Telegram Desktop</h2></div></header>
  <div class=\"split\">
    <div>
      $(uri_block "$tg_http" "t.me")
      $(uri_block "$tg_app" "tg://")
    </div>
    $(qr_img "$tg_http" "Telegram")
  </div>
</article>"
fi

if enabled "${VLESS_ENABLED:-1}"; then
  vless_link=""
  if [ -f "$VLESS_ENV" ]; then
    vless_link=$(sed -n 's/^link=//p' "$VLESS_ENV" | sed "s/HOST/${PUBLIC_IP}/g")
  fi
  PORTS="${PORTS}, ${VLESS_PORT}/tcp"
  vless_block="<p class=\"muted\">нет client.env — перезапустите контейнер</p>"
  vless_qr=""
  if [ -n "$vless_link" ]; then
    vless_block=$(uri_block "$vless_link")
    vless_qr=$(qr_img "$vless_link" "VLESS")
  fi
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">REALITY · $(html_esc "$VLESS_PORT")</p><h2>VLESS</h2></div></header>
  <div class=\"split\">
    <div>
      ${vless_block}
    </div>
    ${vless_qr}
  </div>
</article>"
fi

if [ -z "$CARDS" ]; then
  CARDS='<p class="muted">Все протоколы выключены в env.</p>'
fi

css=$(cat "${ROOT}/access.css")
cat >"$OUT" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<title>$(html_esc "$DOMAIN")</title>
<style>
${css}
</style>
</head>
<body>
<main class="wrap">
  <header class="top">
    <div>
      <p class="brand">access</p>
      <h1>$(html_esc "$DOMAIN")</h1>
    </div>
    <p class="meta">
      <code>$(html_esc "$PUBLIC_IP")</code><br>
      $(html_esc "$NOW")
    </p>
  </header>
  <div class="grid">
    ${CARDS}
  </div>
  <p class="ports">firewall: <code>$(html_esc "$PORTS")</code></p>
</main>
<script>
document.querySelectorAll("[data-copy]").forEach(function (btn) {
  btn.addEventListener("click", async function () {
    var v = btn.getAttribute("data-copy") || "";
    try { await navigator.clipboard.writeText(v); }
    catch (e) {
      var t = document.createElement("textarea");
      t.value = v; document.body.appendChild(t); t.select(); document.execCommand("copy"); t.remove();
    }
    var prev = btn.textContent;
    btn.textContent = "Скопировано";
    btn.classList.add("ok");
    setTimeout(function () { btn.textContent = prev; btn.classList.remove("ok"); }, 1400);
  });
});
</script>
</body>
</html>
EOF

chmod 644 "$OUT"
echo "wrote ${OUT}"
