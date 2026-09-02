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

mkdir -p "$(dirname "$OUT")"

DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-UNKNOWN}"
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
MIERU_PORT_RANGE="${MIERU_PORT_RANGE:-40000-40010}"
TELEGRAM_PORT="${TELEGRAM_PORT:-48291}"
TELEGRAM_EE_DOMAIN="${TELEGRAM_EE_DOMAIN:-www.google.com}"
VLESS_PORT="${VLESS_PORT:-59684}"
VLESS_DEST="${VLESS_DEST:-www.cloudflare.com}"

CARDS=""
PORTS="80/tcp, 443/tcp"

if enabled "${NAIVE_ENABLED:-1}"; then
  naive_link="https://${USER}:${PASSWORD}@${DOMAIN}"
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">HTTPS · 443</p><h2>NaiveProxy</h2></div></header>
  <p>Трафик выглядит как обычный HTTPS на этот домен. Подходит для браузера и приложений с поддержкой naive.</p>
  $(uri_block "$naive_link")
  <ol>
    <li>Клиент: <b>naiveproxy</b>, NekoBox или Hiddify.</li>
    <li>Тип прокси — Naive / HTTPS, вставьте ссылку целиком.</li>
    <li>Домен должен открываться по HTTPS — сертификат выпускается автоматически.</li>
  </ol>
</article>"
fi

if enabled "${MIERU_ENABLED:-1}"; then
  mieru_link="mierus://${USER}:${PASSWORD}@${PUBLIC_IP}?profile=default&port=${MIERU_PORT_RANGE}&protocol=TCP&port=${MIERU_PORT_RANGE}&protocol=UDP&mtu=1400&multiplexing=MULTIPLEXING_HIGH"
  PORTS="${PORTS}, ${MIERU_PORT_RANGE}/tcp+udp"
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">TCP/UDP · $(html_esc "$MIERU_PORT_RANGE")</p><h2>mieru</h2></div></header>
  <p>Свой протокол без TLS. Хорошо проходит там, где HTTPS-прокси уже режут.</p>
  $(uri_block "$mieru_link")
  <ol>
    <li>Клиент: официальный <b>mieru</b> или NekoBox с плагином mieru.</li>
    <li>Импортируйте <code>mierus://</code> ссылку.</li>
    <li>Откройте на фаерволе диапазон портов и TCP, и UDP.</li>
  </ol>
</article>"
fi

if enabled "${TELEGRAM_ENABLED:-1}"; then
  ee_hex=$(printf '%s' "$TELEGRAM_EE_DOMAIN" | xxd -p | tr -d ' \n')
  tg_secret="ee${TELEPROXY_SECRET}${ee_hex}"
  tg_http="https://t.me/proxy?server=${PUBLIC_IP}&port=${TELEGRAM_PORT}&secret=${tg_secret}"
  tg_app="tg://proxy?server=${PUBLIC_IP}&port=${TELEGRAM_PORT}&secret=${tg_secret}"
  PORTS="${PORTS}, ${TELEGRAM_PORT}/tcp"
  qr=""
  qr_file=$(mktemp)
  if qrencode -o "$qr_file" -t PNG -s 5 -m 1 "$tg_http" 2>/dev/null; then
    qr_b64=$(base64 -w0 "$qr_file")
    qr="<img class=\"qr\" src=\"data:image/png;base64,${qr_b64}\" alt=\"QR Telegram proxy\" width=\"168\" height=\"168\">"
  fi
  rm -f "$qr_file"
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">MTProto · $(html_esc "$TELEGRAM_PORT")</p><h2>Telegram</h2></div></header>
  <p>Teleproxy с Fake-TLS. Откройте ссылку в Telegram — прокси подставится сам. Нужен свежий клиент Telegram (после обновления Fake-TLS в августе 2026).</p>
  <div class=\"split\">
    <div>
      $(uri_block "$tg_http" "Скопировать t.me")
      $(uri_block "$tg_app" "Скопировать tg://")
      <ol>
        <li>На телефоне откройте ссылку — Telegram предложит «Использовать прокси».</li>
        <li>Либо Настройки → Данные и память → Прокси → добавить.</li>
        <li>Прокси работает только внутри Telegram, не для всего устройства.</li>
      </ol>
    </div>
    ${qr}
  </div>
</article>"
fi

if enabled "${VLESS_ENABLED:-1}"; then
  vless_link=""
  vless_sni="$VLESS_DEST"
  if [ -f "$VLESS_ENV" ]; then
    vless_link=$(sed -n 's/^link=//p' "$VLESS_ENV" | sed "s/HOST/${PUBLIC_IP}/g")
    vless_sni=$(sed -n 's/^sni=//p' "$VLESS_ENV")
    vless_sni="${vless_sni:-$VLESS_DEST}"
    vless_fp=$(sed -n 's/^fp=//p' "$VLESS_ENV")
  fi
  vless_fp="${vless_fp:-${VLESS_FP:-edge}}"
  PORTS="${PORTS}, ${VLESS_PORT}/tcp"
  vless_block="<p class=\"muted\">ещё не готово — перезапустите контейнер</p>"
  if [ -n "$vless_link" ]; then
    vless_block=$(uri_block "$vless_link")
  fi
  CARDS="${CARDS}
<article class=\"card\">
  <header><div><p class=\"kicker\">REALITY · $(html_esc "$VLESS_PORT")</p><h2>VLESS</h2></div></header>
  <p>Маскировка под TLS $(html_esc "$vless_sni"). Универсальный вариант для телефонов и десктопа.</p>
  ${vless_block}
  <ol>
    <li>Клиент: v2rayN, v2rayNG, Streisand, Hiddify, Happ.</li>
    <li>Импорт из буфера обмена — вставьте URI <code>vless://</code>.</li>
    <li>Fingerprint: <code>$(html_esc "$vless_fp")</code>, flow — <code>xtls-rprx-vision</code>.</li>
  </ol>
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
<title>Доступ — $(html_esc "$DOMAIN")</title>
<style>
${css}
</style>
</head>
<body>
<main class="wrap">
  <header class="top">
    <div>
      <p class="brand">proxy-box</p>
      <h1>Доступ</h1>
    </div>
    <p class="meta">
      $(html_esc "$DOMAIN")<br>
      <code>$(html_esc "$PUBLIC_IP")</code><br>
      $(html_esc "$NOW")
    </p>
  </header>
  <p class="lead">Ссылки этого сервера. Страница собирается при старте контейнера.</p>
  <div class="grid">
    ${CARDS}
  </div>
  <p class="ports">На фаерволе должны быть открыты: <code>$(html_esc "$PORTS")</code></p>
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
