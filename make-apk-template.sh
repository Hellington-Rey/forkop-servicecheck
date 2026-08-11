#!/bin/sh
#
# Сборщик пакета @@PACKAGE@@ в формате APKv3 для OpenWrt 25.12 и новее.
#
# APKv3 - бинарный формат (ADB), собрать его может только apk-tools v3, поэтому
# скрипт зовёт `apk mkpkg`. Запускать там, где apk есть:
#
#   на самом роутере с OpenWrt 25.12:   sh make-apk.sh
#   в контейнере Alpine:                docker run --rm -v "$PWD:/w" -w /w alpine:edge sh -c "apk add apk-tools && sh make-apk.sh"
#
# Готовый пакет ставится так:
#   apk add --allow-untrusted ./@@PACKAGE@@-@@VERSION@@.apk
#
# Можно сразу подписать, тогда --allow-untrusted не нужен:
#   sh make-apk.sh --sign-key mykey.pem
#
# Ключ - обычный EC в PEM. Создать пару:
#   openssl ecparam -name prime256v1 -genkey -noout -out mykey.pem
#   openssl ec -in mykey.pem -pubout -out mykey.pub.pem
# Публичный ключ раскладывается на роутеры в /etc/apk/keys/.
#
# Пакет архитектурно-независим (arch: @@ARCH@@).
#

set -e

PACKAGE="@@PACKAGE@@"
VERSION="@@VERSION@@"
ARCH="@@ARCH@@"
OUTPUT="${PACKAGE}-${VERSION}.apk"
SIGN_KEY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --sign-key) SIGN_KEY="$2"; shift 2 ;;
        --output|-o) OUTPUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sh make-apk.sh [--sign-key KEYFILE] [--output FILE]"
            echo
            echo "  --sign-key KEYFILE  подписать пакет приватным ключом (EC/RSA в PEM)"
            echo "  --output FILE       имя итогового файла"
            exit 0
            ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

log() {
    printf '\033[0;36m[make-apk]\033[0m %s\n' "$1"
}

fail() {
    printf '\033[0;31m[make-apk]\033[0m %s\n' "$1" >&2
    exit 1
}

command -v apk >/dev/null 2>&1 || fail "Не найден apk. Нужен apk-tools v3: запустите на роутере с OpenWrt 25.12 или в контейнере Alpine."

# Проверяем по выводу, а не по коду возврата: apk на --help выходит с кодом 1.
if ! apk mkpkg --help 2>&1 | grep -q "mkpkg"; then
    fail "У этой сборки apk нет команды mkpkg. Нужен полноценный apk-tools v3 (например, пакет apk-tools в Alpine)."
fi

command -v base64 >/dev/null 2>&1 || fail "Не найдена утилита base64."
command -v tar >/dev/null 2>&1 || fail "Не найдена утилита tar."

WORK="$(mktemp -d /tmp/make-apk.XXXXXX)"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

ROOTFS="$WORK/rootfs"
SCRIPTS="$WORK/scripts"
mkdir -p "$ROOTFS" "$SCRIPTS"

log "Разворачиваю файлы пакета"
sed -n '/^__PAYLOAD_BELOW__$/,$p' "$0" | tail -n +2 | base64 -d | tar -xzf - -C "$ROOTFS"

[ -f "$ROOTFS/usr/lib/forkop-servicecheck/probe.uc" ] || fail "В архиве нет движка проверки."

chmod 0755 "$ROOTFS/usr/bin/forkop-servicecheck"

cat > "$SCRIPTS/post-install" <<'POST_INSTALL_EOF'
@@POSTINST@@
POST_INSTALL_EOF

cat > "$SCRIPTS/pre-deinstall" <<'PRE_DEINSTALL_EOF'
@@PRERM@@
PRE_DEINSTALL_EOF

chmod 0755 "$SCRIPTS/post-install" "$SCRIPTS/pre-deinstall"

if [ -n "$SIGN_KEY" ]; then
    [ -f "$SIGN_KEY" ] || fail "Файл ключа не найден: $SIGN_KEY"
fi

# Флаги ровно те же, что использует сборочная система OpenWrt (include/package-pack.mk).
build_package() {
    SOURCE_DATE_EPOCH=0 apk mkpkg \
        "$@" \
        --info "name:$PACKAGE" \
        --info "version:$VERSION" \
        --info "description:@@DESCRIPTION@@" \
        --info "arch:$ARCH" \
        --info "license:@@LICENSE@@" \
        --info "origin:$PACKAGE" \
        --info "url:@@URL@@" \
        --info "maintainer:@@MAINTAINER@@" \
        --info "depends:@@DEPENDS@@" \
        --script "post-install:$SCRIPTS/post-install" \
        --script "pre-deinstall:$SCRIPTS/pre-deinstall" \
        --files "$ROOTFS" \
        --output "$OUTPUT"
}

SIGNED=0

if [ -n "$SIGN_KEY" ]; then
    log "Собираю $OUTPUT с подписью"
    # --sign-key есть в опциях генерации mkpkg (проверено на apk-tools 3.0.6).
    # На случай сборок, где его нет, оставлен запасной путь через adbsign.
    if build_package --sign-key "$SIGN_KEY" 2>/tmp/.mkpkg-err; then
        SIGNED=1
    else
        log "mkpkg не принял --sign-key ($(head -1 /tmp/.mkpkg-err)), подпишу отдельно через adbsign"
        build_package || fail "apk mkpkg не смог собрать пакет: $(head -3 /tmp/.mkpkg-err)"
        apk adbsign --sign-key "$SIGN_KEY" "$OUTPUT" || fail "apk adbsign не смог подписать пакет."
        SIGNED=1
    fi
    rm -f /tmp/.mkpkg-err
else
    log "Собираю $OUTPUT без подписи"
    build_package
fi

[ -f "$OUTPUT" ] || fail "apk mkpkg не создал файл."

log "Готово: $OUTPUT ($(wc -c < "$OUTPUT") байт)"

if [ "$SIGNED" = "1" ]; then
    if apk verify "$OUTPUT" >/dev/null 2>&1; then
        log "Подпись проверена: apk verify доволен"
    else
        log "Внимание: apk verify не признал подпись - публичный ключ ещё не в /etc/apk/keys/?"
    fi
    cat <<EOF

Установка:
  apk add ./$OUTPUT

Публичный ключ должен лежать в /etc/apk/keys/ на целевом роутере:
  openssl ec -in <ваш ключ>.pem -pubout -out /etc/apk/keys/forkop-servicecheck.pem

EOF
else
    cat <<EOF

Установка:
  apk add --allow-untrusted ./$OUTPUT

Пакет не подписан, поэтому нужен --allow-untrusted.
Подписать сразу при сборке: sh make-apk.sh --sign-key ваш-ключ.pem

EOF
fi

exit 0

__PAYLOAD_BELOW__
@@PAYLOAD@@
