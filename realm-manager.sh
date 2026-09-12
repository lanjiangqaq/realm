#!/bin/bash
#
# Realm 一键转发管理脚本
# 功能覆盖: 安装/更新/卸载、双栈(IPv4+IPv6)转发、TCP/UDP、WS/TLS/WSS隧道、
#          MPTCP、PROXY protocol、多出口负载均衡(roundrobin/iphash)、
#          出口IP/网卡绑定、DNS设置、systemd服务管理
# 上游项目: https://github.com/zhboner/realm
#
set -o pipefail

REALM_DIR="/etc/realm"
REALM_BIN="${REALM_DIR}/realm"
CONFIG_FILE="${REALM_DIR}/config.toml"
LOG_FILE="${REALM_DIR}/realm.log"
SERVICE_FILE="/etc/systemd/system/realm.service"
GITHUB_REPO="zhboner/realm"
MARKER_LINE="# ===== ENDPOINTS BELOW (由脚本管理，规则块请通过菜单增删) ====="

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"

info()  { echo -e "${CYAN}[信息]${NC} $1"; }
ok()    { echo -e "${GREEN}[完成]${NC} $1"; }
warn()  { echo -e "${YELLOW}[注意]${NC} $1"; }
err()   { echo -e "${RED}[错误]${NC} $1"; }
pause() { read -rp "按回车键返回菜单..." _; }

# ----------------------------------------------------------------------------
# 基础环境检查
# ----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 用户运行本脚本 (sudo -i 后再执行)"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        err "未检测到 systemd，本脚本依赖 systemd 管理服务，暂不支持该系统"
        exit 1
    fi
}

detect_arch_libc() {
    local machine
    machine=$(uname -m)
    local libc="gnu"
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
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
            err "暂不支持的CPU架构: $machine"
            exit 1
            ;;
    esac
    info "检测到架构: ${machine} (libc: ${libc}) -> ${ARCH_TRIPLE}"
}

# ----------------------------------------------------------------------------
# 安装 / 更新 / 卸载
# ----------------------------------------------------------------------------
get_latest_version() {
    local ver
    # 优先走API，失败则用 releases/latest 的重定向兜底，避免API限流导致取不到版本
    ver=$(curl -s --connect-timeout 8 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
          | grep -oE '"tag_name": *"[^"]+"' | head -1 | cut -d'"' -f4)
    if [[ -z "$ver" ]]; then
        ver=$(curl -sIL --connect-timeout 8 "https://github.com/${GITHUB_REPO}/releases/latest" \
              | grep -i '^location:' | grep -oE 'tag/[^[:space:]]+' | tail -1 | cut -d'/' -f2 | tr -d '\r')
    fi
    echo "$ver"
}

install_or_update_realm() {
    detect_arch_libc
    info "正在获取最新版本号..."
    local version
    version=$(get_latest_version)
    if [[ -z "$version" ]]; then
        err "获取版本信息失败，请检查本机到 GitHub 的网络连通性"
        return 1
    fi
    info "最新版本: ${version}"

    mkdir -p "$REALM_DIR"
    local asset="realm-${ARCH_TRIPLE}.tar.gz"
    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${asset}"
    info "下载: ${url}"

    if ! curl -L --connect-timeout 10 -o /tmp/realm.tar.gz "$url"; then
        err "下载失败，请确认该架构/libc组合的发行包是否存在: ${asset}"
        return 1
    fi

    local was_running=0
    if systemctl is-active --quiet realm 2>/dev/null; then
        was_running=1
        systemctl stop realm
    fi

    tar -xzf /tmp/realm.tar.gz -C /tmp
    if [[ ! -f /tmp/realm ]]; then
        err "解压后未找到 realm 可执行文件，安装中止"
        return 1
    fi
    mv -f /tmp/realm "$REALM_BIN"
    chmod +x "$REALM_BIN"
    rm -f /tmp/realm.tar.gz

    init_config
    create_service

    if [[ $was_running -eq 1 ]]; then
        systemctl start realm
    fi

    ok "realm ${version} 安装/更新完成 (${ARCH_TRIPLE})"
}

init_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        return 0
    fi
    cat > "$CONFIG_FILE" << EOF
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

create_service() {
    cat > "$SERVICE_FILE" << EOF
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
    ok "systemd 服务已配置 (开机自启已启用)"
}

uninstall_realm() {
    read -rp "确认卸载 realm 并删除所有配置？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消"
        return 0
    fi
    systemctl stop realm 2>/dev/null
    systemctl disable realm >/dev/null 2>&1
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$REALM_DIR"
    ok "realm 已完全卸载"
}

# ----------------------------------------------------------------------------
# 服务控制
# ----------------------------------------------------------------------------
require_installed() {
    if [[ ! -x "$REALM_BIN" ]]; then
        err "尚未安装 realm，请先执行菜单选项 1"
        return 1
    fi
    return 0
}

service_control() {
    require_installed || return 1
    echo "1) 启动   2) 停止   3) 重启   4) 查看状态   5) 查看实时日志"
    read -rp "选择操作: " op
    case "$op" in
        1) systemctl start realm && ok "已启动" ;;
        2) systemctl stop realm && ok "已停止" ;;
        3) systemctl restart realm && ok "已重启" ;;
        4) systemctl status realm --no-pager ;;
        5) journalctl -u realm -f --no-pager ;;
        *) warn "无效选项" ;;
    esac
}

# ----------------------------------------------------------------------------
# 传输层(WS/TLS/WSS)构造器 —— 分别用于 listen_transport / remote_transport
# ----------------------------------------------------------------------------
build_transport_string() {
    # 注意: 本函数通过 $(...) 被调用方捕获返回值，
    # 所有仅用于展示的输出必须写到 stderr(>&2)，只有最终 result 走 stdout
    local side="$1"  # "监听端(服务端)" 或 "出口端(客户端)"
    local result=""
    echo "" >&2
    echo "  ${side} 传输层封装:" >&2
    echo "    0) 不封装 (纯TCP/UDP)" >&2
    echo "    1) WebSocket (ws)" >&2
    echo "    2) TLS" >&2
    echo "    3) WebSocket + TLS (wss)" >&2
    read -rp "  选择 [0-3，默认0]: " t_choice
    t_choice=${t_choice:-0}

    case "$t_choice" in
        1)
            read -rp "  WS host (伪装域名, 可留空): " ws_host
            read -rp "  WS path (默认 /): " ws_path
            ws_path=${ws_path:-/}
            result="ws"
            [[ -n "$ws_host" ]] && result="${result};host=${ws_host}"
            result="${result};path=${ws_path}"
            ;;
        2)
            if [[ "$side" == "监听端(服务端)" ]]; then
                read -rp "  TLS servername (证书对应域名): " sni
                result="tls;servername=${sni}"
            else
                read -rp "  TLS sni (对端证书域名): " sni
                read -rp "  是否跳过证书校验(自签/无证书时选y) (y/N): " insecure
                result="tls;sni=${sni}"
                [[ "$insecure" == "y" || "$insecure" == "Y" ]] && result="${result};insecure"
            fi
            ;;
        3)
            read -rp "  WS host (伪装域名, 可留空): " ws_host
            read -rp "  WS path (默认 /): " ws_path
            ws_path=${ws_path:-/}
            result="ws"
            [[ -n "$ws_host" ]] && result="${result};host=${ws_host}"
            result="${result};path=${ws_path}"
            if [[ "$side" == "监听端(服务端)" ]]; then
                read -rp "  TLS servername (证书对应域名): " sni
                result="${result};tls;servername=${sni}"
            else
                read -rp "  TLS sni (对端证书域名，需与监听端一致): " sni
                read -rp "  是否跳过证书校验(自签/无证书时选y) (y/N): " insecure
                result="${result};tls;sni=${sni}"
                [[ "$insecure" == "y" || "$insecure" == "Y" ]] && result="${result};insecure"
            fi
            ;;
        *)
            result=""
            ;;
    esac
    echo "$result"
}

# ----------------------------------------------------------------------------
# 添加转发规则
# ----------------------------------------------------------------------------
adv_opt_tcp_udp() {
    echo ""
    echo "  --- TCP/UDP 独立开关 (仅对本条规则生效，覆盖全局设置) ---"
    read -rp "  关闭本条规则的 TCP 转发？(y/N): " a
    [[ "$a" == "y" || "$a" == "Y" ]] && EP_NO_TCP="true"
    read -rp "  关闭本条规则的 UDP 转发？(y/N): " a
    [[ "$a" == "y" || "$a" == "Y" ]] && EP_USE_UDP="false"
}

adv_opt_balance() {
    echo ""
    echo "  --- 多出口负载均衡 ---"
    read -rp "  主出口权重 (数字, 默认1): " w0
    w0=${w0:-1}
    local extras=() weights=("$w0")
    while true; do
        read -rp "  追加一个出口地址 (留空结束): " extra
        [[ -z "$extra" ]] && break
        read -rp "    该出口权重 (默认1): " wN
        wN=${wN:-1}
        extras+=("\"$extra\"")
        weights+=("$wN")
    done
    echo "  负载均衡算法: 1) roundrobin(轮询)  2) iphash(同一来源IP固定同一出口)"
    read -rp "  选择 [1-2，默认1]: " lb_algo
    local algo="roundrobin"
    [[ "$lb_algo" == "2" ]] && algo="iphash"
    local w_joined
    w_joined=$(IFS=,; echo "${weights[*]}")
    EP_BALANCE_LINE="balance = \"${algo}: ${w_joined}\""
    if [[ ${#extras[@]} -gt 0 ]]; then
        local e_joined
        e_joined=$(IFS=,; echo "${extras[*]}")
        EP_EXTRA_REMOTES="extra_remotes = [${e_joined}]"
    fi
}

adv_opt_transport() {
    echo ""
    echo "  --- WS/TLS/WSS 隧道封装 ---"
    EP_LISTEN_TRANSPORT=$(build_transport_string "监听端(服务端)")
    EP_REMOTE_TRANSPORT=$(build_transport_string "出口端(客户端)")
}

adv_opt_mptcp() {
    echo ""
    echo "  --- MPTCP (需内核>5.6 且已开启 net.mptcp.enabled=1) ---"
    read -rp "  为本条规则单独启用 MPTCP？(Y/n): " a
    if [[ "$a" != "n" && "$a" != "N" ]]; then
        EP_SEND_MPTCP="true"
        EP_ACCEPT_MPTCP="true"
    fi
}

adv_opt_proxy_protocol() {
    echo ""
    echo "  --- PROXY protocol (仅对本条规则生效，覆盖全局设置) ---"
    read -rp "  向出口发送 PROXY protocol 头？(y/N): " a
    if [[ "$a" == "y" || "$a" == "Y" ]]; then
        EP_SEND_PROXY="true"
        read -rp "    发送版本 (1/2, 默认2): " v
        EP_PROXY_VERSION="${v:-2}"
    fi
    read -rp "  监听端接收 PROXY protocol 头？(y/N): " a
    [[ "$a" == "y" || "$a" == "Y" ]] && EP_ACCEPT_PROXY="true"
}

adv_opt_bind() {
    echo ""
    echo "  --- 绑定出口IP/网卡 (多IP/多网卡机器分流用) ---"
    read -rp "  出口IP (through, 留空跳过): " through_ip
    read -rp "  出口网卡名 (interface, 留空跳过): " iface_name
    [[ -n "$through_ip" ]] && EP_THROUGH_LINE="through = \"${through_ip}\""
    [[ -n "$iface_name" ]] && EP_IFACE_LINE="interface = \"${iface_name}\""
}

add_rule() {
    require_installed || return 1
    echo -e "${BOLD}=== 添加转发规则 ===${NC}"

    read -rp "规则备注(便于识别，如 SG-to-JP-Hy2): " remark
    remark=${remark:-未命名规则}

    read -rp "本地监听端口: " listen_port
    if ! [[ "$listen_port" =~ ^[0-9]+$ ]]; then
        err "端口必须为数字"; return 1
    fi

    read -rp "是否双栈转发(同时监听 IPv4 + IPv6)？(Y/n): " dual_stack
    local listen_addr
    if [[ "$dual_stack" == "n" || "$dual_stack" == "N" ]]; then
        listen_addr="0.0.0.0:${listen_port}"
    else
        listen_addr="[::]:${listen_port}"  # 全局 ipv6_only=false 时 [::] 即双栈监听
    fi

    read -rp "出口目标地址 (ip_或域名:端口): " remote_addr
    if [[ -z "$remote_addr" ]]; then
        err "出口地址不能为空"; return 1
    fi

    # 各高级选项的输出变量，默认全部为空
    EP_NO_TCP=""; EP_USE_UDP=""
    EP_EXTRA_REMOTES=""; EP_BALANCE_LINE=""
    EP_LISTEN_TRANSPORT=""; EP_REMOTE_TRANSPORT=""
    EP_SEND_MPTCP=""; EP_ACCEPT_MPTCP=""
    EP_SEND_PROXY=""; EP_ACCEPT_PROXY=""; EP_PROXY_VERSION=""
    EP_THROUGH_LINE=""; EP_IFACE_LINE=""

    echo ""
    echo "高级选项 (可多选，空格分隔序号，直接回车表示不需要):"
    echo "  1) TCP/UDP 独立开关"
    echo "  2) 多出口负载均衡"
    echo "  3) WS/TLS/WSS 隧道封装"
    echo "  4) MPTCP"
    echo "  5) PROXY protocol"
    echo "  6) 绑定出口IP/网卡"
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

    local rule_id
    rule_id=$(date +%s)

    {
        echo ""
        echo "# @rule-begin id=${rule_id} remark=${remark}"
        echo "[[endpoints]]"
        echo "listen = \"${listen_addr}\""
        echo "remote = \"${remote_addr}\""
        [[ -n "$EP_EXTRA_REMOTES" ]] && echo "$EP_EXTRA_REMOTES"
        [[ -n "$EP_BALANCE_LINE" ]] && echo "$EP_BALANCE_LINE"
        [[ -n "$EP_THROUGH_LINE" ]] && echo "$EP_THROUGH_LINE"
        [[ -n "$EP_IFACE_LINE" ]] && echo "$EP_IFACE_LINE"
        [[ -n "$EP_LISTEN_TRANSPORT" ]] && echo "listen_transport = \"${EP_LISTEN_TRANSPORT}\""
        [[ -n "$EP_REMOTE_TRANSPORT" ]] && echo "remote_transport = \"${EP_REMOTE_TRANSPORT}\""

        # 所有 endpoint 级别的 network 覆盖项合并进同一张表，避免重复表头
        if [[ -n "$EP_NO_TCP$EP_USE_UDP$EP_SEND_MPTCP$EP_ACCEPT_MPTCP$EP_SEND_PROXY$EP_ACCEPT_PROXY" ]]; then
            echo ""
            echo "[endpoints.network]"
            [[ -n "$EP_NO_TCP" ]] && echo "no_tcp = ${EP_NO_TCP}"
            [[ -n "$EP_USE_UDP" ]] && echo "use_udp = ${EP_USE_UDP}"
            [[ -n "$EP_SEND_MPTCP" ]] && echo "send_mptcp = ${EP_SEND_MPTCP}"
            [[ -n "$EP_ACCEPT_MPTCP" ]] && echo "accept_mptcp = ${EP_ACCEPT_MPTCP}"
            [[ -n "$EP_SEND_PROXY" ]] && echo "send_proxy = ${EP_SEND_PROXY}"
            [[ -n "$EP_SEND_PROXY" && -n "$EP_PROXY_VERSION" ]] && echo "send_proxy_version = ${EP_PROXY_VERSION}"
            [[ -n "$EP_ACCEPT_PROXY" ]] && echo "accept_proxy = ${EP_ACCEPT_PROXY}"
        fi

        echo "# @rule-end"
    } >> "$CONFIG_FILE"

    ok "规则已添加: [${remark}] ${listen_addr} -> ${remote_addr}"
    read -rp "是否立即重启服务使规则生效？(Y/n): " restart_now
    if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
        systemctl restart realm && ok "服务已重启"
    fi
}

# ----------------------------------------------------------------------------
# 列出 / 删除规则
# ----------------------------------------------------------------------------
list_rules() {
    require_installed || return 1
    if ! grep -q "@rule-begin" "$CONFIG_FILE" 2>/dev/null; then
        warn "当前没有任何转发规则"
        return 0
    fi
    echo -e "${BOLD}序号 | 备注 | 监听 | 出口${NC}"
    echo "--------------------------------------------------------"
    awk '
        /# @rule-begin/ {
            match($0, /id=[0-9]+/); id=substr($0, RSTART+3, RLENGTH-3)
            match($0, /remark=.*/); remark=substr($0, RSTART+7)
            n++
            ids[n]=id; remarks[n]=remark
        }
        /^listen = / && n>0 && listens[n]=="" {
            gsub(/listen = "|"/,""); listens[n]=$0
        }
        /^remote = / && n>0 && remotes[n]=="" {
            gsub(/remote = "|"/,""); remotes[n]=$0
        }
        /# @rule-end/ { }
        END {
            for (i=1;i<=n;i++) {
                printf "%-4s | %-20s | %-22s | %-22s | id=%s\n", i, remarks[i], listens[i], remotes[i], ids[i]
            }
        }
    ' "$CONFIG_FILE"
}

delete_rule() {
    require_installed || return 1
    list_rules
    if ! grep -q "@rule-begin" "$CONFIG_FILE" 2>/dev/null; then
        return 0
    fi
    echo ""
    read -rp "输入要删除的规则序号: " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        err "请输入数字序号"; return 1
    fi

    local target_id
    target_id=$(awk -v want="$idx" '
        /# @rule-begin/ {
            match($0, /id=[0-9]+/); id=substr($0, RSTART+3, RLENGTH-3)
            n++
            if (n==want) print id
        }
    ' "$CONFIG_FILE")

    if [[ -z "$target_id" ]]; then
        err "未找到该序号对应的规则"; return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    awk -v tid="$target_id" '
        BEGIN{skip=0}
        $0 ~ "# @rule-begin id=" tid "( |$)" {skip=1}
        skip==0 {print}
        $0 ~ /# @rule-end/ && skip==1 {skip=0; next}
    ' "$CONFIG_FILE" > "$tmpfile"

    mv "$tmpfile" "$CONFIG_FILE"
    ok "规则 (id=${target_id}) 已删除"
    read -rp "是否立即重启服务使更改生效？(Y/n): " restart_now
    if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
        systemctl restart realm && ok "服务已重启"
    fi
}

# ----------------------------------------------------------------------------
# 全局网络参数编辑 (network 段)
# ----------------------------------------------------------------------------
edit_global_network() {
    require_installed || return 1
    echo -e "${BOLD}=== 当前全局 [network] 设置 ===${NC}"
    sed -n '/^\[network\]/,/^\[/p' "$CONFIG_FILE" | sed '$d'
    echo ""
    echo "1) 切换 TCP 转发开关 (no_tcp)"
    echo "2) 切换 UDP 转发开关 (use_udp)"
    echo "3) 切换全局 MPTCP (send_mptcp / accept_mptcp)"
    echo "4) 切换 PROXY protocol 发送 (send_proxy)"
    echo "5) 切换 PROXY protocol 接收 (accept_proxy)"
    echo "6) 修改 TCP/UDP 超时时间"
    echo "0) 返回"
    read -rp "选择: " opt

    toggle_bool() {
        local key="$1"
        local cur new
        cur=$(grep -E "^${key} = " "$CONFIG_FILE" | head -1 | grep -oE 'true|false')
        if [[ "$cur" == "true" ]]; then new="false"; else new="true"; fi
        sed -i "s/^${key} = .*/${key} = ${new}/" "$CONFIG_FILE"
        ok "${key} -> ${new}"
    }

    case "$opt" in
        1) toggle_bool "no_tcp" ;;
        2) toggle_bool "use_udp" ;;
        3) toggle_bool "send_mptcp"; toggle_bool "accept_mptcp" ;;
        4) toggle_bool "send_proxy" ;;
        5) toggle_bool "accept_proxy" ;;
        6)
            read -rp "TCP超时(秒，默认5): " tt
            read -rp "UDP超时(秒，默认30): " ut
            [[ -n "$tt" ]] && sed -i "s/^tcp_timeout = .*/tcp_timeout = ${tt}/" "$CONFIG_FILE"
            [[ -n "$ut" ]] && sed -i "s/^udp_timeout = .*/udp_timeout = ${ut}/" "$CONFIG_FILE"
            ok "超时设置已更新"
            ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac

    read -rp "是否立即重启服务使更改生效？(Y/n): " restart_now
    if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
        systemctl restart realm && ok "服务已重启"
    fi
}

view_raw_config() {
    require_installed || return 1
    echo -e "${BOLD}=== ${CONFIG_FILE} ===${NC}"
    cat -n "$CONFIG_FILE"
}

# ----------------------------------------------------------------------------
# 主菜单
# ----------------------------------------------------------------------------
main_menu() {
    clear
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}      Realm 一键转发管理脚本${NC}"
    echo -e "${BOLD}========================================${NC}"
    if [[ -x "$REALM_BIN" ]]; then
        local status_str
        if systemctl is-active --quiet realm 2>/dev/null; then
            status_str="${GREEN}运行中${NC}"
        else
            status_str="${RED}未运行${NC}"
        fi
        echo -e " realm 状态: ${status_str}"
    else
        echo -e " realm 状态: ${YELLOW}未安装${NC}"
    fi
    echo "----------------------------------------"
    echo " 1) 安装 / 更新 realm"
    echo " 2) 添加转发规则 (支持双栈/负载均衡/WS/TLS/WSS/MPTCP)"
    echo " 3) 查看转发规则"
    echo " 4) 删除转发规则"
    echo " 5) 服务管理 (启动/停止/重启/状态/日志)"
    echo " 6) 全局网络设置 (TCP/UDP开关/MPTCP/PROXY protocol/超时)"
    echo " 7) 查看原始配置文件"
    echo " 8) 卸载 realm"
    echo " 0) 退出"
    echo "----------------------------------------"
    read -rp "请选择: " choice
    case "$choice" in
        1) install_or_update_realm; pause ;;
        2) add_rule; pause ;;
        3) list_rules; pause ;;
        4) delete_rule; pause ;;
        5) service_control; pause ;;
        6) edit_global_network; pause ;;
        7) view_raw_config; pause ;;
        8) uninstall_realm; pause ;;
        0) exit 0 ;;
        *) warn "无效选项"; sleep 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# 入口
# ----------------------------------------------------------------------------
check_root
check_systemd
mkdir -p "$REALM_DIR"

while true; do
    main_menu
done
