#!/bin/bash
#===============================================================================
# NAS 反向隧道一键部署脚本（Mac mini 端 · OpenList）
#
# 目标：
#   在家里 Mac mini 上把 OpenList 跑起来，并通过「Hysteria2 加密隧道 + frp
#   反向端口映射」挂到国内服务器的公网域名上；OpenList / hysteria / frpc
#   三个组件全部用 launchd 开机自启 + 挂掉自动拉起。
#
# 数据流（Mac 侧视角）：
#
#   OpenList 127.0.0.1:5244
#        ▲
#        │ 本地 TCP
#        │
#   frpc ──「CONNECT 127.0.0.1:7000」──► hysteria 客户端 socks5 127.0.0.1:1080
#                                              │
#                                              └─ UDP/443 QUIC 加密隧道 ─► 服务器
#                                                   （服务器侧 HY2 再拨号到 frps）
#
#   观众 ──TCP/443──► 服务器 Caddy ──► 127.0.0.1:15244 ──► … ──► Mac 的 5244
#
# 本脚本与服务器端的 deploy-nas-tunnel.sh 严格配套：
#   - 服务器侧必须先跑通 deploy-nas-tunnel.sh（它会生成 Mac 端对接包）
#   - 本脚本只负责 Mac 侧，绝不改动服务器上的任何配置
#
# 用法：
#   bash deploy-nas-tunnel-mac.sh                  # 交互式部署（推荐）
#   bash deploy-nas-tunnel-mac.sh --status         # 查看当前状态
#   bash deploy-nas-tunnel-mac.sh --self-test-only # 只跑端到端自检
#   bash deploy-nas-tunnel-mac.sh --uninstall      # 卸载（默认保留 OpenList 数据）
#   bash deploy-nas-tunnel-mac.sh --help
#
# 三条重要约束：
#   1. 请用「普通用户」运行（不要 sudo bash 本脚本）。Homebrew 拒绝以 root 运行；
#      脚本内部需要提权的地方会自己调用 sudo。
#   2. 网络：默认走本机代理 127.0.0.1:10808（v2rayN 的 xray 后端）。
#      实测国内直连 github.com 会失败，所以拉取二进制必须走代理或加速站。
#   3. OpenList 默认监听 0.0.0.0，脚本会把它改成只监听 127.0.0.1，
#      避免局域网绕过隧道直连。
#
# 版本：1.0.0
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# 全局常量
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="deploy-nas-tunnel-mac.sh"

# 日志文件（每次执行生成一份；用户可写目录，先探测，失败降级到 /tmp）
LOG_FILE=""

# 状态文件：记录本次部署的关键参数，供 --status / --uninstall / 重复执行使用
readonly CONF_DIR="/usr/local/etc/nas-tunnel"
readonly STATE_FILE="${CONF_DIR}/state.env"
readonly STATE_VERSION="1"
readonly LOG_DIR="/usr/local/var/log/nas-tunnel"

# 二进制路径
readonly HY2_BIN="/usr/local/bin/hysteria"
readonly FRPC_BIN="/usr/local/bin/frpc"
BREW_PREFIX="/opt/homebrew"
BREW_BIN="${BREW_PREFIX}/bin/brew"
OPENLIST_BIN="${BREW_PREFIX}/bin/openlist"

# OpenList
OPENLIST_DATA_DEFAULT="/opt/openlist/data"
readonly OPENLIST_PORT_DEFAULT="5244"

# 配置文件（由服务器侧对接包填充）
readonly HY2_CLIENT_CONF="${CONF_DIR}/hysteria-client.yaml"
readonly FRPC_CONF="${CONF_DIR}/frpc.toml"
readonly BUNDLE_README="${CONF_DIR}/README.md"

# launchd
readonly LAUNCHD_DIR="/Library/LaunchDaemons"
readonly LABEL_HY2="com.nas.tunnel.hysteria"
readonly LABEL_FRPC="com.nas.tunnel.frpc"
readonly LABEL_OPENLIST="com.openlist.server"
readonly PLIST_HY2="${LAUNCHD_DIR}/${LABEL_HY2}.plist"
readonly PLIST_FRPC="${LAUNCHD_DIR}/${LABEL_FRPC}.plist"
readonly PLIST_OPENLIST="${LAUNCHD_DIR}/${LABEL_OPENLIST}.plist"

# 「国外下载那套」(deploy-nas-nl-mac.sh) 的痕迹。
# 两套脚本唯一共用的资源是 hysteria 二进制 /usr/local/bin/hysteria，
# 所以卸载时必须先看看那边是不是还在用，避免把它的隧道一起弄坏。
readonly NL_PLIST="/Library/LaunchDaemons/com.nas.nl.hysteria.plist"
readonly NL_CONF_DIR="/usr/local/etc/nas-nl"

# 下载源
readonly HYSTERIA_REPO="https://github.com/apernet/hysteria"
readonly HYSTERIA_RELEASE_BASE="${HYSTERIA_REPO}/releases/latest/download"
readonly FRP_REPO="https://github.com/fatedier/frp"
readonly FRP_VERSION_FALLBACK="0.71.0"
readonly BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# 候选 GitHub 加速代理（本机代理不可用时逐个尝试）
readonly -a GH_PROXY_CANDIDATES=(
  "https://gh-proxy.com/"
  "https://ghfast.top/"
  "https://ghproxy.net/"
)

# 本机代理候选端口（v2rayN 默认 10808 socks / 10809 http；其余是常见代理端口）
readonly -a PROXY_PORT_CANDIDATES=(10808 10809 7890 1080 2080 8118)
readonly PROXY_URL_DEFAULT="http://127.0.0.1:10808"

# 服务器侧对接包位置
readonly SERVER_BUNDLE_DIR="/root/nas-tunnel-mac-client"

#-------------------------------------------------------------------------------
# 运行期变量
#-------------------------------------------------------------------------------
RUN_USER=""
RUN_GROUP=""
SERVER_IP=""
SERVER_USER="root"
PROXY_URL=""
PROXY_EXPLICIT=0
OPENLIST_DATA="$OPENLIST_DATA_DEFAULT"
DO_STATUS=0
DO_UNINSTALL=0
SELF_TEST_ONLY=0
SKIP_BREW=0
KEEP_OPENLIST_DATA=0

# 从对接包解析出来的参数
PUBLIC_DOMAIN=""
HY2_SERVER_ADDR=""
HY2_PORT="443"
HY2_PASSWORD=""
SOCKS5_LISTEN="127.0.0.1:1080"
SOCKS5_PORT="1080"
SOCKS5_USER=""
SOCKS5_PASS=""
FRP_TOKEN=""
FRP_REMOTE_PORT="15244"
OPENLIST_LOCAL_PORT="$OPENLIST_PORT_DEFAULT"
FRP_VERSION=""
FRP_SERVER_PORT="7000"
HY2_INSECURE="false"
OPENLIST_INITIAL_PASSWORD=""

# 自检临时
TMP_DIR=""

#-------------------------------------------------------------------------------
# 颜色（仅在终端下启用）
#-------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

#-------------------------------------------------------------------------------
# 日志
#-------------------------------------------------------------------------------
init_log() {
    local dir="$HOME/Library/Logs/nas-tunnel"
    mkdir -p "$dir" 2>/dev/null || dir="/tmp"
    LOG_FILE="${dir}/deploy-mac-$(date +%Y%m%d-%H%M%S).log"
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/dev/null"
    fi
    log_raw "==============================================================="
    log_raw " NAS 反向隧道部署日志（Mac 端）  版本：$SCRIPT_VERSION"
    log_raw " 开始时间：$(date '+%Y-%m-%d %H:%M:%S')  主机：$(hostname)"
    log_raw "==============================================================="
}

log_raw() {
    if [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "/dev/null" ]; then
        printf '%s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
    fi
    printf '%b\n' "$*"
}
log_info() { log_raw "${C_BLUE}[信息]${C_RESET} $*"; }
log_ok()   { log_raw "${C_GREEN}[成功]${C_RESET} $*"; }
log_warn() { log_raw "${C_YELLOW}[警告]${C_RESET} $*"; }
log_err()  { log_raw "${C_RED}[错误]${C_RESET} $*"; }
log_step() { log_raw ""; log_raw "${C_CYAN}${C_BOLD}==> $*${C_RESET}"; }

die() {
    log_err "$*"
    [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "/dev/null" ] && log_err "详细日志：$LOG_FILE"
    exit 1
}

#-------------------------------------------------------------------------------
# 帮助
#-------------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}NAS 反向隧道部署脚本（Mac mini 端）v${SCRIPT_VERSION}${C_RESET}

${C_BOLD}它做什么：${C_RESET}
  在 Mac mini 上装好 OpenList、Hysteria2 客户端、frpc，并把三者都设为
  launchd 开机自启；随后把本机 OpenList(127.0.0.1:${OPENLIST_PORT_DEFAULT}) 挂到
  服务器公网域名上。公网段是纯 UDP（QUIC），一个 TCP 包都不出去。

${C_BOLD}用法：${C_RESET}
  bash ${SCRIPT_NAME} [选项]

${C_BOLD}选项：${C_RESET}
  -s, --server <IP>       服务器公网 IP（不填则交互询问）
      --server-user <用户>  登录服务器的 SSH 用户（默认 ${SERVER_USER}）
  -p, --proxy <地址>      指定本机下载代理，如 http://127.0.0.1:10808
      --openlist-data <目录>
                          OpenList 数据目录（默认 ${OPENLIST_DATA_DEFAULT}）
      --skip-brew         不安装 Homebrew（用于你已自行装好 openlist 的情况）
      --status            查看当前状态
      --self-test-only    只跑端到端自检
      --uninstall         卸载（默认保留 OpenList 数据目录）
      --purge-data        配合 --uninstall：连 OpenList 数据目录一起删
  -h, --help              显示本帮助
  -v, --version           显示脚本版本

${C_BOLD}执行流程：${C_RESET}
  阶段 0/6  环境准备：macOS/架构检查、运行身份检查、代理探测、sudo 预热
  阶段 1/6  拉取对接包：SSH 到服务器取 /root/nas-tunnel-mac-client/
  阶段 2/6  部署 OpenList：按需安装 Homebrew → brew install openlist → 只绑回环
  阶段 3/6  部署隧道：下载 hysteria / frpc（macOS arm64）
  阶段 4/6  写配置：按对接包生成两份配置，日志路径改写为用户可写目录
  阶段 5/6  写 launchd：三个 LaunchDaemon（RunAtLoad + KeepAlive）
  阶段 6/6  端到端自检与汇总

${C_BOLD}执行前请确认：${C_RESET}
  1. 服务器侧已跑通 deploy-nas-tunnel.sh，且安全组已放行 UDP ${HY2_PORT}

${C_BOLD}常用排查：${C_RESET}
  · 域名一直 502        → Mac 上 frpc 没跑起来：sudo launchctl print system/${LABEL_FRPC}
  · 隧道连不上          → 服务器安全组没放行 UDP，或 tls.sni 写错
  · 想看参数与状态      → bash ${SCRIPT_NAME} --status
  · 想推倒重来          → bash ${SCRIPT_NAME} --uninstall 后重新执行
EOF
}

#-------------------------------------------------------------------------------
# 参数解析
#-------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -s|--server)
                [ -n "${2:-}" ] || die "选项 $1 需要一个 IP"
                SERVER_IP="$2"; shift 2 ;;
            --server-user)
                [ -n "${2:-}" ] || die "选项 $1 需要一个用户名"
                SERVER_USER="$2"; shift 2 ;;
            -p|--proxy)
                [ -n "${2:-}" ] || die "选项 $1 需要地址"
                PROXY_URL="$2"; PROXY_EXPLICIT=1; shift 2 ;;
            --openlist-data)
                [ -n "${2:-}" ] || die "选项 $1 需要目录"
                OPENLIST_DATA="$2"; shift 2 ;;
            --skip-brew)
                SKIP_BREW=1; shift ;;
            --status)
                DO_STATUS=1; shift ;;
            --self-test-only)
                SELF_TEST_ONLY=1; shift ;;
            --uninstall)
                DO_UNINSTALL=1; shift ;;
            --purge-data)
                KEEP_OPENLIST_DATA=0; shift ;;
            -h|--help)
                usage; exit 0 ;;
            -v|--version)
                echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
            *)
                echo "未知参数：$1" >&2
                echo "使用 --help 查看用法" >&2
                exit 2 ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# 通用工具
#-------------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

ask() {
    local prompt="$1" default="${2:-}" answer=""
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " answer || true
        answer="${answer:-$default}"
    else
        read -r -p "$prompt: " answer || true
    fi
    REPLY="$answer"
}

confirm() {
    local prompt="$1" default="${2:-n}" answer="" hint
    if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "$prompt $hint: " answer || true
    answer="${answer:-$default}"
    case "$answer" in
        [yY]*) return 0 ;;
        *)     return 1 ;;
    esac
}

is_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

port_listening() {
    local port="$1"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
        || netstat -an 2>/dev/null | grep -qE "[.:]${port}[[:space:]].*LISTEN"
}

port_listening_on() {
    # 只有在该地址上监听才算命中（用于确认 OpenList 只绑了 127.0.0.1）
    local port="$1" addr="$2"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q "$addr"
}

wait_for_port() {
    local port="$1" timeout="${2:-30}" i=0
    while [ "$i" -lt "$timeout" ]; do
        port_listening "$port" && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# 读取 YAML 一级/二级标量：yaml_scalar <file> <key>
yaml_scalar() {
    local f="$1" k="$2"
    [ -f "$f" ] || return 1
    sed -nE "s/^[[:space:]]*${k}:[[:space:]]*(.*)$/\1/p" "$f" \
        | head -n1 | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]*$//'
}

# 读取 TOML 形如 a.b = "x" 的值：toml_value <file> <key>
toml_value() {
    local f="$1" k="$2" pat
    [ -f "$f" ] || return 1
    pat=$(printf '%s' "$k" | sed 's/\./\\./g')
    sed -nE "s/^[[:space:]]*${pat}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$f" \
        | head -n1
}

#-------------------------------------------------------------------------------
# 运行身份检查：必须是非 root 的普通用户
#-------------------------------------------------------------------------------
require_normal_user() {
    local u g
    u=$(id -un)
    g=$(id -gn)
    if [ "$(id -u)" -eq 0 ]; then
        log_err "检测到当前是 root（或用了 sudo 运行本脚本）"
        log_err "Homebrew 拒绝以 root 运行，而且以 root 跑 OpenList 对公网服务不安全"
        log_err "正确用法：bash ${SCRIPT_NAME}    （脚本内部需要提权时会自己调用 sudo）"
        exit 1
    fi
    RUN_USER="$u"
    RUN_GROUP="$g"
    log_ok "运行身份：${RUN_USER}（组 ${RUN_GROUP}）"
}

#-------------------------------------------------------------------------------
# 代理
#-------------------------------------------------------------------------------
probe_proxy() {
    local p code
    if [ "$PROXY_EXPLICIT" -eq 1 ]; then
        log_info "使用命令行指定的代理：$PROXY_URL"
        return 0
    fi
    for p in "${PROXY_PORT_CANDIDATES[@]}"; do
        nc -z 127.0.0.1 "$p" >/dev/null 2>&1 || continue
        # 端口开着不等于能当 HTTP 代理用：本机 hysteria 的 socks5(1080) 就是这种，
        # 它要账号密码、不接受裸 CONNECT，误判会让后面所有下载全失败。
        code=$(curl -s -o /dev/null -m 6 -x "http://127.0.0.1:${p}" -w '%{http_code}' \
               https://www.baidu.com 2>/dev/null) || code="000"
        if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
            PROXY_URL="http://127.0.0.1:${p}"
            log_ok "检测到可用代理：$PROXY_URL"
            return 0
        fi
        log_info "端口 ${p} 有监听但代理不可用（HTTP ${code}），跳过"
    done
    PROXY_URL=""
    log_warn "未检测到可用代理（常见端口都试过并实测验证）"
    return 1
}

apply_proxy_env() {
    if [ -n "$PROXY_URL" ]; then
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL"
        export HTTPS_PROXY="$PROXY_URL"
        export all_proxy="$PROXY_URL"
        export ALL_PROXY="$PROXY_URL"
        export no_proxy="127.0.0.1,localhost"
        export NO_PROXY="127.0.0.1,localhost"
        log_info "已为下载/Homebrew 设置代理环境变量"
    else
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    fi
}

# 带兜底的下载：代理 → 直连 → GitHub 加速站
gh_download() {
    local url="$1" dest="$2" t="${3:-600}" base

    if [ -n "$PROXY_URL" ]; then
        log_info "下载（经代理 $PROXY_URL）：$url"
        if curl -fSL --retry 2 --retry-delay 3 --max-time "$t" -o "$dest" "$url" 2>>"$LOG_FILE"; then
            return 0
        fi
        log_warn "经代理下载失败，改用直连/加速站重试"
    fi

    log_info "下载（直连）：$url"
    if curl -fSL --retry 2 --retry-delay 3 --max-time "$t" -o "$dest" "$url" 2>>"$LOG_FILE"; then
        return 0
    fi

    for base in "${GH_PROXY_CANDIDATES[@]}"; do
        log_info "下载（加速站 ${base}）：$url"
        if curl -fSL --retry 2 --retry-delay 3 --max-time "$t" -o "$dest" "${base}${url}" 2>>"$LOG_FILE"; then
            return 0
        fi
    done
    log_err "所有线路都下载失败：$url"
    return 1
}

#-------------------------------------------------------------------------------
# 状态文件
#-------------------------------------------------------------------------------
save_state() {
    sudo mkdir -p "$CONF_DIR" || die "无法创建目录：$CONF_DIR"
    sudo chown "$RUN_USER:$RUN_GROUP" "$CONF_DIR" 2>/dev/null || true
    sudo chmod 700 "$CONF_DIR" 2>/dev/null || true
    sudo tee "$STATE_FILE" >/dev/null <<EOF
STATE_VERSION=${STATE_VERSION}
RUN_USER=${RUN_USER}
SERVER_IP=${SERVER_IP}
PUBLIC_DOMAIN=${PUBLIC_DOMAIN}
HY2_SERVER_ADDR=${HY2_SERVER_ADDR}
HY2_PORT=${HY2_PORT}
SOCKS5_PORT=${SOCKS5_PORT}
FRP_REMOTE_PORT=${FRP_REMOTE_PORT}
OPENLIST_LOCAL_PORT=${OPENLIST_LOCAL_PORT}
OPENLIST_DATA=${OPENLIST_DATA}
FRP_VERSION=${FRP_VERSION}
PROXY_URL=${PROXY_URL}
EOF
    sudo chown "$RUN_USER:$RUN_GROUP" "$STATE_FILE" 2>/dev/null || true
    sudo chmod 600 "$STATE_FILE" 2>/dev/null || true
}

load_state() {
    [ -f "$STATE_FILE" ] || return 1
    local v
    v=$(state_get RUN_USER);           [ -n "$v" ] && RUN_USER="$v"
    v=$(state_get SERVER_IP);          [ -n "$v" ] && SERVER_IP="$v"
    v=$(state_get PUBLIC_DOMAIN);      [ -n "$v" ] && PUBLIC_DOMAIN="$v"
    v=$(state_get HY2_SERVER_ADDR);    [ -n "$v" ] && HY2_SERVER_ADDR="$v"
    v=$(state_get HY2_PORT);           [ -n "$v" ] && HY2_PORT="$v"
    v=$(state_get SOCKS5_PORT);        [ -n "$v" ] && SOCKS5_PORT="$v"
    v=$(state_get FRP_REMOTE_PORT);    [ -n "$v" ] && FRP_REMOTE_PORT="$v"
    v=$(state_get OPENLIST_LOCAL_PORT);[ -n "$v" ] && OPENLIST_LOCAL_PORT="$v"
    v=$(state_get OPENLIST_DATA);      [ -n "$v" ] && OPENLIST_DATA="$v"
    v=$(state_get FRP_VERSION);        [ -n "$v" ] && FRP_VERSION="$v"
    v=$(state_get PROXY_URL);          [ -n "$v" ] && PROXY_URL="$v"
    [ -z "$RUN_USER" ] && RUN_USER=$(id -un)
    [ -z "$RUN_GROUP" ] && RUN_GROUP=$(id -gn)
    return 0
}

state_get() {
    [ -f "$STATE_FILE" ] || return 1
    local line
    line=$(grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -n1) || return 1
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

#-------------------------------------------------------------------------------
# launchd 封装（现代 bootstrap/bootout，回退老式 load/unload）
#-------------------------------------------------------------------------------
launchd_is_loaded() {
    sudo launchctl print "system/$1" >/dev/null 2>&1
}

launchd_load() {
    local label="$1" plist="$2"
    launchd_is_loaded "$label" && return 0
    if sudo launchctl bootstrap system "$plist" >/dev/null 2>&1; then
        sudo launchctl enable "system/${label}" >/dev/null 2>&1 || true
        return 0
    fi
    sudo launchctl load -w "$plist" >/dev/null 2>&1
}

launchd_unload() {
    local label="$1" plist="$2"
    sudo launchctl bootout "system/${label}" >/dev/null 2>&1 \
        || sudo launchctl unload -w "$plist" >/dev/null 2>&1 || true
}

launchd_restart() {
    local label="$1"
    sudo launchctl kickstart -k "system/${label}" >/dev/null 2>&1 \
        || sudo launchctl stop "$label" >/dev/null 2>&1 || true
}

# 返回 "running(pid=N)" / "已安装但未运行" / "未安装"
#
# 注意：system 域的 LaunchDaemon 不会出现在普通用户的 `launchctl list` 里，
# 因此这里以「plist 是否存在 + 进程是否在跑」为准；只有在能免密 sudo 时才补问 launchd。
launchd_state() {
    local label="$1" plist="" pat="" pid="" out state
    case "$label" in
        # 注意：进程匹配必须带上各自的配置路径。两套脚本共用同一个 hysteria 二进制，
        # 只写 "hysteria client" 会把「国外下载那套」的进程误认成自己这套。
        "$LABEL_HY2")      plist="$PLIST_HY2";     pat="${HY2_BIN} client.*nas-tunnel" ;;
        "$LABEL_FRPC")     plist="$PLIST_FRPC";    pat="${FRPC_BIN} -c.*nas-tunnel" ;;
        "$LABEL_OPENLIST") plist="$PLIST_OPENLIST"; pat="${OPENLIST_BIN} server" ;;
    esac
    [ -f "$plist" ] || { echo "未安装"; return 0; }

    pid=$(pgrep -f "$pat" 2>/dev/null | head -n1)
    if [ -n "$pid" ]; then
        echo "running(pid=$pid)"
        return 0
    fi

    out=$(sudo -n launchctl print "system/${label}" 2>/dev/null) || out=""
    [ -n "$out" ] || { echo "已安装但未运行"; return 0; }
    state=$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*state = (.*)$/\1/p' | head -n1)
    echo "${state:-已安装但未运行}"
}

write_plist_header() {
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
EOF
}

install_plist() {
    local label="$1" tmp="$2" plist="$3"
    plutil -lint "$tmp" >/dev/null 2>&1 || die "plist 格式非法（$label），已中止"
    sudo cp "$tmp" "$plist" || die "写入 $plist 失败"
    sudo chown root:wheel "$plist"
    sudo chmod 644 "$plist"
    launchd_unload "$label" "$plist"
    launchd_load "$label" "$plist" || die "加载 launchd 服务失败：$label"
    log_ok "已写入并加载 launchd：${label}"
}

#-------------------------------------------------------------------------------
# 阶段 0：环境准备
#-------------------------------------------------------------------------------
phase0_env() {
    log_step "阶段 0/6：环境准备"

    [ "$(uname -s)" = "Darwin" ] || die "本脚本只能在 macOS 上运行（当前：$(uname -s)）"
    log_info "系统：macOS $(sw_vers -productVersion)（$(sw_vers -buildVersion)）"

    case "$(uname -m)" in
        arm64) ARCH_ASSET="arm64" ;;
        x86_64) ARCH_ASSET="amd64" ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
    log_ok "架构：$(uname -m) → 将使用 darwin-${ARCH_ASSET} 版本"

    has_cmd curl || die "缺少 curl"
    has_cmd tar  || die "缺少 tar"
    has_cmd ssh  || die "缺少 ssh（系统自带，请检查 PATH）"

    require_normal_user

    # sudo 预热：后面要多次用，先让用户输一次密码，并起一个保活子进程
    log_info "后续需要 sudo 权限（写入 /usr/local、/opt、/Library/LaunchDaemons）；请先授权"
    sudo -v || die "无法获得 sudo 权限"
    ( while true; do
          sudo -n true 2>/dev/null || exit
          kill -0 "$$" 2>/dev/null || exit
          sleep 50
      done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true' EXIT

    if probe_proxy; then :; fi
    apply_proxy_env

    [ -z "$PROXY_URL" ] && log_warn "没有可用代理时，GitHub 下载会走加速站兜底（可能较慢）"
    log_ok "环境准备完成"
}

#-------------------------------------------------------------------------------
# 阶段 1：拉取服务器侧对接包
#-------------------------------------------------------------------------------
prompt_server_ip() {
    local i=0 default="${SERVER_IP:-}"
    SERVER_IP=""
    while [ -z "$SERVER_IP" ]; do
        if [ "$i" -gt 0 ]; then
            log_warn "请输入形如 1.2.3.4 的公网 IP"
        fi
        ask "请输入国内服务器的公网 IP" "$default"
        case "$REPLY" in
            *[!0-9.]*|"") log_warn "格式不对：$REPLY" ;;
            *) if is_valid_ip "$REPLY"; then SERVER_IP="$REPLY"; else log_warn "格式不对：$REPLY"; fi ;;
        esac
        i=$((i + 1))
        [ "$i" -gt 5 ] && die "多次输入无效，已中止"
    done
    log_ok "服务器 IP：$SERVER_IP"
}

pull_bundle() {
    local tmp target

    log_info "将用 SSH 登录 ${SERVER_USER}@${SERVER_IP} 拉取对接包"
    log_info "（会提示输入服务器密码；只拉取 /root/nas-tunnel-mac-client/ 这一个目录）"

    tmp=$(mktemp -d) || die "无法创建临时目录"
    if ! scp -r -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
            "${SERVER_USER}@${SERVER_IP}:${SERVER_BUNDLE_DIR}" "${tmp}/" ; then
        rm -rf "$tmp"
        log_warn "拉取对接包失败"
        return 1
    fi

    target="${tmp}/$(basename "$SERVER_BUNDLE_DIR")"
    if [ ! -f "${target}/hysteria-client.yaml" ] || [ ! -f "${target}/frpc.toml" ]; then
        rm -rf "$tmp"
        log_warn "对接包内容不完整（缺 hysteria-client.yaml 或 frpc.toml）"
        return 1
    fi

    sudo mkdir -p "$CONF_DIR" /usr/local/bin "$LOG_DIR" || die "无法创建目录"
    # CONF_DIR 必须归运行用户所有：hysteria/frpc 是以该用户跑的，
    # 若目录是 root 独占的 700，它们连自己的配置都读不到（EACCES）。
    sudo chown "$RUN_USER:$RUN_GROUP" "$CONF_DIR" "$LOG_DIR"
    sudo chmod 700 "$CONF_DIR" 2>/dev/null || true

    sudo cp "${target}/hysteria-client.yaml" "$HY2_CLIENT_CONF" || die "写入配置失败"
    sudo cp "${target}/frpc.toml" "$FRPC_CONF" || die "写入配置失败"
    [ -f "${target}/README.md" ] && sudo cp "${target}/README.md" "$BUNDLE_README" || true

    # 配置里含密码/token，只给运行用户读写
    sudo chown "$RUN_USER:$RUN_GROUP" "$HY2_CLIENT_CONF" "$FRPC_CONF"
    sudo chmod 600 "$HY2_CLIENT_CONF" "$FRPC_CONF"
    [ -f "$BUNDLE_README" ] && sudo chmod 600 "$BUNDLE_README"

    rm -rf "$tmp"
    log_ok "对接包已就位：$CONF_DIR"
    return 0
}

parse_bundle() {
    local v

    v=$(yaml_scalar "$HY2_CLIENT_CONF" server)
    if [ -n "$v" ]; then
        HY2_SERVER_ADDR="$v"
        HY2_PORT="${v##*:}"
        [ -z "$HY2_PORT" ] && HY2_PORT="443"
    fi

    v=$(yaml_scalar "$HY2_CLIENT_CONF" auth); [ -n "$v" ] && HY2_PASSWORD="$v"
    v=$(yaml_scalar "$HY2_CLIENT_CONF" sni);  [ -n "$v" ] && PUBLIC_DOMAIN="$v"
    v=$(yaml_scalar "$HY2_CLIENT_CONF" insecure); [ -n "$v" ] && HY2_INSECURE="$v"

    v=$(yaml_scalar "$HY2_CLIENT_CONF" listen); [ -n "$v" ] && SOCKS5_LISTEN="$v"
    SOCKS5_PORT="${SOCKS5_LISTEN##*:}"
    v=$(yaml_scalar "$HY2_CLIENT_CONF" username); [ -n "$v" ] && SOCKS5_USER="$v"
    v=$(yaml_scalar "$HY2_CLIENT_CONF" password); [ -n "$v" ] && SOCKS5_PASS="$v"

    v=$(toml_value "$FRPC_CONF" "auth.token");        [ -n "$v" ] && FRP_TOKEN="$v"
    v=$(toml_value "$FRPC_CONF" "serverPort");        [ -n "$v" ] && FRP_SERVER_PORT="$v"
    v=$(toml_value "$FRPC_CONF" "remotePort");        [ -n "$v" ] && FRP_REMOTE_PORT="$v"
    v=$(toml_value "$FRPC_CONF" "localPort");         [ -n "$v" ] && OPENLIST_LOCAL_PORT="$v"

    # frp 版本从对接包 README 里抠（服务器脚本会把真实版本号写进去）
    if [ -f "$BUNDLE_README" ]; then
        v=$(grep -oE 'frp_[0-9]+\.[0-9]+\.[0-9]+_darwin_' "$BUNDLE_README" 2>/dev/null | head -n1 \
            | sed -E 's/^frp_([0-9.]+)_darwin_$/\1/')
        [ -n "$v" ] && FRP_VERSION="$v"
    fi
    [ -z "$FRP_VERSION" ] && FRP_VERSION="$FRP_VERSION_FALLBACK"

    if [ -z "$PUBLIC_DOMAIN" ] || [ -z "$HY2_PASSWORD" ] || [ -z "$FRP_TOKEN" ]; then
        log_warn "对接包里缺少关键字段（域名/HY2 密码/frp token）"
        return 1
    fi
    log_ok "已解析：域名=${PUBLIC_DOMAIN}  HY2=${HY2_SERVER_ADDR}  socks5=127.0.0.1:${SOCKS5_PORT}  远端端口=${FRP_REMOTE_PORT}  frp=${FRP_VERSION}"
    return 0
}

# 拉不到对接包时的兜底：手工输入参数并按服务器端同样的格式生成配置
prompt_params_manually() {
    log_warn "进入手工输入模式（这些值可在服务器上执行 deploy-nas-tunnel.sh --status 查到）"

    ask "Hysteria2 UDP 端口" "443"
    HY2_PORT="${REPLY:-443}"

    ask "Hysteria2 密码" ""
    HY2_PASSWORD="$REPLY"
    [ -n "$HY2_PASSWORD" ] || die "Hysteria2 密码不能为空"

    ask "域名 / TLS SNI" ""
    PUBLIC_DOMAIN="$REPLY"
    [ -n "$PUBLIC_DOMAIN" ] || die "域名不能为空"

    ask "frp token" ""
    FRP_TOKEN="$REPLY"
    [ -n "$FRP_TOKEN" ] || die "frp token 不能为空"

    ask "frps 控制口（服务器侧，仅回环）" "7000"
    FRP_SERVER_PORT="${REPLY:-7000}"

    ask "远端映射端口（服务器侧）" "15244"
    FRP_REMOTE_PORT="${REPLY:-15244}"

    ask "Mac 上 OpenList 端口" "$OPENLIST_PORT_DEFAULT"
    OPENLIST_LOCAL_PORT="${REPLY:-$OPENLIST_PORT_DEFAULT}"

    ask "Mac 端 socks5 入站端口" "1080"
    SOCKS5_PORT="${REPLY:-1080}"

    ask "socks5 用户名" ""
    SOCKS5_USER="$REPLY"

    ask "socks5 密码" ""
    SOCKS5_PASS="$REPLY"

    if confirm "服务器是否已降级为自签证书（即 tls.insecure 需要设 true）？" n; then
        HY2_INSECURE="true"
    else
        HY2_INSECURE="false"
    fi

    HY2_SERVER_ADDR="${SERVER_IP}:${HY2_PORT}"
    SOCKS5_LISTEN="127.0.0.1:${SOCKS5_PORT}"
    [ -n "$FRP_VERSION" ] || FRP_VERSION="$FRP_VERSION_FALLBACK"

    log_ok "参数已录入：域名=${PUBLIC_DOMAIN}  HY2=${HY2_SERVER_ADDR}  远端端口=${FRP_REMOTE_PORT}  OpenList=127.0.0.1:${OPENLIST_LOCAL_PORT}"
}

generate_configs_from_params() {
    local proxyline=""
    [ -n "$SOCKS5_USER" ] && proxyline="${SOCKS5_USER}:${SOCKS5_PASS}@"

    sudo mkdir -p "$CONF_DIR" "$LOG_DIR" /usr/local/bin || die "无法创建目录"
    sudo chown "$RUN_USER:$RUN_GROUP" "$CONF_DIR" "$LOG_DIR"
    sudo chmod 700 "$CONF_DIR" 2>/dev/null || true

    sudo tee "$HY2_CLIENT_CONF" >/dev/null <<EOF
# Mac mini 端 —— Hysteria2 客户端配置
# 由 ${SCRIPT_NAME} 的「手工输入模式」生成（未能从服务器拉到对接包）
server: ${HY2_SERVER_ADDR}
auth: ${HY2_PASSWORD}

tls:
  # 必须与服务器端证书的域名一致（服务器开了 sniGuard: strict）
  sni: ${PUBLIC_DOMAIN}
  insecure: ${HY2_INSECURE}

# 给本机 frpc 用的 socks5 入站
socks5:
  listen: ${SOCKS5_LISTEN}
  username: ${SOCKS5_USER}
  password: ${SOCKS5_PASS}

# 不写 bandwidth 会退回 BBR，拿不到 Brutal 的抗丢包/抢带宽效果
bandwidth:
  up: 50 mbps
  down: 1000 mbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

    sudo tee "$FRPC_CONF" >/dev/null <<EOF
# Mac mini 端 —— frpc 反向隧道客户端配置
# 由 ${SCRIPT_NAME} 的「手工输入模式」生成（未能从服务器拉到对接包）
#
# serverAddr 必须是 127.0.0.1，由 transport.proxyURL 交给 Hysteria2 的 socks5，
# 最终由服务器端 HY2 在服务器本机拨号到 frps —— 这样公网段只有 UDP。
serverAddr = "127.0.0.1"
serverPort = ${FRP_SERVER_PORT}
loginFailExit = false

auth.method = "token"
auth.token = "${FRP_TOKEN}"

transport.proxyURL = "socks5://${proxyline}127.0.0.1:${SOCKS5_PORT}"
transport.tcpMux = true
transport.tls.enable = false

log.to = "${LOG_DIR}/frpc.log"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true

[[proxies]]
name = "openlist"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${OPENLIST_LOCAL_PORT}
remotePort = ${FRP_REMOTE_PORT}
EOF

    sudo chown "$RUN_USER:$RUN_GROUP" "$HY2_CLIENT_CONF" "$FRPC_CONF"
    sudo chmod 600 "$HY2_CLIENT_CONF" "$FRPC_CONF"
    log_ok "已按手工输入生成配置：$CONF_DIR"
}

phase1_params() {
    log_step "阶段 1/6：拉取服务器侧对接包"

    # 重复执行时，用上次记录的服务器 IP 作为默认值（不覆盖命令行显式指定的）
    if [ -z "$SERVER_IP" ] && [ -f "$STATE_FILE" ]; then
        local v
        v=$(state_get SERVER_IP 2>/dev/null) && [ -n "$v" ] && SERVER_IP="$v"
    fi

    prompt_server_ip

    if pull_bundle && parse_bundle; then
        log_ok "参数已从服务器对接包获取"
        return 0
    fi

    log_err "无法从服务器获取有效对接包"
    log_err "请确认：服务器已跑过 deploy-nas-tunnel.sh，且 ${SERVER_USER}@${SERVER_IP}:${SERVER_BUNDLE_DIR} 存在"
    log_err "（该目录由服务器脚本在阶段 6 生成；也可能是 IP / 密码输错，或 SSH 被挡）"
    log_raw ""
    if ! confirm "是否改为手工输入参数（脚本会按同样格式生成配置）？" n; then
        die "已取消。建议先确认服务器侧部署与 SSH 连通性后重试"
    fi
    prompt_params_manually
    generate_configs_from_params
}

#-------------------------------------------------------------------------------
# 阶段 2：部署 OpenList
#-------------------------------------------------------------------------------
ensure_homebrew() {
    if [ -x "$BREW_BIN" ]; then
        log_ok "Homebrew 已安装：$("$BREW_BIN" --version 2>/dev/null | head -n1)"
        return 0
    fi
    if [ "$SKIP_BREW" -eq 1 ]; then
        log_warn "已指定 --skip-brew，跳过 Homebrew 安装"
        return 1
    fi

    log_warn "未检测到 Homebrew（openlist 用 brew 安装）"
    if ! confirm "是否现在安装 Homebrew？（官方脚本，需 sudo，走当前代理）" y; then
        die "已取消。可自行安装 Homebrew 后重跑，或加 --skip-brew 只部署隧道"
    fi

    log_info "正在下载并执行 Homebrew 官方安装脚本（NONINTERACTIVE=1）..."
    if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL --max-time 120 "$BREW_INSTALL_URL")" >>"$LOG_FILE" 2>&1; then
        die "Homebrew 安装失败，详情见 $LOG_FILE（国内网络请确认代理可用）"
    fi
    [ -x "$BREW_BIN" ] || die "Homebrew 安装后仍找不到 $BREW_BIN"
    log_ok "Homebrew 安装完成：$("$BREW_BIN" --version 2>/dev/null | head -n1)"
    return 0
}

brew_install_openlist() {
    if has_cmd openlist || [ -x "$OPENLIST_BIN" ]; then
        local cur
        cur=$("$OPENLIST_BIN" version 2>/dev/null | head -n1 || true)
        log_ok "OpenList 已安装：${cur:-未知版本}"
        return 0
    fi

    log_info "正在执行 brew install openlist ..."
    if ! "$BREW_BIN" install openlist >>"$LOG_FILE" 2>&1; then
        log_err "brew install openlist 失败，最近日志："
        tail -n 20 "$LOG_FILE" | sed 's/^/      /'
        return 1
    fi
    [ -x "$OPENLIST_BIN" ] || return 1
    log_ok "OpenList 安装完成：$("$OPENLIST_BIN" version 2>/dev/null | head -n1)"
    return 0
}

# 定位 openlist 可执行文件（brew 前缀可能不是 /opt/homebrew，比如 Intel 机是 /usr/local）
resolve_openlist_bin() {
    local p
    if [ -x "$BREW_BIN" ]; then
        p=$("$BREW_BIN" --prefix 2>/dev/null)
        if [ -n "$p" ] && [ -x "${p}/bin/openlist" ]; then
            OPENLIST_BIN="${p}/bin/openlist"
            BREW_PREFIX="$p"
            return 0
        fi
    fi
    for p in /opt/homebrew/bin/openlist /usr/local/bin/openlist; do
        [ -x "$p" ] && { OPENLIST_BIN="$p"; return 0; }
    done
    if has_cmd openlist; then
        OPENLIST_BIN="$(command -v openlist)"
        return 0
    fi
    return 1
}

# 把 OpenList 的监听地址从默认 0.0.0.0 改成 127.0.0.1（默认值见 internal/conf/config.go）
patch_openlist_config() {
    local cfg="$1" before after

    [ -f "$cfg" ] || return 1

    # 取 scheme.address 的当前值。
    # 同时兼容「每行一个键」与「整份 JSON 压成一行」两种写法：
    # 前置字符不能是下划线/字母数字，避免误命中 proxy_address。
    before=$(sed -nE 's/.*[^_[:alnum:]]"address"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$cfg" | head -n1)
    if [ -z "$before" ]; then
        before=$(sed -nE 's/^[[:space:]]*"address"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$cfg" | head -n1)
    fi

    if [ "$before" = "127.0.0.1" ]; then
        log_ok "OpenList 已只监听 127.0.0.1"
        return 0
    fi
    if [ -z "$before" ]; then
        log_warn "未能在 $cfg 中找到 scheme.address，请手工确认监听地址是 127.0.0.1"
        return 1
    fi

    sed -i '' -E 's/([^_[:alnum:]])"address"([[:space:]]*:[[:space:]]*)"[^"]*"/\1"address"\2"127.0.0.1"/' "$cfg"
    sed -i '' -E 's/^([[:space:]]*)"address"([[:space:]]*:[[:space:]]*)"[^"]*"/\1"address"\2"127.0.0.1"/' "$cfg"

    after=$(sed -nE 's/.*[^_[:alnum:]]"address"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$cfg" | head -n1)
    if [ "$after" = "127.0.0.1" ]; then
        log_ok "已把 OpenList 监听地址 ${before} → 127.0.0.1（避免局域网绕过隧道直连）"
        return 0
    fi
    log_warn "自动改写监听地址失败（当前：${after:-未知}），请手工把 $cfg 里的 address 改成 127.0.0.1"
    return 1
}

# 首次启动一次，让它生成 config.json 并打印初始管理员密码，然后停掉
openlist_first_run() {
    local log="$1" i=0 cfg="${OPENLIST_DATA}/config.json"

    log_info "首次启动 OpenList（用于生成配置与初始管理员密码，稍后会停掉再交给 launchd）"
    OPENLIST_ADDR=127.0.0.1 "$OPENLIST_BIN" server --data "$OPENLIST_DATA" --log-std \
        >"$log" 2>&1 &
    local pid=$!

    while [ "$i" -lt 60 ]; do
        [ -f "$cfg" ] && break
        sleep 1
        i=$((i + 1))
    done

    if [ ! -f "$cfg" ]; then
        kill "$pid" >/dev/null 2>&1 || true
        log_warn "等待 config.json 超时（${cfg}），首次启动日志："
        tail -n 15 "$log" 2>/dev/null | sed 's/^/      /'
        return 1
    fi

    # 等它把端口也拉起来，确认能正常服务
    wait_for_port "$OPENLIST_PORT_DEFAULT" 30 || log_warn "首次启动未在 ${OPENLIST_PORT_DEFAULT} 上就绪"

    kill "$pid" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 15 ] && kill -0 "$pid" >/dev/null 2>&1; do
        sleep 1
        i=$((i + 1))
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
    sleep 1
    log_ok "OpenList 配置已生成：$cfg"
    return 0
}

extract_openlist_password() {
    local log="$1" line pwd
    # 源码 internal/bootstrap/data/user.go 用 fmt.Printf 输出到 stdout：
    #   Successfully created the admin user and the initial password is: XXXXX
    line=$(grep -F 'initial password is:' "$log" 2>/dev/null | tail -n1)
    [ -n "$line" ] || return 1
    pwd=$(printf '%s' "$line" | sed -E 's/.*initial password is:[[:space:]]*//' | tr -d '\r' | sed -E 's/[[:space:]]+$//')
    [ -n "$pwd" ] || return 1
    printf '%s' "$pwd"
}

write_openlist_plist() {
    local tmp
    tmp=$(mktemp) || die "无法创建临时文件"
    write_plist_header > "$tmp"
    cat >> "$tmp" <<EOF
	<key>Label</key>
	<string>${LABEL_OPENLIST}</string>

	<key>ProgramArguments</key>
	<array>
		<string>${OPENLIST_BIN}</string>
		<string>server</string>
		<string>--data</string>
		<string>${OPENLIST_DATA}</string>
		<string>--log-std</string>
	</array>

	<key>UserName</key>
	<string>${RUN_USER}</string>
	<key>WorkingDirectory</key>
	<string>$(dirname "$OPENLIST_DATA")</string>

	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>

	<key>StandardOutPath</key>
	<string>${LOG_DIR}/openlist.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/openlist.log</string>
</dict>
</plist>
EOF
    install_plist "$LABEL_OPENLIST" "$tmp" "$PLIST_OPENLIST"
    rm -f "$tmp"
}

phase2_openlist() {
    log_step "阶段 2/6：部署 OpenList"

    if [ "$SKIP_BREW" -eq 0 ]; then
        if ensure_homebrew; then
            brew_install_openlist || die "OpenList 安装失败（brew install openlist）"
        else
            log_warn "跳过 Homebrew，改为依赖你已装好的 openlist"
        fi
    fi
    resolve_openlist_bin \
        || die "找不到 openlist 可执行文件；请先 brew install openlist，或用 --skip-brew 配合自装版本"

    sudo mkdir -p "$OPENLIST_DATA" "$LOG_DIR" || die "无法创建目录"
    sudo chown -R "$RUN_USER:$RUN_GROUP" "$OPENLIST_DATA"
    sudo chown "$RUN_USER:$RUN_GROUP" "$LOG_DIR"
    sudo chmod 700 "$OPENLIST_DATA" 2>/dev/null || true

    local first_log="${LOG_DIR}/openlist-firstrun.log"
    local cfg="${OPENLIST_DATA}/config.json"

    if [ -f "$cfg" ]; then
        log_info "检测到既有 OpenList 配置（$cfg），跳过首次初始化"
        patch_openlist_config "$cfg" || true
    else
        openlist_first_run "$first_log" || log_warn "首次启动未完全成功，继续尝试"
        [ -f "$cfg" ] && patch_openlist_config "$cfg" || true
    fi

    write_openlist_plist

    if wait_for_port "$OPENLIST_PORT_DEFAULT" 45; then
        if port_listening_on "$OPENLIST_PORT_DEFAULT" "127.0.0.1"; then
            log_ok "OpenList 已就绪：http://127.0.0.1:${OPENLIST_PORT_DEFAULT}/（只监听回环）"
        else
            log_warn "OpenList 在 ${OPENLIST_PORT_DEFAULT} 上就绪，但监听地址看起来不是 127.0.0.1，请检查 $cfg"
        fi
    else
        log_warn "OpenList 尚未在 ${OPENLIST_PORT_DEFAULT} 上就绪，日志：${LOG_DIR}/openlist.log"
    fi

    # 抓取初始管理员密码（只在首次启动出现）
    local pwd=""
    for f in "$first_log" "${LOG_DIR}/openlist.log"; do
        [ -f "$f" ] || continue
        pwd=$(extract_openlist_password "$f" 2>/dev/null) && break
    done
    if [ -n "$pwd" ]; then
        OPENLIST_INITIAL_PASSWORD="$pwd"
        log_ok "OpenList 初始管理员密码：${C_BOLD}${pwd}${C_RESET}"
        log_info "（该密码只在首次启动输出一次；已存到 ${CONF_DIR}/openlist-initial-password.txt）"
        sudo mkdir -p "$CONF_DIR"
        printf '%s\n' "$pwd" | sudo tee "${CONF_DIR}/openlist-initial-password.txt" >/dev/null
        sudo chown "$RUN_USER:$RUN_GROUP" "${CONF_DIR}/openlist-initial-password.txt"
        sudo chmod 600 "${CONF_DIR}/openlist-initial-password.txt"
    else
        log_warn "未能从日志里抓到初始管理员密码（可能不是首次启动）"
        log_info "可执行：${OPENLIST_BIN} admin random --data ${OPENLIST_DATA}   # 重置为随机密码并打印"
        log_info "或执行：${OPENLIST_BIN} admin set <新密码> --data ${OPENLIST_DATA}"
    fi
}

#-------------------------------------------------------------------------------
# 阶段 3：下载隧道二进制
#-------------------------------------------------------------------------------
phase3_tunnel_binaries() {
    log_step "阶段 3/6：下载 hysteria / frpc（darwin-${ARCH_ASSET}）"

    local tmp
    tmp=$(mktemp -d) || die "无法创建临时目录"

    # hysteria（同一二进制既可做服务端也可做客户端）
    if [ -x "$HY2_BIN" ]; then
        log_ok "hysteria 已存在：$("$HY2_BIN" version 2>/dev/null | head -n1)"
    else
        local hurl="${HYSTERIA_RELEASE_BASE}/hysteria-darwin-${ARCH_ASSET}"
        gh_download "$hurl" "${tmp}/hysteria" 600 || die "下载 hysteria 失败（可加 -p 指定代理）"
        chmod +x "${tmp}/hysteria"
        "${tmp}/hysteria" version >/dev/null 2>&1 || die "下载的 hysteria 无法运行"
        sudo mkdir -p /usr/local/bin
        sudo install -m 755 "${tmp}/hysteria" "$HY2_BIN" || die "安装 hysteria 失败"
        log_ok "hysteria 安装完成：$("$HY2_BIN" version 2>/dev/null | head -n1)"
    fi

    # frpc（版本与服务器 frps 保持一致）
    if [ -x "$FRPC_BIN" ]; then
        log_ok "frpc 已存在：$("$FRPC_BIN" --version 2>/dev/null | head -n1)"
    else
        local inner="frp_${FRP_VERSION}_darwin_${ARCH_ASSET}"
        local tarball="${tmp}/frp.tar.gz"
        local url="${FRP_REPO}/releases/download/v${FRP_VERSION}/${inner}.tar.gz"
        gh_download "$url" "$tarball" 600 || die "下载 frp v${FRP_VERSION} 失败（可用服务器同版本号核对）"
        tar -xzf "$tarball" -C "$tmp" >>"$LOG_FILE" 2>&1 || die "解压 frp 失败"
        [ -f "${tmp}/${inner}/frpc" ] || die "frp 包结构异常，未找到 ${inner}/frpc"
        sudo mkdir -p /usr/local/bin
        sudo install -m 755 "${tmp}/${inner}/frpc" "$FRPC_BIN" || die "安装 frpc 失败"
        log_ok "frpc 安装完成：$("$FRPC_BIN" --version 2>/dev/null | head -n1)"
    fi

    rm -rf "$tmp"
}

#-------------------------------------------------------------------------------
# 阶段 4：写配置（修正日志路径）
#-------------------------------------------------------------------------------
fix_config_log_paths() {
    # 服务器生成的 frpc.toml 里 log.to = /var/log/frpc.log，
    # 而以普通用户运行写不了 /var/log，这里统一改到用户可写目录。
    if grep -qE '^[[:space:]]*log\.to[[:space:]]*=' "$FRPC_CONF" 2>/dev/null; then
        sudo sed -i '' -E "s|^([[:space:]]*log\.to[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"${LOG_DIR}/frpc.log\"|" "$FRPC_CONF"
        if grep -q "log.to = \"${LOG_DIR}/frpc.log\"" "$FRPC_CONF"; then
            log_ok "frpc 日志路径已改写为 ${LOG_DIR}/frpc.log"
        else
            log_info "frpc 日志路径已在 ${LOG_DIR}（或服务器模板已不含 log.to）"
        fi
    fi
}

verify_configs() {
    local sni insecure
    sni=$(yaml_scalar "$HY2_CLIENT_CONF" sni)
    insecure=$(yaml_scalar "$HY2_CLIENT_CONF" insecure)

    [ -n "$sni" ] || die "hysteria 配置缺少 tls.sni"
    if [ "$sni" != "$PUBLIC_DOMAIN" ]; then
        log_warn "配置里的 sni(${sni}) 与对接包域名(${PUBLIC_DOMAIN}) 不一致，请核对"
    fi
    case "$insecure" in
        true) log_warn "tls.insecure = true（服务器是自签降级模式，属预期）" ;;
        *)    log_ok "tls.insecure = false，将校验证书链" ;;
    esac

    grep -qE '^[[:space:]]*serverAddr[[:space:]]*=[[:space:]]*"127\.0\.0\.1"' "$FRPC_CONF" \
        || log_warn "frpc.toml 的 serverAddr 不是 127.0.0.1 —— 这会让 frpc 绕过隧道直连服务器，请检查对接包"

    if [ -n "$OPENLIST_LOCAL_PORT" ] && [ "$OPENLIST_LOCAL_PORT" != "$OPENLIST_PORT_DEFAULT" ]; then
        log_warn "对接包里的 OpenList 端口是 ${OPENLIST_LOCAL_PORT}，而本脚本按 ${OPENLIST_PORT_DEFAULT} 做健康检查"
        log_warn "若你确实改过 OpenList 端口，请同步调整服务器侧反代目标与 frpc 的 localPort"
    fi

    log_ok "配置检查完成"
}

phase4_configs() {
    log_step "阶段 4/6：写入并校正配置"

    [ -f "$HY2_CLIENT_CONF" ] || die "缺少 $HY2_CLIENT_CONF"
    [ -f "$FRPC_CONF" ] || die "缺少 $FRPC_CONF"

    fix_config_log_paths
    verify_configs
}

#-------------------------------------------------------------------------------
# 阶段 5：写入 launchd（三个服务开机自启）
#-------------------------------------------------------------------------------
write_hysteria_plist() {
    local tmp
    tmp=$(mktemp) || die "无法创建临时文件"
    write_plist_header > "$tmp"
    cat >> "$tmp" <<EOF
	<key>Label</key>
	<string>${LABEL_HY2}</string>

	<key>ProgramArguments</key>
	<array>
		<string>${HY2_BIN}</string>
		<string>client</string>
		<string>--config</string>
		<string>${HY2_CLIENT_CONF}</string>
	</array>

	<key>UserName</key>
	<string>${RUN_USER}</string>

	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>

	<key>StandardOutPath</key>
	<string>${LOG_DIR}/hysteria.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/hysteria.log</string>
</dict>
</plist>
EOF
    install_plist "$LABEL_HY2" "$tmp" "$PLIST_HY2"
    rm -f "$tmp"
}

write_frpc_plist() {
    local tmp
    tmp=$(mktemp) || die "无法创建临时文件"
    write_plist_header > "$tmp"
    cat >> "$tmp" <<EOF
	<key>Label</key>
	<string>${LABEL_FRPC}</string>

	<key>ProgramArguments</key>
	<array>
		<string>${FRPC_BIN}</string>
		<string>-c</string>
		<string>${FRPC_CONF}</string>
	</array>

	<key>UserName</key>
	<string>${RUN_USER}</string>

	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>

	<key>StandardOutPath</key>
	<string>${LOG_DIR}/frpc.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/frpc.log</string>
</dict>
</plist>
EOF
    install_plist "$LABEL_FRPC" "$tmp" "$PLIST_FRPC"
    rm -f "$tmp"
}

phase5_launchd() {
    log_step "阶段 5/6：写入 launchd（开机自启 + 挂掉自动拉起）"

    sudo mkdir -p "$LAUNCHD_DIR" "$LOG_DIR"
    sudo chown "$RUN_USER:$RUN_GROUP" "$LOG_DIR"

    log_info "先起隧道（hysteria → frpc），再起 OpenList"
    write_hysteria_plist
    sleep 2
    write_frpc_plist
    write_openlist_plist

    local i=0
    while [ "$i" -lt 20 ]; do
        port_listening "$SOCKS5_PORT" && break
        sleep 1
        i=$((i + 1))
    done
    if port_listening "$SOCKS5_PORT"; then
        log_ok "hysteria socks5 入站已就绪：127.0.0.1:${SOCKS5_PORT}"
    else
        log_warn "hysteria socks5 入站未就绪，日志：${LOG_DIR}/hysteria.log"
    fi

    # 上面重写 OpenList 的 plist 会让它重启一次（有意为之：先隧道后 OpenList），
    # 这里等它回来再进自检，避免自检撞上重启窗口。
    wait_for_port "$OPENLIST_PORT_DEFAULT" 30 \
        || log_warn "OpenList 重启后未在 ${OPENLIST_PORT_DEFAULT} 上就绪，日志：${LOG_DIR}/openlist.log"
}

#-------------------------------------------------------------------------------
# 阶段 6：自检与汇总
#-------------------------------------------------------------------------------
socks5_url() {
    if [ -n "$SOCKS5_USER" ]; then
        printf 'socks5h://%s:%s@127.0.0.1:%s' "$SOCKS5_USER" "$SOCKS5_PASS" "$SOCKS5_PORT"
    else
        printf 'socks5h://127.0.0.1:%s' "$SOCKS5_PORT"
    fi
}

selftest_tunnel() {
    log_info "自检 1/4：Hysteria2 隧道层（经隧道访问外网）..."
    local code
    code=$(curl -s -o /dev/null --max-time 25 -w '%{http_code}' -x "$(socks5_url)" https://www.baidu.com 2>/dev/null) || code="000"
    if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
        log_ok "隧道层正常（经隧道访问外网返回 HTTP $code）"
        return 0
    fi
    log_err "隧道层自检失败（HTTP $code）"
    log_err "常见原因：服务器安全组没放行 UDP ${HY2_PORT}；或 tls.sni / 密码不对"
    [ -f "${LOG_DIR}/hysteria.log" ] && tail -n 15 "${LOG_DIR}/hysteria.log" | sed 's/^/      /'
    return 1
}

selftest_openlist() {
    log_info "自检 2/4：OpenList 本机服务..."
    local code
    code=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "http://127.0.0.1:${OPENLIST_PORT_DEFAULT}/" 2>/dev/null) || code="000"
    if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
        log_ok "OpenList 正常（HTTP $code）"
        return 0
    fi
    log_err "OpenList 无响应（HTTP $code），日志：${LOG_DIR}/openlist.log"
    return 1
}

selftest_frpc() {
    log_info "自检 3/4：frpc 反向映射登记..."
    local i=0
    while [ "$i" -lt 20 ]; do
        if grep -qi 'start proxy success' "${LOG_DIR}/frpc.log" 2>/dev/null; then
            log_ok "frpc 已登记反向映射（start proxy success）"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    log_err "frpc 未登记反向映射，日志：${LOG_DIR}/frpc.log"
    [ -f "${LOG_DIR}/frpc.log" ] && tail -n 15 "${LOG_DIR}/frpc.log" | sed 's/^/      /'
    return 1
}

selftest_public() {
    [ -n "$PUBLIC_DOMAIN" ] || return 0
    log_info "自检 4/4：公网入口 https://${PUBLIC_DOMAIN}/ ..."
    local code i=0
    while [ "$i" -lt 3 ]; do
        code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://${PUBLIC_DOMAIN}/" 2>/dev/null) || code="000"
        [[ "$code" =~ ^[123][0-9][0-9]$ ]] && break
        sleep 2
        i=$((i + 1))
    done
    if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
        log_ok "公网入口正常：https://${PUBLIC_DOMAIN}/ 返回 HTTP $code"
        return 0
    fi
    log_err "公网入口异常（HTTP $code）"
    log_err "若返回 502，说明服务器侧正常但 frpc 未登记成功；若超时，检查 DNS 与服务器 Caddy"
    return 1
}

run_selftests() {
    local ok=0
    selftest_tunnel || ok=1
    selftest_openlist || ok=1
    selftest_frpc || ok=1
    selftest_public || ok=1
    return "$ok"
}

print_summary() {
    log_raw ""
    log_raw "${C_GREEN}${C_BOLD}════════════════ Mac 端部署完成 ════════════════${C_RESET}"
    log_raw ""
    log_raw "  公网入口   ： ${C_BOLD}https://${PUBLIC_DOMAIN}/${C_RESET}"
    log_raw "  服务器     ： ${SERVER_IP}（UDP ${HY2_PORT}）"
    log_raw "  OpenList   ： http://127.0.0.1:${OPENLIST_PORT_DEFAULT}/（数据目录 ${OPENLIST_DATA}）"
    if [ -n "$OPENLIST_INITIAL_PASSWORD" ]; then
        log_raw "  OpenList 初始管理员密码 ： ${C_BOLD}${OPENLIST_INITIAL_PASSWORD}${C_RESET}"
        log_raw "             （也存于 ${CONF_DIR}/openlist-initial-password.txt）"
    fi
    log_raw ""
    log_raw "${C_BOLD}三个开机自启服务（launchd）：${C_RESET}"
    log_raw "  ${LABEL_OPENLIST} : $(launchd_state "$LABEL_OPENLIST")"
    log_raw "  ${LABEL_HY2} : $(launchd_state "$LABEL_HY2")"
    log_raw "  ${LABEL_FRPC} : $(launchd_state "$LABEL_FRPC")"
    log_raw ""
    log_raw "${C_BOLD}文件位置：${C_RESET}"
    log_raw "  配置目录   ： ${CONF_DIR}/"
    log_raw "  运行日志   ： ${LOG_DIR}/"
    log_raw "  hysteria   ： ${HY2_BIN}    frpc：${FRPC_BIN}"
    log_raw "  OpenList   ： ${OPENLIST_BIN}"
    log_raw ""
    log_raw "${C_BOLD}常用运维命令：${C_RESET}"
    log_raw "  sudo launchctl print system/${LABEL_OPENLIST}"
    log_raw "  sudo launchctl print system/${LABEL_HY2}"
    log_raw "  sudo launchctl print system/${LABEL_FRPC}"
    log_raw "  tail -f ${LOG_DIR}/openlist.log ${LOG_DIR}/hysteria.log ${LOG_DIR}/frpc.log"
    log_raw "  bash ${SCRIPT_NAME} --status"
    log_raw "  bash ${SCRIPT_NAME} --self-test-only"
    log_raw "  bash ${SCRIPT_NAME} --uninstall"
}

phase6_summary() {
    log_step "阶段 6/6：端到端自检与汇总"

    save_state

    if run_selftests; then
        log_ok "四项自检全部通过"
    else
        log_warn "自检未全部通过，请按上面的提示排查；服务与配置均已保留，可增量修复"
    fi

    print_summary
}

#-------------------------------------------------------------------------------
# --status
#-------------------------------------------------------------------------------
do_status() {
    [ -f "$STATE_FILE" ] || log_warn "未找到状态文件（$STATE_FILE），部分信息可能缺失"
    load_state || true

    log_step "NAS 反向隧道 Mac 端当前状态"

    log_raw "  服务状态（launchd）  ："
    log_raw "    ${LABEL_OPENLIST} : $(launchd_state "$LABEL_OPENLIST")"
    log_raw "    ${LABEL_HY2} : $(launchd_state "$LABEL_HY2")"
    log_raw "    ${LABEL_FRPC} : $(launchd_state "$LABEL_FRPC")"
    log_raw ""
    log_raw "  端口监听  ："
    if port_listening "$OPENLIST_PORT_DEFAULT"; then
        if port_listening_on "$OPENLIST_PORT_DEFAULT" "127.0.0.1"; then
            log_raw "    OpenList  ${OPENLIST_PORT_DEFAULT} : ${C_GREEN}127.0.0.1 监听中${C_RESET}"
        else
            log_raw "    OpenList  ${OPENLIST_PORT_DEFAULT} : ${C_YELLOW}监听中，但地址不是 127.0.0.1${C_RESET}"
        fi
    else
        log_raw "    OpenList  ${OPENLIST_PORT_DEFAULT} : ${C_RED}未监听${C_RESET}"
    fi
    if port_listening "$SOCKS5_PORT"; then
        log_raw "    hysteria  ${SOCKS5_PORT} : ${C_GREEN}监听中${C_RESET}"
    else
        log_raw "    hysteria  ${SOCKS5_PORT} : ${C_RED}未监听${C_RESET}"
    fi

    log_raw ""
    log_raw "  参数  ："
    log_raw "    服务器      ： ${SERVER_IP:-未知}（UDP ${HY2_PORT:-未知}）"
    log_raw "    域名        ： ${PUBLIC_DOMAIN:-未知}"
    log_raw "    远端端口    ： ${FRP_REMOTE_PORT:-未知}"
    log_raw "    OpenList 数据目录 ： ${OPENLIST_DATA:-未知}"
    log_raw "    frp 版本    ： ${FRP_VERSION:-未知}"

    if [ -n "$PUBLIC_DOMAIN" ]; then
        local code
        code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "https://${PUBLIC_DOMAIN}/" 2>/dev/null) || code="000"
        log_raw ""
        if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
            log_ok "链路在线：https://${PUBLIC_DOMAIN}/ 返回 HTTP $code"
        else
            log_warn "https://${PUBLIC_DOMAIN}/ 无正常响应（HTTP $code）"
            log_warn "若为 502 且 frpc 未起来，属预期现象"
        fi
    fi
}

#-------------------------------------------------------------------------------
# --self-test-only
#-------------------------------------------------------------------------------
do_self_test_only() {
    load_state || log_warn "未找到状态文件，将使用默认端口进行探测"
    log_step "只执行端到端自检"
    if run_selftests; then
        log_ok "四项自检全部通过"
    else
        die "自检未通过，请根据上面的输出排查"
    fi
}

#-------------------------------------------------------------------------------
# --uninstall
#-------------------------------------------------------------------------------
do_uninstall() {
    log_step "卸载：移除 Mac 端隧道与 OpenList 服务"

    load_state 2>/dev/null || true

    log_info "将执行："
    log_raw "    · 卸载并删除 launchd：${LABEL_OPENLIST}、${LABEL_HY2}、${LABEL_FRPC}"
    log_raw "    · 删除二进制：${FRPC_BIN}"
    log_raw "    · hysteria（${HY2_BIN}）：与「国外下载那套」共用，默认保留"
    log_raw "    · 归档并删除配置目录：${CONF_DIR}/"
    if [ "$KEEP_OPENLIST_DATA" -eq 0 ]; then
        log_raw "    · ${C_RED}删除 OpenList 数据目录：${OPENLIST_DATA}（含数据库与配置）${C_RESET}"
    else
        log_raw "    · 保留 OpenList 数据目录：${OPENLIST_DATA}"
    fi
    log_raw ""
    confirm "确认继续？" n || die "已取消"

    launchd_unload "$LABEL_FRPC" "$PLIST_FRPC"
    launchd_unload "$LABEL_HY2" "$PLIST_HY2"
    launchd_unload "$LABEL_OPENLIST" "$PLIST_OPENLIST"
    sudo rm -f "$PLIST_FRPC" "$PLIST_HY2" "$PLIST_OPENLIST"
    log_ok "已卸载并删除 launchd 单元"

    local ts backup
    ts=$(date +%Y%m%d-%H%M%S)
    backup="/tmp/nas-tunnel-mac-backup-${ts}"
    mkdir -p "$backup" 2>/dev/null || true
    [ -d "$CONF_DIR" ] && cp -a "$CONF_DIR" "$backup/" 2>/dev/null || true
    log_ok "配置已归档到：$backup"

    # frpc 只有这一套在用，可以删。
    if [ -f "$FRPC_BIN" ]; then
        sudo rm -f "$FRPC_BIN"
        log_info "已删除 frpc：$FRPC_BIN"
    fi

    # hysteria 是和「国外下载那套」共用的同一个二进制，删之前必须先确认那边不用了。
    # （对称逻辑见 uninstall-nas-nl-mac.sh 里对 CN_PLIST / CN_CONF_DIR 的检查）
    if [ -x "$HY2_BIN" ]; then
        if [ -f "$NL_PLIST" ] || [ -d "$NL_CONF_DIR" ]; then
            log_warn "检测到「国外下载那套」还在（${NL_PLIST} 或 ${NL_CONF_DIR}）——它也用 ${HY2_BIN}！"
            log_warn "删掉会让它的拉取隧道起不来；要删请先跑 uninstall-nas-nl-mac.sh"
            if confirm "确定还是要删除 ${HY2_BIN} 吗？" n; then
                sudo rm -f "$HY2_BIN"
                log_info "已删除：$HY2_BIN"
            else
                log_info "已跳过（保留 $HY2_BIN）"
            fi
        else
            if confirm "确认删除 ${HY2_BIN} ？" n; then
                sudo rm -f "$HY2_BIN"
                log_info "已删除：$HY2_BIN"
            else
                log_info "已跳过（保留 $HY2_BIN）"
            fi
        fi
    fi

    sudo rm -rf "$CONF_DIR"

    if [ "$KEEP_OPENLIST_DATA" -eq 0 ]; then
        sudo rm -rf "$OPENLIST_DATA"
        log_info "已删除 OpenList 数据目录：$OPENLIST_DATA"
    fi

    if has_cmd "$BREW_BIN" && "$BREW_BIN" list openlist >/dev/null 2>&1; then
        if confirm "是否同时执行 brew uninstall openlist？（数据目录不受影响）" n; then
            "$BREW_BIN" uninstall openlist >>"$LOG_FILE" 2>&1 || log_warn "brew uninstall openlist 失败"
            log_ok "已卸载 openlist"
        fi
    fi

    log_raw ""
    log_ok "卸载完成（配置已归档到 $backup）"
}

#-------------------------------------------------------------------------------
# 主流程
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_log
    log_raw ""
    log_raw "${C_CYAN}${C_BOLD}  NAS 反向隧道部署脚本 v${SCRIPT_VERSION}  （Mac mini 端 · OpenList）${C_RESET}"
    log_raw "${C_CYAN}  OpenList + Hysteria2 客户端 + frpc，全部 launchd 开机自启${C_RESET}"
    log_raw ""

    if [ "$DO_STATUS" -eq 1 ]; then
        do_status
        exit 0
    fi
    if [ "$DO_UNINSTALL" -eq 1 ]; then
        do_uninstall
        exit 0
    fi
    if [ "$SELF_TEST_ONLY" -eq 1 ]; then
        do_self_test_only
        exit 0
    fi

    phase0_env
    phase1_params
    phase2_openlist
    phase3_tunnel_binaries
    phase4_configs
    phase5_launchd
    phase6_summary
}

main "$@"
