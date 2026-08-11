#!/bin/sh
set -eu
fail() { echo "ERROR: $*" >&2; exit 1; }
command -v ucode >/dev/null 2>&1 || fail "ucode не найден"
TARGET="${FORKOP_PARSER:-}"
if [ -z "$TARGET" ]; then
    for p in /usr/lib/forkop/subscription/parser.uc /usr/share/forkop/subscription/parser.uc /opt/forkop/subscription/parser.uc; do
        [ -f "$p" ] && TARGET="$p" && break
    done
fi
[ -n "$TARGET" ] && [ -f "$TARGET" ] || fail "parser.uc не найден"
[ -w "$TARGET" ] || fail "нет прав на запись: $TARGET"
grep -q '^function xhttp_optional_string(object, key, value)' "$TARGET" && { echo "Hotfix уже установлен: $TARGET"; exit 0; }
grep -q '"sc_stream_up_server_secs",' "$TARGET" || fail "несовместимая версия Forkop"
grep -q '^function xhttp_object_setting_value(source, camel_key, snake_key)' "$TARGET" || fail "несовместимая версия Forkop"
grep -q 'xhttp_setting_value(query, extra_settings, "scStreamUpServerSecs"' "$TARGET" || fail "несовместимая версия Forkop"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/$(basename "$TARGET").before-xhttp-hotfix-$STAMP"
TMP="$(mktemp /tmp/forkop-parser-hotfix.XXXXXX)"
BC="$TMP.bc"
trap 'rm -f "$TMP" "$BC"' EXIT HUP INT TERM
cp -p "$TARGET" "$BACKUP"
cp -p "$TARGET" "$TMP"
sed -i '/        "sc_stream_up_server_secs",/a\
        "scMaxBufferedPosts", "sc_max_buffered_posts", "xPaddingObfsMode", "x_padding_obfs_mode",\
        "xPaddingKey", "x_padding_key", "xPaddingHeader", "x_padding_header",\
        "xPaddingPlacement", "x_padding_placement", "xPaddingMethod", "x_padding_method",\
        "uplinkHTTPMethod", "uplink_http_method", "headers",' "$TMP"
sed -i '/^function xhttp_object_setting_value(source, camel_key, snake_key) {/i\
function xhttp_optional_string(object, key, value) {\
    if (xhttp_value_present(value) \&\& type(value) == "string") object[key] = value;\
}\
' "$TMP"
sed -i '/xhttp_optional_range(result, "sc_stream_up_server_secs", xhttp_setting_value(query, extra/a\
        xhttp_optional_string(result, "x_padding_key", xhttp_setting_value(query, extra_settings, "xPaddingKey", "x_padding_key"));\
        xhttp_optional_string(result, "x_padding_header", xhttp_setting_value(query, extra_settings, "xPaddingHeader", "x_padding_header"));\
        xhttp_optional_string(result, "x_padding_method", xhttp_setting_value(query, extra_settings, "xPaddingMethod", "x_padding_method"));\
        xhttp_optional_string(result, "uplink_http_method", xhttp_setting_value(query, extra_settings, "uplinkHTTPMethod", "uplink_http_method"));' "$TMP"
ucode -c -o "$BC" "$TMP" || fail "ucode не принял патч; оригинал сохранён: $BACKUP"
cp -p "$TMP" "$TARGET"
sync
echo "OK: xHTTP hotfix установлен"
echo "Parser: $TARGET"
echo "Backup: $BACKUP"
