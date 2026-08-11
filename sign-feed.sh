#!/bin/sh
#
# Подпись индекса opkg-фида ключом usign.
#
# Отдельные .ipk в opkg не подписываются в принципе - подписывается только индекс
# репозитория (файл Packages), и именно его проверяет `option check_signature`
# при `opkg update`. Установка локального файла (`opkg install ./пакет.ipk`)
# подпись не проверяет никогда.
#
# Запускать там, где есть usign: на любом роутере OpenWrt или на Linux с
# установленным usign. Windows не подойдёт.
#
#   sh sign-feed.sh -d dist/feed                 подписать (ключ создастся при первом запуске)
#   sh sign-feed.sh -d dist/feed -s ~/feed.sec   подписать конкретным ключом
#
# Приватный ключ по умолчанию кладётся рядом с каталогом фида, а НЕ внутрь него,
# чтобы не уехать случайно на веб-сервер вместе с пакетами.
#

set -e

FEED_DIR="."
SECRET_KEY=""
PUBLIC_KEY=""
COMMENT="forkop-servicecheck feed"

log() {
    printf '\033[0;36m[sign-feed]\033[0m %s\n' "$1"
}

fail() {
    printf '\033[0;31m[sign-feed]\033[0m %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: sh sign-feed.sh [-d FEED_DIR] [-s SECRET_KEY] [-p PUBLIC_KEY] [-c COMMENT]

  -d FEED_DIR    каталог с пакетами и файлом Packages (по умолчанию текущий)
  -s SECRET_KEY  приватный ключ usign (по умолчанию FEED_DIR/../feed.sec)
  -p PUBLIC_KEY  публичный ключ usign (по умолчанию рядом с приватным, .pub)
  -c COMMENT     комментарий в новом ключе
  -h             эта справка
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d) FEED_DIR="$2"; shift 2 ;;
        -s) SECRET_KEY="$2"; shift 2 ;;
        -p) PUBLIC_KEY="$2"; shift 2 ;;
        -c) COMMENT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Неизвестный аргумент: $1" ;;
    esac
done

command -v usign >/dev/null 2>&1 || fail "Не найден usign. Запустите на роутере OpenWrt или на Linux с usign."

[ -d "$FEED_DIR" ] || fail "Каталог фида не найден: $FEED_DIR"
[ -f "$FEED_DIR/Packages" ] || fail "В $FEED_DIR нет файла Packages - сначала соберите фид (build_packages.py)."

[ -n "$SECRET_KEY" ] || SECRET_KEY="$FEED_DIR/../feed.sec"
[ -n "$PUBLIC_KEY" ] || PUBLIC_KEY="${SECRET_KEY%.sec}.pub"

if [ ! -f "$SECRET_KEY" ]; then
    log "Ключа нет, создаю новый: $SECRET_KEY"
    usign -G -c "$COMMENT" -s "$SECRET_KEY" -p "$PUBLIC_KEY"
    chmod 0600 "$SECRET_KEY"
    log "Приватный ключ создан. Храните его вне каталога фида и не публикуйте."
else
    log "Использую существующий ключ: $SECRET_KEY"
    [ -f "$PUBLIC_KEY" ] || fail "Публичный ключ $PUBLIC_KEY не найден рядом с приватным."
fi

# usign по умолчанию пишет <message>.sig, то есть ровно Packages.sig.
log "Подписываю $FEED_DIR/Packages"
usign -S -m "$FEED_DIR/Packages" -s "$SECRET_KEY"

[ -f "$FEED_DIR/Packages.sig" ] || fail "Подпись не создана."

if usign -V -m "$FEED_DIR/Packages" -p "$PUBLIC_KEY" -q; then
    log "Подпись проверена своим же публичным ключом"
else
    fail "Подпись не проходит проверку - что-то не так с ключами."
fi

FINGERPRINT="$(usign -F -p "$PUBLIC_KEY")"

cp -f "$PUBLIC_KEY" "$FEED_DIR/$FINGERPRINT.pub" 2>/dev/null || true

log "Готово. Отпечаток ключа: $FINGERPRINT"

cat <<EOF

Что лежит в фиде:
$(ls -1 "$FEED_DIR" | sed 's/^/  /')

Выложите каталог фида на HTTP-сервер, затем на каждом роутере:

  wget -O /tmp/feed.pub http://ВАШ_СЕРВЕР/$FINGERPRINT.pub
  opkg-key add /tmp/feed.pub
  echo 'src/gz forkop_servicecheck http://ВАШ_СЕРВЕР' >> /etc/opkg/customfeeds.conf
  opkg update
  opkg install luci-app-forkop-servicecheck

Публичный ключ ляжет в /etc/opkg/keys/$FINGERPRINT и будет проверяться
при каждом opkg update, пока в /etc/opkg.conf включён option check_signature.

EOF
