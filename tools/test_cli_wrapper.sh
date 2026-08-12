#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/files/usr/bin/forkop-servicecheck"
TMP="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$TMP/bin" "$TMP/lib"
: > "$TMP/lib/probe.uc"

cat > "$TMP/bin/ucode" <<'EOF'
#!/bin/sh
printf '%s\n' "$@"
EOF
chmod +x "$TMP/bin/ucode"

run_wrapper() {
    PATH="$TMP/bin:$PATH" FORKOP_SC_LIB="$TMP/lib" sh "$WRAPPER" "$@"
}

CUSTOM_OUTPUT="$(run_wrapper custom example.com 443 netns 192.168.2.55)"
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- '-L'
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- "$TMP/lib"
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- "$TMP/lib/probe.uc"
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- 'custom'
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- 'example.com'
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- '443'
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- 'netns'
printf '%s\n' "$CUSTOM_OUTPUT" | grep -Fxq -- '192.168.2.55'

[ "$(run_wrapper xhttp_patch | tail -n 1)" = "xhttp-patch" ]
[ "$(run_wrapper icmp_tproxy_patch | tail -n 1)" = "icmp-tproxy-patch" ]
[ "$(run_wrapper netns_teardown | tail -n 1)" = "netns-teardown" ]

if run_wrapper unknown >/dev/null 2>&1; then
    echo "ERROR: unknown command must fail" >&2
    exit 1
fi

echo "cli wrapper tests: OK"
