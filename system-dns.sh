#!/usr/bin/env bash

system_dns_should_activate() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --install-only|--no-system-dns|--no-restart|--dry-run|--list|-h|--help)
        return 1
        ;;
    esac
  done
  return 0
}

system_dns_get_flags() {
  local output flags
  output="$(lsattr -d -- "$1" 2>/dev/null)" || return 1
  flags="${output%% *}"
  [[ "$flags" =~ ^[-[:alpha:]]+$ ]] || return 1
  printf '%s\n' "$flags"
}

system_dns_lock_file() {
  local file="$1" flags
  chattr +i -- "$file" || return 1
  flags="$(system_dns_get_flags "$file")" || return 1
  [[ "$flags" == *i* ]]
}

system_dns_probe() {
  local domain="$1" dig_command="$2" output
  if ! command -v "$dig_command" >/dev/null 2>&1; then
    printf '错误：找不到 dig，无法验证 127.0.0.1:53；未修改系统 DNS。\n' >&2
    return 1
  fi

  if ! output="$("$dig_command" +time=2 +tries=1 +noall +answer "$domain" A @127.0.0.1 2>/dev/null)"; then
    printf '错误：SmartDNS 本地 DNS 查询命令失败；未修改系统 DNS。\n' >&2
    return 1
  fi
  if ! awk '
    $4 == "A" {
      count = split($5, octets, ".")
      valid = (count == 4)
      for (i = 1; i <= count; i++) {
        if (octets[i] !~ /^[0-9]+$/ || octets[i] > 255) valid = 0
      }
      if (valid && $5 != "0.0.0.0") found = 1
    }
    END { exit !found }
  ' <<< "$output"; then
    printf '错误：SmartDNS 在 127.0.0.1:53 未返回有效的 %s A 记录；未修改系统 DNS。\n' "$domain" >&2
    return 1
  fi
}

system_dns_check_service_active() {
  local systemctl_command="${1:-systemctl}"
  if ! command -v "$systemctl_command" >/dev/null 2>&1; then
    printf '错误：找不到 systemctl，无法确认 SmartDNS 服务状态。\n' >&2
    return 1
  fi
  if ! "$systemctl_command" is-active --quiet smartdns; then
    printf '错误：smartdns.service 当前未处于 active 状态。\n' >&2
    return 1
  fi
  return 0
}

system_dns_ensure_service_enabled() {
  local systemctl_command="${1:-systemctl}"
  if ! system_dns_check_service_active "$systemctl_command"; then
    return 1
  fi
  if ! "$systemctl_command" is-enabled --quiet smartdns; then
    if ! "$systemctl_command" enable smartdns; then
      printf '错误：无法启用 smartdns.service 开机自启。\n' >&2
      return 1
    fi
  fi
  if ! "$systemctl_command" is-enabled --quiet smartdns; then
    printf '错误：无法确认 smartdns.service 已设为开机自启。\n' >&2
    return 1
  fi
  return 0
}

system_dns_restore_backup() {
  local resolver="$1" backup="$2" original_immutable="$3"

  # The replacement may have been made immutable even if chattr returned an error.
  chattr -i -- "$resolver" >/dev/null 2>&1 || true
  if ! rm -f -- "$resolver"; then
    printf '严重错误：无法移除未锁定的临时 resolver 文件：%s\n' "$resolver" >&2
    return 1
  fi
  if ! cp -a -- "$backup" "$resolver"; then
    printf '严重错误：无法从备份恢复原 resolver 文件：%s\n' "$backup" >&2
    return 1
  fi
  if ((original_immutable)) && ! system_dns_lock_file "$resolver"; then
    printf '严重错误：已恢复原 resolver 内容，但未能恢复并验证原 immutable 锁：%s\n' "$resolver" >&2
    return 1
  fi
  return 0
}

system_dns_activate() {
  local resolver="${1:-/etc/resolv.conf}"
  local domain="${2:-youtube.com}"
  local dig_command="${3:-dig}"
  local systemctl_command="${4:-systemctl}"
  local flags backup temp original_immutable=0

  if [[ ! -f "$resolver" ]]; then
    printf '错误：resolver 文件不存在或不可读写：%s；未修改系统 DNS。\n' "$resolver" >&2
    return 1
  fi

  if ! system_dns_check_service_active "$systemctl_command"; then
    return 1
  fi
  if ! system_dns_probe "$domain" "$dig_command"; then
    return 1
  fi
  if ! command -v chattr >/dev/null 2>&1 || ! command -v lsattr >/dev/null 2>&1; then
    printf '错误：缺少 chattr/lsattr，无法可靠锁定 resolver；未修改系统 DNS。\n' >&2
    return 1
  fi
  if ! system_dns_ensure_service_enabled "$systemctl_command"; then
    printf '错误：SmartDNS 未能确认已运行并设为开机自启；未修改系统 DNS。\n' >&2
    return 1
  fi

  # Do not try to alter attributes on the old symlink's target. The symlink itself
  # will be backed up and atomically replaced by a regular resolver file.
  if [[ ! -L "$resolver" ]]; then
    if ! flags="$(system_dns_get_flags "$resolver")"; then
      printf '错误：无法读取 resolver 文件的 immutable 状态；未修改系统 DNS。\n' >&2
      return 1
    fi
    [[ "$flags" == *i* ]] && original_immutable=1
  fi

  backup="${resolver}.smartdns-app-dns.bak.$(date +%Y%m%d%H%M%S).$$"
  if [[ -e "$backup" || -L "$backup" ]]; then
    printf '错误：备份路径已存在，拒绝覆盖：%s\n' "$backup" >&2
    return 1
  fi
  if ! cp -a -- "$resolver" "$backup"; then
    printf '错误：无法备份现有 resolver 文件；未修改系统 DNS。\n' >&2
    return 1
  fi

  if ! temp="$(mktemp "${resolver}.smartdns-app-dns.tmp.XXXXXX")"; then
    rm -f -- "$backup"
    printf '错误：无法创建临时 resolver 文件；未修改系统 DNS。\n' >&2
    return 1
  fi
  if ! awk 'BEGIN { print "nameserver 127.0.0.1" } !/^[[:space:]]*nameserver([[:space:]]|$)/ { print }' "$resolver" > "$temp" || ! chmod 0644 "$temp"; then
    rm -f -- "$temp" "$backup"
    printf '错误：无法生成新的 resolver 文件；未修改系统 DNS。\n' >&2
    return 1
  fi

  if ((original_immutable)); then
    if ! chattr -i -- "$resolver"; then
      rm -f -- "$temp"
      if ! system_dns_lock_file "$resolver"; then
        printf '严重错误：无法解除现有 resolver 锁，也无法确认已恢复原锁；备份保留在：%s\n' "$backup" >&2
        return 1
      fi
      rm -f -- "$backup"
      printf '错误：无法解除现有 resolver 的 immutable 锁；未修改系统 DNS。\n' >&2
      return 1
    fi
    if ! flags="$(system_dns_get_flags "$resolver")" || [[ "$flags" == *i* ]]; then
      rm -f -- "$temp"
      if ! system_dns_lock_file "$resolver"; then
        printf '严重错误：现有 resolver 仍处于 immutable 状态且无法确认恢复；备份保留在：%s\n' "$backup" >&2
        return 1
      fi
      rm -f -- "$backup"
      printf '错误：现有 resolver 仍处于 immutable 状态；未修改系统 DNS。\n' >&2
      return 1
    fi
  fi

  if ! mv -f -- "$temp" "$resolver"; then
    rm -f -- "$temp"
    if ((original_immutable)); then
      if ! system_dns_lock_file "$resolver"; then
        printf '严重错误：无法替换 resolver，也无法确认原 immutable 锁已恢复；备份保留在：%s\n' "$backup" >&2
        return 1
      fi
    fi
    rm -f -- "$backup"
    printf '错误：无法替换 resolver 文件；未修改系统 DNS。\n' >&2
    return 1
  fi

  if ! system_dns_lock_file "$resolver"; then
    printf '错误：resolver 已写入，但 chattr +i 失败，正在恢复原配置。\n' >&2
    if system_dns_restore_backup "$resolver" "$backup" "$original_immutable"; then
      printf '已恢复原 resolver 配置；备份保留在：%s\n' "$backup" >&2
    fi
    return 1
  fi

  if ! flags="$(system_dns_get_flags "$resolver")" || [[ "$flags" != *i* ]]; then
    printf '错误：未能确认 resolver 的 immutable 锁，正在恢复原配置。\n' >&2
    if system_dns_restore_backup "$resolver" "$backup" "$original_immutable"; then
      printf '已恢复原 resolver 配置；备份保留在：%s\n' "$backup" >&2
    fi
    return 1
  fi

  printf 'SmartDNS 本地解析验证成功（%s）；系统 DNS 已切换为 127.0.0.1 并锁定。\n' "$domain"
  printf '原 resolver 备份：%s\n' "$backup"
  return 0
}
