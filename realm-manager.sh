#!/bin/bash

# ============================================================================
# Realm 一键转发管理脚本
#
# 功能:
#   - 安装 / 更新 Realm
#   - 更新本管理脚本
#   - 卸载 Realm + 删除本管理脚本
#   - 双栈 IPv4 + IPv6
#   - TCP / UDP
#   - WS / TLS / WSS
#   - MPTCP
#   - PROXY protocol
#   - 多出口负载均衡
#   - 出口 IP / 网卡绑定
#   - DNS 设置
#   - systemd 服务管理
#
# 上游项目:
# https://github.com/zhboner/realm
# ============================================================================

set -o pipefail

# ============================================================================
# 基础路径
# ============================================================================

REALM_DIR="/etc/realm"
REALM_BIN="${REALM_DIR}/realm"
CONFIG_FILE="${REALM_DIR}/config.toml"
LOG_FILE="${REALM_DIR}/realm.log"

SERVICE_FILE="/etc/systemd/system/realm.service"

GITHUB_REPO="zhboner/realm"

# ============================================================================
# 管理脚本更新设置
# ============================================================================

SCRIPT_VERSION="1.0.0"

# 改成你自己 GitHub 仓库中 realm.sh 的 Raw 地址
#
# 例如：
# SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/username/repo/main/realm.sh"
#
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/你的用户名/你的仓库/main/realm.sh"

# 当前管理脚本绝对路径
SCRIPT_PATH="$(
    readlink -f "$0" 2>/dev/null ||
    realpath "$0" 2>/dev/null ||
    echo "$0"
)"

MARKER_LINE="# ===== ENDPOINTS BELOW (由脚本管理，规则块请通过菜单增删) ====="

# ============================================================================
# 颜色
# ============================================================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
NC="\033[0m"

# ============================================================================
# 输出
# ============================================================================

info() {
    echo -e "${CYAN}[信息]${NC} $1"
}

ok() {
    echo -e "${GREEN}[完成]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[注意]${NC} $1"
}

err() {
    echo -e "${RED}[错误]${NC} $1"
}

pause() {
    read -rp "按回车键返回菜单..." _
}

# ============================================================================
# 基础环境检查
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 用户运行本脚本"
        echo "例如：sudo -i"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        err "未检测到 systemd"
        err "本脚本依赖 systemd 管理 Realm 服务"
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    for cmd in curl tar awk sed grep cut head tail tr date mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺少必要命令: ${missing[*]}"
        echo ""
        echo "Debian / Ubuntu 可以执行："
        echo "apt update && apt install -y curl tar gawk sed grep coreutils"
        return 1
    fi

    return 0
}

# ============================================================================
# 架构 / libc 检测
# ============================================================================

detect_arch_libc() {
    local machine
    local libc="gnu"

    machine="$(uname -m)"

    if command -v ldd >/dev/null 2>&1 &&
       ldd --version 2>&1 | grep -qi musl; then
        libc="musl"
    elif [[ -f /etc/alpine-release ]]; then
        libc="musl"
    fi

    case "$machine" in
        x86_64|amd64)
            ARCH_TRIPLE="x86_64-unknown-linux-${libc}"
            ;;
        aarch64|arm64)
            ARCH_TRIPLE="aarch64-unknown-linux-${libc}"
            ;;
        armv7l|armv7)
            if [[ "$libc" == "musl" ]]; then
                ARCH_TRIPLE="arm-unknown-linux-musleabihf"
            else
                ARCH_TRIPLE="arm-unknown-linux-gnueabihf"
            fi
            ;;
        *)
            err "暂不支持的 CPU 架构: $machine"
            return 1
            ;;
    esac

    info "检测到架构: ${machine} (libc: ${libc})"
    info "Realm 下载架构: ${ARCH_TRIPLE}"

    return 0
}

# ============================================================================
# 获取最新 Realm 版本
# ============================================================================

get_latest_version() {
    local ver=""

    ver="$(
        curl -fsSL \
            --connect-timeout 8 \
            --max-time 15 \
            "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
            2>/dev/null |
        grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' |
        head -1 |
        cut -d'"' -f4
    )"

    if [[ -z "$ver" ]]; then
        ver="$(
            curl -fsSLI \
                --connect-timeout 8 \
                --max-time 15 \
                "https://github.com/${GITHUB_REPO}/releases/latest" \
                2>/dev/null |
            grep -i '^location:' |
            grep -oE 'tag/[^[:space:]]+' |
            tail -1 |
            cut -d'/' -f2 |
            tr -d '\r'
        )"
    fi

    echo "$ver"
}

# ============================================================================
# 初始化配置
# ============================================================================

init_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        return 0
    fi

    mkdir -p "$REALM_DIR"

    cat > "$CONFIG_FILE" <<EOF
[log]
level = "warn"
output = "${LOG_FILE}"

[dns]
mode = "ipv4_and_ipv6"
protocol = "tcp_and_udp"
nameservers = ["8.8.8.8:53", "1.1.1.1:53"]
min_ttl = 600
max_ttl = 3600
cache_size = 256

[network]
no_tcp = false
use_udp = true
ipv6_only = false
tcp_timeout = 5
udp_timeout = 30
tcp_keepalive = 300
tcp_keepalive_probe = 3
send_mptcp = false
accept_mptcp = false
send_proxy = false
send_proxy_version = 2
accept_proxy = false
accept_proxy_timeout = 5

${MARKER_LINE}
EOF

    ok "已生成默认配置: ${CONFIG_FILE}"
}

# ============================================================================
# 创建 systemd 服务
# ============================================================================

create_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm high-performance relay
Documentation=https://github.com/${GITHUB_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${CONFIG_FILE}
WorkingDirectory=${REALM_DIR}
Restart=on-failure
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1

    ok "systemd 服务已配置"
    ok "已启用开机自启"
}

# ============================================================================
# 安装 / 更新 Realm
# ============================================================================

install_or_update_realm() {
    detect_arch_libc || return 1

    info "正在获取最新 Realm 版本..."

    local version
    version="$(get_latest_version)"

    if [[ -z "$version" ]]; then
        err "获取 Realm 版本失败"
        echo "请检查本机到 GitHub 的网络连通性"
        return 1
    fi

    info "最新版本: ${version}"

    mkdir -p "$REALM_DIR"

    local asset="realm-${ARCH_TRIPLE}.tar.gz"
    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${asset}"
    local tmp_archive="/tmp/realm.tar.gz"

    info "下载地址:"
    echo "$url"

    rm -f "$tmp_archive"

    if ! curl -fL \
        --connect-timeout 10 \
        --max-time 120 \
        -o "$tmp_archive" \
        "$url"; then

        err "Realm 下载失败"
        echo ""
        echo "请确认："
        echo "1. GitHub 网络正常"
        echo "2. 当前架构的发行包存在"
        echo "3. 没有触发 GitHub 限流"

        rm -f "$tmp_archive"
        return 1
    fi

    if [[ ! -s "$tmp_archive" ]]; then
        err "下载文件为空"
        rm -f "$tmp_archive"
        return 1
    fi

    local was_running=0

    if systemctl is-active --quiet realm 2>/dev/null; then
        was_running=1
        info "检测到 Realm 正在运行，先停止服务..."
        systemctl stop realm
    fi

    rm -f /tmp/realm

    if ! tar -xzf "$tmp_archive" -C /tmp; then
        err "Realm 压缩包解压失败"
        rm -f "$tmp_archive"
        return 1
    fi

    if [[ ! -f /tmp/realm ]]; then
        err "解压后未找到 realm 可执行文件"
        rm -f "$tmp_archive"
        return 1
    fi

    mv -f /tmp/realm "$REALM_BIN"
    chmod +x "$REALM_BIN"

    rm -f "$tmp_archive"

    init_config
    create_service

    if [[ $was_running -eq 1 ]]; then
        systemctl start realm

        if systemctl is-active --quiet realm; then
            ok "Realm 服务已重新启动"
        else
            warn "Realm 服务启动失败，请使用菜单 5 查看状态"
        fi
    fi

    ok "Realm ${version} 安装 / 更新完成"
    ok "架构: ${ARCH_TRIPLE}"
}

# ============================================================================
# 更新管理脚本
# ============================================================================

update_script() {
    echo ""
    echo -e "${BOLD}=== 更新 Realm 管理脚本 ===${NC}"
    echo ""

    if [[ ! -f "$SCRIPT_PATH" ]]; then
        err "无法确定当前脚本文件位置"
        echo "当前路径: $SCRIPT_PATH"
        return 1
    fi

    if [[ -z "$SCRIPT_UPDATE_URL" ||
          "$SCRIPT_UPDATE_URL" == *"你的用户名"* ||
          "$SCRIPT_UPDATE_URL" == *"你的仓库"* ]]; then

        err "尚未配置脚本更新地址"
        echo ""
        echo "请修改脚本顶部："
        echo ""
        echo 'SCRIPT_UPDATE_URL="..."'
        echo ""
        echo "设置为你 GitHub 仓库中的 Raw 地址"
        return 1
    fi

    info "当前脚本版本: ${SCRIPT_VERSION}"
    info "正在从 GitHub 获取最新版..."

    local tmp_script="/tmp/realm-manager-update.sh"

    rm -f "$tmp_script"

    if ! curl -fL \
        --connect-timeout 10 \
        --max-time 60 \
        -o "$tmp_script" \
        "$SCRIPT_UPDATE_URL"; then

        err "下载新版管理脚本失败"
        rm -f "$tmp_script"
        return 1
    fi

    if [[ ! -s "$tmp_script" ]]; then
        err "下载的脚本为空"
        rm -f "$tmp_script"
        return 1
    fi

    # ------------------------------------------------------------------------
    # 检查 Shebang
    # ------------------------------------------------------------------------

    if ! head -n 1 "$tmp_script" | grep -qE '^#!.*bash'; then
        err "下载的文件不是有效的 Bash 脚本"
        rm -f "$tmp_script"
        return 1
    fi

    # ------------------------------------------------------------------------
    # Bash 语法检查
    # ------------------------------------------------------------------------

    info "正在检查新脚本语法..."

    if ! bash -n "$tmp_script"; then
        err "新脚本语法检查失败，拒绝更新"
        rm -f "$tmp_script"
        return 1
    fi

    ok "新脚本语法检查通过"

    # ------------------------------------------------------------------------
    # 获取远程脚本版本
    # ------------------------------------------------------------------------

    local remote_version

    remote_version="$(
        grep -E '^SCRIPT_VERSION=' "$tmp_script" |
        head -1 |
        cut -d'"' -f2
    )"

    if [[ -n "$remote_version" ]]; then
        info "远程脚本版本: ${remote_version}"
    else
        warn "无法读取远程脚本版本"
    fi

    echo ""

    read -rp "确认更新管理脚本？(Y/n): " confirm

    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        info "已取消"
        rm -f "$tmp_script"
        return 0
    fi

    # ------------------------------------------------------------------------
    # 备份当前脚本
    # ------------------------------------------------------------------------

    local backup_script="${SCRIPT_PATH}.bak"

    info "正在备份当前脚本..."

    if ! cp -f "$SCRIPT_PATH" "$backup_script"; then
        err "备份当前脚本失败，取消更新"
        rm -f "$tmp_script"
        return 1
    fi

    # ------------------------------------------------------------------------
    # 设置权限
    # ------------------------------------------------------------------------

    chmod +x "$tmp_script"

    # ------------------------------------------------------------------------
    # 替换当前脚本
    # ------------------------------------------------------------------------

    if ! mv -f "$tmp_script" "$SCRIPT_PATH"; then
        err "替换管理脚本失败"

        if [[ -f "$backup_script" ]]; then
            cp -f "$backup_script" "$SCRIPT_PATH"
        fi

        rm -f "$tmp_script"
        return 1
    fi

    chmod +x "$SCRIPT_PATH"

    ok "管理脚本更新成功"

    if [[ -n "$remote_version" ]]; then
        echo "版本: ${SCRIPT_VERSION} -> ${remote_version}"
    fi

    rm -f "$backup_script"

    echo ""
    echo "正在启动新版管理脚本..."
    sleep 1

    # 使用 exec 替换当前进程
    exec "$SCRIPT_PATH"
}

# ============================================================================
# 卸载 Realm + 删除管理脚本自身
# ============================================================================

uninstall_realm() {
    echo ""
    echo -e "${RED}${BOLD}警告：此操作将删除以下内容：${NC}"
    echo ""
    echo "  /etc/realm/"
    echo "  /etc/systemd/system/realm.service"
    echo "  当前 Realm 管理脚本"
    echo ""

    read -rp "确认继续？(y/N): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消"
        return 0
    fi

    echo ""

    # ------------------------------------------------------------------------
    # 停止服务
    # ------------------------------------------------------------------------

    info "正在停止 realm 服务..."
    systemctl stop realm 2>/dev/null || true

    # ------------------------------------------------------------------------
    # 禁用开机启动
    # ------------------------------------------------------------------------

    info "正在禁用 realm 开机自启..."
    systemctl disable realm >/dev/null 2>&1 || true

    # ------------------------------------------------------------------------
    # 删除 systemd 服务文件
    # ------------------------------------------------------------------------

    info "正在删除 systemd 服务文件..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    # ------------------------------------------------------------------------
    # 删除 Realm 目录
    # ------------------------------------------------------------------------

    if [[ -d "$REALM_DIR" ]]; then
        info "正在删除 Realm 程序、配置和日志..."
        rm -rf "$REALM_DIR"
    fi

    # ------------------------------------------------------------------------
    # 清理可能的运行文件
    # ------------------------------------------------------------------------

    rm -f /run/realm.pid 2>/dev/null || true

    # ------------------------------------------------------------------------
    # 删除当前管理脚本自身
    # ------------------------------------------------------------------------

    if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
        info "正在删除当前管理脚本:"
        echo "  $SCRIPT_PATH"

        rm -f -- "$SCRIPT_PATH"
    fi

    echo ""
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo -e "${GREEN}${BOLD} Realm 已完全卸载${NC}"
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo ""
    echo "已删除:"
    echo "  ✓ Realm 可执行文件"
    echo "  ✓ Realm 配置文件"
    echo "  ✓ Realm 日志"
    echo "  ✓ systemd 服务"
    echo "  ✓ /etc/realm/"
    echo "  ✓ 当前管理脚本"
    echo ""

    # 防止自删除以后继续运行主循环
    exit 0
}

# ============================================================================
# 判断是否安装
# ============================================================================

require_installed() {
    if [[ ! -x "$REALM_BIN" ]]; then
        err "尚未安装 Realm，请先执行菜单选项 1"
        return 1
    fi

    return 0
}

# ============================================================================
# 服务控制
# ============================================================================

service_control() {
    require_installed || return 1

    echo ""
    echo "1) 启动"
    echo "2) 停止"
    echo "3) 重启"
    echo "4) 查看状态"
    echo "5) 查看实时日志"
    echo "0) 返回"
    echo ""

    read -rp "选择操作: " op

    case "$op" in
        1)
            systemctl start realm

            if systemctl is-active --quiet realm; then
                ok "Realm 已启动"
            else
                err "Realm 启动失败"
                systemctl status realm --no-pager -l
            fi
            ;;

        2)
            systemctl stop realm
            ok "Realm 已停止"
            ;;

        3)
            systemctl restart realm

            if systemctl is-active --quiet realm; then
                ok "Realm 已重启"
            else
                err "Realm 重启失败"
                systemctl status realm --no-pager -l
            fi
            ;;

        4)
            systemctl status realm --no-pager -l
            ;;

        5)
            journalctl -u realm -f --no-pager
            ;;

        0)
            return 0
            ;;

        *)
            warn "无效选项"
            ;;
    esac
}

# ============================================================================
# WS / TLS / WSS
# ============================================================================

build_transport_string() {
    local side="$1"
    local result=""

    echo "" >&2
    echo "  ${side} 传输层封装:" >&2
    echo "    0) 不封装 (纯 TCP/UDP)" >&2
    echo "    1) WebSocket (ws)" >&2
    echo "    2) TLS" >&2
    echo "    3) WebSocket + TLS (wss)" >&2

    read -rp "  选择 [0-3，默认0]: " t_choice
    t_choice=${t_choice:-0}

    case "$t_choice" in
        1)
            read -rp "  WS host (伪装域名，可留空): " ws_host
            read -rp "  WS path (默认 /): " ws_path

            ws_path=${ws_path:-/}

            result="ws"

            [[ -n "$ws_host" ]] &&
                result="${result};host=${ws_host}"

            result="${result};path=${ws_path}"
            ;;

        2)
            if [[ "$side" == "监听端(服务端)" ]]; then
                read -rp "  TLS servername (证书对应域名): " sni

                result="tls;servername=${sni}"
            else
                read -rp "  TLS sni (对端证书域名): " sni
                read -rp "  是否跳过证书校验(自签/无证书时选 y) (y/N): " insecure

                result="tls;sni=${sni}"

                [[ "$insecure" == "y" || "$insecure" == "Y" ]] &&
                    result="${result};insecure"
            fi
            ;;

        3)
            read -rp "  WS host (伪装域名，可留空): " ws_host
            read -rp "  WS path (默认 /): " ws_path

            ws_path=${ws_path:-/}

            result="ws"

            [[ -n "$ws_host" ]] &&
                result="${result};host=${ws_host}"

            result="${result};path=${ws_path}"

            if [[ "$side" == "监听端(服务端)" ]]; then
                read -rp "  TLS servername (证书对应域名): " sni
                result="${result};tls;servername=${sni}"
            else
                read -rp "  TLS sni (对端证书域名): " sni
                read -rp "  是否跳过证书校验(自签/无证书时选 y) (y/N): " insecure

                result="${result};tls;sni=${sni}"

                [[ "$insecure" == "y" || "$insecure" == "Y" ]] &&
                    result="${result};insecure"
            fi
            ;;

        *)
            result=""
            ;;
    esac

    echo "$result"
}

# ============================================================================
# 高级选项
# ============================================================================

adv_opt_tcp_udp() {
    echo ""
    echo "  --- TCP/UDP 独立开关 ---"

    read -rp "  关闭本条规则的 TCP 转发？(y/N): " a

    [[ "$a" == "y" || "$a" == "Y" ]] &&
        EP_NO_TCP="true"

    read -rp "  关闭本条规则的 UDP 转发？(y/N): " a

    [[ "$a" == "y" || "$a" == "Y" ]] &&
        EP_USE_UDP="false"
}

adv_opt_balance() {
    echo ""
    echo "  --- 多出口负载均衡 ---"

    read -rp "  主出口权重 (数字，默认1): " w0
    w0=${w0:-1}

    local extras=()
    local weights=("$w0")

    while true; do
        read -rp "  追加一个出口地址 (留空结束): " extra

        [[ -z "$extra" ]] && break

        read -rp "    该出口权重 (默认1): " wN
        wN=${wN:-1}

        extras+=("\"$extra\"")
        weights+=("$wN")
    done

    echo "  负载均衡算法:"
    echo "    1) roundrobin"
    echo "    2) iphash"

    read -rp "  选择 [1-2，默认1]: " lb_algo

    local algo="roundrobin"

    [[ "$lb_algo" == "2" ]] &&
        algo="iphash"

    local w_joined
    w_joined="$(IFS=,; echo "${weights[*]}")"

    EP_BALANCE_LINE="balance = \"${algo}: ${w_joined}\""

    if [[ ${#extras[@]} -gt 0 ]]; then
        local e_joined
        e_joined="$(IFS=,; echo "${extras[*]}")"

        EP_EXTRA_REMOTES="extra_remotes = [${e_joined}]"
    fi
}

adv_opt_transport() {
    echo ""
    echo "  --- WS/TLS/WSS 隧道封装 ---"

    EP_LISTEN_TRANSPORT="$(build_transport_string "监听端(服务端)")"
    EP_REMOTE_TRANSPORT="$(build_transport_string "出口端(客户端)")"
}

adv_opt_mptcp() {
    echo ""
    echo "  --- MPTCP ---"
    echo "  需要内核 > 5.6，并确保："
    echo "  net.mptcp.enabled = 1"

    read -rp "  为本条规则单独启用 MPTCP？(Y/n): " a

    if [[ "$a" != "n" && "$a" != "N" ]]; then
        EP_SEND_MPTCP="true"
        EP_ACCEPT_MPTCP="true"
    fi
}

adv_opt_proxy_protocol() {
    echo ""
    echo "  --- PROXY protocol ---"

    read -rp "  向出口发送 PROXY protocol 头？(y/N): " a

    if [[ "$a" == "y" || "$a" == "Y" ]]; then
        EP_SEND_PROXY="true"

        read -rp "    发送版本 (1/2，默认2): " v
        EP_PROXY_VERSION="${v:-2}"
    fi

    read -rp "  监听端接收 PROXY protocol 头？(y/N): " a

    [[ "$a" == "y" || "$a" == "Y" ]] &&
        EP_ACCEPT_PROXY="true"
}

adv_opt_bind() {
    echo ""
    echo "  --- 绑定出口 IP / 网卡 ---"

    read -rp "  出口 IP (through，留空跳过): " through_ip
    read -rp "  出口网卡名 (interface，留空跳过): " iface_name

    [[ -n "$through_ip" ]] &&
        EP_THROUGH_LINE="through = \"${through_ip}\""

    [[ -n "$iface_name" ]] &&
        EP_IFACE_LINE="interface = \"${iface_name}\""
}

# ============================================================================
# 添加规则
# ============================================================================

add_rule() {
    require_installed || return 1

    echo ""
    echo -e "${BOLD}=== 添加转发规则 ===${NC}"
    echo ""

    read -rp "规则备注(便于识别，如 SG-to-JP-Hy2): " remark
    remark=${remark:-未命名规则}

    read -rp "本地监听端口: " listen_port

    if ! [[ "$listen_port" =~ ^[0-9]+$ ]] ||
       (( listen_port < 1 || listen_port > 65535 )); then
        err "端口必须是 1-65535 的数字"
        return 1
    fi

    read -rp "是否双栈转发(同时监听 IPv4 + IPv6)？(Y/n): " dual_stack

    local listen_addr

    if [[ "$dual_stack" == "n" || "$dual_stack" == "N" ]]; then
        listen_addr="0.0.0.0:${listen_port}"
    else
        listen_addr="[::]:${listen_port}"
    fi

    read -rp "出口目标地址 (IP 或域名:端口): " remote_addr

    if [[ -z "$remote_addr" ]]; then
        err "出口地址不能为空"
        return 1
    fi

    # 初始化高级选项

    EP_NO_TCP=""
    EP_USE_UDP=""

    EP_EXTRA_REMOTES=""
    EP_BALANCE_LINE=""

    EP_LISTEN_TRANSPORT=""
    EP_REMOTE_TRANSPORT=""

    EP_SEND_MPTCP=""
    EP_ACCEPT_MPTCP=""

    EP_SEND_PROXY=""
    EP_ACCEPT_PROXY=""
    EP_PROXY_VERSION=""

    EP_THROUGH_LINE=""
    EP_IFACE_LINE=""

    echo ""
    echo "高级选项 (可多选，空格分隔序号，直接回车表示不需要):"
    echo "  1) TCP/UDP 独立开关"
    echo "  2) 多出口负载均衡"
    echo "  3) WS/TLS/WSS 隧道封装"
    echo "  4) MPTCP"
    echo "  5) PROXY protocol"
    echo "  6) 绑定出口 IP / 网卡"

    read -rp "选择: " -a adv_choices

    for c in "${adv_choices[@]}"; do
        case "$c" in
            1) adv_opt_tcp_udp ;;
            2) adv_opt_balance ;;
            3) adv_opt_transport ;;
            4) adv_opt_mptcp ;;
            5) adv_opt_proxy_protocol ;;
            6) adv_opt_bind ;;
            *) warn "忽略无效选项: $c" ;;
        esac
    done

    # 内部唯一 ID
    local rule_id
    rule_id="$(date +%s%N)"

    {
        echo ""
        echo "# @rule-begin id=${rule_id} remark=${remark}"
        echo "[[endpoints]]"
        echo "listen = \"${listen_addr}\""
        echo "remote = \"${remote_addr}\""

        [[ -n "$EP_EXTRA_REMOTES" ]] &&
            echo "$EP_EXTRA_REMOTES"

        [[ -n "$EP_BALANCE_LINE" ]] &&
            echo "$EP_BALANCE_LINE"

        [[ -n "$EP_THROUGH_LINE" ]] &&
            echo "$EP_THROUGH_LINE"

        [[ -n "$EP_IFACE_LINE" ]] &&
            echo "$EP_IFACE_LINE"

        [[ -n "$EP_LISTEN_TRANSPORT" ]] &&
            echo "listen_transport = \"${EP_LISTEN_TRANSPORT}\""

        [[ -n "$EP_REMOTE_TRANSPORT" ]] &&
            echo "remote_transport = \"${EP_REMOTE_TRANSPORT}\""

        if [[ -n "${EP_NO_TCP}${EP_USE_UDP}${EP_SEND_MPTCP}${EP_ACCEPT_MPTCP}${EP_SEND_PROXY}${EP_ACCEPT_PROXY}" ]]; then
            echo ""
            echo "[endpoints.network]"

            [[ -n "$EP_NO_TCP" ]] &&
                echo "no_tcp = ${EP_NO_TCP}"

            [[ -n "$EP_USE_UDP" ]] &&
                echo "use_udp = ${EP_USE_UDP}"

            [[ -n "$EP_SEND_MPTCP" ]] &&
                echo "send_mptcp = ${EP_SEND_MPTCP}"

            [[ -n "$EP_ACCEPT_MPTCP" ]] &&
                echo "accept_mptcp = ${EP_ACCEPT_MPTCP}"

            [[ -n "$EP_SEND_PROXY" ]] &&
                echo "send_proxy = ${EP_SEND_PROXY}"

            [[ -n "$EP_PROXY_VERSION" ]] &&
                echo "send_proxy_version = ${EP_PROXY_VERSION}"

            [[ -n "$EP_ACCEPT_PROXY" ]] &&
                echo "accept_proxy = ${EP_ACCEPT_PROXY}"
        fi

        echo "# @rule-end"

    } >> "$CONFIG_FILE"

    ok "规则已添加"
    echo "  备注: ${remark}"
    echo "  监听: ${listen_addr}"
    echo "  出口: ${remote_addr}"

    echo ""

    read -rp "是否立即重启服务使规则生效？(Y/n): " restart_now

    if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
        if systemctl restart realm; then
            ok "服务已重启"
        else
            err "服务重启失败"
            systemctl status realm --no-pager -l
        fi
    fi
}

# ============================================================================
# 列出规则
# ============================================================================

list_rules() {
    require_installed || return 1

    if ! grep -q "@rule-begin" "$CONFIG_FILE" 2>/dev/null; then
        warn "当前没有任何转发规则"
        return 0
    fi

    echo ""
    echo -e "${BOLD}序号 | 备注         | 监听            | 出口${NC}"
    echo "-----|--------------|-----------------|------------------------"

    awk '
        /# @rule-begin/ {
            remark=$0
            sub(/^.*remark=/, "", remark)

            n++
            remarks[n]=remark
            listens[n]=""
            remotes[n]=""
            next
        }

        /^listen = / && n>0 {
            value=$0
            sub(/^listen = "/, "", value)
            sub(/"$/, "", value)
            listens[n]=value
            next
        }

        /^remote = / && n>0 {
            value=$0
            sub(/^remote = "/, "", value)
            sub(/"$/, "", value)
            remotes[n]=value
            next
        }

        END {
            for (i=1; i<=n; i++) {

                r=remarks[i]
                l=listens[i]
                m=remotes[i]

                if (length(r) > 12)
                    r=substr(r,1,12) "..."

                if (length(l) > 15)
                    l=substr(l,1,15) "..."

                if (length(m) > 22)
                    m=substr(m,1,22) "..."

                printf "%-4d | %-12s | %-15s | %-22s\n", \
                    i, r, l, m
            }
        }
    ' "$CONFIG_FILE"

    echo ""
}

# ============================================================================
# 删除规则
# ============================================================================

delete_rule() {
    require_installed || return 1

    list_rules

    if ! grep -q "@rule-begin" "$CONFIG_FILE" 2>/dev/null; then
        return 0
    fi

    echo ""

    read -rp "输入要删除的规则序号: " idx

    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        err "请输入数字序号"
        return 1
    fi

    local target_id

    target_id="$(
        awk -v want="$idx" '
            /# @rule-begin/ {
                match($0, /id=[0-9]+/)
                id=substr($0, RSTART+3, RLENGTH-3)

                n++

                if (n == want) {
                    print id
                    exit
                }
            }
        ' "$CONFIG_FILE"
    )"

    if [[ -z "$target_id" ]]; then
        err "未找到该序号对应的规则"
        return 1
    fi

    local tmpfile
    tmpfile="$(mktemp)"

    awk -v tid="$target_id" '
        BEGIN {
            skip=0
        }

        $0 ~ "^# @rule-begin id=" tid "( |$)" {
            skip=1
        }

        skip == 0 {
            print
        }

        /# @rule-end/ && skip == 1 {
            skip=0
            next
        }
    ' "$CONFIG_FILE" > "$tmpfile"

    if [[ ! -s "$tmpfile" ]]; then
        err "生成临时配置失败，原配置未修改"
        rm -f "$tmpfile"
        return 1
    fi

    mv -f "$tmpfile" "$CONFIG_FILE"

    ok "规则（序号 ${idx}）已删除"

    read -rp "是否立即重启服务使更改生效？(Y/n): " restart_now

    if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
        if systemctl restart realm; then
            ok "服务已重启"
        else
            err "服务重启失败"
            systemctl status realm --no-pager -l
        fi
    fi
}

# ============================================================================
# 全局网络参数编辑
# ============================================================================

edit_global_network() {
    require_installed || return 1

    echo ""
    echo -e "${BOLD}=== 当前全局 [network] 设置 ===${NC}"

    sed -n '/^\[network\]/,/^\[/p' "$CONFIG_FILE" | sed '$d'

    echo ""
    echo "1) 切换 TCP 转发开关 (no_tcp)"
    echo "2) 切换 UDP 转发开关 (use_udp)"
    echo "3) 切换全局 MPTCP (send_mptcp / accept_mptcp)"
    echo "4) 切换 PROXY protocol 发送 (send_proxy)"
    echo "5) 切换 PROXY protocol 接收 (accept_proxy)"
    echo "6) 修改 TCP / UDP 超时时间"
    echo "0) 返回"

    read -rp "选择: " opt

    toggle_bool() {
        local key="$1"
        local cur
        local new

        cur="$(
            grep -E "^${key}[[:space:]]*=" "$CONFIG_FILE" |
            head -1 |
            grep -oE 'true|false'
        )"

        if [[ "$cur" == "true" ]]; then
            new="false"
        else
            new="true"
        fi

        sed -i -E \
            "s/^${key}[[:space:]]*=.*/${key} = ${new}/" \
            "$CONFIG_FILE"

        ok "${key} -> ${new}"
    }

    case "$opt" in
        1)
            toggle_bool "no_tcp"
            ;;

        2)
            toggle_bool "use_udp"
            ;;

        3)
            toggle_bool "send_mptcp"
            toggle_bool "accept_mptcp"
            ;;

        4)
            toggle_bool "send_proxy"
            ;;

        5)
            toggle_bool "accept_proxy"
            ;;

        6)
            read -rp "TCP 超时(秒，留空不修改): " tt
            read -rp "UDP 超时(秒，留空不修改): " ut

            if [[ -n "$tt" ]]; then
                sed -i -E \
                    "s/^tcp_timeout[[:space:]]*=.*/tcp_timeout = ${tt}/" \
                    "$CONFIG_FILE"
            fi

            if [[ -n "$ut" ]]; then
                sed -i -E \
                    "s/^udp_timeout[[:space:]]*=.*/udp_timeout = ${ut}/" \
                    "$CONFIG_FILE"
            fi

            ok "超时设置已更新"
            ;;

        0)
            return 0
            ;;

        *)
            warn "无效选项"
            return 0
            ;;
    esac

    echo ""

    read -rp "是否立即重启服务使更改生效？(Y/n): " restart_now

    if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
        if systemctl restart realm; then
            ok "服务已重启"
        else
            err "服务重启失败"
            systemctl status realm --no-pager -l
        fi
    fi
}

# ============================================================================
# 查看原始配置
# ============================================================================

view_raw_config() {
    require_installed || return 1

    echo ""
    echo -e "${BOLD}=== ${CONFIG_FILE} ===${NC}"
    echo ""

    if [[ -f "$CONFIG_FILE" ]]; then
        cat -n "$CONFIG_FILE"
    else
        err "配置文件不存在"
    fi
}

# ============================================================================
# 主菜单
# ============================================================================

main_menu() {
    clear

    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}      Realm 一键转发管理脚本${NC}"
    echo -e "${BOLD}========================================${NC}"

    echo " 管理脚本版本: ${SCRIPT_VERSION}"

    if [[ -x "$REALM_BIN" ]]; then

        local status_str

        if systemctl is-active --quiet realm 2>/dev/null; then
            status_str="${GREEN}运行中${NC}"
        else
            status_str="${RED}未运行${NC}"
        fi

        echo -e " Realm 状态: ${status_str}"

    else

        echo -e " Realm 状态: ${YELLOW}未安装${NC}"

    fi

    echo "----------------------------------------"
    echo " 1) 安装 / 更新 realm"
    echo " 2) 添加转发规则"
    echo " 3) 查看转发规则"
    echo " 4) 删除转发规则"
    echo " 5) 服务管理"
    echo " 6) 全局网络设置"
    echo " 7) 查看原始配置文件"
    echo " 8) 更新管理脚本"
    echo " 9) 卸载 realm（同时删除本脚本）"
    echo " 0) 退出"
    echo "----------------------------------------"

    read -rp "请选择: " choice

    case "$choice" in
        1)
            install_or_update_realm
            pause
            ;;

        2)
            add_rule
            pause
            ;;

        3)
            list_rules
            pause
            ;;

        4)
            delete_rule
            pause
            ;;

        5)
            service_control
            pause
            ;;

        6)
            edit_global_network
            pause
            ;;

        7)
            view_raw_config
            pause
            ;;

        8)
            update_script
            ;;

        9)
            uninstall_realm
            ;;

        0)
            exit 0
            ;;

        *)
            warn "无效选项"
            sleep 1
            ;;
    esac
}

# ============================================================================
# 入口
# ============================================================================

check_root
check_systemd
check_dependencies || exit 1

mkdir -p "$REALM_DIR"

while true; do
    main_menu
done
