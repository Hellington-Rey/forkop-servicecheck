#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
HOTFIX="$ROOT/files/usr/lib/forkop-servicecheck/icmp_tproxy_hotfix.sh"
TMP="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$TMP/bin" "$TMP/backups"

cat > "$TMP/bin/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && echo 0
EOF

cat > "$TMP/bin/ucode" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
if [ "${NFT_UNSAFE:-0}" = "1" ]; then
    echo 'ip daddr @forkop_rule_test_subnets meta mark set 0x04000000 accept'
else
    echo 'ip daddr @forkop_rule_test_subnets meta l4proto { tcp, udp } meta mark set 0x04000000 accept'
fi
EOF

cat > "$TMP/bin/forkop-init" <<'EOF'
#!/bin/sh
echo "${1:-}" >> "$INIT_LOG"
if [ "${1:-}" = "running" ]; then
    [ "${FORKOP_RUNNING:-0}" = "1" ]
fi
EOF

chmod +x "$TMP/bin/id" "$TMP/bin/ucode" "$TMP/bin/nft" "$TMP/bin/forkop-init"

write_source() {
    cat > "$1" <<'EOF'
function fixture(section, sets) {
    let match_ip4 = [ "ip", "daddr", "@" + as_string(sets.subnets) ];
    let match_ip6 = [ "ip6", "daddr", "@" + as_string(sets.subnets6) ];
    return match_ip4;
}
EOF
}

run_hotfix() {
    PATH="$TMP/bin:$PATH" \
    INIT_LOG="$TMP/init.log" \
    FORKOP_NFT_APPLY="$1" \
    FORKOP_INIT_SCRIPT="$TMP/bin/forkop-init" \
    FORKOP_BACKUP_DIR="$TMP/backups" \
    FORKOP_LIB_DIR="$TMP" \
    FORKOP_RUNNING="${2:-0}" \
    NFT_UNSAFE="${3:-0}" \
    sh "$HOTFIX"
}

SOURCE_STOPPED="$TMP/stopped.uc"
write_source "$SOURCE_STOPPED"
run_hotfix "$SOURCE_STOPPED" 0 > "$TMP/stopped.out"
grep -Fq 'append_array(match_ip4, [ "meta", "l4proto", "{ tcp, udp }" ]);' "$SOURCE_STOPPED"
grep -Fq 'append_array(match_ip6, [ "meta", "l4proto", "{ tcp, udp }" ]);' "$SOURCE_STOPPED"
grep -Fq 'fixed rules will apply on the next start' "$TMP/stopped.out"
! grep -Fq 'restart' "$TMP/init.log"

BACKUPS_BEFORE="$(find "$TMP/backups" -type f | wc -l)"
run_hotfix "$SOURCE_STOPPED" 0 > "$TMP/idempotent.out"
BACKUPS_AFTER="$(find "$TMP/backups" -type f | wc -l)"
[ "$BACKUPS_BEFORE" = "$BACKUPS_AFTER" ]
grep -Fq 'already installed' "$TMP/idempotent.out"

: > "$TMP/init.log"
SOURCE_RUNNING="$TMP/running.uc"
write_source "$SOURCE_RUNNING"
run_hotfix "$SOURCE_RUNNING" 1 0 > "$TMP/running.out"
grep -Fq 'restart' "$TMP/init.log"
grep -Fq 'live nftables rules verified' "$TMP/running.out"

: > "$TMP/init.log"
SOURCE_ROLLBACK="$TMP/rollback.uc"
write_source "$SOURCE_ROLLBACK"
cp "$SOURCE_ROLLBACK" "$TMP/rollback.original"
if run_hotfix "$SOURCE_ROLLBACK" 1 1 > "$TMP/rollback.out" 2>&1; then
    echo "ERROR: unsafe live rules must trigger rollback" >&2
    exit 1
fi
cmp "$TMP/rollback.original" "$SOURCE_ROLLBACK"
grep -Fq 'restart' "$TMP/init.log"
grep -Fq 'restoring' "$TMP/rollback.out"

SOURCE_PARTIAL="$TMP/partial.uc"
write_source "$SOURCE_PARTIAL"
sed -i '/let match_ip6/a\        append_array(match_ip4, [ "meta", "l4proto", "{ tcp, udp }" ]);' "$SOURCE_PARTIAL"
if run_hotfix "$SOURCE_PARTIAL" 0 > "$TMP/partial.out" 2>&1; then
    echo "ERROR: a partial patch must be rejected" >&2
    exit 1
fi
grep -Fq 'partial ICMP/TProxy patch' "$TMP/partial.out"

echo "icmp_tproxy_hotfix tests: OK"
