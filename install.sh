#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="llovely45/smartdns-app-dns"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}/${BRANCH}"
SMARTDNS_REPOSITORY="pymumu/smartdns"
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

smartdns_present() {
  local path state status
  command -v smartdns >/dev/null 2>&1 && return 0

  for path in \
    /usr/sbin/smartdns /usr/local/sbin/smartdns \
    /usr/bin/smartdns /usr/local/bin/smartdns /sbin/smartdns /bin/smartdns \
    /etc/init.d/smartdns /etc/systemd/system/smartdns.service \
    /lib/systemd/system/smartdns.service /usr/lib/systemd/system/smartdns.service; do
    [[ -x "$path" || -f "$path" ]] && return 0
  done

  if command -v systemctl >/dev/null 2>&1; then
    state="$(systemctl show smartdns.service --property=LoadState --value 2>/dev/null || true)"
    [[ -n "$state" && "$state" != not-found ]] && return 0
  fi

  if command -v dpkg-query >/dev/null 2>&1; then
    status="$(dpkg-query -W -f='${Status}' smartdns 2>/dev/null || true)"
    [[ "$status" == 'install ok installed' ]] && return 0
  fi
  if command -v rpm >/dev/null 2>&1 && rpm -q smartdns >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

json_value() {
  local value="${1#*:}"
  value="${value# }"
  value="${value#\"}"
  value="${value%%\"*}"
  printf '%s' "$value"
}

release_asset() {
  local json_file="$1" suffix="$2" line name in_target=0
  SMARTDNS_ASSET_NAME=""
  SMARTDNS_ASSET_URL=""
  SMARTDNS_ASSET_DIGEST=""

  while IFS= read -r line; do
    case "$line" in
      *'"name":'*)
        name="$(json_value "$line")"
        in_target=0
        if [[ "$name" == smartdns.*."$suffix" ]]; then
          in_target=1
          SMARTDNS_ASSET_NAME="$name"
        fi
        ;;
    esac

    if ((in_target)); then
      case "$line" in
        *'"digest":'*) SMARTDNS_ASSET_DIGEST="$(json_value "$line")" ;;
        *'"browser_download_url":'*)
          SMARTDNS_ASSET_URL="$(json_value "$line")"
          break
          ;;
      esac
    fi
  done < "$json_file"

  [[ -n "$SMARTDNS_ASSET_NAME" && -n "$SMARTDNS_ASSET_URL" ]]
}

verify_download() {
  local file="$1" expected actual
  [[ "$SMARTDNS_ASSET_DIGEST" == sha256:* ]] || {
    printf '错误：GitHub Release 未提供可用的 SHA-256 摘要，拒绝安装。\n' >&2
    return 1
  }
  expected="${SMARTDNS_ASSET_DIGEST#sha256:}"

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file")"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$file")"
  else
    printf '错误：系统缺少 sha256sum/shasum，无法校验 SmartDNS 安装包。\n' >&2
    return 1
  fi
  actual="${actual%% *}"
  [[ "$actual" == "$expected" ]] || {
    printf '错误：SmartDNS 安装包 SHA-256 校验失败。\n' >&2
    return 1
  }
}

install_smartdns() {
  local temp_dir="$1" release_json release_tag os_id os_like raw_arch asset_arch
  local debian_like=0 install_mode="tar" suffix asset_file installer
  release_json="$temp_dir/smartdns-release.json"

  printf '正在检查 SmartDNS 官方 Release…\n'
  fetch "https://api.github.com/repos/${SMARTDNS_REPOSITORY}/releases/latest" "$release_json" || {
    printf '错误：无法读取 SmartDNS 官方 Release 信息。\n' >&2
    return 1
  }
  release_tag="$(sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$release_json" | head -n 1)"
  [[ -n "$release_tag" ]] || {
    printf '错误：无法从 GitHub API 解析 SmartDNS Release 版本。\n' >&2
    return 1
  }

  os_id=""
  os_like=""
  if [[ -r /etc/os-release ]]; then
    while IFS='=' read -r key value; do
      value="${value%\"}"
      value="${value#\"}"
      value="${value%\'}"
      value="${value#\'}"
      case "$key" in
        ID) os_id="$value" ;;
        ID_LIKE) os_like="$value" ;;
      esac
    done < /etc/os-release
  fi
  case " $os_id $os_like " in
    *' debian '*|*' ubuntu '*) debian_like=1 ;;
  esac

  raw_arch="$(uname -m)"
  case "$raw_arch" in
    amd64|x86_64) asset_arch="x86_64" ;;
    arm64|aarch64) asset_arch="aarch64" ;;
    arm|armv5*|armv6*|armv7*) asset_arch="arm" ;;
    i386|i486|i586|i686) asset_arch="x86" ;;
    *) asset_arch="$raw_arch" ;;
  esac

  if ((debian_like)) && command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
    install_mode="deb"
    suffix="${asset_arch}-debian-all.deb"
    if ! release_asset "$release_json" "$suffix"; then
      install_mode="tar"
    fi
  fi

  if [[ "$install_mode" == tar ]]; then
    suffix="${asset_arch}-linux-all.tar.gz"
    release_asset "$release_json" "$suffix" || {
      printf '错误：SmartDNS 官方 Release 没有适用于 %s（%s）的安装包。\n' "$os_id" "$raw_arch" >&2
      return 1
    }
  fi

  [[ "$SMARTDNS_ASSET_URL" == "https://github.com/${SMARTDNS_REPOSITORY}/releases/download/"* ]] || {
    printf '错误：SmartDNS Release 返回了非官方安装包地址。\n' >&2
    return 1
  }
  [[ "$SMARTDNS_ASSET_DIGEST" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || {
    printf '错误：SmartDNS Release 缺少有效 SHA-256 摘要。\n' >&2
    return 1
  }

  asset_file="$temp_dir/$SMARTDNS_ASSET_NAME"
  printf '正在下载 SmartDNS %s（%s）…\n' "$release_tag" "$asset_arch"
  fetch "$SMARTDNS_ASSET_URL" "$asset_file" || {
    printf '错误：SmartDNS 安装包下载失败。\n' >&2
    return 1
  }
  verify_download "$asset_file" || return 1

  if [[ "$install_mode" == deb ]]; then
    printf '通过 Debian/Ubuntu 软件包安装 SmartDNS…\n'
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$asset_file" || {
      printf '错误：apt-get 安装 SmartDNS 失败。未执行 apt-get update 或系统升级。\n' >&2
      return 1
    }
  else
    command -v tar >/dev/null 2>&1 || {
      printf '错误：安装通用 Linux 包需要 tar。\n' >&2
      return 1
    }
    tar -xzf "$asset_file" -C "$temp_dir" || {
      printf '错误：无法解压 SmartDNS 官方安装包。\n' >&2
      return 1
    }
    installer="$temp_dir/smartdns/install"
    [[ -f "$installer" ]] || {
      printf '错误：通用 Linux 包中缺少官方安装脚本。\n' >&2
      return 1
    }
    printf '通过 SmartDNS 官方 Linux 安装脚本安装…\n'
    sh "$installer" -i || {
      printf '错误：SmartDNS 官方 Linux 安装脚本执行失败。\n' >&2
      return 1
    }
  fi

  smartdns_present || {
    printf '错误：安装命令已完成，但未检测到 SmartDNS 程序或服务。\n' >&2
    return 1
  }
  printf 'SmartDNS %s 已安装。\n' "$release_tag"
}

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
fetch "$RAW_BASE/smartdns-app-dns.sh" "$TEMP_DIR/smartdns-app-dns.sh"
fetch "$RAW_BASE/apps.tsv" "$TEMP_DIR/apps.tsv"

if smartdns_present; then
  printf '检测到已有 SmartDNS，跳过自动安装。\n'
else
  should_install=1
  for arg in "$@"; do
    case "$arg" in
      -h|--help|--list|--dry-run) should_install=0 ;;
    esac
  done
  if ((should_install)); then
    install_smartdns "$TEMP_DIR"
  fi
fi

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
