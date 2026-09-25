#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/smartdns-app-dns"
EXTENSION_DIR="${SMARTDNS_APP_DNS_EXTENSION_DIR:-$CONFIG_DIR/apps.d}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

declare -A APP_DOMAINS=()
declare -A DOMAIN_OWNER=()
declare -A REQUESTED_DNS=()
declare -a REQUEST_ORDER=()

usage() {
  cat <<'EOF'
SmartDNS App DNS — 为指定应用配置独立上游 DNS

用法:
  smartdns-app-dns --youtube 1.1.1.1 [--netflix 8.8.8.8 ...]
  smartdns-app-dns --list

选项:
  --<应用名> <IPv4|IPv6>  设置该应用的上游 DNS，可同时设置多个
  --config <路径>         指定 SmartDNS 配置文件
  --no-restart            写入后不重启 SmartDNS
  --dry-run               展示将要写入的差异，不修改文件
  --list                  列出应用名和域名
  -h, --help              显示帮助

默认检测路径:
  /etc/smartdns/smartdns.conf
  /etc/smartdns.conf
  /usr/local/etc/smartdns/smartdns.conf

可在 /etc/smartdns-app-dns/apps.d/*.tsv 中添加自定义应用。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

valid_domain() {
  local domain="$1" label
  local -a labels=()
  [[ ${#domain} -le 253 && "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
  IFS='.' read -r -a labels <<< "$domain"
  ((${#labels[@]} >= 2)) || return 1
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])$ ]] || return 1
    ((${#label} <= 63)) || return 1
  done
}

load_catalog_file() {
  local file="$1" line slug domains domain
  local -a domain_list=()
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    [[ "$line" == *'|'* && "${line#*|}" != *'|'* ]] || die "清单格式错误：$file 中的行应为 slug|domain1,domain2"
    slug="${line%%|*}"
    domains="${line#*|}"
    [[ "$slug" =~ ^[a-z][a-z0-9-]*$ ]] || die "清单中的应用名无效：$slug"
    [[ -n "$domains" ]] || die "应用 $slug 没有配置域名"
    [[ -z "${APP_DOMAINS[$slug]:-}" ]] || die "应用名重复：$slug"
    IFS=',' read -r -a domain_list <<< "$domains"
    ((${#domain_list[@]} > 0)) || die "应用 $slug 没有配置域名"
    for domain in "${domain_list[@]}"; do
      valid_domain "$domain" || die "应用 $slug 的域名无效：$domain"
      [[ -z "${DOMAIN_OWNER[$domain]:-}" ]] || die "域名 $domain 同时属于 ${DOMAIN_OWNER[$domain]} 和 $slug"
      DOMAIN_OWNER["$domain"]="$slug"
    done
    APP_DOMAINS["$slug"]="$domains"
  done < "$file"
}

valid_dns_address() {
  local address="$1" octet
  local -a octets=()
  if [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    IFS='.' read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
      ((10#$octet <= 255)) || return 1
    done
    return 0
  fi
  if [[ "$address" == *:* && "$address" =~ ^[0-9a-fA-F:]+$ ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$address" >/dev/null 2>&1
      return $?
    fi
    [[ ${#address} -le 39 && "$address" != *:::* ]]
    return $?
  fi
  return 1
}

print_apps() {
  local slug
  printf '可用应用参数（DNS 支持 IPv4 或 IPv6）：\n'
  for slug in "${!APP_DOMAINS[@]}"; do
    printf '  --%-12s %s\n' "$slug" "${APP_DOMAINS[$slug]}"
  done | sort
}

BASE_CATALOG="$SCRIPT_DIR/apps.tsv"
[[ -f "$BASE_CATALOG" ]] || BASE_CATALOG="/usr/local/share/smartdns-app-dns/apps.tsv"
[[ -f "$BASE_CATALOG" ]] || die "找不到应用清单 apps.tsv"
load_catalog_file "$BASE_CATALOG"
shopt -s nullglob
for catalog in "$EXTENSION_DIR"/*.tsv; do
  load_catalog_file "$catalog"
done

CONFIG_ARG=""
DO_RESTART=1
DRY_RUN=0
LIST_ONLY=0

while (($# > 0)); do
  arg="$1"
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --no-restart)
      DO_RESTART=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --config)
      (($# >= 2)) || die "--config 需要一个文件路径"
      CONFIG_ARG="$2"
      shift 2
      ;;
    --config=*)
      CONFIG_ARG="${arg#*=}"
      [[ -n "$CONFIG_ARG" ]] || die "--config 需要一个文件路径"
      shift
      ;;
    --*)
      flag="$arg"
      if [[ "$arg" == *=* ]]; then
        flag="${arg%%=*}"
        value="${arg#*=}"
        shift
      else
        (($# >= 2)) || die "$arg 需要一个 IPv4 或 IPv6 地址"
        value="$2"
        shift 2
      fi
      slug="${flag#--}"
      [[ "$slug" =~ ^[a-z][a-z0-9-]*$ ]] || die "无效的应用参数：$flag"
      [[ -n "${APP_DOMAINS[$slug]:-}" ]] || die "未知应用参数：$flag（使用 --list 查看，或添加 apps.d 清单）"
      valid_dns_address "$value" || die "DNS 地址格式无效：$value（只接受 IPv4 或 IPv6）"
      if [[ -z "${REQUESTED_DNS[$slug]:-}" ]]; then
        REQUEST_ORDER+=("$slug")
      fi
      REQUESTED_DNS["$slug"]="$value"
      ;;
    *)
      die "无法识别的参数：$arg"
      ;;
  esac
done

if ((LIST_ONLY)); then
  ((${#REQUEST_ORDER[@]} == 0)) || die "--list 不能与应用参数一起使用"
  print_apps
  exit 0
fi
((${#REQUEST_ORDER[@]} > 0)) || { usage >&2; exit 2; }

if [[ -n "$CONFIG_ARG" ]]; then
  [[ -f "$CONFIG_ARG" ]] || die "SmartDNS 配置文件不存在：$CONFIG_ARG"
  CONFIG_PATH="$CONFIG_ARG"
else
  CONFIG_PATH=""
  for candidate in \
    /etc/smartdns/smartdns.conf \
    /etc/smartdns.conf \
    /usr/local/etc/smartdns/smartdns.conf; do
    if [[ -f "$candidate" ]]; then
      CONFIG_PATH="$candidate"
      break
    fi
  done
  [[ -n "$CONFIG_PATH" ]] || die "未找到 SmartDNS 配置文件；请确认 SmartDNS 已安装，或使用 --config 指定路径"
fi

if command -v readlink >/dev/null 2>&1; then
  resolved_path="$(readlink -f -- "$CONFIG_PATH" 2>/dev/null || true)"
  [[ -n "$resolved_path" ]] && CONFIG_PATH="$resolved_path"
fi
[[ -f "$CONFIG_PATH" ]] || die "SmartDNS 配置文件不是可读的普通文件：$CONFIG_PATH"
CONFIG_PARENT="$(dirname -- "$CONFIG_PATH")"

WORK_DIR="$(mktemp -d "$CONFIG_PARENT/.smartdns-app-dns.XXXXXX")" || die "无法在配置目录创建临时文件：$CONFIG_PARENT"
trap 'rm -rf -- "$WORK_DIR"' EXIT
REQUEST_FILE="$WORK_DIR/requested.tsv"
NEW_CONFIG="$WORK_DIR/smartdns.conf"
cp -p -- "$CONFIG_PATH" "$NEW_CONFIG"
for slug in "${REQUEST_ORDER[@]}"; do
  printf '%s|%s|%s\n' "$slug" "${REQUESTED_DNS[$slug]}" "${APP_DOMAINS[$slug]}"
done > "$REQUEST_FILE"

if ! awk -v reqfile="$REQUEST_FILE" '
  BEGIN {
    begin_prefix = "# BEGIN smartdns-app-dns:"
    end_prefix = "# END smartdns-app-dns:"
    while ((getline request < reqfile) > 0) {
      count = split(request, fields, "|")
      if (count != 3) {
        print "请求清单格式错误" > "/dev/stderr"
        exit 2
      }
      slug = fields[1]
      dns[slug] = fields[2]
      order[++app_count] = slug
      requested[slug] = 1
      target_group["appdns_" slug] = 1
      domain_count[slug] = split(fields[3], domain_list, ",")
      for (i = 1; i <= domain_count[slug]; i++) {
        domain[slug, i] = domain_list[i]
        target_domain[domain_list[i]] = 1
      }
    }
    close(reqfile)
  }
  {
    line = $0
    if (index(line, begin_prefix) == 1) {
      marker_slug = substr(line, length(begin_prefix) + 1)
      if (requested[marker_slug]) {
        skipping = 1
        skipped_slug = marker_slug
        next
      }
    }
    if (skipping) {
      if (index(line, end_prefix) == 1 && substr(line, length(end_prefix) + 1) == skipped_slug) {
        skipping = 0
        skipped_slug = ""
      }
      next
    }

    parsed = line
    sub(/[[:space:]]+#.*/, "", parsed)
    sub(/^[[:space:]]+/, "", parsed)
    sub(/[[:space:]]+$/, "", parsed)
    fields_count = split(parsed, fields, /[[:space:]]+/)
    if (fields[1] == "server") {
      for (i = 2; i < fields_count; i++) {
        if (fields[i] == "-group" && target_group[fields[i + 1]])
          next
      }
    }
    if (fields[1] == "nameserver" && fields_count >= 2) {
      route_count = split(fields[2], route, "/")
      if (route_count >= 3 && route[1] == "" && target_domain[route[2]])
        next
    }
    print line
  }
  END {
    if (skipping) {
      print "配置中的托管区块缺少匹配的 END 标记：" skipped_slug > "/dev/stderr"
      exit 3
    }
    print ""
    print "# Generated by smartdns-app-dns. Edit apps.tsv to change the domain list."
    for (app = 1; app <= app_count; app++) {
      slug = order[app]
      group = "appdns_" slug
      print "# BEGIN smartdns-app-dns:" slug
      print "server " dns[slug] " -group " group " -exclude-default-group
      for (i = 1; i <= domain_count[slug]; i++)
        print "nameserver /" domain[slug, i] "/" group
      print "# END smartdns-app-dns:" slug
    }
  }
' "$CONFIG_PATH" > "$NEW_CONFIG"; then
  die "无法生成配置更新；原配置没有被修改"
fi

if ((DRY_RUN)); then
  printf '配置文件：%s\n' "$CONFIG_PATH"
  diff -u -- "$CONFIG_PATH" "$NEW_CONFIG" || [[ $? -eq 1 ]]
  printf '\n试运行完成；未修改文件，也未重启服务。\n'
  exit 0
fi

timestamp="$(date '+%Y%m%d%H%M%S')"
BACKUP_PATH="${CONFIG_PATH}.bak.${timestamp}"
if [[ -e "$BACKUP_PATH" ]]; then
  BACKUP_PATH="${BACKUP_PATH}.$$"
fi
cp -p -- "$CONFIG_PATH" "$BACKUP_PATH" || die "创建备份失败：$BACKUP_PATH"
mv -f -- "$NEW_CONFIG" "$CONFIG_PATH" || die "写入失败；原配置备份在 $BACKUP_PATH"

printf '已更新 %s\n' "$CONFIG_PATH"
printf '原配置备份：%s\n' "$BACKUP_PATH"
for slug in "${REQUEST_ORDER[@]}"; do
  printf '  --%-12s %s  (group: appdns_%s)\n' "$slug" "${REQUESTED_DNS[$slug]}" "$slug"
done

if ((DO_RESTART)); then
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart smartdns; then
      printf 'SmartDNS 已重启。\n'
    else
      printf '警告：配置已写入，但 smartdns.service 重启失败；请检查服务状态。备份：%s\n' "$BACKUP_PATH" >&2
      exit 1
    fi
  elif command -v service >/dev/null 2>&1; then
    if service smartdns restart; then
      printf 'SmartDNS 已重启。\n'
    else
      printf '警告：配置已写入，但 SmartDNS 重启失败；请检查服务状态。备份：%s\n' "$BACKUP_PATH" >&2
      exit 1
    fi
  else
    printf '未检测到 systemctl/service；请手动重启 SmartDNS。\n' >&2
  fi
else
  printf '按 --no-restart 要求，跳过服务重启。\n'
fi
