#!/bin/sh

set -eu
umask 077
LC_ALL=C
export LC_ALL
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

SERVICE_NAME=tinyproxy
CONFIG_DIR=/etc/tinyproxy
CONFIG_FILE=${CONFIG_DIR}/tinyproxy.conf
BACKUP_DIR=
TMP_CONFIG=
PORT=12345
USERNAME='admin'
PASSWORD=
IPV6_ENABLED=0
OLD_CONFIG_EXISTS=0
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_ENABLED=0
SERVICE_START_ATTEMPTED=0
SERVICE_ENABLE_ATTEMPTED=0
CONFIG_REPLACED=0
TRANSACTION_STARTED=0
TTY_ECHO_DISABLED=0

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

restore_tty() {
    if [ "$TTY_ECHO_DISABLED" -eq 1 ]; then
        stty echo </dev/tty 2>/dev/null || true
        TTY_ECHO_DISABLED=0
    fi
}

cleanup() {
    EXIT_STATUS=$?
    trap - 0 INT TERM
    restore_tty

    if [ -n "$TMP_CONFIG" ]; then
        rm -f "$TMP_CONFIG" 2>/dev/null || true
    fi

    if [ "$EXIT_STATUS" -ne 0 ] && [ "$TRANSACTION_STARTED" -eq 1 ]; then
        warn "部署失败，正在恢复原配置和服务状态。"

        if [ "$SERVICE_START_ATTEMPTED" -eq 1 ]; then
            rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        fi

        if [ "$CONFIG_REPLACED" -eq 1 ]; then
            if [ "$OLD_CONFIG_EXISTS" -eq 1 ]; then
                cp -p "${BACKUP_DIR}/tinyproxy.conf" "$CONFIG_FILE" || \
                    warn "旧配置恢复失败，请从 $BACKUP_DIR 手动恢复。"
            else
                rm -f "$CONFIG_FILE" || warn "无法删除新配置文件 $CONFIG_FILE。"
            fi
        fi

        if [ "$SERVICE_ENABLE_ATTEMPTED" -eq 1 ] && \
           [ "$SERVICE_WAS_ENABLED" -eq 0 ]; then
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        fi

        if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
            rc-service "$SERVICE_NAME" start >/dev/null 2>&1 || \
                warn "原服务未能重新启动，请检查 OpenRC 状态。"
        fi
    fi

    exit "$EXIT_STATUS"
}

trap cleanup 0
trap 'exit 130' INT TERM

require_alpine_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行。"
    [ -f /etc/alpine-release ] || die "此脚本仅支持 Alpine Linux。"
    command -v apk >/dev/null 2>&1 || die "未找到 apk。"
    command -v rc-service >/dev/null 2>&1 || die "未找到 OpenRC rc-service。"
    command -v rc-update >/dev/null 2>&1 || die "未找到 OpenRC rc-update。"
}

read_line() {
    if ! IFS= read -r REPLY </dev/tty; then
        die "无法读取终端输入。请在交互式终端中运行此脚本。"
    fi
}

read_secret() {
    printf '%s' "$1"
    stty -echo </dev/tty || die "无法隐藏密码输入。"
    TTY_ECHO_DISABLED=1
    if ! IFS= read -r REPLY </dev/tty; then
        die "读取密码失败。"
    fi
    restore_tty
    printf '\n'
}

prompt_settings() {
    while :; do
        printf '监听端口 [1-65535] [%s]: ' "$PORT"
        read_line
        [ -n "$REPLY" ] && PORT=$REPLY

        case "$PORT" in
            ''|0*|*[!0-9]*)
                warn "端口必须是 1-65535 的十进制整数，且不能有前导零。"
                PORT=12345
                continue
                ;;
        esac
        [ "${#PORT}" -le 5 ] && [ "$PORT" -le 65535 ] 2>/dev/null && break
        warn "端口必须在 1-65535 范围内。"
        PORT=12345
    done

    while :; do
        printf 'BasicAuth 用户名 [admin]: '
        read_line
        [ -n "$REPLY" ] && USERNAME=$REPLY
        case "$USERNAME" in
            ''|*[!A-Za-z0-9_.-]*) warn "用户名仅可使用字母、数字、点、下划线和连字符。" ;;
            *) break ;;
        esac
        USERNAME='admin'
    done

    while :; do
        read_secret 'BasicAuth 密码（至少 8 位，输入隐藏）: '
        PASSWORD=$REPLY
        if [ "${#PASSWORD}" -lt 8 ] || [ "${#PASSWORD}" -gt 128 ]; then
            warn "密码长度必须在 8-128 个字符之间。"
            continue
        fi
        case "$PASSWORD" in
            *[!A-Za-z0-9._!@%+=:,~-]*)
                warn "密码仅可使用字母、数字及 . _ ! @ % + = : , ~ -。"
                continue
                ;;
        esac

        read_secret '再次输入密码确认: '
        if [ "$PASSWORD" = "$REPLY" ]; then
            break
        fi
        warn "两次输入不一致，请重试。"
    done

    if [ "${#PASSWORD}" -lt 12 ]; then
        warn "短密码更容易被猜中；公网代理建议使用至少 16 位随机密码。"
    fi
}

service_is_enabled() {
    rc-update show default 2>/dev/null | awk -v service="$SERVICE_NAME" \
        '$1 == service || $2 == service { found=1 } END { exit !found }'
}

port_is_listening() {
    ss -ltn 2>/dev/null | awk -v port=":$PORT" \
        '$1 == "LISTEN" && $4 ~ (port "$" ) { found=1 } END { exit !found }'
}

check_config_path() {
    [ ! -L "$CONFIG_DIR" ] || die "拒绝使用符号链接配置目录：$CONFIG_DIR"
    [ ! -e "$CONFIG_DIR" ] || [ -d "$CONFIG_DIR" ] || die "配置路径不是目录：$CONFIG_DIR"
    [ ! -L "$CONFIG_FILE" ] || die "拒绝覆盖符号链接：$CONFIG_FILE"
    [ ! -e "$CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ] || die "配置路径不是普通文件：$CONFIG_FILE"
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    chown root:tinyproxy "$CONFIG_DIR"
    chmod 0750 "$CONFIG_DIR"
    TMP_CONFIG=$(mktemp "${CONFIG_DIR}/tinyproxy.conf.XXXXXX") || die "无法创建临时配置文件。"

    {
        printf 'User tinyproxy\n'
        printf 'Group tinyproxy\n'
        printf 'Port %s\n' "$PORT"
        printf 'Listen 0.0.0.0\n'
        if [ "$IPV6_ENABLED" -eq 1 ]; then
            printf 'Listen ::\n'
        fi
        printf 'Timeout 600\n'
        printf 'BasicAuth %s %s\n' "$USERNAME" "$PASSWORD"
        printf 'Allow 0.0.0.0/0\n'
        if [ "$IPV6_ENABLED" -eq 1 ]; then
            printf 'Allow ::/0\n'
        fi
        printf 'ConnectPort 443\n'
        printf 'ConnectPort 563\n'
    } >"$TMP_CONFIG"

    chown root:tinyproxy "$TMP_CONFIG"
    chmod 0640 "$TMP_CONFIG"
    mv -f "$TMP_CONFIG" "$CONFIG_FILE"
    TMP_CONFIG=
    CONFIG_REPLACED=1
}

main() {
    require_alpine_root
    prompt_settings

    info "安装 Tinyproxy 和 ss 检查工具。"
    apk add --no-cache tinyproxy iproute2-ss || die "apk 安装失败，请检查 Alpine 软件源。"
    command -v ss >/dev/null 2>&1 || die "未找到 ss 命令。"
    id tinyproxy >/dev/null 2>&1 || die "软件包未创建 tinyproxy 服务用户。"

    if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && \
       [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = 0 ]; then
        IPV6_ENABLED=1
    fi

    check_config_path
    if [ -f "$CONFIG_FILE" ]; then
        OLD_CONFIG_EXISTS=1
        BACKUP_DIR=$(mktemp -d /root/tinyproxy-backup.XXXXXX) || die "无法备份现有配置。"
        cp -p "$CONFIG_FILE" "${BACKUP_DIR}/tinyproxy.conf" || die "无法备份现有配置。"
    fi

    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        SERVICE_WAS_ACTIVE=1
    fi
    if service_is_enabled; then
        SERVICE_WAS_ENABLED=1
    fi

    TRANSACTION_STARTED=1
    if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
        rc-service "$SERVICE_NAME" stop || die "无法停止现有 Tinyproxy 服务。"
    fi

    if port_is_listening; then
        die "TCP 端口 $PORT 已被其他进程占用。"
    fi

    write_config
    SERVICE_START_ATTEMPTED=1
    rc-service "$SERVICE_NAME" start || die "Tinyproxy 启动失败。"
    rc-service "$SERVICE_NAME" status || die "Tinyproxy 启动后状态异常。"
    port_is_listening || die "没有检测到 TCP 端口 $PORT 正在监听。"

    SERVICE_ENABLE_ATTEMPTED=1
    rc-update add "$SERVICE_NAME" default || die "设置 Tinyproxy 开机自启失败。"

    printf '\nTinyproxy 部署完成\n'
    printf '监听端口：%s/TCP\n' "$PORT"
    printf '用户名：%s\n' "$USERNAME"
    printf '配置文件：%s\n' "$CONFIG_FILE"
    printf '开机自启：已启用\n'
    printf 'IPv6：%s\n' "$([ "$IPV6_ENABLED" -eq 1 ] && printf 已启用 || printf 未启用)"
    printf '\n状态检查：rc-service tinyproxy status\n'
    printf '监听检查：ss -ltnp | grep ":%s"\n' "$PORT"
    printf '请在云安全组/防火墙放行 TCP %s。\n' "$PORT"
    if [ -n "$BACKUP_DIR" ]; then
        printf '旧配置备份：%s\n' "$BACKUP_DIR"
    fi
}

main "$@"
