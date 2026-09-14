#!/usr/bin/env bash
#===============================================================================
# NAS 反向隧道一键部署脚本（服务器端 · 国内服务器适配版）
#
# 目标：
#   把家里 Mac mini 上的 OpenList（127.0.0.1:5244）通过「Hysteria2 加密高速
#   隧道 + frp 反向端口映射」暴露到本服务器的公网域名上，由 Caddy 自动签发
#   并续期 Let's Encrypt 证书并提供 HTTPS 反向代理。
#
# 协议与数据流（关键：Mac↔服务器 公网段是纯 UDP）：
#
#   观众 ──TCP/443──► Caddy(本机)                UDP/443 ◄── QUIC 加密隧道 ── Mac mini
#                      │  <域名> 站点块                                    │
#                      └► reverse_proxy 127.0.0.1:15244                   │
#                                            ▲                            │
#                                       frps(本机 127.0.0.1:7000) ◄── 经隧道登录 ── frpc(Mac)
#                                       proxyBindAddr=127.0.0.1      proxyURL=socks5://127.0.0.1:1080
#                                                                        │
#                                              hysteria 客户端 socks5 ◄──┘
#                                                    (Mac) ──► OpenList 127.0.0.1:5244
#
#   为什么需要两层：Hysteria2 v2 官方不支持反向隧道（v1 的端口转发已在 v2 移除），
#   所以 HY2 负责「怎么过公网」（UDP/QUIC + Brutal 拥塞控制），frp 负责
#   「把内网哪个端口接到本机」（反向端口映射）。frp 跑在 HY2 隧道内部，公网不可见。
#
# 用法：
#   bash deploy-nas-tunnel.sh                     # 交互式部署（推荐）
#   bash deploy-nas-tunnel.sh --help              # 查看完整帮助
#   bash deploy-nas-tunnel.sh -d mac.example.com  # 预填域名，其余仍交互
#   bash deploy-nas-tunnel.sh --status            # 查看状态与 Mac 端对接信息
#   bash deploy-nas-tunnel.sh --self-test-only    # 只跑端到端自检
#   bash deploy-nas-tunnel.sh --uninstall         # 卸载本脚本部署的全部组件
#
# 安全与边界：
#   - 仅管理 Caddyfile 中带 nas-tunnel-managed 标记的区块，绝不改动其他已有站点
#   - 公网只暴露 TCP 443(Caddy) 与 UDP 443(Hysteria2)；frp 全部绑定回环地址
#   - 幂等设计：重复执行沿用既有密码/密钥与端口，不重置已部署的隧道
#   - 不修改系统软件源；不自动操作云厂商安全组；不代做 DNS 解析
#   - 不做通用清理：不碰其他站点、不删 /opt/openlist 等与本脚本无关的内容
#
# 版本：1.0.0
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# 全局常量
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="deploy-nas-tunnel.sh"

# 日志文件（每次执行生成一份，便于排查）
# 非 readonly：若 /var/log 不可写（受限环境）会自动降级到 /tmp，再不行就丢弃日志输出
LOG_FILE="/var/log/nas-tunnel-deploy-$(date +%Y%m%d-%H%M%S).log"
LOG_ENABLED=1

# 状态目录：保存本次部署的关键参数，供 --status / --uninstall / 重复执行使用
readonly STATE_DIR="/etc/nas-tunnel"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly STATE_VERSION="1"

# Hysteria2 相关路径
readonly HY2_BIN="/usr/local/bin/hysteria"
readonly HY2_CONFIG_DIR="/etc/hysteria"
readonly HY2_CONFIG="${HY2_CONFIG_DIR}/config.yaml"
readonly HY2_TLS_DIR="${HY2_CONFIG_DIR}/tls"
readonly HY2_SERVICE="hysteria-server"
readonly HY2_UNIT_FILE="/etc/systemd/system/hysteria-server.service"

# frp 相关路径
readonly FRP_CONFIG_DIR="/etc/frp"
readonly FRPS_CONFIG="${FRP_CONFIG_DIR}/frps.toml"
readonly FRPS_BIN="/usr/local/bin/frps"
readonly FRPC_BIN="/usr/local/bin/frpc"
readonly FRPS_SERVICE="frps"
readonly FRPS_UNIT_FILE="/etc/systemd/system/frps.service"

# Caddy 相关路径
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly CADDY_BACKUP_DIR="/etc/caddy/backups"
readonly CADDY_LOG_DIR="/var/log/caddy"
readonly CADDY_BACKUP_KEEP="5"

# Caddy 安装源（Caddy 是本脚本的硬性前置条件：本机缺失时脚本自动安装）
readonly CADDY_APT_LIST="/etc/apt/sources.list.d/caddy-stable.list"
readonly CADDY_APT_KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
readonly CADDY_APT_GPG_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
readonly CADDY_APT_DEB_URL="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"
readonly CADDY_INSTALL_DOC_URL="https://caddyserver.com/docs/install"

# Caddyfile 标记块（用于幂等替换；与本仓库 deploy-openlist.sh 的 openlist-managed 互不干扰）
readonly CADDY_BLOCK_BEGIN_PREFIX="# >>> nas-tunnel-managed:"
readonly CADDY_BLOCK_END_PREFIX="# <<< nas-tunnel-managed:"
readonly CADDY_GLOBAL_MARK="global"

# 输出文件
readonly INFO_FILE="/root/nas-tunnel-info.txt"
readonly CLIENT_BUNDLE_DIR="/root/nas-tunnel-mac-client"

# 默认端口与后端
readonly DEFAULT_HY2_PORT="443"
readonly DEFAULT_FRPS_BIND_PORT="7000"
readonly DEFAULT_FRPS_PROXY_PORT="15244"
readonly FALLBACK_HY2_PORT="8443"
readonly MAC_OPENLIST_PORT="5244"          # Mac 上 OpenList 的监听端口
readonly MAC_SOCKS5_PORT="1080"            # Mac 上 hysteria 客户端 socks5 入站端口

# 自检临时端口
readonly SELFTEST_SOCKS5_PORT="11080"

# 候选 GitHub 加速代理（脚本会实测测速后择优）
readonly -a GH_PROXY_CANDIDATES=(
  "https://gh-proxy.com/"
  "https://ghfast.top/"
  "https://ghproxy.net/"
)

# 版本下载地址
readonly HYSTERIA_REPO="https://github.com/apernet/hysteria"
readonly HYSTERIA_RELEASE_BASE="${HYSTERIA_REPO}/releases/latest/download"
readonly HYSTERIA_PROBE_URL="${HYSTERIA_RELEASE_BASE}/hysteria-linux-amd64"

readonly FRP_REPO="https://github.com/fatedier/frp"
readonly FRP_VERSION_FALLBACK="0.71.0"

#-------------------------------------------------------------------------------
# 运行期变量（由命令行参数或交互输入填充）
#-------------------------------------------------------------------------------
DOMAIN=""
ACME_EMAIL=""
EMAIL_PROVIDED=0
GH_PROXY=""
PUBLIC_IP=""
HY2_PORT="$DEFAULT_HY2_PORT"
HY2_PORT_EXPLICIT=0
HY2_PASSWORD=""
FRP_TOKEN=""
SOCKS5_USER=""
SOCKS5_PASS=""
FRPS_BIND_PORT="$DEFAULT_FRPS_BIND_PORT"
FRPS_PROXY_PORT="$DEFAULT_FRPS_PROXY_PORT"
HOME_UPLOAD="65"
SERVER_BANDWIDTH_DOWN=""
HOP_RANGE=""
FRP_VERSION=""
KEEP_H3=0
HY2_ARCH="amd64"
HY2_CERT_MODE="caddy"          # caddy = 复用 Caddy 证书；selfsigned = 自签降级
CADDY_CERT_SRC=""
CADDY_KEY_SRC=""
H3_DISABLED=0
MASQUERADE_MODE="proxy"
RESUME_EXISTING=0

DO_UNINSTALL=0
DO_STATUS=0
SELF_TEST_ONLY=0
ROTATE_SECRETS=0
DNS_OK=1

# 自检临时进程
declare -a SELFTEST_PIDS=()
SELFTEST_TMP=""

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
# 日志输出：同时打印到终端与日志文件
#
# 注意：这里刻意不用 `tee -a`。tee 的 stdout 不是终端时会走 stdio 缓冲，
# 脚本一旦被信号打断，缓冲区里最后几 KB 日志会整段丢失（实测踩过这个坑：
# 阶段 5/6 的日志全部没落盘）。直接 `>>` 追加由 shell 内置完成写入，
# 不经 stdio 缓冲，尾部日志不会再丢，而且省掉每行一个 tee 进程。
#-------------------------------------------------------------------------------
log_raw() {
    if [ "$LOG_ENABLED" -eq 1 ]; then
        printf '%b\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
    fi
    printf '%b\n' "$*"
}
log_info() { log_raw "${C_BLUE}[信息]${C_RESET} $*"; }
log_ok()   { log_raw "${C_GREEN}[成功]${C_RESET} $*"; }
log_warn() { log_raw "${C_YELLOW}[警告]${C_RESET} $*"; }
log_err()  { log_raw "${C_RED}[错误]${C_RESET} $*"; }
log_step() { log_raw ""; log_raw "${C_CYAN}${C_BOLD}==> $*${C_RESET}"; }

# 致命错误：打印后退出
die() {
    log_err "$*"
    if [ "$LOG_ENABLED" -eq 1 ]; then
        log_err "详细日志：$LOG_FILE"
    fi
    exit 1
}

# 初始化日志文件（不可写则逐级降级，避免每行日志都喷 Permission denied）
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    # 用 touch 探测可写性：重定向失败的报错由 bash 自己打印，
    # 写在命令末尾的 2>/dev/null 来不及生效（redirection 是从左到右依次执行的），
    # 所以这里用 touch + 2>/dev/null，确保探测失败时静默降级。
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/nas-tunnel-deploy-$(date +%Y%m%d-%H%M%S).log"
        touch "$LOG_FILE" 2>/dev/null || true
    fi
    if [ ! -f "$LOG_FILE" ]; then
        LOG_FILE="/dev/null"
        LOG_ENABLED=0
    fi
    if [ "$LOG_ENABLED" -eq 1 ]; then
        : > "$LOG_FILE" 2>/dev/null || true
        chmod 600 "$LOG_FILE" 2>/dev/null || true
    fi
    log_raw "==============================================================="
    log_raw " NAS 反向隧道部署日志  版本：$SCRIPT_VERSION"
    log_raw " 开始时间：$(date '+%Y-%m-%d %H:%M:%S')  主机：$(hostname)"
    log_raw "==============================================================="
}

#-------------------------------------------------------------------------------
# 帮助信息
#-------------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}NAS 反向隧道一键部署脚本（服务器端）v${SCRIPT_VERSION}${C_RESET}

${C_BOLD}它做什么：${C_RESET}
  在本服务器上搭建「Hysteria2 加密隧道 + frp 反向映射 + Caddy 自动 HTTPS」，
  让 <你填的域名> 指向家里 Mac mini 上的 OpenList。Mac↔服务器 的公网段是纯 UDP。

${C_BOLD}用法：${C_RESET}
  bash ${SCRIPT_NAME} [选项]

${C_BOLD}选项：${C_RESET}
  -d, --domain <域名>       指定对外访问域名（不填则交互询问）
  -e, --email <邮箱>        指定 ACME 证书联系邮箱（可留空）
  -p, --proxy <地址>        指定 GitHub 加速代理，跳过自动测速
      --hy2-port <端口>     Hysteria2 监听的 UDP 端口（默认 ${DEFAULT_HY2_PORT}）
      --no-disable-h3       保留 Caddy 的 HTTP/3（UDP ${DEFAULT_HY2_PORT}），HY2 自动改用其他端口
      --home-upload <Mbps>  Mac 端家宽上行，用于生成客户端的 Brutal 目标速率（默认 ${HOME_UPLOAD}）
      --bandwidth-down <速率>
                            可选：限制服务器接收方向（Mac→服务器）的隧道速率，如 8mbps
      --hop <起-止>         可选：Hysteria2 端口跳跃，如 20000-50000（需安全组放行整段 UDP）
      --frp-version <版本>  指定 frp 版本（默认自动取最新，失败回退 ${FRP_VERSION_FALLBACK}）
      --rotate-secrets      重新生成 HY2 密码与 frp token（默认沿用已有部署的密钥）
      --status              查看当前部署状态与 Mac 端对接信息
      --self-test-only      只跑端到端自检（需已部署）
      --uninstall           卸载本脚本部署的全部组件并恢复 Caddy 配置
  -h, --help                显示本帮助
  -v, --version             显示脚本版本

${C_BOLD}示例：${C_RESET}
  bash ${SCRIPT_NAME}
  bash ${SCRIPT_NAME} -d mac.example.com -e you@example.com
  bash ${SCRIPT_NAME} --status
  bash ${SCRIPT_NAME} --uninstall

${C_BOLD}执行流程：${C_RESET}
  阶段 0/6  环境准备：root/系统/依赖/磁盘/公网 IP 探测
  阶段 1/6  预检交互：域名、邮箱、UDP 端口、HTTP/3 取舍、下载线路、DNS 与端口检查
  阶段 2/6  下载安装：hysteria（AVX 优先，失败回退）与 frp 二进制
  阶段 3/6  部署 frps：反向隧道服务端（仅监听回环）
  阶段 4/6  配置 Caddy：站点反代 + 可选关闭 HTTP/3 + 等待证书签发
  阶段 5/6  部署 Hysteria2：写入配置、启动、并在本机跑两级端到端自检
  阶段 6/6  生成 Mac 端对接包与凭据文件，打印全部连接参数

${C_BOLD}执行前请确认：${C_RESET}
  1. 已用 root 身份执行（sudo bash ${SCRIPT_NAME}）
  2. 域名的 A 记录已指向本机公网 IP，且 Cloudflare 处于「仅 DNS」（关闭小云朵）
     —— TLS-ALPN 挑战穿不过 CF 代理，橙云一定签不下证书
  3. 云服务器安全组已放行 UDP ${DEFAULT_HY2_PORT} 入站（TCP 80/443 已有）

${C_BOLD}该脚本不会替你做：${C_RESET}
  - 云厂商安全组放行（尤其 UDP ${DEFAULT_HY2_PORT} 入站，必须手动放行）
  - DNS 解析（Cloudflare 加一条 A 记录指向本机公网 IP）
  - Mac 端安装 hysteria / frpc（脚本只生成可直接使用的配置与说明）
  - 通用清理（不删其他站点、不动 /opt/openlist 等无关内容）

${C_BOLD}常用排查：${C_RESET}
  · 域名打不开      → systemctl status caddy / journalctl -u caddy -n 50
  · 隧道连不上      → systemctl status ${HY2_SERVICE} / journalctl -u ${HY2_SERVICE} -n 50
  · 反代 502        → 说明 Mac 端 frpc 未上线：systemctl status ${FRPS_SERVICE}
  · 想看连接参数    → bash ${SCRIPT_NAME} --status
  · 想推倒重来      → bash ${SCRIPT_NAME} --uninstall 然后重新执行
EOF
}

#-------------------------------------------------------------------------------
# 命令行参数解析
#-------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--domain)
                [ -n "${2:-}" ] || die "选项 $1 需要一个域名参数"
                DOMAIN="$2"; shift 2 ;;
            -e|--email)
                ACME_EMAIL="${2:-}"; EMAIL_PROVIDED=1; shift 2 ;;
            -p|--proxy)
                GH_PROXY="${2:-}"; shift 2 ;;
            --hy2-port)
                [ -n "${2:-}" ] || die "选项 $1 需要一个端口号"
                HY2_PORT="$2"; HY2_PORT_EXPLICIT=1; shift 2 ;;
            --no-disable-h3)
                KEEP_H3=1; shift ;;
            --home-upload)
                HOME_UPLOAD="${2:-}"; shift 2 ;;
            --bandwidth-down)
                SERVER_BANDWIDTH_DOWN="${2:-}"; shift 2 ;;
            --hop)
                HOP_RANGE="${2:-}"; shift 2 ;;
            --frp-version)
                FRP_VERSION="${2:-}"; shift 2 ;;
            --rotate-secrets)
                ROTATE_SECRETS=1; shift ;;
            --status)
                DO_STATUS=1; shift ;;
            --self-test-only)
                SELF_TEST_ONLY=1; shift ;;
            --uninstall)
                DO_UNINSTALL=1; shift ;;
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
# 基础校验
#-------------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}[错误]${C_RESET} 请使用 root 权限运行：sudo bash $SCRIPT_NAME" >&2
        exit 1
    fi
}

print_banner() {
    log_raw ""
    log_raw "${C_CYAN}${C_BOLD}  NAS 反向隧道部署脚本 v${SCRIPT_VERSION}  （服务器端 · 国内服务器适配）${C_RESET}"
    log_raw "${C_CYAN}  Hysteria2 UDP 隧道 + frp 反向映射 + Caddy 自动 HTTPS${C_RESET}"
    log_raw ""
}

#-------------------------------------------------------------------------------
# 通用工具函数
#-------------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 交互式读取（带默认值），结果写入全局变量 REPLY
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

# 是/否确认；默认值 default 取 y 或 n
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

is_valid_domain() {
    local d="$1"
    [ -n "$d" ] || return 1
    [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# 校验带宽表达式，如 8mbps / 100 mbps / 1gbps / 512kbps
is_valid_rate() {
    [[ "${1// /}" =~ ^[0-9]+(\.[0-9]+)?(bps|b|kbps|kb|k|mbps|mb|m|gbps|gb|g|tbps|tb|t)$ ]]
}

# 生成强随机密钥（纯字母数字，避免配置文件引号/转义问题）
random_secret() {
    local len="${1:-32}" s=""
    s=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$len" 2>/dev/null) || true
    if [ "${#s}" -lt "$len" ]; then
        s=$(openssl rand -hex $(( len / 2 + 1 )) 2>/dev/null | head -c "$len") || true
    fi
    printf '%s' "$s"
}

# 探测本机公网 IP（多源回退）
detect_public_ip() {
    local svc ip
    for svc in "https://ifconfig.me" "https://ip.sb" "https://ipinfo.io/ip" \
               "https://ip.3322.net" "https://api.ipify.org"; do
        ip=$(curl -s4 --max-time 6 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 解析域名得到的 IPv4 列表（getent → python3 → DoH 三级兜底）
resolve_domain_ipv4() {
    local d="$1" ips=""
    if has_cmd getent; then
        ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    if [ -z "$ips" ] && has_cmd python3; then
        ips=$(python3 - "$d" <<'PY' 2>/dev/null
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)
    print("\n".join(sorted({i[4][0] for i in infos})))
except Exception:
    pass
PY
)
    fi
    if [ -z "$ips" ]; then
        # 系统解析可用但结果为空时再走 DoH，绕过本机 resolv.conf 异常
        ips=$(curl -s --max-time 6 -H 'accept: application/dns-json' \
              "https://doh.pub/dns-query?name=${d}&type=A" 2>/dev/null \
              | grep -oE '"data":"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
              | sed 's/"data":"//; s/"$//' | sort -u)
    fi
    echo "$ips"
}

# 检查磁盘可用空间（要求不少于 2GB）
check_disk_space() {
    local target avail_kb
    target="$STATE_DIR"
    mkdir -p "$target" 2>/dev/null || target="/"
    avail_kb=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$avail_kb" ]; then
        log_warn "无法读取磁盘空间信息，跳过检查"
        return 0
    fi
    if [ "$avail_kb" -lt 2097152 ]; then
        die "磁盘可用空间不足 2GB（当前 $(df -Ph "$target" | awk 'NR==2 {print $4}')）"
    fi
    log_ok "磁盘空间充足：$(df -Ph "$target" | awk 'NR==2 {print $4}') 可用"
}

# 安装缺失的系统依赖（不修改软件源）
ensure_dependencies() {
    local need_apt=0
    local -a missing_pkgs=()

    has_cmd curl    || { missing_pkgs+=(curl);    need_apt=1; }
    has_cmd tar     || { missing_pkgs+=(tar);     need_apt=1; }
    has_cmd openssl || { missing_pkgs+=(openssl); need_apt=1; }
    has_cmd python3 || { missing_pkgs+=(python3); need_apt=1; }
    has_cmd getent  || { missing_pkgs+=(libc-bin); need_apt=1; }
    has_cmd ss      || { missing_pkgs+=(iproute2); need_apt=1; }
    [ -f /etc/ssl/certs/ca-certificates.crt ] || { missing_pkgs+=(ca-certificates); need_apt=1; }

    if [ "$need_apt" -eq 0 ]; then
        log_ok "系统依赖齐全（curl / tar / openssl / python3 / ss / ca-certificates）"
        return 0
    fi

    log_warn "检测到缺失依赖：${missing_pkgs[*]}"
    if ! has_cmd apt-get; then
        die "缺少依赖且未检测到 apt-get，请手动安装后重试：${missing_pkgs[*]}"
    fi
    if ! confirm "是否使用当前 apt 源自动安装这些依赖？（不会修改你已配置的软件源）" y; then
        die "已取消。请手动安装后重试：${missing_pkgs[*]}"
    fi

    log_info "正在更新 apt 索引（沿用你当前配置的国内源）..."
    apt-get update -qq 2>&1 | tee -a "$LOG_FILE" || log_warn "apt-get update 失败，将直接尝试安装"
    log_info "正在安装：${missing_pkgs[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_pkgs[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        die "依赖安装失败，请手动安装后重试：${missing_pkgs[*]}"
    fi
    log_ok "依赖安装完成"
}

#-------------------------------------------------------------------------------
# 状态文件：保存/读取部署参数（供 --status / --uninstall / 重复执行使用）
#-------------------------------------------------------------------------------
state_get() {
    local key="$1" file="${2:-$STATE_FILE}"
    [ -f "$file" ] || return 1
    local line
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1) || return 1
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

state_has() {
    local key="$1" file="${2:-$STATE_FILE}"
    [ -f "$file" ] || return 1
    grep -qE "^${key}=" "$file" 2>/dev/null
}

save_state() {
    mkdir -p "$STATE_DIR" || die "无法创建状态目录：$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    cat > "$STATE_FILE" <<EOF
STATE_VERSION=${STATE_VERSION}
DOMAIN=${DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PASSWORD}
HY2_ARCH=${HY2_ARCH}
HY2_CERT_MODE=${HY2_CERT_MODE}
CADDY_CERT_SRC=${CADDY_CERT_SRC}
CADDY_KEY_SRC=${CADDY_KEY_SRC}
FRP_TOKEN=${FRP_TOKEN}
FRP_VERSION=${FRP_VERSION}
FRPS_BIND_PORT=${FRPS_BIND_PORT}
FRPS_PROXY_PORT=${FRPS_PROXY_PORT}
SOCKS5_USER=${SOCKS5_USER}
SOCKS5_PASS=${SOCKS5_PASS}
MAC_OPENLIST_PORT=${MAC_OPENLIST_PORT}
MAC_SOCKS5_PORT=${MAC_SOCKS5_PORT}
HOME_UPLOAD=${HOME_UPLOAD}
SERVER_BANDWIDTH_DOWN=${SERVER_BANDWIDTH_DOWN}
HOP_RANGE=${HOP_RANGE}
H3_DISABLED=${H3_DISABLED}
MASQUERADE_MODE=${MASQUERADE_MODE}
ACME_EMAIL=${ACME_EMAIL}
GH_PROXY=${GH_PROXY}
EOF
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

# 从状态文件恢复运行期变量（用于 --status / --uninstall / 重复执行）
load_state() {
    [ -f "$STATE_FILE" ] || return 1
    local v
    v=$(state_get DOMAIN 2>/dev/null || true);          [ -n "$v" ] && DOMAIN="$v"
    v=$(state_get PUBLIC_IP 2>/dev/null || true);       [ -n "$v" ] && PUBLIC_IP="$v"
    v=$(state_get HY2_PORT 2>/dev/null || true);        [ -n "$v" ] && HY2_PORT="$v"
    v=$(state_get HY2_PASSWORD 2>/dev/null || true);    [ -n "$v" ] && HY2_PASSWORD="$v"
    v=$(state_get HY2_ARCH 2>/dev/null || true);        [ -n "$v" ] && HY2_ARCH="$v"
    v=$(state_get HY2_CERT_MODE 2>/dev/null || true);   [ -n "$v" ] && HY2_CERT_MODE="$v"
    v=$(state_get CADDY_CERT_SRC 2>/dev/null || true);  [ -n "$v" ] && CADDY_CERT_SRC="$v"
    v=$(state_get CADDY_KEY_SRC 2>/dev/null || true);   [ -n "$v" ] && CADDY_KEY_SRC="$v"
    v=$(state_get FRP_TOKEN 2>/dev/null || true);       [ -n "$v" ] && FRP_TOKEN="$v"
    v=$(state_get FRP_VERSION 2>/dev/null || true);     [ -n "$v" ] && FRP_VERSION="$v"
    v=$(state_get FRPS_BIND_PORT 2>/dev/null || true);  [ -n "$v" ] && FRPS_BIND_PORT="$v"
    v=$(state_get FRPS_PROXY_PORT 2>/dev/null || true); [ -n "$v" ] && FRPS_PROXY_PORT="$v"
    v=$(state_get SOCKS5_USER 2>/dev/null || true);     [ -n "$v" ] && SOCKS5_USER="$v"
    v=$(state_get SOCKS5_PASS 2>/dev/null || true);     [ -n "$v" ] && SOCKS5_PASS="$v"
    v=$(state_get HOME_UPLOAD 2>/dev/null || true);     [ -n "$v" ] && HOME_UPLOAD="$v"
    v=$(state_get SERVER_BANDWIDTH_DOWN 2>/dev/null || true); [ -n "$v" ] && SERVER_BANDWIDTH_DOWN="$v"
    v=$(state_get HOP_RANGE 2>/dev/null || true);       [ -n "$v" ] && HOP_RANGE="$v"
    v=$(state_get H3_DISABLED 2>/dev/null || true);     [ -n "$v" ] && H3_DISABLED="$v"
    v=$(state_get MASQUERADE_MODE 2>/dev/null || true); [ -n "$v" ] && MASQUERADE_MODE="$v"
    v=$(state_get ACME_EMAIL 2>/dev/null || true);      [ -n "$v" ] && ACME_EMAIL="$v"
    v=$(state_get GH_PROXY 2>/dev/null || true);        [ -n "$v" ] && GH_PROXY="$v"
    return 0
}

#-------------------------------------------------------------------------------
# 端口与服务探测
#-------------------------------------------------------------------------------
tcp_listening_on() {
    has_cmd ss || return 1
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

udp_listening_on() {
    has_cmd ss || return 1
    ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

tcp_listening_addr() {
    has_cmd ss || return 1
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qF "$1"
}

udp_owner_desc() {
    local port="$1" line=""
    has_cmd ss || return 0
    # 注意：不能对整行做 grep ':$port$'，因为第 4 列之后还有对端地址/进程列；
    # 必须只看第 4 列（本地地址:端口），否则永远匹配不到。
    line=$(ss -ulnpe 2>/dev/null | awk -v p=":${port}" '$4 ~ (p "$") {print; exit}')
    [ -n "$line" ] && printf '%s\n' "$line"
}

systemd_unit_exists() {
    has_cmd systemctl || return 1
    systemctl cat "$1" >/dev/null 2>&1
}

service_active() {
    systemd_unit_exists "$1" || return 1
    systemctl is-active --quiet "$1"
}

wait_for_tcp_port() {
    local port="$1" timeout="${2:-30}" i=0
    while [ "$i" -lt "$timeout" ]; do
        tcp_listening_on "$port" && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

wait_for_udp_port() {
    local port="$1" timeout="${2:-30}" i=0
    while [ "$i" -lt "$timeout" ]; do
        udp_listening_on "$port" && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

#-------------------------------------------------------------------------------
# 备份工具
#-------------------------------------------------------------------------------
backup_file() {
    local src="$1" dest="$2" ts target
    [ -f "$src" ] || return 0
    mkdir -p "$dest" || return 1
    ts=$(date +%Y%m%d-%H%M%S)
    target="$dest/$(basename "$src").$ts"
    cp -a "$src" "$target" || return 1
    echo "$target"
}

prune_backups() {
    local dir="$1" keep="$2" f
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$dir/$f"
    done < <(ls -1t "$dir" 2>/dev/null | tail -n +$((keep + 1)))
}

#-------------------------------------------------------------------------------
# 下载：GitHub 加速代理测速择优
#-------------------------------------------------------------------------------
# 测试某条线路；输出 "HTTP状态码 速度(B/s) 已下载字节"
probe_download_speed() {
    local base="$1" out=""
    out=$(curl -sL --max-time 12 -r 0-4000000 -o /dev/null \
          -w '%{http_code} %{speed_download} %{size_download}' \
          "${base}${HYSTERIA_PROBE_URL}" 2>/dev/null) || out="000 0 0"
    [ -n "$out" ] || out="000 0 0"
    echo "$out"
}

select_gh_proxy() {
    if [ -n "$GH_PROXY" ]; then
        log_info "使用命令行指定的加速代理：$GH_PROXY"
        # 统一补上结尾斜杠，保证拼接正确
        case "$GH_PROXY" in
            */) ;;
            *) GH_PROXY="${GH_PROXY}/" ;;
        esac
        return 0
    fi

    log_raw ""
    log_info "正在测试 GitHub 下载线路（国内服务器直连通常不可用，需走加速代理）..."

    local best_base="" best_speed=0 best_label="直连 GitHub"
    local -a labels=("直连 GitHub" "gh-proxy.com" "ghfast.top" "ghproxy.net")
    local -a bases=("" "${GH_PROXY_CANDIDATES[@]}")
    local i result code speed size human

    for i in "${!bases[@]}"; do
        result=$(probe_download_speed "${bases[$i]}")
        code=$(echo "$result" | awk '{print $1}')
        speed=$(echo "$result" | awk '{printf "%d", $2}')
        size=$(echo "$result" | awk '{printf "%d", $3}')
        human=$(awk -v s="$speed" 'BEGIN{printf "%.2f MB/s", s/1048576}')
        if [ "$code" = "200" ] || [ "$code" = "206" ]; then
            [ "$speed" -gt 0 ] 2>/dev/null && log_raw "    ${labels[$i]}：$human（已下载 $((size/1024)) KB）" \
                || log_raw "    ${labels[$i]}：${C_RED}速度为 0${C_RESET}"
        else
            log_raw "    ${labels[$i]}：${C_RED}不可用${C_RESET}（HTTP $code）"
            speed=0
        fi
        if [ "$speed" -gt "$best_speed" ] 2>/dev/null; then
            best_speed="$speed"
            best_base="${bases[$i]}"
            best_label="${labels[$i]}"
        fi
    done

    if [ "$best_speed" -le 0 ]; then
        log_warn "所有加速线路测速均失败，可能是当前网络异常"
        [ -t 0 ] || die "无法自动选择下载线路，请用 -p/--proxy 指定代理后重试"
        ask "请手动输入 GitHub 加速代理地址（形如 https://gh-proxy.com/，回车放弃）" ""
        if [ -n "$REPLY" ]; then
            GH_PROXY="$REPLY"
            case "$GH_PROXY" in */) ;; *) GH_PROXY="${GH_PROXY}/" ;; esac
            log_info "将使用自定义代理：$GH_PROXY"
            return 0
        fi
        die "未选择可用下载线路，已中止"
    fi

    GH_PROXY="$best_base"
    log_ok "已自动选择最快的下载线路：$best_label（$(awk -v s="$best_speed" 'BEGIN{printf "%.2f MB/s", s/1048576}')）"
}

# 带代理下载；失败返回非 0
download_file() {
    local url="$1" dest="$2" max_time="${3:-300}"
    log_info "正在下载：$url"
    if [ -n "$GH_PROXY" ]; then
        log_info "经加速代理：$GH_PROXY"
    fi
    if curl -fSL --retry 2 --retry-delay 3 --max-time "$max_time" \
            -H 'Cache-Control: no-cache' \
            -o "$dest" "${GH_PROXY}${url}" 2>>"$LOG_FILE"; then
        log_ok "下载完成：$(basename "$dest")（$(du -h "$dest" 2>/dev/null | awk '{print $1}')）"
        return 0
    fi
    log_err "下载失败：${GH_PROXY}${url}"
    return 1
}

# 获取 frp 最新版本号（失败回退固定版本）
fetch_frp_version() {
    [ -n "$FRP_VERSION" ] && return 0

    local json tag
    json=$(curl -sL --max-time 15 "https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null) || json=""
    tag=$(printf '%s' "$json" | grep -oE '"tag_name": *"[^"]+"' | head -n1 | sed 's/.*"tag_name": *"//; s/"$//')
    if [ -n "$tag" ]; then
        FRP_VERSION="${tag#v}"
        log_info "frp 最新版本：v${FRP_VERSION}"
        return 0
    fi
    FRP_VERSION="$FRP_VERSION_FALLBACK"
    log_warn "无法获取 frp 最新版本，回退到 v${FRP_VERSION}"
}

#-------------------------------------------------------------------------------
# Caddy 通用工具（与 deploy-openlist.sh 保持一致的踩坑修复）
#-------------------------------------------------------------------------------
ensure_caddy_log_dir() {
    [ -d "$CADDY_LOG_DIR" ] || mkdir -p "$CADDY_LOG_DIR" 2>/dev/null || true
    fix_caddy_log_perms
}

# 关键：caddy validate 以 root 运行时会创建日志文件（属主 root、权限 600），
# 而 caddy.service 以 caddy 用户运行，启动时会因无法写入而整体失败。
fix_caddy_log_perms() {
    [ -d "$CADDY_LOG_DIR" ] || return 0
    chmod 755 "$CADDY_LOG_DIR" 2>/dev/null || true
    if id caddy >/dev/null 2>&1; then
        chown -R caddy:caddy "$CADDY_LOG_DIR" 2>/dev/null || true
        find "$CADDY_LOG_DIR" -type f -name '*.log' -exec chmod 644 {} + 2>/dev/null || true
    fi
}

caddy_service_healthy() {
    if systemd_unit_exists caddy; then
        systemctl is-active --quiet caddy
        return $?
    fi
    return 0
}

caddy_recent_logs() {
    if has_cmd journalctl; then
        journalctl -u caddy --no-pager -n 25 2>/dev/null | tail -n 25
    fi
}

reload_caddy() {
    if systemctl is-active --quiet caddy 2>/dev/null; then
        if systemctl reload caddy >/dev/null 2>&1 \
           || caddy reload --config "$CADDYFILE" --force >>"$LOG_FILE" 2>&1; then
            log_ok "Caddy 配置已热加载（现有站点不受影响）"
            return 0
        fi
        log_warn "Caddy 热加载失败，尝试重启服务..."
        if systemctl restart caddy >>"$LOG_FILE" 2>&1; then
            log_ok "Caddy 已重启"
            return 0
        fi
        log_err "Caddy 重启失败"
        return 1
    fi

    log_warn "Caddy 服务未运行，正在启动..."
    if systemctl start caddy >>"$LOG_FILE" 2>&1 || caddy start --config "$CADDYFILE" >>"$LOG_FILE" 2>&1; then
        log_ok "Caddy 已启动"
        return 0
    fi
    log_err "Caddy 启动失败"
    return 1
}

#-------------------------------------------------------------------------------
# 自动安装 Caddy（本脚本依赖 Caddy 提供公网 HTTPS 入口）
#
# 设计：
#   - 只在「本机没有 caddy 命令」时触发；已装 Caddy 的机器行为完全不变
#   - 优先用 Caddy 官方 apt 源（dl.cloudsmith.io）装最新稳定版，
#     失败再回退到系统自带软件源里的 caddy 包，两条路都失败才报错退出
#   - 沿用脚本既有约定：不改动你已配置的系统软件源，只在 sources.list.d 下
#     新增一个 caddy-stable.list；回退时会把它摘掉，不留半成品源
#-------------------------------------------------------------------------------
install_caddy_from_official_repo() {
    log_info "正在添加 Caddy 官方 apt 源（dl.cloudsmith.io）..."

    # 官方源需要 curl 下载，以及 gpg 把 ASCII 公钥解成二进制 keyring
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            curl gnupg apt-transport-https ca-certificates >>"$LOG_FILE" 2>&1; then
        log_warn "安装 curl / gnupg 等前置包失败，无法使用官方源"
        return 1
    fi

    local tmp
    tmp=$(mktemp) || return 1

    log_info "正在下载并导入 Caddy 官方源签名公钥..."
    if ! curl -1sLf --max-time 60 "$CADDY_APT_GPG_URL" -o "$tmp" >>"$LOG_FILE" 2>&1; then
        log_warn "下载 Caddy 官方源公钥失败"
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$CADDY_APT_KEYRING")" 2>/dev/null || true
    if ! gpg --dearmor < "$tmp" > "$CADDY_APT_KEYRING" 2>>"$LOG_FILE"; then
        log_warn "导入 Caddy 官方源公钥失败"
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    chmod 644 "$CADDY_APT_KEYRING" 2>/dev/null || true

    if ! curl -1sLf --max-time 60 "$CADDY_APT_DEB_URL" -o "$CADDY_APT_LIST" >>"$LOG_FILE" 2>&1 \
       || [ ! -s "$CADDY_APT_LIST" ]; then
        log_warn "写入 Caddy 官方源列表失败"
        rm -f "$CADDY_APT_LIST"
        return 1
    fi

    log_info "正在更新 apt 索引（含 Caddy 官方源）..."
    apt-get update -qq >>"$LOG_FILE" 2>&1 || log_warn "apt-get update 出现告警，继续尝试安装"

    log_info "正在从官方源安装 caddy..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends caddy \
            >>"$LOG_FILE" 2>&1 && has_cmd caddy; then
        log_ok "已通过官方源安装 Caddy"
        return 0
    fi
    log_warn "官方源安装 Caddy 失败"
    return 1
}

install_caddy_from_distro_repo() {
    log_info "正在回退到系统自带软件源安装 caddy..."
    # 官方源列表留着会让后续 apt 操作反复报错，先摘掉
    rm -f "$CADDY_APT_LIST"
    apt-get update -qq >>"$LOG_FILE" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends caddy \
        >>"$LOG_FILE" 2>&1 && has_cmd caddy
}

# 兜底：个别 caddy 包不自带 /etc/caddy/Caddyfile，此时先建一个占位文件，
# 否则下一处检查会直接 die，安装等于白做
ensure_caddyfile() {
    [ -f "$CADDYFILE" ] && return 0
    mkdir -p "$(dirname "$CADDYFILE")" 2>/dev/null || return 1
    cat > "$CADDYFILE" <<'EOF'
# 由 deploy-nas-tunnel.sh 在自动安装 Caddy 后创建（该 caddy 包未自带 Caddyfile）
EOF
    log_info "已创建空的 Caddyfile：$CADDYFILE"
}

install_caddy() {
    if ! has_cmd apt-get; then
        log_err "未检测到 Caddy，且本机没有 apt-get，无法自动安装"
        log_err "请手动安装后重试：$CADDY_INSTALL_DOC_URL"
        return 1
    fi

    log_warn "未检测到 Caddy —— 它是本脚本提供公网 HTTPS 入口的硬性前置条件"
    if ! confirm "是否现在自动安装 Caddy？（优先官方源，失败回退系统源）" y; then
        log_err "已取消。请手动安装 Caddy 后重试：$CADDY_INSTALL_DOC_URL"
        return 1
    fi

    if ! install_caddy_from_official_repo; then
        install_caddy_from_distro_repo || {
            log_err "Caddy 自动安装失败（官方源与系统源均未成功）"
            log_err "请手动安装后重试：$CADDY_INSTALL_DOC_URL"
            return 1
        }
    fi

    has_cmd caddy || { log_err "caddy 命令仍不可用，自动安装失败"; return 1; }

    ensure_caddyfile || log_warn "创建 Caddyfile 失败，请检查 $CADDYFILE"

    # 先起一次，确认 systemd 单元与配置可用；后续 install_caddy_config 会正常热加载
    systemctl enable caddy >>"$LOG_FILE" 2>&1 || true
    systemctl start caddy >>"$LOG_FILE" 2>&1 || true

    log_ok "Caddy 安装完成：$(caddy version 2>/dev/null | head -n1)"
    return 0
}

check_caddy_ready() {
    if ! has_cmd caddy; then
        # 缺失时先尝试自动安装，装不上才退出（原先此处直接 die）
        install_caddy || die "未检测到 Caddy 且自动安装失败。请手动安装后重试（$CADDY_INSTALL_DOC_URL）"
    fi
    if [ ! -f "$CADDYFILE" ]; then
        die "未找到 Caddy 配置文件：$CADDYFILE"
    fi
    if ! caddy_service_healthy; then
        log_warn "Caddy 服务未运行，稍后将尝试启动"
    fi
    log_ok "Caddy 就绪：$(caddy version 2>/dev/null | head -n1)"
}

#-------------------------------------------------------------------------------
# Caddyfile：全局选项块（关闭 HTTP/3，把 UDP 443 让给 Hysteria2）
#-------------------------------------------------------------------------------
# 文件首个有效行是否为全局选项块（{ 开头）
caddy_has_global_options() {
    python3 - "$CADDYFILE" <<'PY' 2>/dev/null
import sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            sys.exit(0 if s == "{" or s.startswith("{") else 1)
except Exception:
    pass
sys.exit(1)
PY
}

# mode: ensure | remove
caddy_apply_global_block() {
    local mode="$1" result=0
    python3 - "$CADDYFILE" "$mode" <<'PY' 2>&1 | tee -a "$LOG_FILE"
import re
import sys

path, mode = sys.argv[1], sys.argv[2]
BEGIN = "# >>> nas-tunnel-managed: global"
END = "# <<< nas-tunnel-managed: global"
INNER = "\tservers {\n\t\tprotocols h1 h2\n\t}\n"
FULL_BLOCK = f"{BEGIN}\n{{\n{INNER}}}\n{END}\n"

with open(path, encoding="utf-8") as fh:
    content = fh.read()

# 先移除既有标记块（无论它当时是完整块还是内嵌片段）
pattern = re.compile(
    r"^[ \t]*# >>> nas-tunnel-managed: global\n"
    r".*?"
    r"^[ \t]*# <<< nas-tunnel-managed: global\n?",
    re.MULTILINE | re.DOTALL,
)
content, removed = pattern.subn("", content)
if removed:
    print(f"[信息] 已移除旧的全局选项标记块（{removed} 处）")

if mode == "remove":
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content.rstrip() + "\n")
    print("[信息] 已恢复 Caddyfile（HTTP/3 权限交还 Caddy）")
    sys.exit(0)

# 判断文件是否已有全局选项块（首个有效行是 {）
lines = content.splitlines()
first_idx = None
for i, line in enumerate(lines):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    first_idx = i
    break

has_global = first_idx is not None and lines[first_idx].strip().startswith("{")

if has_global:
    # 已有全局块：把标记片段插到起始 { 之后，可被同一规则移除
    snippet = f"{BEGIN}\n{INNER}{END}\n"
    insert_at = first_idx + 1
    lines[insert_at:insert_at] = snippet.splitlines()
    new_content = "\n".join(lines) + "\n"
    print("[信息] 检测到已有全局选项块，已在其内部插入 HTTP/3 关闭配置")
else:
    new_content = FULL_BLOCK + "\n" + content.lstrip("\n")
    print("[信息] 已在 Caddyfile 顶部插入全局选项块（关闭 HTTP/3）")

with open(path, "w", encoding="utf-8") as fh:
    fh.write(new_content)
PY
    result=${PIPESTATUS[0]}
    return "$result"
}

#-------------------------------------------------------------------------------
# Caddyfile：站点块（幂等写入/移除）
#-------------------------------------------------------------------------------
caddy_site_block() {
    local domain="$1"
    cat <<EOF
${CADDY_BLOCK_BEGIN_PREFIX} ${domain}
${domain} {
	encode zstd gzip
	reverse_proxy 127.0.0.1:${FRPS_PROXY_PORT} {
		header_up X-Real-IP {remote_host}
		flush_interval -1
	}
	header {
		-Server
		Strict-Transport-Security "max-age=31536000"
	}
	log {
		output file ${CADDY_LOG_DIR}/${domain}.log {
			roll_size 20MiB
			roll_keep 5
		}
	}
}
${CADDY_BLOCK_END_PREFIX} ${domain}
EOF
}

apply_caddy_blocks() {
    local tmp
    tmp=$(mktemp) || die "无法创建临时文件"
    caddy_site_block "$DOMAIN" > "$tmp"
    printf '\n' >> "$tmp"

    if ! python3 - "$CADDYFILE" "$tmp" "$DOMAIN" <<'PY' 2>&1 | tee -a "$LOG_FILE"
import re
import sys

caddyfile, blocks_file, domain = sys.argv[1], sys.argv[2], sys.argv[3]

with open(caddyfile, encoding="utf-8") as fh:
    content = fh.read()
with open(blocks_file, encoding="utf-8") as fh:
    blocks = fh.read().rstrip() + "\n"

pattern = re.compile(
    r"^# >>> nas-tunnel-managed: " + re.escape(domain) + r"\n"
    r".*?"
    r"^# <<< nas-tunnel-managed: " + re.escape(domain) + r"\n?",
    re.MULTILINE | re.DOTALL,
)
content, count = pattern.subn("", content)
if count:
    print(f"[信息] 已移除 {domain} 的旧站点块（{count} 处）")

content = content.rstrip() + "\n\n" + blocks
with open(caddyfile, "w", encoding="utf-8") as fh:
    fh.write(content)
print(f"[信息] 已写入 {domain} 的站点块")
PY
    then
        rm -f "$tmp"
        die "写入 Caddyfile 失败"
    fi
    rm -f "$tmp"
}

remove_caddy_blocks() {
    local domain="$1"
    if ! python3 - "$CADDYFILE" "$domain" <<'PY' 2>&1 | tee -a "$LOG_FILE"
import re
import sys

caddyfile, domain = sys.argv[1], sys.argv[2]

with open(caddyfile, encoding="utf-8") as fh:
    content = fh.read()

pattern = re.compile(
    r"^# >>> nas-tunnel-managed: " + re.escape(domain) + r"\n"
    r".*?"
    r"^# <<< nas-tunnel-managed: " + re.escape(domain) + r"\n?",
    re.MULTILINE | re.DOTALL,
)
content, removed = pattern.subn("", content)

with open(caddyfile, "w", encoding="utf-8") as fh:
    fh.write(content.rstrip() + "\n")
print(f"[信息] 共移除 {removed} 个站点块")
PY
    then
        die "移除 Caddy 站点块失败"
    fi
}

list_managed_domains() {
    [ -f "$CADDYFILE" ] || return 0
    grep "^${CADDY_BLOCK_BEGIN_PREFIX}" "$CADDYFILE" 2>/dev/null \
        | sed "s/^${CADDY_BLOCK_BEGIN_PREFIX}//" \
        | sed 's/[[:space:]]//g'
}

# 检测 Caddyfile 中是否已存在同名（其他脚本管理的）站点块，返回该标记前缀
detect_conflicting_block() {
    local domain="$1"
    [ -f "$CADDYFILE" ] || return 1
    grep -nE "^# >>> [a-z0-9-]+-managed: *${domain}\$" "$CADDYFILE" 2>/dev/null \
        | grep -v "nas-tunnel-managed" | head -n1
}

# 移除其他脚本管理的同域名站点块（仅在用户确认后调用）
remove_foreign_block() {
    local domain="$1"
    if ! python3 - "$CADDYFILE" "$domain" <<'PY' 2>&1 | tee -a "$LOG_FILE"
import re
import sys

path, domain = sys.argv[1], sys.argv[2]
begin_re = re.compile(r"^# >>> ([a-z0-9-]+)-managed: *" + re.escape(domain) + r"\s*$")
end_re = re.compile(r"^# <<< ([a-z0-9-]+)-managed: *" + re.escape(domain) + r"\s*$")

out = []
skipping = False
removed = 0
with open(path, encoding="utf-8") as fh:
    for line in fh:
        if not skipping and begin_re.match(line.rstrip("\n")):
            skipping = True
            removed += 1
            continue
        if skipping:
            if end_re.match(line.rstrip("\n")):
                skipping = False
            continue
        out.append(line)

with open(path, "w", encoding="utf-8") as fh:
    fh.write("".join(out).rstrip() + "\n")
print(f"[信息] 已移除同域名旧站点块（{removed} 处）")
PY
    then
        die "移除同域名旧站点块失败"
    fi
}

# 备份 + 改 Caddyfile + 校验 + 热加载（失败自动回滚）
install_caddy_config() {
    local bak=""
    ensure_caddy_log_dir
    mkdir -p "$CADDY_BACKUP_DIR"

    bak=$(backup_file "$CADDYFILE" "$CADDY_BACKUP_DIR") || bak=""
    if [ -z "$bak" ]; then
        die "备份 Caddyfile 失败，已中止（避免无回滚依据地修改 Caddy 配置）：$CADDYFILE"
    fi
    log_info "已备份 Caddyfile：$bak"
    prune_backups "$CADDY_BACKUP_DIR" "$CADDY_BACKUP_KEEP"

    if [ "$H3_DISABLED" -eq 1 ]; then
        # 注意：该函数内部已 tee 到日志，这里不要再重定向 stdout，否则日志会重复两遍
        caddy_apply_global_block ensure \
            || log_warn "写入全局选项块时出现异常，继续校验"
    else
        # 曾经关闭过 HTTP/3、这次又不关了：把遗留的全局标记块清掉
        caddy_apply_global_block remove || true
    fi
    apply_caddy_blocks

    caddy fmt --overwrite "$CADDYFILE" >>"$LOG_FILE" 2>&1 || log_warn "caddy fmt 执行异常，继续校验"

    if ! caddy validate --config "$CADDYFILE" >>"$LOG_FILE" 2>&1; then
        log_err "Caddy 配置校验失败，正在回滚到备份..."
        [ -n "$bak" ] && cp -a "$bak" "$CADDYFILE"
        die "Caddy 配置校验失败（已回滚），详情请查看：$LOG_FILE"
    fi
    log_ok "Caddy 配置校验通过"

    # caddy validate 会以 root 创建日志文件，必须在启动前把属主交还给 caddy 用户
    fix_caddy_log_perms

    reload_caddy || true

    if ! caddy_service_healthy; then
        log_err "Caddy 未能正常运行，最近日志如下："
        caddy_recent_logs | sed 's/^/      /' | tee -a "$LOG_FILE"
        if [ -n "$bak" ]; then
            log_warn "正在回滚 Caddy 配置，避免影响现有站点..."
            cp -a "$bak" "$CADDYFILE"
            fix_caddy_log_perms
            reload_caddy || true
            if caddy_service_healthy; then
                log_warn "已回滚到修改前的 Caddy 配置，现有站点已恢复"
            else
                log_err "回滚后 Caddy 仍未恢复，请手动检查：systemctl status caddy"
            fi
        fi
        die "Caddy 启动失败（配置已回滚），请根据上面的日志排查"
    fi
    log_ok "Caddy 运行正常"
}

#-------------------------------------------------------------------------------
# 证书：定位 Caddy 签发的证书并交给 Hysteria2 使用
#-------------------------------------------------------------------------------
caddy_cert_roots() {
    local home xdg
    home=$(getent passwd caddy 2>/dev/null | cut -d: -f6)
    xdg="${XDG_DATA_HOME:-}"
    [ -n "$xdg" ]  && printf '%s\n' "${xdg}/caddy/certificates"
    [ -n "$home" ] && printf '%s\n' "${home}/.local/share/caddy/certificates"
    printf '%s\n' \
        "/var/lib/caddy/.local/share/caddy/certificates" \
        "/root/.local/share/caddy/certificates" \
        "/var/lib/caddy/certificates"
}

# 输出两行：证书路径、私钥路径
find_caddy_cert() {
    local domain="$1" root crt key
    while IFS= read -r root; do
        [ -n "$root" ] && [ -d "$root" ] || continue
        crt=$(find "$root" -maxdepth 4 -type f -path "*/${domain}/${domain}.crt" 2>/dev/null | head -n1)
        [ -n "$crt" ] || continue
        key="${crt%.crt}.key"
        [ -f "$key" ] || continue
        printf '%s\n%s\n' "$crt" "$key"
        return 0
    done < <(caddy_cert_roots)
    return 1
}

# 等待 Caddy 完成证书签发；成功返回 0 并打印证书路径
wait_caddy_cert() {
    local domain="$1" timeout="${2:-120}" i=0 out
    while [ "$i" -lt "$timeout" ]; do
        out=$(find_caddy_cert "$domain") && { printf '%s\n' "$out"; return 0; }
        sleep 2
        i=$((i + 2))
        [ $((i % 20)) -eq 0 ] && log_info "仍在等待证书签发（已等待 ${i}s / ${timeout}s）..."
    done
    return 1
}

# 自签证书降级
make_selfsigned_cert() {
    mkdir -p "$HY2_TLS_DIR" || die "无法创建目录：$HY2_TLS_DIR"
    chmod 700 "$HY2_TLS_DIR"
    local crt="${HY2_TLS_DIR}/${DOMAIN}.crt" key="${HY2_TLS_DIR}/${DOMAIN}.key"
    rm -f "$crt" "$key"
    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout "$key" -out "$crt" \
            -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN}" \
            >>"$LOG_FILE" 2>&1; then
        die "生成自签证书失败，请检查 openssl 是否可用"
    fi
    chmod 600 "$crt" "$key"
    CADDY_CERT_SRC="$crt"
    CADDY_KEY_SRC="$key"
    HY2_CERT_MODE="selfsigned"
    log_warn "已生成自签证书（客户端需设置 tls.insecure: true）"
}

# 把证书准备好给 Hysteria2：
#   - 优先符号链接到 Caddy 的证书文件：hysteria 每次 TLS 握手都会重新读取证书，
#     Caddy 续期后自动生效，无需重启、无需额外定时任务
#   - 链接失败则退化为复制（此时续期需要重跑脚本或手动同步）
link_cert_to_hy2() {
    local crt_src="$1" key_src="$2"
    mkdir -p "$HY2_TLS_DIR" || die "无法创建目录：$HY2_TLS_DIR"
    chmod 700 "$HY2_TLS_DIR"

    local crt="${HY2_TLS_DIR}/${DOMAIN}.crt" key="${HY2_TLS_DIR}/${DOMAIN}.key"
    rm -f "$crt" "$key"

    if ln -s "$crt_src" "$crt" 2>/dev/null && ln -s "$key_src" "$key" 2>/dev/null; then
        log_ok "已符号链接 Caddy 证书 → ${HY2_TLS_DIR}/（Caddy 续期后自动生效）"
    else
        rm -f "$crt" "$key"
        cp -a "$crt_src" "$crt" && cp -a "$key_src" "$key" \
            || die "复制证书失败：$crt_src"
        chmod 600 "$crt" "$key"
        log_warn "符号链接失败，已改为复制证书（Caddy 续期后需重跑本脚本同步）"
    fi
    CADDY_CERT_SRC="$crt_src"
    CADDY_KEY_SRC="$key_src"
    HY2_CERT_MODE="caddy"
}

#-------------------------------------------------------------------------------
# 二进制安装
#-------------------------------------------------------------------------------
# 需要 AVX 支持吗（AMD EPYC / 现代 Intel 都支持；不支持则用普通版本）
cpu_has_avx() {
    [ -r /proc/cpuinfo ] || return 1
    grep -qm1 -E '(^| )avx( |$)' /proc/cpuinfo
}

install_hysteria_binary() {
    if [ -x "$HY2_BIN" ] && [ "$ROTATE_SECRETS" != "1" ]; then
        local cur
        cur=$("$HY2_BIN" version 2>/dev/null | head -n1 || true)
        if [ -n "$cur" ]; then
            log_info "已安装 Hysteria2：$cur（如需升级请先删除 $HY2_BIN）"
            HY2_ARCH=$(state_get HY2_ARCH 2>/dev/null || echo "amd64")
            return 0
        fi
    fi

    local tmp arch_candidates=() asset
    tmp=$(mktemp) || die "无法创建临时文件"

    if cpu_has_avx; then
        arch_candidates=("amd64-avx" "amd64")
    else
        arch_candidates=("amd64")
    fi

    for asset in "${arch_candidates[@]}"; do
        log_info "尝试 Hysteria2 二进制：hysteria-linux-${asset}"
        if download_file "${HYSTERIA_RELEASE_BASE}/hysteria-linux-${asset}" "$tmp" 300; then
            chmod 755 "$tmp"
            if "$tmp" version >/dev/null 2>&1; then
                install -m 755 "$tmp" "$HY2_BIN" || die "安装到 $HY2_BIN 失败"
                HY2_ARCH="$asset"
                log_ok "Hysteria2 安装成功：$("$HY2_BIN" version 2>/dev/null | head -n1)（${asset}）"
                rm -f "$tmp"
                return 0
            fi
            log_warn "该二进制在当前 CPU 上无法运行（可能缺少指令集），尝试下一个版本"
        fi
    done

    rm -f "$tmp"
    die "Hysteria2 二进制下载或运行失败，请检查网络或使用 -p 指定加速代理"
}

install_frp_binaries() {
    local need=0
    [ -x "$FRPS_BIN" ] || need=1
    [ -x "$FRPC_BIN" ] || need=1

    if [ "$need" -eq 0 ] && [ "$ROTATE_SECRETS" != "1" ]; then
        local cur
        cur=$("$FRPS_BIN" --version 2>/dev/null | head -n1)
        log_info "已安装 frp：${cur:-未知版本}"
        # 已安装时也必须确定版本号：生成 Mac 端对接包要用它拼 darwin 包名，
        # 否则会写出 frp__darwin_arm64.tar.gz 这种缺版本号的错误文件名。
        if [ -z "$FRP_VERSION" ]; then
            FRP_VERSION=$(printf '%s' "$cur" | sed -nE 's/.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)
        fi
        [ -n "$FRP_VERSION" ] || fetch_frp_version
        return 0
    fi

    fetch_frp_version
    local tarball url tmpdir inner
    tmpdir=$(mktemp -d) || die "无法创建临时目录"
    tarball="${tmpdir}/frp.tar.gz"
    inner="frp_${FRP_VERSION}_linux_amd64"
    url="${FRP_REPO}/releases/download/v${FRP_VERSION}/${inner}.tar.gz"

    if ! download_file "$url" "$tarball" 300; then
        rm -rf "$tmpdir"
        die "frp 下载失败（v${FRP_VERSION}）。可用 --frp-version 指定其他版本后重试"
    fi

    if ! tar -xzf "$tarball" -C "$tmpdir" >>"$LOG_FILE" 2>&1; then
        rm -rf "$tmpdir"
        die "解压 frp 压缩包失败：$LOG_FILE"
    fi
    [ -d "${tmpdir}/${inner}" ] || { rm -rf "$tmpdir"; die "frp 压缩包结构异常，未找到 ${inner}"; }

    install -m 755 "${tmpdir}/${inner}/frps" "$FRPS_BIN" || { rm -rf "$tmpdir"; die "安装 frps 失败"; }
    install -m 755 "${tmpdir}/${inner}/frpc" "$FRPC_BIN" || { rm -rf "$tmpdir"; die "安装 frpc 失败"; }
    rm -rf "$tmpdir"
    log_ok "frp 安装成功：$("$FRPS_BIN" --version 2>/dev/null | head -n1)（frps + frpc）"
}

#-------------------------------------------------------------------------------
# frps（反向隧道服务端）
#-------------------------------------------------------------------------------
write_frps_config() {
    mkdir -p "$FRP_CONFIG_DIR" || die "无法创建目录：$FRP_CONFIG_DIR"
    chmod 700 "$FRP_CONFIG_DIR" 2>/dev/null || true

    cat > "$FRPS_CONFIG" <<EOF
# 由 ${SCRIPT_NAME} 生成 —— 请勿手工修改（重跑脚本会覆盖）
# 只监听回环：Mac 端的 frpc 是通过 Hysteria2 隧道「回到本机」来登录的，
# 公网无法直接访问 frps，也不会有额外的端口暴露在公网上。
bindAddr = "127.0.0.1"
bindPort = ${FRPS_BIND_PORT}
proxyBindAddr = "127.0.0.1"

auth.method = "token"
auth.token = "${FRP_TOKEN}"

# Hysteria2 已经做了端到端加密，这里再套一层 frp 自带 TLS 只是白耗 CPU
transport.tls.force = false

log.to = "/var/log/frps.log"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true
EOF
    chmod 600 "$FRPS_CONFIG"
    log_ok "已写入 frps 配置：$FRPS_CONFIG"
}

write_frps_service() {
    cat > "$FRPS_UNIT_FILE" <<EOF
# 由 ${SCRIPT_NAME} 生成
[Unit]
Description=frp server (NAS reverse tunnel)
After=network.target

[Service]
Type=simple
ExecStart=${FRPS_BIN} -c ${FRPS_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "已写入 systemd 单元：$FRPS_UNIT_FILE"
}

validate_frps_config() {
    # frp 较新版本提供 verify 子命令；不支持时跳过（启动阶段仍会暴露问题）
    if "$FRPS_BIN" verify -c "$FRPS_CONFIG" >>"$LOG_FILE" 2>&1; then
        log_ok "frps 配置校验通过"
        return 0
    fi
    if "$FRPS_BIN" verify --help >/dev/null 2>&1; then
        log_err "frps 配置校验失败，详情：$LOG_FILE"
        return 1
    fi
    log_info "当前 frp 版本无 verify 子命令，跳过配置校验"
    return 0
}

start_frps() {
    systemctl enable "$FRPS_SERVICE" >>"$LOG_FILE" 2>&1 || true
    if ! systemctl restart "$FRPS_SERVICE" >>"$LOG_FILE" 2>&1; then
        log_err "frps 启动失败，最近日志："
        journalctl -u "$FRPS_SERVICE" --no-pager -n 25 2>/dev/null | sed 's/^/      /' | tee -a "$LOG_FILE"
        die "frps 启动失败"
    fi
    if ! wait_for_tcp_port "$FRPS_BIND_PORT" 20; then
        log_err "frps 未在 ${FRPS_BIND_PORT} 上监听，最近日志："
        journalctl -u "$FRPS_SERVICE" --no-pager -n 25 2>/dev/null | sed 's/^/      /' | tee -a "$LOG_FILE"
        die "frps 未正常监听"
    fi
    log_ok "frps 已运行：127.0.0.1:${FRPS_BIND_PORT}（控制口，仅回环）"
}

#-------------------------------------------------------------------------------
# Hysteria2 服务端
#-------------------------------------------------------------------------------
write_hy2_config() {
    mkdir -p "$HY2_CONFIG_DIR" || die "无法创建目录：$HY2_CONFIG_DIR"
    chmod 700 "$HY2_CONFIG_DIR" 2>/dev/null || true

    local listen_addr cert key sni_guard bandwidth_block masq_block
    if [ -n "$HOP_RANGE" ]; then
        listen_addr=":${HOP_RANGE}"
    else
        listen_addr=":${HY2_PORT}"
    fi

    cert="${HY2_TLS_DIR}/${DOMAIN}.crt"
    key="${HY2_TLS_DIR}/${DOMAIN}.key"
    if [ "$HY2_CERT_MODE" = "caddy" ]; then
        sni_guard="strict"
    else
        sni_guard="disable"
    fi

    # 默认不设服务端带宽：按官方建议，个人自用由客户端决定 Brutal 速率
    if [ -n "$SERVER_BANDWIDTH_DOWN" ]; then
        bandwidth_block="bandwidth:
  down: ${SERVER_BANDWIDTH_DOWN}
"
    else
        bandwidth_block=""
    fi

    if [ "$MASQUERADE_MODE" = "proxy" ]; then
        masq_block="masquerade:
  type: proxy
  proxy:
    url: https://${DOMAIN}
    rewriteHost: true"
    else
        masq_block="masquerade:
  type: string
  string:
    content: '404 page not found'
    statusCode: 404"
    fi

    cat > "$HY2_CONFIG" <<EOF
# 由 ${SCRIPT_NAME} 生成 —— 请勿手工修改（重跑脚本会覆盖）
#
# 说明：
#   - 监听 UDP，使用 Caddy 为 ${DOMAIN} 签发的同一张证书，因此对探测者而言
#     TCP/${HY2_PORT} 与 UDP/${HY2_PORT} 呈现为同一个 HTTPS 站点
#   - 只允许 SNI = ${DOMAIN} 的客户端握手，配合密码认证双重保护
listen: ${listen_addr}

tls:
  cert: ${cert}
  key: ${key}
  sniGuard: ${sni_guard}

auth:
  type: password
  password: ${HY2_PASSWORD}

${bandwidth_block}${masq_block}
EOF
    chmod 600 "$HY2_CONFIG"
    log_ok "已写入 Hysteria2 配置：$HY2_CONFIG"
}

write_hy2_service() {
    # 说明：这里以 root 运行，是为了让 hysteria 能直接读取 Caddy 私钥目录
    # （/var/lib/caddy/.local/share/caddy 整条链路权限 700 caddy:caddy，
    #   证书文件 600）。好处是符号链接即可让证书续期立即生效，
    # 不需要额外的定时同步任务。
    #
    # ⚠️ 关键：CAP_DAC_READ_SEARCH 绝对不能从 CapabilityBoundingSet 里去掉！
    #   root 之所以能读别的用户的 700 目录，靠的就是 CAP_DAC_OVERRIDE /
    #   CAP_DAC_READ_SEARCH 这类绕过 DAC 检查的能力。一旦用
    #   CapabilityBoundingSet 把它们裁掉，root 同样吃 EACCES，表现为
    #   hysteria 启动即 FATAL：
    #     tls.cert: stat /etc/hysteria/tls/<域名>.crt: permission denied
    #   这里只保留 CAP_DAC_READ_SEARCH（仅能读/穿越目录，不能绕过写权限），
    #   是最小够用的选择。
    cat > "$HY2_UNIT_FILE" <<EOF
# 由 ${SCRIPT_NAME} 生成
[Unit]
Description=Hysteria2 Server Service (${DOMAIN})
After=network.target

[Service]
Type=simple
WorkingDirectory=${HY2_CONFIG_DIR}
ExecStart=${HY2_BIN} server --config ${HY2_CONFIG}
Environment=HYSTERIA_LOG_LEVEL=info
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

# 权限收紧（root 运行，但去掉一切非必要能力与提权路径）
# 注意：CAP_DAC_READ_SEARCH 是读取 Caddy 私钥目录所必需的，删掉会导致启动失败
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_DAC_READ_SEARCH
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "已写入 systemd 单元：$HY2_UNIT_FILE"
}

# Hysteria2 启动失败时的针对性诊断（把最容易踩的两类坑直接指出来）
hysteria_failure_hint() {
    local logs
    logs=$(journalctl -u "$HY2_SERVICE" --no-pager -n 40 2>/dev/null) || return 0

    if echo "$logs" | grep -qi 'tls.cert.*permission denied\|permission denied.*\.crt'; then
        log_raw ""
        log_err "诊断：hysteria 读不到证书文件 —— 这是 systemd 单元的能力集问题，不是文件不存在。"
        log_raw "      证书是符号链接到 Caddy 的私钥目录（各级 700 caddy:caddy，文件 600）。"
        log_raw "      root 能读它靠的是 CAP_DAC_READ_SEARCH / CAP_DAC_OVERRIDE；"
        log_raw "      如果 CapabilityBoundingSet 里没有 CAP_DAC_READ_SEARCH，root 一样会 EACCES。"
        log_raw "      自检命令：systemctl show ${HY2_SERVICE} -p CapabilityBoundingSet"
        log_raw "      修复：把 CAP_DAC_READ_SEARCH 加回 ${HY2_UNIT_FILE} 后 systemctl daemon-reload && systemctl restart ${HY2_SERVICE}"
    elif echo "$logs" | grep -qi 'address already in use\|bind'; then
        log_err "诊断：UDP ${HY2_PORT} 被其他进程占用 —— 用 ss -ulnpe | grep :${HY2_PORT} 查看占用者"
    elif echo "$logs" | grep -qi 'no such file\|cannot find'; then
        log_err "诊断：配置或证书文件缺失，检查 ${HY2_CONFIG} 与 ${HY2_TLS_DIR}/"
    fi
}

start_hysteria() {
    systemctl enable "$HY2_SERVICE" >>"$LOG_FILE" 2>&1 || true
    if ! systemctl restart "$HY2_SERVICE" >>"$LOG_FILE" 2>&1; then
        log_err "Hysteria2 启动失败，最近日志："
        journalctl -u "$HY2_SERVICE" --no-pager -n 25 2>/dev/null | sed 's/^/      /' | tee -a "$LOG_FILE"
        hysteria_failure_hint
        die "Hysteria2 启动失败"
    fi
    sleep 1
    if ! wait_for_udp_port "$HY2_PORT" 20; then
        log_err "Hysteria2 未在 UDP ${HY2_PORT} 上监听，最近日志："
        journalctl -u "$HY2_SERVICE" --no-pager -n 25 2>/dev/null | sed 's/^/      /' | tee -a "$LOG_FILE"
        hysteria_failure_hint
        die "Hysteria2 未正常监听"
    fi
    log_ok "Hysteria2 已运行：UDP/${HY2_PORT}（证书来源：${HY2_CERT_MODE}）"
}

#-------------------------------------------------------------------------------
# 端到端自检
#-------------------------------------------------------------------------------
selftest_cleanup() {
    local pid
    for pid in "${SELFTEST_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    done
    SELFTEST_PIDS=()
    if [ -n "$SELFTEST_TMP" ] && [ -d "$SELFTEST_TMP" ]; then
        rm -rf "$SELFTEST_TMP"
    fi
    SELFTEST_TMP=""
}

trap 'selftest_cleanup' EXIT

# 挑选一个可用的本机 HTTP 靶机（仅用于自检，证明隧道真的能取到后端内容）
pick_selftest_backend() {
    local p code
    for p in "$MAC_OPENLIST_PORT" 8000 2019 80; do
        code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:${p}/" 2>/dev/null) || code="000"
        if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# 生成自检用的临时 Hysteria2 客户端配置并启动，返回 0 表示 socks5 已就绪
start_selftest_hy2_client() {
    local conf="${SELFTEST_TMP}/client.yaml" insecure="false"
    [ "$HY2_CERT_MODE" = "selfsigned" ] && insecure="true"

    cat > "$conf" <<EOF
server: 127.0.0.1:${HY2_PORT}
auth: ${HY2_PASSWORD}

tls:
  sni: ${DOMAIN}
  insecure: ${insecure}

socks5:
  listen: 127.0.0.1:${SELFTEST_SOCKS5_PORT}
EOF

    "$HY2_BIN" client --config "$conf" >>"${SELFTEST_TMP}/hy2-client.log" 2>&1 &
    SELFTEST_PIDS+=("$!")

    if wait_for_tcp_port "$SELFTEST_SOCKS5_PORT" 15; then
        return 0
    fi
    return 1
}

# 第一级：证明 Hysteria2 的 TLS + SNI + 密码认证 + 转发全部可用
selftest_hy2_layer() {
    log_info "自检 1/2：Hysteria2 隧道层..."
    SELFTEST_TMP=$(mktemp -d) || { log_err "无法创建自检临时目录"; return 1; }

    if ! start_selftest_hy2_client; then
        log_err "临时 Hysteria2 客户端未能就绪，日志："
        sed 's/^/      /' "${SELFTEST_TMP}/hy2-client.log" 2>/dev/null | tee -a "$LOG_FILE"
        return 1
    fi

    local code
    code=$(curl -s -o /dev/null --max-time 25 -w '%{http_code}' \
           -x "socks5h://127.0.0.1:${SELFTEST_SOCKS5_PORT}" https://www.baidu.com 2>/dev/null) || code="000"

    if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
        log_ok "Hysteria2 隧道层正常（经隧道访问外网返回 HTTP $code）"
        return 0
    fi
    log_err "Hysteria2 隧道层自检失败（HTTP $code）"
    log_err "临时客户端日志："
    tail -n 20 "${SELFTEST_TMP}/hy2-client.log" 2>/dev/null | sed 's/^/      /' | tee -a "$LOG_FILE"
    return 1
}

# 判断真实链路是否已经在工作（Mac 端已上线的情况）
real_path_ok() {
    local code
    code=$(curl -s -o /dev/null --max-time 8 --resolve "${DOMAIN}:443:127.0.0.1" \
           -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null) || code="000"
    [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
}

# 第二级：证明 Caddy→frps→Hysteria2→frpc→后端 整条生产路径可用
selftest_full_chain() {
    log_info "自检 2/2：完整链路（Caddy → frps → Hysteria2 → frpc → 后端）..."

    if real_path_ok; then
        log_ok "真实链路已在线（Mac 端已连接），https://${DOMAIN}/ 正常响应"
        return 0
    fi

    local backend
    backend=$(pick_selftest_backend) || {
        log_warn "本机找不到可用 HTTP 靶机，跳过完整链路自检"
        return 0
    }
    log_info "使用本机 127.0.0.1:${backend} 作为临时后端靶机"

    SELFTEST_TMP="${SELFTEST_TMP:-$(mktemp -d)}"
    if ! tcp_listening_on "$SELFTEST_SOCKS5_PORT"; then
        if ! start_selftest_hy2_client; then
            log_err "临时 Hysteria2 客户端未能就绪，跳过完整链路自检"
            return 1
        fi
    fi

    # 临时 frpc：完全照抄 Mac 端将要使用的连接方式
    cat > "${SELFTEST_TMP}/frpc.toml" <<EOF
serverAddr = "127.0.0.1"
serverPort = ${FRPS_BIND_PORT}
loginFailExit = false

auth.method = "token"
auth.token = "${FRP_TOKEN}"

transport.tls.enable = false
transport.proxyURL = "socks5://127.0.0.1:${SELFTEST_SOCKS5_PORT}"

log.to = "${SELFTEST_TMP}/frpc.log"
log.level = "info"
log.disablePrintColor = true

[[proxies]]
name = "selftest"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${backend}
remotePort = ${FRPS_PROXY_PORT}
EOF

    "$FRPC_BIN" -c "${SELFTEST_TMP}/frpc.toml" >>"${SELFTEST_TMP}/frpc-stdout.log" 2>&1 &
    SELFTEST_PIDS+=("$!")

    local i=0 code
    while [ "$i" -lt 40 ]; do
        code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:${FRPS_PROXY_PORT}/" 2>/dev/null) || code="000"
        [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && break
        sleep 1
        i=$((i + 1))
    done

    if ! [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
        log_err "隧道链路自检失败：127.0.0.1:${FRPS_PROXY_PORT} 未取到后端响应（HTTP $code）"
        log_err "temp frpc 日志："
        tail -n 25 "${SELFTEST_TMP}/frpc.log" 2>/dev/null | sed 's/^/      /' | tee -a "$LOG_FILE"
        tail -n 25 "${SELFTEST_TMP}/frpc-stdout.log" 2>/dev/null | sed 's/^/      /' | tee -a "$LOG_FILE"
        return 1
    fi
    log_ok "隧道链路正常（frps → Hysteria2 → frpc → 后端返回 HTTP $code）"

    if [ "$HY2_CERT_MODE" = "caddy" ]; then
        local hcode
        hcode=$(curl -s -o /dev/null --max-time 10 --resolve "${DOMAIN}:443:127.0.0.1" \
                -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null) || hcode="000"
        if [[ "$hcode" =~ ^[1-5][0-9][0-9]$ ]]; then
            log_ok "完整链路正常：https://${DOMAIN}/ 返回 HTTP $hcode（证书由 Caddy 签发）"
        else
            log_warn "Caddy 层未取到响应（HTTP $hcode），请检查：systemctl status caddy"
            return 1
        fi
    else
        log_warn "当前为自签证书模式，跳过 Caddy HTTPS 断言（域名 HTTPS 暂不可用）"
    fi
    return 0
}

run_selftests() {
    local ok=0
    selftest_hy2_layer || ok=1
    selftest_full_chain || ok=1
    selftest_cleanup
    return "$ok"
}

#-------------------------------------------------------------------------------
# Mac 端对接包与凭据文件
#-------------------------------------------------------------------------------
hy2_uri() {
    local server_addr insecure="0"
    [ "$HY2_CERT_MODE" = "selfsigned" ] && insecure="1"
    if [ -n "$HOP_RANGE" ]; then
        server_addr="${PUBLIC_IP}:${HOP_RANGE}"
    else
        server_addr="${PUBLIC_IP}:${HY2_PORT}"
    fi
    printf 'hysteria2://%s@%s/?sni=%s&insecure=%s#%s' \
        "$HY2_PASSWORD" "$server_addr" "$DOMAIN" "$insecure" "$DOMAIN"
}

write_client_bundle() {
    mkdir -p "$CLIENT_BUNDLE_DIR" || { log_warn "无法创建对接包目录：$CLIENT_BUNDLE_DIR"; return 1; }
    chmod 700 "$CLIENT_BUNDLE_DIR" 2>/dev/null || true

    local insecure="false" cert_note sni_note insecure_note
    if [ "$HY2_CERT_MODE" = "selfsigned" ]; then
        insecure="true"
        cert_note="服务器当前是**自签证书**模式：\`insecure: true\` 必须保留；浏览器直接访问域名会报证书错误，需要先修好 DNS / 备案后重跑服务器脚本。"
        sni_note="必须与服务器端证书的域名一致（当前是自签模式，sniGuard 已关闭，域名仍用于 SNI 与 Caddy 路由）"
        insecure_note="服务器当前是自签证书，这里必须是 true"
    else
        cert_note="服务器使用 Caddy 签发的真证书：\`insecure: false\`，不要改成 true。"
        sni_note="必须与服务器端证书的域名一致（服务器开启了 sniGuard: strict，SNI 不匹配会直接断开）"
        insecure_note="服务器复用 Caddy 签发的真证书，必须保持 false"
    fi

    local server_line extra=""
    if [ -n "$HOP_RANGE" ]; then
        server_line="server: ${PUBLIC_IP}:${HOP_RANGE}"
        extra=$'\nhopInterval: 30s'
    else
        server_line="server: ${PUBLIC_IP}:${HY2_PORT}"
    fi

    cat > "${CLIENT_BUNDLE_DIR}/hysteria-client.yaml" <<EOF
# Mac mini 端 —— Hysteria2 客户端配置
# 由服务器 ${SCRIPT_NAME} 生成，请与服务器端保持一致；如服务器参数变更请重新生成。
${server_line}
auth: ${HY2_PASSWORD}${extra}

tls:
  # ${sni_note}
  sni: ${DOMAIN}
  # ${insecure_note}
  insecure: ${insecure}

# 给本机的 frpc 用的 socks5 入站；frpc 通过它把「127.0.0.1:${FRPS_BIND_PORT}」交给服务器拨号
socks5:
  listen: 127.0.0.1:${MAC_SOCKS5_PORT}
  username: ${SOCKS5_USER}
  password: ${SOCKS5_PASS}

# 关键：不写 bandwidth 的话 Hysteria2 会退回 BBR，拿不到 Brutal 的抗丢包/抢带宽效果。
# up  = 你家宽带的上行（决定服务器从你这里取数据的速度）
# down= 你家宽带的下行（一般不是瓶颈）
bandwidth:
  up: ${HOME_UPLOAD} mbps
  down: 1000 mbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF

    cat > "${CLIENT_BUNDLE_DIR}/frpc.toml" <<EOF
# Mac mini 端 —— frpc 反向隧道客户端配置
# 由服务器 ${SCRIPT_NAME} 生成。
#
# 注意 serverAddr：这里故意写 127.0.0.1。frpc 并不直连服务器，而是把这个
# 「CONNECT 127.0.0.1:${FRPS_BIND_PORT}」交给 Hysteria2 的 socks5 入站，
# 由服务器端的 Hysteria2 进程在服务器本机拨号到 frps。
# 这样 Mac↔服务器 的公网段全程只有 UDP（QUIC），一个 TCP 包都不走公网。
serverAddr = "127.0.0.1"
serverPort = ${FRPS_BIND_PORT}
loginFailExit = false

auth.method = "token"
auth.token = "${FRP_TOKEN}"

# 连接服务器时走本机 Hysteria2 的 socks5 入站
transport.proxyURL = "socks5://${SOCKS5_USER}:${SOCKS5_PASS}@127.0.0.1:${MAC_SOCKS5_PORT}"
transport.tcpMux = true
# Hysteria2 已做端到端加密，去掉 frp 自带的 TLS 层
transport.tls.enable = false

log.to = "/var/log/frpc.log"
log.level = "info"
log.maxDays = 3
log.disablePrintColor = true

[[proxies]]
name = "openlist"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${MAC_OPENLIST_PORT}
remotePort = ${FRPS_PROXY_PORT}

# 需要再暴露别的端口就照抄下面这段（记得同步在 Caddy 里加站点或直接访问该端口）
# [[proxies]]
# name = "openlist-udp-demo"
# type = "udp"
# localIP = "127.0.0.1"
# localPort = 5244
# remotePort = 15245
EOF

    cat > "${CLIENT_BUNDLE_DIR}/README.md" <<EOF
# Mac mini 端对接说明

本目录由服务器上的 \`${SCRIPT_NAME}\` 生成，内容与服务器当前配置**逐字对应**。
服务器参数若有变更，请在服务器上重跑脚本（或执行 \`--status\`）后重新拷贝本目录。

## 一、为什么要两个进程

Hysteria2 v2 **不支持反向隧道**（v1 的端口转发已在 v2 移除），所以拆成两层：

| 层 | 进程 | 职责 |
| --- | --- | --- |
| 过公网 | \`hysteria\`（客户端） | 用 UDP/QUIC 把 Mac 连到服务器，提供本地 socks5 出口；Brutal 拥塞控制负责抗丢包 |
| 接端口 | \`frpc\` | 反向端口映射：把「服务器上的 ${FRPS_PROXY_PORT} 端口」接到「Mac 的 ${MAC_OPENLIST_PORT}」 |

frpc 不直连服务器：它的 \`serverAddr\` 写成 \`127.0.0.1:${FRPS_BIND_PORT}\`，
由 \`transport.proxyURL\` 把这句 CONNECT 交给 Hysteria2 的 socks5 入站，
最终由**服务器端的 Hysteria2 进程在服务器本机**拨号到 frps。
→ 结果：Mac↔服务器 的公网段**只有 UDP**，没有任何 TCP 包出去。

## 二、需要拿到的参数（服务器上 \`--status\` 会打印）

| 参数 | 当前值 |
| --- | --- |
| 服务器公网 IP | \`${PUBLIC_IP}\` |
| Hysteria2 端口 | \`${HY2_PORT}/udp\`${HOP_RANGE:+（端口跳跃：\`${HOP_RANGE}\`）} |
| Hysteria2 密码 | \`${HY2_PASSWORD}\` |
| 域名 / SNI | \`${DOMAIN}\` |
| 证书模式 | \`${HY2_CERT_MODE}\` |
| frp token | \`${FRP_TOKEN}\` |
| frps 控制口（仅回环） | \`127.0.0.1:${FRPS_BIND_PORT}\` |
| 远端映射端口 | \`${FRPS_PROXY_PORT}\` |
| Mac 端 socks5 入站 | \`127.0.0.1:${MAC_SOCKS5_PORT}\`（用户 \`${SOCKS5_USER}\`） |
| Mac 上 OpenList | \`127.0.0.1:${MAC_OPENLIST_PORT}\` |

分享链接（可直接导进手机客户端，先单独验证隧道是否通）：

\`\`\`
$(hy2_uri)
\`\`\`

## 三、Mac 端安装步骤

1. 下载二进制（Apple Silicon 用 arm64）：
   - hysteria：\`curl -fsSL -o hysteria https://github.com/apernet/hysteria/releases/latest/download/hysteria-darwin-arm64 && chmod +x hysteria\`
   - frp：\`frp_${FRP_VERSION:-$FRP_VERSION_FALLBACK}_darwin_arm64.tar.gz\`（github.com/fatedier/frp/releases）
2. 安装到 \`/usr/local/bin/\`（\`hysteria\`、\`frpc\`）
3. 配置目录建议 \`/usr/local/etc/nas-tunnel/\`，把本目录的
   \`hysteria-client.yaml\` 与 \`frpc.toml\` 放进去
4. **先起 hysteria，再起 frpc**（frpc 有重连，顺序不致命，但日志更干净）

## 四、launchd 自启（两个 plist，都要 KeepAlive）

\`/Library/LaunchDaemons/com.nas.tunnel.hysteria.plist\`：

\`\`\`xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.nas.tunnel.hysteria</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/hysteria</string>
    <string>client</string>
    <string>--config</string>
    <string>/usr/local/etc/nas-tunnel/hysteria-client.yaml</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/nas-tunnel-hysteria.log</string>
  <key>StandardErrorPath</key><string>/var/log/nas-tunnel-hysteria.log</string>
</dict>
</plist>
\`\`\`

\`/Library/LaunchDaemons/com.nas.tunnel.frpc.plist\`：把 Label/ProgramArguments 换成
\`com.nas.tunnel.frpc\` / \`/usr/local/bin/frpc -c /usr/local/etc/nas-tunnel/frpc.toml\`，
日志换成 \`/var/log/nas-tunnel-frpc.log\`。

加载：\`sudo launchctl load -w /Library/LaunchDaemons/com.nas.tunnel.hysteria.plist\`

## 五、必须注意的坑

1. **\`tls.sni\` 必须等于 \`${DOMAIN}\`**。服务器开了 \`sniGuard: strict\`，SNI 不匹配直接断开。
2. **\`bandwidth\` 不能省**。省了 Hysteria2 就退回 BBR，没有 Brutal 的抗丢包/抢带宽效果。
   当前 \`up\` 设为 \`${HOME_UPLOAD} mbps\`，请按你家宽上行实测值调整（先测速再定）。
   服务器出口带宽小时，\`up\` 不要设得远高于它，否则 Brutal 的丢包补偿会猛冲，反而更慢更抖。
3. **\`transport.tls.enable = false\`**：Hysteria2 已经加密，frp 再套 TLS 只是白耗 CPU。
4. **\`serverAddr\` 必须是 \`127.0.0.1\`**，且 \`transport.proxyURL\` 必须指向
   hysteria 的 socks5 入站，否则 frpc 会绕过隧道直连服务器（那就白搭了）。
5. **OpenList 在 Mac 上只监听 \`127.0.0.1:${MAC_OPENLIST_PORT}\`**，不要暴露到局域网。
6. ${cert_note}
7. 服务器安全组必须放行 **UDP ${HY2_PORT} 入站**，否则 Mac 永远连不上
   （服务器本机自检是走回环的，绕过安全组，检测不出这个问题）。

## 六、Mac 端自查命令

\`\`\`bash
# 隧道是否通（应返回 200/301/302）
curl -x socks5h://127.0.0.1:${MAC_SOCKS5_PORT} -s -o /dev/null -w '%{http_code}\n' https://www.baidu.com

# 反向映射是否登记成功（服务器上执行）
#   curl -s --resolve ${DOMAIN}:443:127.0.0.1 https://${DOMAIN}/ -o /dev/null -w '%{http_code}\n'
#   → 200 说明整条链路通了
\`\`\`
EOF

    chmod 600 "${CLIENT_BUNDLE_DIR}/hysteria-client.yaml" "${CLIENT_BUNDLE_DIR}/frpc.toml" 2>/dev/null || true
    log_ok "已生成 Mac 端对接包：${CLIENT_BUNDLE_DIR}/"
}

write_info_file() {
    {
        echo "==========================================================="
        echo " NAS 反向隧道 · 连接信息"
        echo " 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "==========================================================="
        echo ""
        echo "[公网入口]"
        echo "  访问地址      ： https://${DOMAIN}/"
        echo "  域名 (SNI)    ： ${DOMAIN}"
        echo "  证书模式      ： ${HY2_CERT_MODE}"
        echo ""
        echo "[Mac 端连接参数（6 项）]"
        echo "  1. 服务器 IP  ： ${PUBLIC_IP}"
        echo "  2. UDP 端口   ： ${HY2_PORT}${HOP_RANGE:+（跳跃范围 ${HOP_RANGE}）}"
        echo "  3. HY2 密码   ： ${HY2_PASSWORD}"
        echo "  4. 域名/SNI   ： ${DOMAIN}"
        echo "  5. frp token  ： ${FRP_TOKEN}"
        echo "  6. 远端端口   ： ${FRPS_PROXY_PORT}"
        echo ""
        echo "  分享链接      ： $(hy2_uri)"
        echo ""
        echo "[服务器侧内部端口（仅回环，不对外）]"
        echo "  frps 控制口   ： 127.0.0.1:${FRPS_BIND_PORT}"
        echo "  frps 映射口   ： 127.0.0.1:${FRPS_PROXY_PORT}"
        echo "  Caddy 反代到  ： 127.0.0.1:${FRPS_PROXY_PORT}"
        echo ""
        echo "[Mac 端端口约定]"
        echo "  hysteria socks5 入站 ： 127.0.0.1:${MAC_SOCKS5_PORT}（用户 ${SOCKS5_USER}）"
        echo "  OpenList            ： 127.0.0.1:${MAC_OPENLIST_PORT}"
        echo ""
        echo "[文件位置]"
        echo "  Hysteria2 配置 ： ${HY2_CONFIG}"
        echo "  frps 配置      ： ${FRPS_CONFIG}"
        echo "  Caddyfile      ： ${CADDYFILE}"
        echo "  Mac 端对接包   ： ${CLIENT_BUNDLE_DIR}/"
        echo ""
        echo "[手动事项]"
        echo "  1. Cloudflare：为 ${DOMAIN} 添加 A 记录 → ${PUBLIC_IP}，必须关闭小云朵（仅 DNS）"
        echo "  2. 安全组：放行 UDP ${HY2_PORT} 入站"
        echo ""
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE" 2>/dev/null || true
    log_ok "已写入连接信息：$INFO_FILE"
}

print_connection_info() {
    log_raw ""
    log_raw "${C_BOLD}──────────────── Mac 端连接参数（6 项）────────────────${C_RESET}"
    log_raw "  1. 服务器 IP  ： ${C_BOLD}${PUBLIC_IP}${C_RESET}"
    log_raw "  2. UDP 端口   ： ${C_BOLD}${HY2_PORT}${C_RESET}${HOP_RANGE:+（跳跃范围 ${HOP_RANGE}）}"
    log_raw "  3. HY2 密码   ： ${C_BOLD}${HY2_PASSWORD}${C_RESET}"
    log_raw "  4. 域名 / SNI ： ${C_BOLD}${DOMAIN}${C_RESET}"
    log_raw "  5. frp token  ： ${C_BOLD}${FRP_TOKEN}${C_RESET}"
    log_raw "  6. 远端端口   ： ${C_BOLD}${FRPS_PROXY_PORT}${C_RESET}"
    log_raw ""
    log_raw "  分享链接（可导入手机客户端先验证隧道）："
    log_raw "  ${C_CYAN}$(hy2_uri)${C_RESET}"
}

#-------------------------------------------------------------------------------
# 阶段 0：环境准备
#-------------------------------------------------------------------------------
phase0_prepare_env() {
    log_step "阶段 0/6：环境准备"

    local pretty="未知"
    [ -r /etc/os-release ] && pretty=$(. /etc/os-release; echo "${PRETTY_NAME:-未知}")
    log_info "系统：$pretty    架构：$(uname -m)    内核：$(uname -r)"

    if [ "$(uname -m)" != "x86_64" ]; then
        log_warn "当前架构 $(uname -m) 非 x86_64，脚本仅内置 amd64 二进制，请谨慎继续"
        die "本脚本当前只支持 x86_64 服务器"
    fi
    if ! has_cmd systemctl; then
        die "未检测到 systemd，本脚本依赖 systemd 管理服务"
    fi

    ensure_dependencies
    check_disk_space

    if PUBLIC_IP=$(detect_public_ip); then
        log_ok "本机公网 IP：$PUBLIC_IP"
    else
        PUBLIC_IP=""
        log_warn "未能自动探测公网 IP，后续 DNS 预检将被跳过，Mac 端配置里的 IP 需要你手工填写"
    fi
}

#-------------------------------------------------------------------------------
# 阶段 1：预检与交互
#-------------------------------------------------------------------------------
prompt_domain() {
    if [ -n "$DOMAIN" ]; then
        is_valid_domain "$DOMAIN" || die "域名格式不合法：$DOMAIN"
        log_info "使用命令行指定的域名：$DOMAIN"
        return 0
    fi
    [ -t 0 ] || die "当前不是交互式终端，请用 -d/--domain 指定域名"

    log_raw ""
    log_raw "${C_BOLD}请输入用于访问家里 Mac mini（OpenList）的域名${C_RESET}（例如：mac.example.com）"
    log_raw "  · 该域名将由 Caddy 自动申请 Let's Encrypt 证书"
    log_raw "  · 请先把它的 A 记录指向本机公网 IP${PUBLIC_IP:+（$PUBLIC_IP）}，并在 Cloudflare 关闭小云朵"
    log_raw "  · 同一个域名同时被用作 Hysteria2 的 TLS SNI"
    log_raw ""

    while true; do
        ask "域名" ""
        if [ -z "$REPLY" ]; then
            log_warn "域名不能为空，请重新输入"
            continue
        fi
        if is_valid_domain "$REPLY"; then
            DOMAIN="$REPLY"
            return 0
        fi
        log_warn "域名格式不合法：$REPLY，请重新输入"
    done
}

prompt_acme_email() {
    [ "$EMAIL_PROVIDED" -eq 1 ] && return 0
    [ -t 0 ] || return 0

    log_raw ""
    log_raw "${C_BOLD}请输入 Let's Encrypt 证书联系邮箱${C_RESET}（可回车跳过）"
    log_raw "  · 仅用于证书到期/异常提醒；Caddy 通常已注册过账户，可留空"
    log_raw ""
    ask "邮箱（回车跳过）" ""
    if [ -n "$REPLY" ]; then
        if is_valid_email "$REPLY"; then
            ACME_EMAIL="$REPLY"
            log_ok "已设置证书邮箱：$ACME_EMAIL"
        else
            log_warn "邮箱格式不合法，已忽略"
            ACME_EMAIL=""
        fi
    fi
}

# 决定 UDP 端口与是否关闭 Caddy HTTP/3
prompt_hy2_port() {
    # 重复执行：端口已由本脚本的 Hysteria2 占用，保持现状即可
    if [ "$RESUME_EXISTING" -eq 1 ] && service_active "$HY2_SERVICE" && udp_listening_on "$HY2_PORT"; then
        log_info "既有部署仍在运行：UDP ${HY2_PORT} 由 Hysteria2 占用，端口与 HTTP/3 设置保持现状"
        return 0
    fi

    # Caddyfile 里已经有本脚本的全局标记块 → 上次已经关过 HTTP/3，这次必须保持关闭。
    # 否则这里会判定「UDP 443 空闲」，随后把全局块删掉、让 Caddy 的 HTTP/3 重新占用
    # UDP 443，和 Hysteria2 撞车（典型场景：上次部署中途失败后重跑）。
    if [ "$KEEP_H3" -eq 0 ] && [ -f "$CADDYFILE" ] \
       && grep -q "^# >>> nas-tunnel-managed: ${CADDY_GLOBAL_MARK}" "$CADDYFILE"; then
        H3_DISABLED=1
        [ "$HY2_PORT_EXPLICIT" -eq 0 ] && HY2_PORT="$DEFAULT_HY2_PORT"
        log_info "检测到 Caddyfile 中已有本脚本的全局选项块：保持关闭 Caddy HTTP/3，Hysteria2 继续使用 UDP ${HY2_PORT}"
        return 0
    fi

    local h3_owner=""
    if udp_listening_on "$DEFAULT_HY2_PORT"; then
        h3_owner=$(udp_owner_desc "$DEFAULT_HY2_PORT")
    fi

    if [ -n "$h3_owner" ]; then
        log_warn "UDP ${DEFAULT_HY2_PORT} 已被占用："
        log_raw "      $h3_owner"
        log_raw "      通常是 Caddy 的 HTTP/3（QUIC）在监听 UDP ${DEFAULT_HY2_PORT}"
    fi

    if [ "$HY2_PORT_EXPLICIT" -eq 1 ]; then
        is_valid_port "$HY2_PORT" || die "UDP 端口不合法：$HY2_PORT"
        if [ "$HY2_PORT" = "$DEFAULT_HY2_PORT" ] && [ -n "$h3_owner" ]; then
            if [ "$KEEP_H3" -eq 1 ]; then
                die "UDP ${DEFAULT_HY2_PORT} 已被 Caddy 的 HTTP/3 占用，且指定了 --no-disable-h3。请改用 --hy2-port 指定其他端口"
            fi
            log_warn "UDP ${DEFAULT_HY2_PORT} 被 Caddy HTTP/3 占用，将关闭 Caddy 的 HTTP/3 以让位给 Hysteria2"
            H3_DISABLED=1
        fi
        return 0
    fi

    if [ "$KEEP_H3" -eq 1 ]; then
        HY2_PORT="$FALLBACK_HY2_PORT"
        log_info "已指定 --no-disable-h3：Hysteria2 改用 UDP ${HY2_PORT}，Caddy 的 HTTP/3 保持开启"
        return 0
    fi

    if [ -z "$h3_owner" ]; then
        # UDP 443 现在空闲（典型场景：全新机器，Caddy 刚装上、还没跑任何 HTTPS 站点）。
        # 但阶段 4 给本域名写入站点块后，Caddy 会立刻启用 HTTP/3 抢占 UDP 443：
        # 实测 Caddy 日志为 enabling HTTP/3 listener addr=":443"，随后 Hysteria2
        # 直接 FATAL（listen udp :443: bind: address already in use）。
        # 更隐蔽的是：该单元 Type=simple，systemctl restart 仍返回 0，紧接着的
        # wait_for_udp_port 又会看到 Caddy 在听，于是脚本会误报「Hysteria2 已运行」。
        # 所以只要 Hysteria2 用 UDP 443，就必须关掉 Caddy 的 HTTP/3。
        HY2_PORT="$DEFAULT_HY2_PORT"
        H3_DISABLED=1
        log_ok "UDP ${DEFAULT_HY2_PORT} 当前空闲，Hysteria2 将使用它（同时关闭 Caddy HTTP/3，避免阶段 4 写入站点块后被抢占）"
        return 0
    fi

    log_raw ""
    log_raw "  ${C_BOLD}取舍说明：${C_RESET}"
    log_raw "  · 方案 A（推荐）：关闭 Caddy 的 HTTP/3，让 Hysteria2 独占 UDP ${DEFAULT_HY2_PORT}"
    log_raw "    —— 家宽那一跳（真正丢包的一跳）拿到最常用的 UDP 端口，最不容易被运营商限速"
    log_raw "    —— 代价：观众侧只能用 HTTP/1.1 或 HTTP/2（播放器取流本来也基本不用 HTTP/3）"
    log_raw "  · 方案 B：保留 Caddy HTTP/3，Hysteria2 改用 UDP ${FALLBACK_HY2_PORT}"
    log_raw "    —— 代价：非常用 UDP 端口在部分家宽/移动网络被限速更狠"
    log_raw ""
    if [ -t 0 ]; then
        if confirm "是否关闭 Caddy 的 HTTP/3，让 Hysteria2 使用 UDP ${DEFAULT_HY2_PORT}？" y; then
            H3_DISABLED=1
            HY2_PORT="$DEFAULT_HY2_PORT"
            log_info "将关闭 Caddy HTTP/3（原 Caddyfile 会先备份，可用 --uninstall 恢复）"
        else
            HY2_PORT="$FALLBACK_HY2_PORT"
            log_info "保留 Caddy HTTP/3，Hysteria2 使用 UDP ${HY2_PORT}"
        fi
    else
        H3_DISABLED=1
        HY2_PORT="$DEFAULT_HY2_PORT"
        log_info "非交互模式：默认关闭 Caddy HTTP/3 并使用 UDP ${HY2_PORT}"
    fi
}

prompt_home_upload() {
    [ -t 0 ] || return 0
    log_raw ""
    log_raw "${C_BOLD}你家宽带的上行大概是多少 Mbps？${C_RESET}（用于生成 Mac 端 Brutal 目标速率）"
    log_raw "  · 直接回车用默认值 ${HOME_UPLOAD}；不确定就先回车，之后测速再改客户端配置"
    log_raw "  · 注意：不要填得远高于服务器出口带宽，否则 Brutal 丢包补偿会猛冲，反而更慢更抖"
    log_raw ""
    ask "家宽上行 (Mbps)" "$HOME_UPLOAD"
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le 10000 ]; then
        HOME_UPLOAD="$REPLY"
    else
        log_warn "输入不合法，沿用默认值 ${HOME_UPLOAD}"
    fi
}

check_domain_dns() {
    log_info "正在检查域名解析..."
    local ips
    ips=$(resolve_domain_ipv4 "$DOMAIN" | tr '\n' ' ')
    if [ -z "${ips// /}" ]; then
        log_warn "$DOMAIN 当前无法解析出 IPv4 地址"
    elif [ -z "$PUBLIC_IP" ]; then
        log_info "$DOMAIN 解析到：${ips% }"
        return 0
    elif echo " $ips " | grep -q " $PUBLIC_IP "; then
        log_ok "$DOMAIN 已正确解析到本机公网 IP（$PUBLIC_IP）"
        return 0
    else
        log_warn "$DOMAIN 解析到 ${ips% }，与本机公网 IP（$PUBLIC_IP）不一致"
    fi

    DNS_OK=0
    log_warn "证书申请（TLS-ALPN-01）依赖域名正确解析到本机，否则一定签不下来"
    log_warn "Cloudflare 必须处于「仅 DNS」（关闭小云朵），否则挑战穿不过代理"
    if [ -t 0 ]; then
        confirm "仍要继续吗？（继续会走自签证书降级）" n || die "已取消。请先配置 DNS 解析后再运行"
    fi
}

check_port_conflicts() {
    has_cmd ss || return 0

    if udp_listening_on "$HY2_PORT"; then
        if [ "$H3_DISABLED" -eq 1 ] && [ "$HY2_PORT" = "$DEFAULT_HY2_PORT" ]; then
            log_info "UDP ${HY2_PORT} 当前由 Caddy 的 HTTP/3 占用，将在阶段 4 关闭 HTTP/3 后交给 Hysteria2"
        else
            die "UDP ${HY2_PORT} 已被占用，请改用 --hy2-port 指定其他端口"
        fi
    fi

    local p
    for p in "$FRPS_BIND_PORT" "$FRPS_PROXY_PORT"; do
        if tcp_listening_on "$p"; then
            if service_active "$FRPS_SERVICE"; then
                log_info "TCP ${p} 已被本脚本部署的 frps 占用（重复执行，属正常）"
            else
                die "TCP ${p} 已被其他进程占用，请释放后重试（或调整 FRPS 端口常量）"
            fi
        fi
    done
    log_ok "端口检查通过（HY2 UDP ${HY2_PORT} / frps TCP ${FRPS_BIND_PORT},${FRPS_PROXY_PORT}）"
}

print_manual_tips() {
    log_raw ""
    log_raw "${C_YELLOW}${C_BOLD}请注意（脚本无法代替你完成）：${C_RESET}"
    log_raw "  1. ${C_BOLD}云服务器安全组必须放行 UDP ${HY2_PORT} 入站${C_RESET}（Hysteria2 隧道依赖，最容易漏）"
    log_raw "     本机自检走的是回环地址，会绕过安全组，所以这个问题的表现是"
    log_raw "     「脚本全绿但 Mac 连不上」——请务必去控制台确认"
    log_raw "  2. Cloudflare 需为 ${DOMAIN} 添加 A 记录指向本机公网 IP${PUBLIC_IP:+（$PUBLIC_IP）}，且关闭小云朵（仅 DNS）"
    log_raw "  3. 域名需已完成 ICP 备案，否则国内云厂商可能阻断 80/443 导致证书签发失败"
    log_raw ""
}

show_deploy_summary() {
    local proto="HTTPS（Caddy 自动申请并续期 Let's Encrypt 证书）"
    local h3_desc="保持开启"
    [ "$H3_DISABLED" -eq 1 ] && h3_desc="关闭（把 UDP ${DEFAULT_HY2_PORT} 让给 Hysteria2）"

    log_raw ""
    log_raw "${C_BOLD}──────────────── 部署配置确认 ────────────────${C_RESET}"
    log_raw "  访问域名    ： https://${DOMAIN}/"
    log_raw "  访问协议    ： ${proto}"
    log_raw "  证书邮箱    ： ${ACME_EMAIL:-（未填写，沿用 Caddy 已有账户）}"
    log_raw "  本机公网 IP ： ${PUBLIC_IP:-（未探测到）}"
    log_raw "  Hysteria2   ： UDP ${HY2_PORT}${HOP_RANGE:+（端口跳跃 ${HOP_RANGE}）}"
    log_raw "  Caddy HTTP/3： ${h3_desc}"
    log_raw "  frps 控制口 ： 127.0.0.1:${FRPS_BIND_PORT}（仅回环）"
    log_raw "  frps 映射口 ： 127.0.0.1:${FRPS_PROXY_PORT} → Caddy 反代目标"
    log_raw "  Mac 家宽上行： ${HOME_UPLOAD} mbps（写入客户端 bandwidth.up）"
    log_raw "  下载线路    ： ${GH_PROXY:-直连 GitHub}"
    if [ "$RESUME_EXISTING" -eq 1 ]; then
        log_raw "  ${C_YELLOW}已有部署  ： 沿用现有密码/token 与端口（幂等更新）${C_RESET}"
    fi
    log_raw ""

    if [ -t 0 ]; then
        confirm "确认按以上配置部署吗？" y || die "已取消"
    fi
}

# 状态文件丢失（例如上次部署中途失败）时，从现有服务端配置里恢复关键参数，
# 避免重跑时生成新密钥、把已经配好的 Mac 端打散
recover_from_live_config() {
    local v
    if [ -z "$FRP_TOKEN" ] && [ -f "$FRPS_CONFIG" ]; then
        v=$(sed -nE 's/^auth\.token *= *"(.*)"$/\1/p' "$FRPS_CONFIG" 2>/dev/null | head -n1)
        [ -n "$v" ] && FRP_TOKEN="$v"
    fi
    if [ -z "$HY2_PASSWORD" ] && [ -f "$HY2_CONFIG" ]; then
        v=$(sed -nE 's/^  password: *(.+)$/\1/p' "$HY2_CONFIG" 2>/dev/null | head -n1)
        [ -n "$v" ] && HY2_PASSWORD="$v"
    fi
    if [ -f "$HY2_CONFIG" ] && [ "$HY2_PORT_EXPLICIT" -eq 0 ]; then
        v=$(sed -nE 's/^listen: *:([0-9]+)$/\1/p' "$HY2_CONFIG" 2>/dev/null | head -n1)
        [ -n "$v" ] && HY2_PORT="$v"
    fi
    if [ -n "$FRP_TOKEN" ] || [ -n "$HY2_PASSWORD" ]; then
        log_info "已从现有服务端配置恢复密钥与端口（上次部署可能中途失败）"
    fi
}

phase1_precheck() {
    log_step "阶段 1/6：预检与交互"

    # 命令行显式指定的域名优先级最高；先记下来，因为 load_state 会覆盖 DOMAIN
    local cli_domain="$DOMAIN"

    # 已有部署：沿用既有密钥、端口与下载线路，避免把已经在跑的 Mac 端打散
    if [ -f "$STATE_FILE" ] && [ "$ROTATE_SECRETS" != "1" ]; then
        if load_state; then
            RESUME_EXISTING=1
            log_info "检测到既有部署，沿用现有密码/token 与端口（如需重置请加 --rotate-secrets）"
        fi
    fi
    [ -n "$cli_domain" ] && DOMAIN="$cli_domain"

    if [ "$ROTATE_SECRETS" = "1" ]; then
        HY2_PASSWORD=""
        FRP_TOKEN=""
        SOCKS5_USER=""
        SOCKS5_PASS=""
        log_warn "已指定 --rotate-secrets：将重新生成全部密钥（Mac 端配置需要同步更新）"
    fi

    prompt_domain

    # 没有状态文件但服务端配置还在（上次中途失败）：尽量沿用原密钥，不要凭空换掉
    if [ "$ROTATE_SECRETS" != "1" ]; then
        recover_from_live_config
    fi

    [ -n "$HY2_PASSWORD" ] || HY2_PASSWORD=$(random_secret 32)
    [ -n "$FRP_TOKEN" ]    || FRP_TOKEN=$(random_secret 32)
    [ -n "$SOCKS5_USER" ]  || SOCKS5_USER="nas$(random_secret 6)"
    [ -n "$SOCKS5_PASS" ]  || SOCKS5_PASS=$(random_secret 24)

    prompt_acme_email
    prompt_hy2_port
    prompt_home_upload

    echo
    check_caddy_ready
    check_domain_dns
    check_port_conflicts
    print_manual_tips
    select_gh_proxy
    show_deploy_summary
}

#-------------------------------------------------------------------------------
# 阶段 2：下载安装二进制
#-------------------------------------------------------------------------------
phase2_download_binaries() {
    log_step "阶段 2/6：下载安装二进制（hysteria / frp）"
    install_hysteria_binary
    install_frp_binaries
}

#-------------------------------------------------------------------------------
# 阶段 3：部署 frps
#-------------------------------------------------------------------------------
phase3_deploy_frps() {
    log_step "阶段 3/6：部署 frps（反向隧道服务端）"
    write_frps_config
    validate_frps_config || die "frps 配置校验失败，已中止（详情：$LOG_FILE）"
    write_frps_service
    start_frps
}

#-------------------------------------------------------------------------------
# 阶段 4：配置 Caddy（站点 + 证书）
#-------------------------------------------------------------------------------
phase4_configure_caddy() {
    log_step "阶段 4/6：配置 Caddy（域名反代 / 证书）"

    # 换域名重跑时，清理本脚本此前管理的其他域名（只动自家 nas-tunnel-managed 标记）
    local old
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        [ "$old" = "$DOMAIN" ] && continue
        log_warn "检测到本脚本此前管理的其他域名：$old（换域名遗留），正在移除其站点块"
        remove_caddy_blocks "$old"
    done < <(list_managed_domains)

    # 同域名冲突检查：只针对本脚本直接要写的域名，做定向询问
    local conflict
    conflict=$(detect_conflicting_block "$DOMAIN" || true)
    if [ -n "$conflict" ]; then
        log_warn "Caddyfile 中已存在同域名的站点块（可能来自其他脚本）："
        log_raw "      $conflict"
        log_raw "      两者会冲突（Caddy 不允许同一域名出现两次）"
        if [ -t 0 ] && confirm "是否移除这个旧站点块，以便本脚本接管该域名？" y; then
            local bak=""
            bak=$(backup_file "$CADDYFILE" "$CADDY_BACKUP_DIR") || bak=""
            [ -n "$bak" ] && log_info "已备份 Caddyfile：$bak"
            remove_foreign_block "$DOMAIN"
        else
            die "域名 ${DOMAIN} 已被占用，请换一个域名或先手动清理 Caddyfile"
        fi
    fi

    install_caddy_config

    # DNS 没指到本机时 ACME 必然失败，没必要白等满 120 秒
    local cert_wait=120
    if [ "$DNS_OK" -eq 0 ]; then
        cert_wait=15
        log_warn "域名解析未指向本机，证书申请预期会失败，本次只等待 ${cert_wait} 秒即转入自签降级"
    fi
    log_info "正在等待 Caddy 为 ${DOMAIN} 签发证书（TLS-ALPN-01，通常 10~60 秒）..."
    local out
    if out=$(wait_caddy_cert "$DOMAIN" "$cert_wait"); then
        local crt key
        crt=$(printf '%s\n' "$out" | sed -n '1p')
        key=$(printf '%s\n' "$out" | sed -n '2p')
        log_ok "证书已签发：$crt"
        link_cert_to_hy2 "$crt" "$key"
    else
        log_warn "等待证书超时，未能定位到 Caddy 为 ${DOMAIN} 签发的证书"
        log_warn "常见原因：DNS 未指向本机 / Cloudflare 开了小云朵 / 80·443 被安全组或备案拦截"
        log_warn "降级方案：生成自签证书，先让隧道跑起来（Mac 端需设 tls.insecure: true）"
        make_selfsigned_cert
    fi

    # 伪装（masquerade）可行性：Hysteria2 需要把探测请求代理到真站点
    if [ "$HY2_CERT_MODE" = "caddy" ]; then
        local hcode
        hcode=$(curl -s -o /dev/null --max-time 12 -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null) || hcode="000"
        if [[ "$hcode" =~ ^[1-5][0-9][0-9]$ ]]; then
            MASQUERADE_MODE="proxy"
            if [ "$hcode" = "502" ] || [ "$hcode" = "503" ]; then
                log_info "回环访问 https://${DOMAIN}/ 返回 HTTP ${hcode}（Mac 端未上线、反代后端为空，属正常）"
                log_info "伪装仍用 proxy 模式：Mac 上线后，探测者经 UDP/${HY2_PORT} 看到的就是真实 OpenList 页面"
            else
                log_ok "本地回环访问 https://${DOMAIN}/ 正常（HTTP $hcode），伪装将使用 proxy 模式"
            fi
        else
            MASQUERADE_MODE="string"
            log_warn "本机回环访问 https://${DOMAIN}/ 失败（HTTP $hcode），伪装降级为固定 404 响应"
        fi
    else
        MASQUERADE_MODE="string"
    fi
}

#-------------------------------------------------------------------------------
# 阶段 5：部署 Hysteria2 并自检
#-------------------------------------------------------------------------------
phase5_deploy_hysteria() {
    log_step "阶段 5/6：部署 Hysteria2 并自检"

    write_hy2_config
    write_hy2_service
    start_hysteria

    log_step "端到端自检"
    if run_selftests; then
        log_ok "两级自检全部通过"
    else
        log_warn "自检未完全通过，请根据上面的输出排查；服务和配置已保留，可直接增量修复"
    fi

    if real_path_ok; then
        log_ok "真实链路已在工作：https://${DOMAIN}/ 可访问"
    else
        log_raw ""
        log_raw "  ${C_BOLD}当前访问 https://${DOMAIN}/ 会返回 502 —— 这是${C_RESET}${C_GREEN}${C_BOLD}正确状态${C_RESET}${C_BOLD}：${C_RESET}"
        log_raw "  Caddy 与隧道都已就绪，只是 Mac mini 上的 frpc 还没上线。"
        log_raw "  等你按 ${CLIENT_BUNDLE_DIR}/README.md 在 Mac 上起好 hysteria + frpc，"
        log_raw "  502 会自动变成 OpenList 页面，无需再动服务器。"
    fi
}

#-------------------------------------------------------------------------------
# 阶段 6：生成对接包与汇总
#-------------------------------------------------------------------------------
phase6_summary() {
    log_step "阶段 6/6：生成 Mac 端对接包与汇总"

    save_state
    write_client_bundle || true
    write_info_file

    log_raw ""
    log_raw "${C_GREEN}${C_BOLD}════════════════ NAS 反向隧道部署完成 ════════════════${C_RESET}"
    log_raw ""
    log_raw "  公网入口   ： ${C_BOLD}https://${DOMAIN}/${C_RESET}"
    log_raw "  证书模式   ： ${HY2_CERT_MODE}$([ "$HY2_CERT_MODE" = "selfsigned" ] && echo "（自签，需客户端 insecure: true）" || echo "（Caddy 自动续期）")"
    log_raw ""

    print_connection_info

    log_raw ""
    log_raw "${C_BOLD}服务器侧路径：${C_RESET}"
    log_raw "  Hysteria2 配置 ： ${HY2_CONFIG}"
    log_raw "  frps 配置      ： ${FRPS_CONFIG}"
    log_raw "  Caddyfile      ： ${CADDYFILE}"
    log_raw "  Mac 端对接包   ： ${CLIENT_BUNDLE_DIR}/"
    log_raw "  连接信息       ： ${INFO_FILE}"
    log_raw "  部署日志       ： ${LOG_FILE}"
    log_raw ""
    log_raw "${C_BOLD}常用运维命令：${C_RESET}"
    log_raw "  隧道服务端 ： systemctl status ${HY2_SERVICE}   journalctl -u ${HY2_SERVICE} -f"
    log_raw "  反向映射   ： systemctl status ${FRPS_SERVICE}   journalctl -u ${FRPS_SERVICE} -f"
    log_raw "  Web 入口   ： systemctl status caddy        journalctl -u caddy -f"
    log_raw "  查看参数   ： bash ${SCRIPT_NAME} --status"
    log_raw "  重新自检   ： bash ${SCRIPT_NAME} --self-test-only"
    log_raw "  完全卸载   ： bash ${SCRIPT_NAME} --uninstall"
    log_raw ""
    log_raw "${C_YELLOW}${C_BOLD}别忘了：${C_RESET}"
    log_raw "  1. 安全组放行 ${C_BOLD}UDP ${HY2_PORT}${C_RESET} 入站（否则 Mac 连不上，而脚本自检是绿的）"
    log_raw "  2. Cloudflare 为 ${DOMAIN} 添加 A 记录 → ${PUBLIC_IP:-<本机公网IP>}，关闭小云朵"
    log_raw "  3. Mac 端照 ${CLIENT_BUNDLE_DIR}/README.md 装 hysteria + frpc"
    log_raw "${C_GREEN}${C_BOLD}══════════════════════════════════════════════════════${C_RESET}"
}

#-------------------------------------------------------------------------------
# --status
#-------------------------------------------------------------------------------
svc_state() {
    local unit="$1"
    if ! systemd_unit_exists "$unit"; then
        echo "未安装"
    elif systemctl is-active --quiet "$unit"; then
        echo "${C_GREEN}running${C_RESET}"
    else
        echo "${C_RED}stopped${C_RESET}"
    fi
}

do_status() {
    load_state || log_warn "未找到状态文件（${STATE_FILE}），部分信息可能缺失"

    # 域名兜底：从 Caddyfile 标记块里找
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(list_managed_domains | head -n1)
    fi

    log_step "NAS 反向隧道当前状态"

    log_raw "  服务状态   ："
    log_raw "    hysteria-server : $(svc_state "$HY2_SERVICE")"
    log_raw "    frps            : $(svc_state "$FRPS_SERVICE")"
    log_raw "    caddy           : $(svc_state caddy)"
    log_raw ""
    log_raw "  监听端口   ："
    if has_cmd ss; then
        local line
        line=$(ss -ulnH 2>/dev/null | awk '{print $4}' | grep -E "[:.]${HY2_PORT}\$" | head -n1)
        log_raw "    UDP ${HY2_PORT} (Hysteria2) : ${line:-${C_RED}未监听${C_RESET}}"
        line=$(ss -tlnH 2>/dev/null | grep -F "127.0.0.1:${FRPS_BIND_PORT}" | head -n1)
        log_raw "    TCP ${FRPS_BIND_PORT} (frps 控制口) : ${line:-${C_RED}未监听${C_RESET}}"
        line=$(ss -tlnH 2>/dev/null | grep -F "127.0.0.1:${FRPS_PROXY_PORT}" | head -n1)
        log_raw "    TCP ${FRPS_PROXY_PORT} (frps 映射口) : ${line:-（尚无 Mac 端上线时为空）}"
    fi

    log_raw ""
    if [ -n "$DOMAIN" ]; then
        local hcode
        hcode=$(curl -s -o /dev/null --max-time 8 --resolve "${DOMAIN}:443:127.0.0.1" \
                -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null) || hcode="000"
        if [[ "$hcode" =~ ^[1-5][0-9][0-9]$ ]]; then
            log_ok "链路在线：https://${DOMAIN}/ 返回 HTTP $hcode"
        else
            log_warn "https://${DOMAIN}/ 无响应（HTTP $hcode）"
            log_warn "若为 502 且 Mac 端 frpc 未启动，属正常现象"
        fi
    fi

    if [ -n "$HY2_PASSWORD" ]; then
        print_connection_info
        log_raw ""
        log_raw "  Mac 端对接包： ${CLIENT_BUNDLE_DIR}/"
        log_raw "  连接信息文件： ${INFO_FILE}"
    else
        log_warn "未找到 HY2 密钥信息，无法打印连接参数"
    fi
}

#-------------------------------------------------------------------------------
# --uninstall
#-------------------------------------------------------------------------------
stop_and_remove_unit() {
    local unit="$1" unit_file="$2"
    if systemd_unit_exists "$unit"; then
        systemctl stop "$unit" >>"$LOG_FILE" 2>&1 || true
        systemctl disable "$unit" >>"$LOG_FILE" 2>&1 || true
        log_info "已停止并禁用服务：$unit"
    fi
    if [ -f "$unit_file" ]; then
        rm -f "$unit_file"
        log_info "已删除 systemd 单元：$unit_file"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
}

do_uninstall() {
    log_step "卸载：移除本脚本部署的全部组件"

    load_state || true
    [ -z "$DOMAIN" ] && DOMAIN=$(list_managed_domains | head -n1)

    if [ -z "$DOMAIN" ] && ! systemd_unit_exists "$HY2_SERVICE" && ! systemd_unit_exists "$FRPS_SERVICE"; then
        log_warn "未发现本脚本部署的任何组件（无状态文件、无标记块、无服务）"
        exit 0
    fi

    log_info "将卸载以下内容："
    log_raw "    · systemd 服务：${HY2_SERVICE}、${FRPS_SERVICE}"
    log_raw "    · 配置目录    ：${HY2_CONFIG_DIR}、${FRP_CONFIG_DIR}"
    log_raw "    · 二进制      ：${HY2_BIN}、${FRPS_BIN}、${FRPC_BIN}"
    log_raw "    · 对接包/凭据 ：${CLIENT_BUNDLE_DIR}/、${INFO_FILE}（先归档再移除）"
    [ -n "$DOMAIN" ] && log_raw "    · Caddy 站点块：${DOMAIN}（含全局选项块）"
    log_raw ""
    if [ -t 0 ]; then
        confirm "确认卸载？" n || die "已取消"
    fi

    # 1) 停服务、删单元
    stop_and_remove_unit "$HY2_SERVICE" "$HY2_UNIT_FILE"
    stop_and_remove_unit "$FRPS_SERVICE" "$FRPS_UNIT_FILE"

    # 2) 备份并删除配置目录
    local ts backup_dir
    ts=$(date +%Y%m%d-%H%M%S)
    backup_dir="/root/nas-tunnel-backup-${ts}"
    mkdir -p "$backup_dir" || die "无法创建备份目录：$backup_dir"
    [ -d "$HY2_CONFIG_DIR" ] && cp -a "$HY2_CONFIG_DIR" "$backup_dir/" 2>/dev/null || true
    [ -d "$FRP_CONFIG_DIR" ]  && cp -a "$FRP_CONFIG_DIR"  "$backup_dir/" 2>/dev/null || true
    [ -f "$INFO_FILE" ]       && cp -a "$INFO_FILE"       "$backup_dir/" 2>/dev/null || true
    [ -d "$CLIENT_BUNDLE_DIR" ] && cp -a "$CLIENT_BUNDLE_DIR" "$backup_dir/" 2>/dev/null || true
    log_ok "配置已备份到：$backup_dir"

    rm -rf "$HY2_CONFIG_DIR"
    rm -rf "$FRP_CONFIG_DIR"
    log_info "已删除配置目录：${HY2_CONFIG_DIR}、${FRP_CONFIG_DIR}"

    # 对接包与连接信息里含有已失效的密钥与域名，必须一并移除，
    # 否则会留下指向「已经不存在的隧道」的残留配置，后面很容易误用。
    rm -rf "$CLIENT_BUNDLE_DIR"
    rm -f "$INFO_FILE"
    log_info "已移除对接包与连接信息（均已归档到备份目录）"

    # 3) 删除二进制
    local b
    for b in "$HY2_BIN" "$FRPS_BIN" "$FRPC_BIN"; do
        if [ -f "$b" ]; then
            if [ -t 0 ]; then
                confirm "是否删除二进制 $b ？" y && { rm -f "$b"; log_info "已删除：$b"; }
            else
                rm -f "$b"
                log_info "已删除：$b"
            fi
        fi
    done

    # 4) 还原 Caddy 配置
    if [ -n "$DOMAIN" ] && [ -f "$CADDYFILE" ]; then
        ensure_caddy_log_dir
        mkdir -p "$CADDY_BACKUP_DIR"
        local bak=""
        bak=$(backup_file "$CADDYFILE" "$CADDY_BACKUP_DIR") || true
        [ -n "$bak" ] && log_info "已备份 Caddyfile：$bak"

        remove_caddy_blocks "$DOMAIN"
        H3_DISABLED=1
        caddy_apply_global_block remove || log_warn "移除全局选项块时出现异常"

        caddy fmt --overwrite "$CADDYFILE" >>"$LOG_FILE" 2>&1 || true
        if ! caddy validate --config "$CADDYFILE" >>"$LOG_FILE" 2>&1; then
            [ -n "$bak" ] && cp -a "$bak" "$CADDYFILE"
            die "Caddy 配置校验失败，已回滚到备份（详情：$LOG_FILE）"
        fi
        fix_caddy_log_perms
        if ! reload_caddy; then
            [ -n "$bak" ] && cp -a "$bak" "$CADDYFILE"
            fix_caddy_log_perms
            reload_caddy || true
            die "Caddy 重载失败（配置已回滚），详情：$LOG_FILE"
        fi
        log_ok "已移除 Caddy 站点块并恢复 HTTP/3 权限：${DOMAIN}"
    fi

    # 5) 清理状态文件（对接包与连接信息已在第 2 步归档并移除）
    rm -rf "$STATE_DIR"

    log_raw ""
    log_ok "卸载完成（全部配置与对接包已归档到：$backup_dir）"
    log_info "若要重新部署：bash ${SCRIPT_NAME} -d <你的域名>"
}

#-------------------------------------------------------------------------------
# --self-test-only
#-------------------------------------------------------------------------------
do_self_test_only() {
    load_state || die "未找到状态文件（${STATE_FILE}），请先完成部署"

    log_step "只执行端到端自检"

    service_active "$HY2_SERVICE" || die "${HY2_SERVICE} 未运行，请先启动：systemctl start ${HY2_SERVICE}"
    service_active "$FRPS_SERVICE" || die "${FRPS_SERVICE} 未运行，请先启动：systemctl start ${FRPS_SERVICE}"

    if run_selftests; then
        log_ok "两级自检全部通过"
    else
        die "自检未通过，请根据上面的输出排查"
    fi
}

#-------------------------------------------------------------------------------
# 主流程
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    require_root
    init_log
    print_banner

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

    phase0_prepare_env
    phase1_precheck
    phase2_download_binaries
    phase3_deploy_frps
    phase4_configure_caddy
    phase5_deploy_hysteria
    phase6_summary
}

main "$@"
