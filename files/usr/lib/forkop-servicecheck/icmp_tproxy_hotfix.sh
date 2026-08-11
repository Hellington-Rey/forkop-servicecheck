#!/bin/sh
set -eu

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

TARGET="${FORKOP_NFT_APPLY:-}"
if [ -z "$TARGET" ]; then
    for path in /usr/lib/nft/apply.uc /usr/lib/forkop/nft/apply.uc /usr/share/forkop/nft/apply.uc /opt/forkop/nft/apply.uc; do
        [ -f "$path" ] && TARGET="$path" && break
    done
fi

INIT_SCRIPT="${FORKOP_INIT_SCRIPT:-/etc/init.d/forkop}"
FORKOP_BIN="${FORKOP_BIN:-/usr/bin/forkop}"
LIB_DIR="${FORKOP_LIB_DIR:-/usr/lib/forkop}"
BACKUP_DIR="${FORKOP_BACKUP_DIR:-/root}"
MARKER4='append_array(match_ip4, [ "meta", "l4proto", "{ tcp, udp }" ]);'
MARKER6='append_array(match_ip6, [ "meta", "l4proto", "{ tcp, udp }" ]);'
ANCHOR='    let match_ip6 = [ "ip6", "daddr", "@" + as_string(sets.subnets6) ];'

[ "$(id -u)" = "0" ] || fail "root privileges are required"
[ -n "$TARGET" ] && [ -f "$TARGET" ] || fail "Forkop nft/apply.uc was not found"
[ -w "$TARGET" ] || fail "file is not writable: $TARGET"
[ -d "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ] || fail "backup directory is unavailable: $BACKUP_DIR"
[ -x "$INIT_SCRIPT" ] || fail "Forkop init script was not found: $INIT_SCRIPT"
command -v awk >/dev/null 2>&1 || fail "awk was not found"
command -v nft >/dev/null 2>&1 || fail "nft was not found"
command -v ucode >/dev/null 2>&1 || fail "ucode was not found"

if grep -Fq "$MARKER4" "$TARGET" && grep -Fq "$MARKER6" "$TARGET"; then
    echo "ICMP/TProxy fix is already installed: $TARGET"
    exit 0
fi
if grep -Fq "$MARKER4" "$TARGET" || grep -Fq "$MARKER6" "$TARGET"; then
    fail "a partial ICMP/TProxy patch was detected; refusing to modify $TARGET"
fi

anchor_count="$(grep -Fxc "$ANCHOR" "$TARGET" || true)"
[ "$anchor_count" = "1" ] || fail "incompatible Forkop version: expected nft/apply.uc fragment was not found"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/$(basename "$TARGET").before-icmp-tproxy-hotfix-$STAMP"
TMP="$(mktemp "${TARGET}.icmp-tproxy-hotfix.XXXXXX")"
BC="$TMP.bc"
WAS_RUNNING=0

cleanup() {
    rm -f "$TMP" "$BC"
}
trap cleanup EXIT HUP INT TERM

cp -p "$TARGET" "$BACKUP"

awk -v anchor="$ANCHOR" '
{
    print
    if ($0 == anchor) {
        print "    if (section_priority_action(section) != \"bypass\") {"
        print "        append_array(match_ip4, [ \"meta\", \"l4proto\", \"{ tcp, udp }\" ]);"
        print "        append_array(match_ip6, [ \"meta\", \"l4proto\", \"{ tcp, udp }\" ]);"
        print "    }"
    }
}
' "$TARGET" > "$TMP"

grep -Fq "$MARKER4" "$TMP" && grep -Fq "$MARKER6" "$TMP" ||
    fail "failed to generate patched nft/apply.uc; original backup: $BACKUP"
ucode -L "$LIB_DIR" -c -o "$BC" "$TMP" ||
    fail "ucode rejected the patch; original backup: $BACKUP"

chmod 0644 "$TMP"
mv -f "$TMP" "$TARGET"
sync

if [ -x "$FORKOP_BIN" ] &&
    "$FORKOP_BIN" get_status 2>/dev/null | grep -Eq '"running"[[:space:]]*:[[:space:]]*1'; then
    WAS_RUNNING=1
elif "$INIT_SCRIPT" running >/dev/null 2>&1; then
    WAS_RUNNING=1
fi

rollback() {
    echo "Verification failed; restoring $BACKUP" >&2
    cp -p "$BACKUP" "$TARGET"
    if [ "$WAS_RUNNING" = "1" ]; then
        "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    fi
    exit 1
}

if [ "$WAS_RUNNING" = "1" ]; then
    "$INIT_SCRIPT" restart || rollback

    RULES="$({
        nft list chain inet ForkopTable priority_rules
        nft list chain inet ForkopTable priority_output_rules
    } 2>/dev/null)" || rollback

    UNSAFE_RULES="$(printf '%s\n' "$RULES" | awk '
/forkop_rule_[^ ]+_subnets6?[[:space:]].*meta mark set/ &&
    $0 !~ /meta l4proto \{ tcp, udp \}/ {
    print
}
')"

    if [ -n "$UNSAFE_RULES" ]; then
        echo "Unsafe subnet rules remain after restart:" >&2
        echo "$UNSAFE_RULES" >&2
        rollback
    fi
fi

echo "OK: ICMP/TProxy fix installed"
echo "Generator: $TARGET"
echo "Backup: $BACKUP"
if [ "$WAS_RUNNING" = "1" ]; then
    echo "Forkop restarted; live nftables rules verified"
else
    echo "Forkop is stopped; fixed rules will apply on the next start"
fi
