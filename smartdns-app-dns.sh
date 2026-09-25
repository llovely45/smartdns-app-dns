#!/usr/bin/env bash
set -Eeuo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  printf 'smartdns-app-dns 需要 Bash 4 或更新版本。\n' >&2
  exit 1
fi

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
  另外尝试从 systemd/运行进程和常见配置目录定位。

可在 /etc/smartdns-app-dns/apps.d/*.tsv 中添加自定义应用。
也可通过 SMARTDNS_CONFIG 环境变量指定配置文件。
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

config_from_command_line() {
  local command_line="$1" candidate
  local config_pattern='(^|[[:space:]])-c[[:space:]]+([^[:space:];}"]+)'
  if [[ "$command_line" =~ $config_pattern ]]; then
    candidate="${BASH_REMATCH[2]}"
    [[ -f "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

discover_running_config() {
  local command_line proc_args candidate unit
  if command -v systemctl >/dev/null 2>&1; then
    for unit in smartdns.service smartdns; do
      command_line="$(systemctl show "$unit" --property=ExecStart --value 2>/dev/null || true)"
      if candidate="$(config_from_command_line "$command_line" 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  if [[ -d /proc ]]; then
    for proc_args in /proc/[0-9]*/cmdline; do
      [[ -r "$proc_args" ]] || continue
      command_line="$(tr '\0' ' ' < "$proc_args" 2>/dev/null || true)"
      [[ "$command_line" == *smartdns* && "$command_line" != *smartdns-app-dns* ]] || continue
      if candidate="$(config_from_command_line "$command_line" 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

discover_config_file() {
  local candidate root
  local -A discovered=()
  local -a matches=()
  for root in /etc /usr/local/etc /opt; do
    [[ -d "$root" ]] || continue
    while IFS= read -r candidate; do
      [[ -f "$candidate" ]] && discovered["$candidate"]=1
    done < <(find "$root" -type f \( -path '*/smartdns/*.conf' -o -path '*/smartdns.conf.d/*.conf' -o -name 'smartdns*.conf' \) -print 2>/dev/null)
  done

  if ((${#discovered[@]} > 0)); then
    for candidate in "${!discovered[@]}"; do
      matches+=("$candidate")
    done
  fi
  if ((${#matches[@]} == 1)); then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  if ((${#matches[@]} > 1)); then
    printf '发现多个 SmartDNS 配置文件，请使用 --config 指定其中一个：\n' >&2
    printf '  %s\n' "${matches[@]}" >&2
  fi
  return 1
}

NEEDS_RELOCK=0
WAS_IMMUTABLE=0
WORK_DIR=""

cleanup() {
  local result=$?
  if ((NEEDS_RELOCK)) && [[ -n "${CONFIG_PATH:-}" ]] && command -v chattr >/dev/null 2>&1; then
    chattr +i "$CONFIG_PATH" 2>/dev/null || printf '警告：未能恢复 /etc 配置文件的 immutable 锁：%s\n' "$CONFIG_PATH" >&2
    NEEDS_RELOCK=0
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  return "$result"
}

prepare_config_replace() {
  local attributes="" attribute_flags="" attribute_check_available=0
  [[ "$CONFIG_PATH" == /etc/* ]] || return 0

  if command -v lsattr >/dev/null 2>&1; then
    attribute_check_available=1
    attributes="$(lsattr -d "$CONFIG_PATH" 2>/dev/null || true)"
    attribute_flags="${attributes%%[[:space:]]*}"
    [[ "$attribute_flags" == *i* ]] && WAS_IMMUTABLE=1
  fi

  if command -v chattr >/dev/null 2>&1; then
    if chattr -i "$CONFIG_PATH" 2>/dev/null; then
      if ((WAS_IMMUTABLE || !attribute_check_available)); then
        NEEDS_RELOCK=1
      fi
    elif ((WAS_IMMUTABLE || !attribute_check_available)); then
      die "无法确认配置文件已解锁；chattr -i 失败：$CONFIG_PATH"
    else
      printf '警告：chattr -i 未能解锁（文件可能未上锁或文件系统不支持），继续尝试写入。\n' >&2
    fi
  elif ((WAS_IMMUTABLE)); then
    die "配置文件带 immutable 锁，但系统没有 chattr：$CONFIG_PATH"
  else
    printf '警告：未安装 chattr，无法解锁或锁定 /etc 配置文件。\n' >&2
  fi
}

BASE_CATALOG="$SCRIPT_DIR/apps.tsv"
[[ -f "$BASE_CATALOG" ]] || BASE_CATALOG="/usr/local/share/smartdns-app-dns/apps.tsv"
[[ -f "$BASE_CATALOG" ]] || die "找不到应用清单 apps.tsv"
load_catalog_file "$BASE_CATALOG"
shopt -s nullglob
for catalog in "$EXTENSION_DIR"/*.tsv; do
  load_catalog_file "$catalog"
done

CONFIG_ARG="${SMARTDNS_CONFIG:-}"
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
  CONFIG_PATH="$(discover_running_config || true)"
  if [[ -z "$CONFIG_PATH" ]]; then
    for candidate in \
      /etc/smartdns/smartdns.conf \
      /etc/smartdns.conf \
      /usr/local/etc/smartdns/smartdns.conf; do
      if [[ -f "$candidate" ]]; then
        CONFIG_PATH="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$CONFIG_PATH" ]]; then
    CONFIG_PATH="$(discover_config_file || true)"
  fi
  [[ -n "$CONFIG_PATH" ]] || die "未找到 SmartDNS 配置文件。此工具只修改已有配置；请先安装/初始化 SmartDNS，或使用 --config/SMARTDNS_CONFIG 指定路径"
fi

if command -v readlink >/dev/null 2>&1; then
  resolved_path="$(readlink -f -- "$CONFIG_PATH" 2>/dev/null || true)"
  [[ -n "$resolved_path" ]] && CONFIG_PATH="$resolved_path"
fi
[[ -f "$CONFIG_PATH" ]] || die "SmartDNS 配置文件不是可读的普通文件：$CONFIG_PATH"
CONFIG_PARENT="$(dirname -- "$CONFIG_PATH")"

WORK_DIR="$(mktemp -d "$CONFIG_PARENT/.smartdns-app-dns.XXXXXX")" || die "无法在配置目录创建临时文件：$CONFIG_PARENT"
trap cleanup EXIT
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
      group_name = sprintf("appdns_%s", slug)
      target_group[group_name] = 1
      domain_count[slug] = split(fields[3], domain_list, ",")
      for (i = 1; i <= domain_count[slug]; i++) {
        domain_key = sprintf("%s%c%d", slug, SUBSEP, i)
        domain[domain_key] = domain_list[i]
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
      printf "配置中的托管区块缺少匹配的 END 标记：%s\n", skipped_slug > "/dev/stderr"
      exit 3
    }
    printf "\n"
    printf "# Generated by smartdns-app-dns. Edit apps.tsv to change the domain list.\n"
    for (app = 1; app <= app_count; app++) {
      slug = order[app]
      group_name = sprintf("appdns_%s", slug)
      printf "# BEGIN smartdns-app-dns:%s\n", slug
      printf "server %s -group %s -exclude-default-group\n", dns[slug], group_name
      for (i = 1; i <= domain_count[slug]; i++) {
        domain_key = sprintf("%s%c%d", slug, SUBSEP, i)
        printf "nameserver /%s/%s\n", domain[domain_key], group_name
      }
      printf "# END smartdns-app-dns:%s\n", slug
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

prepare_config_replace
timestamp="$(date '+%Y%m%d%H%M%S')"
BACKUP_PATH="${CONFIG_PATH}.bak.${timestamp}"
if [[ -e "$BACKUP_PATH" ]]; then
  BACKUP_PATH="${BACKUP_PATH}.$$"
fi
cp -p -- "$CONFIG_PATH" "$BACKUP_PATH" || die "创建备份失败：$BACKUP_PATH"
mv -f -- "$NEW_CONFIG" "$CONFIG_PATH" || die "写入失败；原配置备份在 $BACKUP_PATH"
if [[ "$CONFIG_PATH" == /etc/* ]] && command -v chattr >/dev/null 2>&1; then
  NEEDS_RELOCK=1
  if chattr +i "$CONFIG_PATH"; then
    NEEDS_RELOCK=0
    printf '已重新锁定配置文件（immutable）：%s\n' "$CONFIG_PATH"
  else
    printf '错误：配置已写入，但 chattr +i 失败：%s\n' "$CONFIG_PATH" >&2
    exit 1
  fi
fi

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
