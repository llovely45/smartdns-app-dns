#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="llovely45/smartdns-app-dns"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${BRANCH}"
BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/smartdns-app-dns"
BIN_PATH="$BIN_DIR/smartdns-app-dns"

if [[ "$(id -u)" -ne 0 ]]; then
  printf '请使用 root 运行安装器，例如：curl ... | sudo bash -s -- --youtube 1.1.1.1\n' >&2
  exit 1
fi

fetch() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$output"
  else
    printf '需要 curl 或 wget 才能下载安装文件。\n' >&2
    return 1
  fi
}

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
fetch "$RAW_BASE/smartdns-app-dns.sh" "$TEMP_DIR/smartdns-app-dns.sh"
fetch "$RAW_BASE/apps.tsv" "$TEMP_DIR/apps.tsv"

install -d -m 0755 "$BIN_DIR" "$SHARE_DIR" /etc/smartdns-app-dns/apps.d
install -m 0755 "$TEMP_DIR/smartdns-app-dns.sh" "$BIN_PATH"
install -m 0644 "$TEMP_DIR/apps.tsv" "$SHARE_DIR/apps.tsv"

printf 'smartdns-app-dns 已安装到 %s\n' "$BIN_PATH"
printf '应用清单：%s/apps.tsv\n' "$SHARE_DIR"
printf '自定义清单目录：/etc/smartdns-app-dns/apps.d\n'

if (($# > 0)); then
  if "$BIN_PATH" "$@"; then
    exit 0
  else
    result=$?
    exit "$result"
  fi
fi

printf '查看应用：sudo smartdns-app-dns --list\n'
printf '设置示例：sudo smartdns-app-dns --youtube 1.1.1.1\n'
