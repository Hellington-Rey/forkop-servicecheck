#!/bin/sh
#
# Forkop Service Check - установщик модуля проверки доступности сервисов.
#
# Скрипт самодостаточный: полезная нагрузка лежит внутри в base64.
# Ни один файл самого forkop не изменяется - добавляются только новые файлы,
# поэтому обновление forkop модуль не ломает и не ломается само.
#
# Установка:   sh install-forkop-servicecheck.sh
# Удаление:    sh install-forkop-servicecheck.sh --uninstall
#

set -e

VERSION="@@VERSION@@"
BUILT_AT="@@BUILT_AT@@"

BIN_PATH="/usr/bin/forkop-servicecheck"
LIB_DIR="/usr/lib/forkop-servicecheck"
SHARE_DIR="/usr/share/forkop-servicecheck"
VERSION_FILE="$SHARE_DIR/version"
VIEW_FILE="/www/luci-static/resources/view/forkop/servicecheck-v110.js"
LEGACY_VIEW_FILE="/www/luci-static/resources/view/forkop/servicecheck.js"
BROKEN_VIEW_FILE="/www/luci-static/resources/view/forkop/servicecheck-1.1.0.js"
MENU_FILE="/usr/share/luci/menu.d/luci-app-forkop-servicecheck.json"
ACL_FILE="/usr/share/rpcd/acl.d/luci-app-forkop-servicecheck.json"
STATE_DIR="/var/run/forkop-servicecheck"
NETNS_DIR="/etc/netns/fkpsc"

log() {
    printf '\033[0;36m[servicecheck]\033[0m %s\n' "$1"
}

fail() {
    printf '\033[0;31m[servicecheck]\033[0m %s\n' "$1" >&2
    exit 1
}

clear_luci_cache() {
    rm -rf /tmp/luci-modulecache 2>/dev/null || true
    rm -f /tmp/luci-indexcache* 2>/dev/null || true
}

reload_rpcd() {
    if [ -x /etc/init.d/rpcd ]; then
        /etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
    fi
}

do_uninstall() {
    log "Удаляю модуль проверки сервисов"

    if [ -x "$BIN_PATH" ]; then
        "$BIN_PATH" netns_teardown >/dev/null 2>&1 || true
    fi

    rm -f "$BIN_PATH" "$VIEW_FILE" "$LEGACY_VIEW_FILE" "$BROKEN_VIEW_FILE" "$MENU_FILE" "$ACL_FILE"
    rm -rf "$LIB_DIR" "$SHARE_DIR" "$STATE_DIR" "$NETNS_DIR"

    clear_luci_cache
    reload_rpcd

    log "Готово. Страница пропадёт из меню после обновления вкладки LuCI."
    exit 0
}

case "$1" in
    --uninstall|uninstall|-u)
        do_uninstall
        ;;
esac

log "Forkop Service Check $VERSION (собран $BUILT_AT)"

detect_installed_version() {
    if [ -s "$VERSION_FILE" ]; then
        head -n 1 "$VERSION_FILE"
        return
    fi

    if command -v opkg >/dev/null 2>&1; then
        PACKAGE_VERSION="$(opkg status luci-app-forkop-servicecheck 2>/dev/null |
            sed -n 's/^Version: //p' | head -n 1)"
        if [ -n "$PACKAGE_VERSION" ]; then
            printf '%s\n' "$PACKAGE_VERSION"
            return
        fi
    fi

    if command -v apk >/dev/null 2>&1 &&
        apk info -e luci-app-forkop-servicecheck >/dev/null 2>&1; then
        apk info -v luci-app-forkop-servicecheck 2>/dev/null | head -n 1
        return
    fi

    if [ -x "$BIN_PATH" ]; then
        printf '%s\n' "legacy (без маркера версии)"
    fi
}

INSTALLED_VERSION="$(detect_installed_version || true)"
if [ -n "$INSTALLED_VERSION" ]; then
    if [ "$INSTALLED_VERSION" = "$VERSION" ]; then
        log "Уже установлена версия $VERSION — выполняю проверку и переустановку"
    else
        log "Обнаружена предыдущая версия: $INSTALLED_VERSION"
        log "Обновляю до версии $VERSION с сохранением пользовательских профилей в /etc"
    fi
else
    log "Предыдущая версия не обнаружена — чистая установка"
fi

# --- Проверки окружения -----------------------------------------------------

[ "$(id -u)" = "0" ] || fail "Нужны права root."

command -v ucode >/dev/null 2>&1 || fail "Не найден ucode - это не роутер с forkop?"
command -v base64 >/dev/null 2>&1 || fail "Не найдена утилита base64."
command -v tar >/dev/null 2>&1 || fail "Не найдена утилита tar."

if [ ! -x /usr/bin/forkop ]; then
    fail "Не найден /usr/bin/forkop. Установите forkop перед этим модулем."
fi

FORKOP_VERSION="$(/usr/bin/forkop show_version 2>/dev/null || echo unknown)"
log "Обнаружен forkop $FORKOP_VERSION"

if [ ! -d /www/luci-static/resources/view/forkop ]; then
    fail "Не найден каталог LuCI-приложения forkop. Установлен ли luci-app-forkop?"
fi

# --- Распаковка во временный каталог ----------------------------------------

TMP_DIR="$(mktemp -d /tmp/forkop-servicecheck.XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

log "Распаковываю файлы"

extract_payload() {
    # Payload находится в here-document, поэтому установка одинаково работает
    # из файла и через `wget -O- URL | sh`, где $0 указывает на `sh`.
    base64 -d <<'__FORKOP_SC_PAYLOAD__' | tar -xzf - -C "$TMP_DIR"
@@PAYLOAD@@
__FORKOP_SC_PAYLOAD__
}

extract_payload || fail "Не удалось распаковать полезную нагрузку."

[ -f "$TMP_DIR/usr/lib/forkop-servicecheck/probe.uc" ] || fail "В архиве нет движка проверки."

# --- Проверка синтаксиса до подмены живых файлов ----------------------------

SYNTAX_CHECK_WORKS=0
printf 'print("ok");\n' > "$TMP_DIR/.syntax-probe.uc"
if ucode -c -o /dev/null "$TMP_DIR/.syntax-probe.uc" >/dev/null 2>&1; then
    SYNTAX_CHECK_WORKS=1
fi

if [ "$SYNTAX_CHECK_WORKS" = "1" ]; then
    for file in "$TMP_DIR/usr/lib/forkop-servicecheck/probe.uc" "$TMP_DIR/usr/bin/forkop-servicecheck"; do
        if ! ucode -c -o /dev/null "$file" >/dev/null 2>&1; then
            printf '\n'
            ucode -c -o /dev/null "$file" || true
            fail "Синтаксическая ошибка в $(basename "$file") - установка отменена, система не тронута."
        fi
    done
    log "Синтаксис ucode-файлов в порядке"
else
    log "Внимание: ucode -c недоступен, пропускаю проверку синтаксиса"
fi

# --- Установка --------------------------------------------------------------

log "Устанавливаю файлы"

mkdir -p "$LIB_DIR" "$SHARE_DIR" "$STATE_DIR"
mkdir -p /usr/share/luci/menu.d /usr/share/rpcd/acl.d

cp -f "$TMP_DIR/usr/bin/forkop-servicecheck" "$BIN_PATH"
cp -f "$TMP_DIR/usr/lib/forkop-servicecheck/probe.uc" "$LIB_DIR/probe.uc"
cp -f "$TMP_DIR/usr/lib/forkop-servicecheck/xhttp_hotfix.sh" "$LIB_DIR/xhttp_hotfix.sh"
cp -f "$TMP_DIR/usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh" "$LIB_DIR/icmp_tproxy_hotfix.sh"
cp -f "$TMP_DIR/usr/share/forkop-servicecheck/profiles.json" "$SHARE_DIR/profiles.json"
cp -f "$TMP_DIR/www/luci-static/resources/view/forkop/servicecheck-v110.js" "$VIEW_FILE"
rm -f "$LEGACY_VIEW_FILE" "$BROKEN_VIEW_FILE"
cp -f "$TMP_DIR/usr/share/luci/menu.d/luci-app-forkop-servicecheck.json" "$MENU_FILE"
cp -f "$TMP_DIR/usr/share/rpcd/acl.d/luci-app-forkop-servicecheck.json" "$ACL_FILE"

chmod 0755 "$BIN_PATH"
chmod 0755 "$LIB_DIR/xhttp_hotfix.sh" "$LIB_DIR/icmp_tproxy_hotfix.sh"
chmod 0644 "$LIB_DIR/probe.uc" "$SHARE_DIR/profiles.json" "$VIEW_FILE" "$MENU_FILE" "$ACL_FILE"
printf '%s\n' "$VERSION" > "$VERSION_FILE"

# --- Дожимаем LuCI ----------------------------------------------------------

clear_luci_cache
reload_rpcd

# --- Проверка работоспособности ---------------------------------------------

log "Проверяю установку"

if ! CAPS="$("$BIN_PATH" capabilities 2>&1)"; then
    fail "Модуль установлен, но не запускается: $CAPS"
fi

echo "$CAPS" | grep -q '"fakeip_ranges"' || fail "Неожиданный ответ модуля: $CAPS"

PROFILES="$("$BIN_PATH" list 2>/dev/null | grep -o '"id":' | wc -l)"

log "Модуль отвечает, профилей сервисов: $PROFILES"

# ucode печатает JSON с пробелом после двоеточия, поэтому сверяемся регуляркой.
if ! echo "$CAPS" | grep -q '"curl": *true'; then
    log "Совет: поставьте curl (opkg install curl / apk add curl) - без него"
    log "       тайминги TCP/TLS и коды ответов определяются приблизительно."
fi

if ! echo "$CAPS" | grep -q '"forkop_running": *true'; then
    log "Внимание: forkop сейчас не запущен - проверка покажет доступность без обхода."
fi

cat <<'EOF'

Готово.

  Веб-интерфейс: LuCI -> Сервисы -> "Forkop: проверка сервисов"
  (если пункт не появился - обновите страницу с Ctrl+F5, кеш LuCI уже сброшен)

  Из консоли:
    forkop-servicecheck list
    forkop-servicecheck run telegram,youtube
    forkop-servicecheck run all netns
    forkop-servicecheck capabilities

  Удалить:
    sh install-forkop-servicecheck.sh --uninstall

EOF

exit 0
