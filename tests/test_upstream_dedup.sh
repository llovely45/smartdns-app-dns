#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'MOCK'
#!/bin/sh
exit 22
MOCK
cat > "$TMP_DIR/bin/dig" <<'MOCK'
#!/bin/sh
cat <<'ANSWER'
www.google.com. 1 IN A 192.0.2.1
;; Query time: 1 msec
ANSWER
MOCK
chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/dig"

run_tool() {
  PATH="$TMP_DIR/bin:$PATH" "$ROOT_DIR/smartdns-app-dns.sh" "$@"
}

config="$TMP_DIR/smartdns.conf"
cat > "$config" <<'CONF'
bind 127.0.0.1:53
server 9.9.9.9
# BEGIN smartdns-app-dns:youtube
# smartdns-app-dns:primary-source=custom
server 4.4.4.4 -group appdns_youtube -exclude-default-group
server 1.1.1.1 -group appdns_youtube -exclude-default-group -fallback
nameserver /youtube.com/appdns_youtube
# END smartdns-app-dns:youtube
CONF

if ! run_tool --youtube 8.8.8.8 --config "$config" --no-restart > "$TMP_DIR/apply.txt" 2>&1; then
  cat "$TMP_DIR/apply.txt" >&2
  exit 1
fi
server_count="$(grep -cE '^server(-tcp|-tls|-https|-quic|-http3)?[[:space:]]' "$config" || true)"
if [[ "$server_count" -ne 4 ]]; then
  printf 'Expected 4 total upstream declarations (1 base + 3 deduplicated), found %s.\n' "$server_count" >&2
  grep -nE '^server(-tcp|-tls|-https|-quic|-http3)?[[:space:]]' "$config" >&2 || true
  exit 1
fi

shared_block_count="$(grep -c '^# BEGIN smartdns-app-dns:_shared-upstreams$' "$config" || true)"
[[ "$shared_block_count" -eq 1 ]]
grep -q '^server 8\.8\.8\.8 .*appdns_youtube' "$config"
grep -q '^server 1\.1\.1\.1 .* -fallback' "$config"
# Shared endpoints must still be assigned to each application's group.
grep '^server 66\.66\.66\.66 ' "$config" | grep -q 'appdns_disney-plus.*appdns_netflix'
grep '^server 1\.1\.1\.1 ' "$config" | grep -q 'appdns_disney-plus.*appdns_netflix'
grep -q '^server 9\.9\.9\.9$' "$config"
grep -A3 '^# BEGIN smartdns-app-dns:youtube$' "$config" | grep -q '^# smartdns-app-dns:primary-dns=8\.8\.8\.8$'

# A second run must preserve the user's custom YouTube upstream and stay idempotent.
cp "$config" "$TMP_DIR/first-result.conf"
run_tool --config "$config" --no-restart > "$TMP_DIR/second-apply.txt" 2>&1
if ! cmp -s "$TMP_DIR/first-result.conf" "$config"; then
  diff -u "$TMP_DIR/first-result.conf" "$config" >&2 || true
  exit 1
fi
server_count="$(grep -cE '^server(-tcp|-tls|-https|-quic|-http3)?[[:space:]]' "$config" || true)"
[[ "$server_count" -eq 4 ]]
[[ "$(grep -c '^# BEGIN smartdns-app-dns:_shared-upstreams$' "$config" || true)" -eq 1 ]]
grep -q '^server 8\.8\.8\.8 .*appdns_youtube' "$config"

# Exactly 64 configured upstreams are accepted.
limit_config="$TMP_DIR/exact-limit.conf"
for _ in $(seq 1 61); do printf 'server 192.0.2.53\n' >> "$limit_config"; done
run_tool --youtube 8.8.8.8 --config "$limit_config" --no-restart > "$TMP_DIR/limit.txt" 2>&1
[[ "$(grep -cE '^server(-tcp|-tls|-https|-quic|-http3)?[[:space:]]' "$limit_config")" -eq 64 ]]

# Do not write a configuration that still exceeds SmartDNS's 64-server limit.
guard_config="$TMP_DIR/at-limit.conf"
for _ in $(seq 1 62); do printf 'server 192.0.2.53\n' >> "$guard_config"; done
cp "$guard_config" "$TMP_DIR/guard-before.conf"
if run_tool --youtube 8.8.8.8 --config "$guard_config" --no-restart > "$TMP_DIR/guard.txt" 2>&1; then
  printf "Expected generation to reject a result over SmartDNS’s 64-server limit.\n" >&2
  exit 1
fi
grep -q '64' "$TMP_DIR/guard.txt"
cmp "$TMP_DIR/guard-before.conf" "$guard_config"

echo 'PASS: shared upstreams are deduplicated, custom settings persist, and oversized configs are rejected.'
