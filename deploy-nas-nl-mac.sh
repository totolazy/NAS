#!/bin/bash
#===============================================================================
# NAS 下载服务器 —— Mac mini 端「拉取」脚本（国外服务器 · 荷兰机）
#
# 目标：
#   在 Mac mini 上跑一个 hysteria2 客户端（纯 UDP）把荷兰机的 SSH 拉到本地
#   127.0.0.1:<转发端口>，然后每 5 分钟自动把荷兰机 /opt/nas 里新出现的文件
#   拉到本机 /Volumes/D/Downloads。
#
# 数据流（Mac 侧视角）：
#
#   荷兰机 sshd :22
#        ▲
#        │ hysteria2 tcpForwarding（remote 由服务器侧解析）
#        │
#   hysteria2 客户端 ——UDP/8443 QUIC——► 荷兰机 hysteria2 服务端
#        │
#        └─ 本地监听 127.0.0.1:2222（供 scp/ssh 使用）
#
#   每 5 分钟：ssh 列出 /opt/nas → 比对本地 size → 并行 scp 只拉缺的
#
# ⚠ 与「国内服务器那套」的关系
#   本脚本与 deploy-nas-tunnel-mac.sh（Mac↔国内服务器·OpenList）**完全独立**：
#     · 独立的 launchd 标签：com.nas.nl.* （那套是 com.nas.tunnel.* / com.openlist.server）
#     · 独立的配置目录：/usr/local/etc/nas-nl（那套是 /usr/local/etc/nas-tunnel）
#     · 独立的日志目录：/usr/local/var/log/nas-nl
#     · 独立的本地端口：转发端口 2222（那套 hysteria 占用 socks5 1080）
#     · 不碰 OpenList、不碰那套的任何文件
#   唯一共用的是 hysteria 二进制 /usr/local/bin/hysteria（同一个程序，只是两份配置）；
#   因此本脚本**卸载时不会删除该二进制**，避免把国内那套隧道一起弄坏。
#
# 用法：
#   bash deploy-nas-nl-mac.sh                  # 交互式部署
#   bash deploy-nas-nl-mac.sh -y               # 全默认值，非交互
#   bash deploy-nas-nl-mac.sh --status         # 查看状态
#   bash deploy-nas-nl-mac.sh --pull-now       # 立刻拉一次（前台看输出）
#   bash deploy-nas-nl-mac.sh --self-test      # 只跑自检
#   bash deploy-nas-nl-mac.sh --uninstall      # 卸载（不动共享的 hysteria 二进制）
#   bash deploy-nas-nl-mac.sh --help
#
# 运行要求：用「普通用户」运行（不要 sudo bash），脚本内部需要提权时自己调用 sudo。
#
# 版本：1.0.0
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# 全局常量
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.5.0"
readonly SCRIPT_NAME="deploy-nas-nl-mac.sh"

LOG_FILE=""

readonly CONF_DIR="/usr/local/etc/nas-nl"
# 服务器上的「已送达归档」目录：Mac 拉走并校验成功后，会把文件从远端待拉目录 mv 到这里。
# 于是待拉目录里永远只剩「还没送出去」的文件，天然不会重复拉取。
readonly DEF_REMOTE_USED_DIR="/opt/nas-used"
readonly STATE_FILE="${CONF_DIR}/state.env"
readonly STATE_VERSION="1"
readonly HY2_CONF="${CONF_DIR}/hysteria-client.yaml"
readonly KNOWN_HOSTS="${CONF_DIR}/known_hosts"
readonly LOG_DIR="/usr/local/var/log/nas-nl"
readonly PULL_LOG="${LOG_DIR}/pull.log"
readonly PULL_SCRIPT="/usr/local/bin/nas-nl-pull.sh"

# 与国内那套共用的二进制：只负责「缺了就装」，绝不负责删
readonly HY2_BIN="/usr/local/bin/hysteria"

readonly LAUNCHD_DIR="/Library/LaunchDaemons"
readonly LABEL_HY2="com.nas.nl.hysteria"
readonly LABEL_PULL="com.nas.nl.pull"
readonly PLIST_HY2="${LAUNCHD_DIR}/${LABEL_HY2}.plist"
readonly PLIST_PULL="${LAUNCHD_DIR}/${LABEL_PULL}.plist"

readonly HYSTERIA_RELEASE_BASE="https://github.com/apernet/hysteria/releases/latest/download"

readonly -a GH_PROXY_CANDIDATES=(
  "https://gh-proxy.com/"
  "https://ghfast.top/"
  "https://ghproxy.net/"
)
readonly -a PROXY_PORT_CANDIDATES=(10808 10809 7890 1080 2080 8118)

#-------------------------------------------------------------------------------
# 默认参数（只放通用值；服务器地址 / 密码 / SNI 一律由使用者输入，
# 脚本里不留任何实机信息，方便直接上传到公开仓库）
#-------------------------------------------------------------------------------
DEF_NL_HOST=""               # 必填
DEF_NL_HY2_PORT="8443"
DEF_NL_SNI=""                # 必填
DEF_FWD_PORT="2222"          # 本机监听端口（≠ 国内的 1080，互不干扰）
# 本机 SOCKS5 入口（走荷兰机的 UDP 隧道出网）。跨境 TCP 丢包严重时（实测 30% 丢包
# 会把 TCP 压到 40 KB/s），浏览器打开 dllist/qb/aria 面板会白屏；把浏览器代理指到
# 这个端口就能正常打开。0 = 不启用。刻意避开国内那套的 1080。
DEF_SOCKS_PORT="1081"
DEF_REMOTE_SSH_PORT="22"     # 由荷兰机侧解析
DEF_SSH_USER="nas"
DEF_REMOTE_DIR="/opt/nas"
DEF_LOCAL_DEST="/Volumes/D/Downloads"
DEF_INTERVAL="300"
# 并发数：实测（中国↔荷兰真实线路，8 个 25MiB 文件）
#   并发 4  → 7.1 MiB/s
#   并发 8  → 11.9 MiB/s   ← 拐点，且低于 sshd 默认 MaxStartups 阈值
#   并发 12 → 12.2 MiB/s
#   并发 16 → 13.1 MiB/s（收益递减，且需要抬高服务器 sshd MaxStartups）
DEF_PARALLEL="8"
# 「静默阈值」：远端文件必须连续这么多秒没有被修改，才允许被拉走。
# 下载中的文件 mtime 一直在变，用这个把它挡在门外，避免反复拉半成品。
# 0 = 关闭该保护（只按 size 比对，不推荐）。
DEF_STABLE_SEC="180"
DEF_UP_MBPS="50"
# 实测 Brutal 声明带宽：100 与 300 差别在噪声内，100 更低更温和、更稳
DEF_DOWN_MBPS="100"

#-------------------------------------------------------------------------------
# 运行期变量
#-------------------------------------------------------------------------------
RUN_USER=""
RUN_GROUP=""
ARCH_ASSET=""
PROXY_URL=""
PROXY_EXPLICIT=0

NL_HOST="$DEF_NL_HOST"
NL_HY2_PORT="$DEF_NL_HY2_PORT"
NL_HY2_PASS=""
NL_SNI="$DEF_NL_SNI"
FWD_PORT="$DEF_FWD_PORT"
SOCKS_PORT="$DEF_SOCKS_PORT"
REMOTE_USED_DIR="$DEF_REMOTE_USED_DIR"
REMOTE_SSH_PORT="$DEF_REMOTE_SSH_PORT"
SSH_USER="$DEF_SSH_USER"
REMOTE_DIR="$DEF_REMOTE_DIR"
LOCAL_DEST="$DEF_LOCAL_DEST"
PULL_INTERVAL="$DEF_INTERVAL"
PULL_PARALLEL="$DEF_PARALLEL"
PULL_STABLE_SEC="$DEF_STABLE_SEC"
UP_MBPS="$DEF_UP_MBPS"
DOWN_MBPS="$DEF_DOWN_MBPS"
KEY_FILE=""
GEN_PUBKEY=""

ASSUME_YES=0
DO_STATUS=0
DO_UNINSTALL=0
DO_PULL_NOW=0
SELF_TEST_ONLY=0
DO_RECALL=0
RECALL_PATTERN=""

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
    local dir="$HOME/Library/Logs/nas-nl"
    mkdir -p "$dir" 2>/dev/null || dir="/tmp"
    LOG_FILE="${dir}/deploy-mac-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
    log_raw "==============================================================="
    log_raw " NAS 荷兰机拉取部署日志（Mac 端）  版本：$SCRIPT_VERSION"
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
${C_BOLD}NAS 荷兰机拉取脚本（Mac mini 端）v${SCRIPT_VERSION}${C_RESET}

${C_BOLD}它做什么：${C_RESET}
  装一个独立的 hysteria2 客户端（纯 UDP）连到荷兰机，把荷兰机的 SSH 映射到
  本机 127.0.0.1:${FWD_PORT}；然后每 ${PULL_INTERVAL} 秒把荷兰机 ${REMOTE_DIR}
  里新出现的文件并行拉到 ${LOCAL_DEST}。两个服务都是 launchd 开机自启。

${C_BOLD}用法：${C_RESET}
  bash ${SCRIPT_NAME} [选项]

${C_BOLD}选项：${C_RESET}
  -y, --yes                其余项全部使用默认值（地址/密码/SNI 仍需给）
      --nl-host <IP>        荷兰机公网 IP（必填，不给会交互询问）
      --nl-port <端口>      荷兰机 hysteria2 UDP 端口（默认 ${DEF_NL_HY2_PORT}）
      --nl-pass <密码>      荷兰机 hysteria2 认证密码（必填，不给会交互询问）
      --nl-sni <域名>       TLS SNI / 证书域名（必填，不给会交互询问）
      --fwd-port <端口>     本机监听端口（默认 ${DEF_FWD_PORT}）
      --socks-port <端口>   本机 SOCKS5 入口（默认 ${DEF_SOCKS_PORT}，走荷兰机 UDP 出网；
                            0 = 不启用。丢包严重时用它打开面板，避免白屏）
      --ssh-user <用户>     荷兰机上的拉取账号（默认 ${DEF_SSH_USER}）
      --remote-dir <目录>   荷兰机上的交换目录（默认 ${DEF_REMOTE_DIR}）
      --dest <目录>         本机落地目录（默认 ${DEF_LOCAL_DEST}）
      --interval <秒>       拉取间隔（默认 ${DEF_INTERVAL}）
      --parallel <N>        并发传输数（默认 ${DEF_PARALLEL}，实测拐点：
                            4→7.1、8→11.9、12→12.2、16→13.1 MiB/s）
      --down-mbps <N>       hysteria2 Brutal 声明下行带宽（默认 ${DEF_DOWN_MBPS}）
      --up-mbps <N>         hysteria2 Brutal 声明上行带宽（默认 ${DEF_UP_MBPS}）
      --stable-sec <N>      静默阈值（默认 ${DEF_STABLE_SEC}s）：远端文件连续 N 秒没被
                            修改才拉走。防止把「正在下载」的半成品反复拉回来。
                            设 0 可关闭该保护。
  -p, --proxy <地址>        下载代理，如 http://127.0.0.1:10808（默认自动探测）
      --status              查看当前状态
      --pull-now            立刻拉取一次（前台运行，直接看输出）
      --recall <名字>        把归档目录（已送达）里匹配的文件挪回待拉目录，
                            下一轮会重新传一遍（子串匹配）
      --remote-used-dir <目录>  服务器上的归档目录（默认 ${DEF_REMOTE_USED_DIR}）
      --self-test           只跑端到端自检
      --uninstall           卸载（不删除共享的 ${HY2_BIN}）
  -h, --help                显示本帮助
  -v, --version             显示脚本版本

${C_BOLD}执行流程：${C_RESET}
  阶段 0/5  环境准备：macOS/架构检查、运行身份检查、代理探测、sudo 预热
  阶段 1/5  参数确认：荷兰机地址 / hy2 密码 / 目录 / 间隔 / 并发
  阶段 2/5  hysteria2 客户端：按需安装二进制 → 写配置（含 tcpForwarding）
  拉取语义  ：只从荷兰机的待拉目录（${REMOTE_DIR}）取；文件拉走并校验大小成功后，
              会把远端那份 **mv 到归档目录**（${REMOTE_USED_DIR}），归档目录 24 小时后自动清理。
              所以同一个文件只会传一遍 —— 你在本地挪到别的文件夹、改名、甚至删掉都不会重传
              （想让它再传一遍用 --recall <名字>）。
  阶段 3/5  生成拉取脚本 ${PULL_SCRIPT}
  阶段 4/5  写 launchd：${LABEL_HY2}（常驻）+ ${LABEL_PULL}（每 ${PULL_INTERVAL}s）
  阶段 5/5  端到端自检与汇总

${C_BOLD}与国内那套的关系：${C_RESET}
  完全独立（独立标签/配置/日志/端口），卸载也不会删共享的 hysteria 二进制。
EOF
}

#-------------------------------------------------------------------------------
# 参数解析
#-------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)          ASSUME_YES=1; shift ;;
            --nl-host)         [ -n "${2:-}" ] || die "选项 $1 需要一个 IP"; NL_HOST="$2"; shift 2 ;;
            --nl-port)         [ -n "${2:-}" ] || die "选项 $1 需要一个端口"; NL_HY2_PORT="$2"; shift 2 ;;
            --nl-pass)         [ -n "${2:-}" ] || die "选项 $1 需要一个密码"; NL_HY2_PASS="$2"; shift 2 ;;
            --nl-sni)          [ -n "${2:-}" ] || die "选项 $1 需要一个域名"; NL_SNI="$2"; shift 2 ;;
            --fwd-port)        [ -n "${2:-}" ] || die "选项 $1 需要一个端口"; FWD_PORT="$2"; shift 2 ;;
            --socks-port)      [ -n "${2:-}" ] || die "选项 $1 需要一个端口"; SOCKS_PORT="$2"; shift 2 ;;
            --ssh-user)        [ -n "${2:-}" ] || die "选项 $1 需要一个用户名"; SSH_USER="$2"; shift 2 ;;
            --remote-dir)      [ -n "${2:-}" ] || die "选项 $1 需要一个目录"; REMOTE_DIR="$2"; shift 2 ;;
            --dest)            [ -n "${2:-}" ] || die "选项 $1 需要一个目录"; LOCAL_DEST="$2"; shift 2 ;;
            --interval)        [ -n "${2:-}" ] || die "选项 $1 需要秒数"; PULL_INTERVAL="$2"; shift 2 ;;
            --parallel)        [ -n "${2:-}" ] || die "选项 $1 需要数字"; PULL_PARALLEL="$2"; shift 2 ;;
            --stable-sec)      [ -n "${2:-}" ] || die "选项 $1 需要秒数"; PULL_STABLE_SEC="$2"; shift 2 ;;
            --down-mbps)       [ -n "${2:-}" ] || die "选项 $1 需要数字"; DOWN_MBPS="$2"; shift 2 ;;
            --up-mbps)         [ -n "${2:-}" ] || die "选项 $1 需要数字"; UP_MBPS="$2"; shift 2 ;;
            -p|--proxy)        [ -n "${2:-}" ] || die "选项 $1 需要地址"; PROXY_URL="$2"; PROXY_EXPLICIT=1; shift 2 ;;
            --status)          DO_STATUS=1; shift ;;
            --pull-now)        DO_PULL_NOW=1; shift ;;
            --recall)          [ -n "${2:-}" ] || die "选项 $1 需要一个文件名（可用子串）"; DO_RECALL=1; RECALL_PATTERN="$2"; shift 2 ;;
            --remote-used-dir) [ -n "${2:-}" ] || die "选项 $1 需要一个目录"; REMOTE_USED_DIR="$2"; shift 2 ;;
            --self-test)       SELF_TEST_ONLY=1; shift ;;
            --uninstall)       DO_UNINSTALL=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            -v|--version)      echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
            *)                 echo "未知参数：$1" >&2; echo "使用 --help 查看用法" >&2; exit 2 ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# 通用工具
#-------------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

ask() {
    local prompt="$1" default="${2:-}" answer=""
    if [ "$ASSUME_YES" -eq 1 ]; then REPLY="$default"; return 0; fi
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
    if [ "$ASSUME_YES" -eq 1 ]; then [ "$default" = "y" ]; return $?; fi
    if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "$prompt $hint: " answer || true
    answer="${answer:-$default}"
    case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# 必填项：交互输入，空值不接受；-y 模式下必须由命令行给出
ask_required() {
    local __v="$1" __p="$2" __a=""
    __a="${!__v}"
    while [ -z "$__a" ]; do
        if [ "$ASSUME_YES" -eq 1 ]; then
            die "非交互模式（-y）下缺少必填项：${__p}（请用命令行参数指定）"
        fi
        read -r -p "${__p}（必填）: " __a || true
        [ -z "$__a" ] && log_warn "该项不能为空"
    done
    printf -v "$__v" '%s' "$__a"
}

# 必填的敏感项：输入不回显
ask_secret_required() {
    local __v="$1" __p="$2" __a=""
    __a="${!__v}"
    while [ -z "$__a" ]; do
        if [ "$ASSUME_YES" -eq 1 ]; then
            die "非交互模式（-y）下缺少必填项：${__p}（请用命令行参数指定）"
        fi
        read -r -s -p "${__p}（必填，输入不回显）: " __a || true
        printf '\n'
        [ -z "$__a" ] && log_warn "该项不能为空"
    done
    printf -v "$__v" '%s' "$__a"
}

is_valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

port_listening() {
    local port="$1"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
        || netstat -an 2>/dev/null | grep -qE "[.:]${port}[[:space:]].*LISTEN"
}

wait_for_port() {
    local port="$1" timeout="${2:-30}" i=0
    while [ "$i" -lt "$timeout" ]; do
        port_listening "$port" && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

yaml_scalar() {
    local f="$1" k="$2"
    [ -f "$f" ] || return 1
    sed -nE "s/^[[:space:]]*${k}:[[:space:]]*(.*)$/\1/p" "$f" \
        | head -n1 | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]*$//'
}

# 找一把可用的 SSH 私钥（默认用 ~/.ssh/id_ed25519）
resolve_key() {
    [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] && return 0
    local c
    for c in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
        if [ -f "$c" ]; then KEY_FILE="$c"; return 0; fi
    done

    # 新机器上没有密钥：自动生成一把免密密钥，并把「怎么装到服务器」直接打印出来
    log_warn "本机没有可用的 SSH 私钥（$HOME/.ssh/id_ed25519 等都不存在）"
    if ! confirm "现在自动生成一把 ed25519 免密密钥？" y; then
        return 1
    fi
    mkdir -p "$HOME/.ssh" 2>/dev/null || return 1
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    ssh-keygen -t ed25519 -N '' -C "macmini-pull@$(hostname -s 2>/dev/null || echo macmini)" \
        -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1 || return 1
    chmod 600 "$HOME/.ssh/id_ed25519" 2>/dev/null || true
    chmod 644 "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true
    KEY_FILE="$HOME/.ssh/id_ed25519"
    GEN_PUBKEY="$(cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null)"
    log_ok "已生成密钥：$KEY_FILE"

    if [ -n "$GEN_PUBKEY" ]; then
        log_raw ""
        log_raw "${C_YELLOW}${C_BOLD}★ 还差一步：把这行公钥装到荷兰机的拉取账号上${C_RESET}"
        log_raw "  公钥："
        log_raw "    ${GEN_PUBKEY}"
        log_raw "  在 Mac 上执行这一条即可（会问荷兰机 root 密码）："
        log_raw "    ssh root@${NL_HOST} 'install -d -m700 -o ${SSH_USER} -g ${SSH_USER} /home/${SSH_USER}/.ssh; touch /home/${SSH_USER}/.ssh/authorized_keys; grep -qF \"${GEN_PUBKEY}\" /home/${SSH_USER}/.ssh/authorized_keys || echo \"${GEN_PUBKEY}\" >> /home/${SSH_USER}/.ssh/authorized_keys; chown ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh/authorized_keys; chmod 600 /home/${SSH_USER}/.ssh/authorized_keys'"
        log_raw "  （或者重跑服务器脚本 ${C_BOLD}nas-server.sh${C_RESET}，它会问你要 Mac 公钥，粘进去即可）"
        log_raw ""
    fi
    return 0
}

# 本地落地目录所在卷是否已挂载（外置盘没插时不要往内置盘写）
dest_volume_mounted() {
    local vol
    case "$LOCAL_DEST" in
        /Volumes/*) vol=$(printf '%s' "$LOCAL_DEST" | cut -d/ -f1-3) ;;
        *) return 0 ;;   # 不是外置卷，不用检查
    esac
    mount | grep -q " on ${vol} " 2>/dev/null
}

dest_volume_name() {
    case "$LOCAL_DEST" in
        /Volumes/*) printf '%s' "$LOCAL_DEST" | cut -d/ -f1-3 ;;
        *) printf '' ;;
    esac
}

#-------------------------------------------------------------------------------
# 运行身份检查：必须是非 root 的普通用户
#-------------------------------------------------------------------------------
require_normal_user() {
    local u g
    u=$(id -un); g=$(id -gn)
    if [ "$(id -u)" -eq 0 ]; then
        log_err "检测到当前是 root（或用了 sudo 运行本脚本）"
        log_err "正确用法：bash ${SCRIPT_NAME}    （脚本内部需要提权时会自己调用 sudo）"
        exit 1
    fi
    RUN_USER="$u"; RUN_GROUP="$g"
    log_ok "运行身份：${RUN_USER}（组 ${RUN_GROUP}）"
}

#-------------------------------------------------------------------------------
# 代理 / 下载
#-------------------------------------------------------------------------------
probe_proxy() {
    local p code
    if [ "$PROXY_EXPLICIT" -eq 1 ]; then
        log_info "使用命令行指定的代理：$PROXY_URL"; return 0
    fi
    for p in "${PROXY_PORT_CANDIDATES[@]}"; do
        nc -z 127.0.0.1 "$p" >/dev/null 2>&1 || continue
        # 端口开着不等于能当 HTTP 代理用：本机 hysteria 的 socks5(1080，国内那套在用)
        # 就是这种，它要账号密码、不接受裸 CONNECT，误判会让后面所有下载全失败。
        code=$(curl -s -o /dev/null -m 6 -x "http://127.0.0.1:${p}" -w '%{http_code}' \
               https://www.baidu.com 2>/dev/null) || code="000"
        if [[ "$code" =~ ^[123][0-9][0-9]$ ]]; then
            PROXY_URL="http://127.0.0.1:${p}"
            log_ok "检测到可用代理：$PROXY_URL"; return 0
        fi
        log_info "端口 ${p} 有监听但代理不可用（HTTP ${code}），跳过"
    done
    PROXY_URL=""
    log_warn "未检测到可用代理（常见端口都试过并实测验证）"
    return 1
}

apply_proxy_env() {
    if [ -n "$PROXY_URL" ]; then
        export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
        export all_proxy="$PROXY_URL" ALL_PROXY="$PROXY_URL"
        export no_proxy="127.0.0.1,localhost" NO_PROXY="127.0.0.1,localhost"
    else
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    fi
}

gh_download() {
    local url="$1" dest="$2" t="${3:-600}" base
    if [ -n "$PROXY_URL" ]; then
        log_info "下载（经代理 ${PROXY_URL}）：$url"
        curl -fSL --retry 2 --retry-delay 3 --max-time "$t" -o "$dest" "$url" 2>>"$LOG_FILE" && return 0
        log_warn "经代理下载失败，改用直连/加速站重试"
    fi
    log_info "下载（直连）：$url"
    curl -fSL --retry 2 --retry-delay 3 --max-time "$t" -o "$dest" "$url" 2>>"$LOG_FILE" && return 0
    for base in "${GH_PROXY_CANDIDATES[@]}"; do
        log_info "下载（加速站 ${base}）：$url"
        curl -fSL --retry 2 --retry-delay 3 --max-time "$t" -o "$dest" "${base}${url}" 2>>"$LOG_FILE" && return 0
    done
    log_err "所有线路都下载失败：$url"
    return 1
}

#-------------------------------------------------------------------------------
# 状态文件
#-------------------------------------------------------------------------------
save_state() {
    sudo mkdir -p "$CONF_DIR" || die "无法创建目录：$CONF_DIR"
    sudo tee "$STATE_FILE" >/dev/null <<EOF
STATE_VERSION=${STATE_VERSION}
RUN_USER=${RUN_USER}
NL_HOST=${NL_HOST}
NL_HY2_PORT=${NL_HY2_PORT}
NL_SNI=${NL_SNI}
FWD_PORT=${FWD_PORT}
SOCKS_PORT=${SOCKS_PORT}
REMOTE_USED_DIR=${REMOTE_USED_DIR}
SSH_USER=${SSH_USER}
REMOTE_DIR=${REMOTE_DIR}
LOCAL_DEST=${LOCAL_DEST}
PULL_INTERVAL=${PULL_INTERVAL}
PULL_PARALLEL=${PULL_PARALLEL}
PULL_STABLE_SEC=${PULL_STABLE_SEC}
UP_MBPS=${UP_MBPS}
DOWN_MBPS=${DOWN_MBPS}
PROXY_URL=${PROXY_URL}
EOF
    sudo chown "$RUN_USER:$RUN_GROUP" "$STATE_FILE" 2>/dev/null || true
    sudo chmod 600 "$STATE_FILE" 2>/dev/null || true
}

state_get() {
    [ -f "$STATE_FILE" ] || return 1
    local line
    line=$(grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -n1) || return 1
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

load_state() {
    [ -f "$STATE_FILE" ] || return 1
    local v
    v=$(state_get RUN_USER);      [ -n "$v" ] && RUN_USER="$v"
    v=$(state_get NL_HOST);       [ -n "$v" ] && NL_HOST="$v"
    v=$(state_get NL_HY2_PORT);   [ -n "$v" ] && NL_HY2_PORT="$v"
    v=$(state_get NL_SNI);        [ -n "$v" ] && NL_SNI="$v"
    v=$(state_get FWD_PORT);      [ -n "$v" ] && FWD_PORT="$v"
    v=$(state_get SOCKS_PORT);    [ -n "$v" ] && SOCKS_PORT="$v"
    v=$(state_get REMOTE_USED_DIR); [ -n "$v" ] && REMOTE_USED_DIR="$v"
    v=$(state_get SSH_USER);      [ -n "$v" ] && SSH_USER="$v"
    v=$(state_get REMOTE_DIR);    [ -n "$v" ] && REMOTE_DIR="$v"
    v=$(state_get LOCAL_DEST);    [ -n "$v" ] && LOCAL_DEST="$v"
    v=$(state_get PULL_INTERVAL); [ -n "$v" ] && PULL_INTERVAL="$v"
    v=$(state_get PULL_PARALLEL); [ -n "$v" ] && PULL_PARALLEL="$v"
    v=$(state_get PULL_STABLE_SEC); [ -n "$v" ] && PULL_STABLE_SEC="$v"
    v=$(state_get UP_MBPS);       [ -n "$v" ] && UP_MBPS="$v"
    v=$(state_get DOWN_MBPS);     [ -n "$v" ] && DOWN_MBPS="$v"
    v=$(state_get PROXY_URL);     [ -n "$v" ] && PROXY_URL="$v"
    [ -z "$RUN_USER" ] && RUN_USER=$(id -un)
    [ -z "$RUN_GROUP" ] && RUN_GROUP=$(id -gn)
    # 密码不落 state（避免明文散落），从配置文件回读
    if [ -z "$NL_HY2_PASS" ] && [ -f "$HY2_CONF" ]; then
        v=$(yaml_scalar "$HY2_CONF" auth); [ -n "$v" ] && NL_HY2_PASS="$v"
    fi
    return 0
}

#-------------------------------------------------------------------------------
# launchd 封装
#-------------------------------------------------------------------------------
launchd_is_loaded() { sudo launchctl print "system/$1" >/dev/null 2>&1; }

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

launchd_state() {
    local label="$1" plist="" pat="" pid="" out state
    case "$label" in
        "$LABEL_HY2")  plist="$PLIST_HY2";  pat="${HY2_BIN} client.*nas-nl" ;;
        "$LABEL_PULL") plist="$PLIST_PULL"; pat="nas-nl-pull.sh" ;;
    esac
    [ -f "$plist" ] || { echo "未安装"; return 0; }
    pid=$(pgrep -f "$pat" 2>/dev/null | head -n1)
    if [ -n "$pid" ]; then echo "running(pid=$pid)"; return 0; fi
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
    plutil -lint "$tmp" >/dev/null 2>&1 || die "plist 格式非法（${label}），已中止"
    sudo cp "$tmp" "$plist" || die "写入 $plist 失败"
    sudo chown root:wheel "$plist"
    sudo chmod 644 "$plist"
    launchd_unload "$label" "$plist"
    launchd_load "$label" "$plist" || die "加载 launchd 服务失败：$label"
    log_ok "已写入并加载 launchd：${label}"
}

# ssh / scp 公共参数（都指向本机转发端口）
ssh_opts() {
    printf '%s' "-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${KNOWN_HOSTS} -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o Compression=no -o IPQoS=throughput"
}

ssh_run() {
    # shellcheck disable=SC2086
    ssh -p "$FWD_PORT" $(ssh_opts) "${SSH_USER}@127.0.0.1" "$@"
}

#-------------------------------------------------------------------------------
# 阶段 0：环境准备
#-------------------------------------------------------------------------------
nl_phase0_env() {
    log_step "阶段 0/5：环境准备"

    [ "$(uname -s)" = "Darwin" ] || die "本脚本只能在 macOS 上运行（当前：$(uname -s)）"
    log_info "系统：macOS $(sw_vers -productVersion)（$(sw_vers -buildVersion)）"

    case "$(uname -m)" in
        arm64)  ARCH_ASSET="arm64" ;;
        x86_64) ARCH_ASSET="amd64" ;;
        *)      die "不支持的架构：$(uname -m)" ;;
    esac
    log_ok "架构：$(uname -m) → darwin-${ARCH_ASSET}"

    has_cmd curl || die "缺少 curl"
    has_cmd ssh  || die "缺少 ssh"
    has_cmd scp  || die "缺少 scp"

    require_normal_user

    log_info "后续需要 sudo 权限（写 /usr/local、/Library/LaunchDaemons）；请先授权"
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

    # 检查落地卷
    local vol; vol=$(dest_volume_name)
    if [ -n "$vol" ]; then
        if dest_volume_mounted; then
            log_ok "落地卷已挂载：${vol}"
        else
            log_warn "落地卷 ${vol} 当前没挂载（拉取任务届时会自动跳过，不会往内置盘写）"
        fi
    fi
    log_ok "环境准备完成"
}

#-------------------------------------------------------------------------------
# 阶段 1：参数确认
#-------------------------------------------------------------------------------
nl_phase1_params() {
    log_step "阶段 1/5：确认参数"

    if [ "$ASSUME_YES" -eq 1 ]; then
        log_info "已指定 -y，全部使用当前值（命令行 > 状态文件 > 默认值）"
    else
        log_raw ""
        log_raw "  荷兰机侧参数（可在荷兰机执行 sudo /root/nas-server.sh macmini 查看）"
        ask_required        NL_HOST    "荷兰机公网 IP"
        ask                 "hysteria2 UDP 端口" "$NL_HY2_PORT";   NL_HY2_PORT="$REPLY"
        ask_secret_required NL_HY2_PASS "hysteria2 认证密码"
        ask_required        NL_SNI     "TLS SNI（荷兰机证书域名）"
        ask                 "本机监听端口（转发荷兰机 22）" "$FWD_PORT"; FWD_PORT="$REPLY"
        ask                 "荷兰机上的拉取账号" "$SSH_USER";      SSH_USER="$REPLY"
        log_raw ""
        log_raw "  目录与节奏"
        ask "荷兰机上的交换目录" "$REMOTE_DIR";                  REMOTE_DIR="$REPLY"
        ask "本机落地目录" "$LOCAL_DEST";                        LOCAL_DEST="$REPLY"
        ask "拉取间隔（秒）" "$PULL_INTERVAL";                   PULL_INTERVAL="$REPLY"
        ask "并发传输数" "$PULL_PARALLEL";                       PULL_PARALLEL="$REPLY"
    fi

    is_valid_ip "$NL_HOST" || die "荷兰机地址不合法：$NL_HOST"
    case "$NL_HY2_PORT" in *[!0-9]*|"") die "hysteria2 端口不合法：$NL_HY2_PORT" ;; esac
    case "$FWD_PORT" in *[!0-9]*|"") die "本机监听端口不合法：$FWD_PORT" ;; esac
    case "$SOCKS_PORT" in *[!0-9]*|"") die "SOCKS5 端口不合法：$SOCKS_PORT" ;; esac
    case "$PULL_INTERVAL" in *[!0-9]*|"") die "间隔必须是秒数：$PULL_INTERVAL" ;; esac
    case "$PULL_PARALLEL" in *[!0-9]*|"") die "并发数不合法：$PULL_PARALLEL" ;; esac
    [ "$PULL_PARALLEL" -ge 1 ] || die "并发数至少为 1"
    [ -n "$NL_HY2_PASS" ] || die "hysteria2 认证密码不能为空（用 --nl-pass 传入或交互输入）"
    [ -n "$SSH_USER" ]    || die "拉取账号不能为空"
    [ -n "$REMOTE_DIR" ]  || die "远端目录不能为空"
    [ -n "$LOCAL_DEST" ]  || die "本机落地目录不能为空"

    if [ "$SOCKS_PORT" != "0" ] && [ "$SOCKS_PORT" = "$FWD_PORT" ]; then
        die "SOCKS5 端口与转发端口相同（$SOCKS_PORT），会互相抢占"
    fi
    if [ "$SOCKS_PORT" = "1080" ]; then
        die "SOCKS5 端口 1080 与国内那套 hysteria 的 socks5 冲突，请改用 ${DEF_SOCKS_PORT}"
    fi
    if [ "$FWD_PORT" = "1080" ]; then
        log_warn "本机监听端口 1080 与国内那套 hysteria 的 socks5 冲突，建议改用 2222"
    fi

    resolve_key || die "找不到 SSH 私钥（默认 $HOME/.ssh/id_ed25519）；请先生成并把公钥装到荷兰机"
    log_ok "使用私钥：$KEY_FILE"

    # 选拉取引擎
    # 外置卷受 macOS TCC 保护：launchd 任务的写入需要一次「完全磁盘访问权限」授权。
    # 这里只提示，不拦截（授权后照常工作）。
    case "$LOCAL_DEST" in
        /Volumes/*)
            log_info "落地目录在外置卷：首次拉取前需给 ${C_BOLD}/bin/bash${C_RESET} 授予「完全磁盘访问权限」"
            log_info "  未授权时拉取日志会出现 Operation not permitted，脚本里已给出解决提示"
            ;;
    esac

    log_ok "荷兰机=${NL_HOST}:${NL_HY2_PORT}(UDP)  SNI=${NL_SNI}  本机转发=127.0.0.1:${FWD_PORT}"
    log_ok "拉取 ${SSH_USER}@荷兰机:${REMOTE_DIR}  →  ${LOCAL_DEST}  每 ${PULL_INTERVAL}s，并发 ${PULL_PARALLEL}"
}

#-------------------------------------------------------------------------------
# 阶段 2：hysteria2 客户端
#-------------------------------------------------------------------------------
ensure_hysteria_bin() {
    if [ -x "$HY2_BIN" ]; then
        log_ok "hysteria 已存在（与国内那套共用）：$("$HY2_BIN" version 2>/dev/null | head -n1)"
        return 0
    fi
    local tmp; tmp=$(mktemp -d) || die "无法创建临时目录"
    local url="${HYSTERIA_RELEASE_BASE}/hysteria-darwin-${ARCH_ASSET}"
    gh_download "$url" "${tmp}/hysteria" 600 || { rm -rf "$tmp"; die "下载 hysteria 失败（可加 -p 指定代理）"; }
    chmod +x "${tmp}/hysteria"
    "${tmp}/hysteria" version >/dev/null 2>&1 || { rm -rf "$tmp"; die "下载的 hysteria 无法运行"; }
    sudo mkdir -p /usr/local/bin
    sudo install -m 755 "${tmp}/hysteria" "$HY2_BIN" || { rm -rf "$tmp"; die "安装 hysteria 失败"; }
    rm -rf "$tmp"
    log_ok "hysteria 安装完成：$("$HY2_BIN" version 2>/dev/null | head -n1)"
}

write_hy2_conf() {
    sudo mkdir -p "$CONF_DIR" "$LOG_DIR" || die "无法创建目录"
    sudo chown "$RUN_USER:$RUN_GROUP" "$LOG_DIR"
    sudo chmod 700 "$CONF_DIR" 2>/dev/null || true

    local socks_block=""
    local domain_suffix="${NL_SNI#*.}"
    if [ "$SOCKS_PORT" != "0" ]; then
        socks_block="# 本机 SOCKS5 入口：跨境 TCP 丢包严重时，浏览器的请求经这条 UDP 隧道出网，
# 避免 dllist / qb / aria 面板因为前端 JS 拉不完而白屏。
# 用法：把浏览器的 SOCKS5 代理指到 127.0.0.1:${SOCKS_PORT}，并建议只对 *.${domain_suffix} 生效。
socks5:
  listen: 127.0.0.1:${SOCKS_PORT}
"
    fi

    sudo tee "$HY2_CONF" >/dev/null <<EOF
# Mac mini 端 —— 荷兰机 hysteria2 客户端（由 ${SCRIPT_NAME} 生成）
#
# 与国内那套（/usr/local/etc/nas-tunnel/hysteria-client.yaml）互不相干。
server: ${NL_HOST}:${NL_HY2_PORT}
auth: ${NL_HY2_PASS}

tls:
  # 荷兰机用的是 Caddy 签发的 Let's Encrypt 证书，正常校验
  sni: ${NL_SNI}
  insecure: false

# 把荷兰机的 SSH 拉到本机 ${FWD_PORT}（remote 端由荷兰机解析为它自己的 22）
tcpForwarding:
  - listen: 127.0.0.1:${FWD_PORT}
    remote: 127.0.0.1:${REMOTE_SSH_PORT}

${socks_block}# 给了 bandwidth 才会启用 Brutal（抗丢包）；纯 UDP，跨境链路更稳
bandwidth:
  up: ${UP_MBPS} mbps
  down: ${DOWN_MBPS} mbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  keepAlivePeriod: 10s
EOF

    sudo chown "$RUN_USER:$RUN_GROUP" "$HY2_CONF"
    sudo chmod 600 "$HY2_CONF"
    log_ok "已写入 $HY2_CONF"
}

write_hy2_plist() {
    local tmp; tmp=$(mktemp) || die "无法创建临时文件"
    write_plist_header > "$tmp"
    cat >> "$tmp" <<EOF
	<key>Label</key>
	<string>${LABEL_HY2}</string>

	<key>ProgramArguments</key>
	<array>
		<string>${HY2_BIN}</string>
		<string>client</string>
		<string>--config</string>
		<string>${HY2_CONF}</string>
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

nl_phase2_hysteria() {
    log_step "阶段 2/5：部署 hysteria2 客户端（纯 UDP）"
    ensure_hysteria_bin
    write_hy2_conf
}

#-------------------------------------------------------------------------------
# 阶段 3：生成拉取脚本
#-------------------------------------------------------------------------------
write_pull_script() {
    local tmp; tmp=$(mktemp) || die "无法创建临时文件"

    cat > "$tmp" <<'PULL_HEAD'
#!/bin/bash
#===============================================================================
# nas-nl-pull.sh —— 从荷兰机拉取新文件（由 deploy-nas-nl-mac.sh 生成，勿手改）
#
# 逻辑：ssh 列出远端目录（size + mtime + 相对路径，NUL 分隔）
#       → 与本地同名文件比对 size → 只拉缺的/不完整的 → 并行 scp
# 说明：本脚本**不删除**荷兰机上的源文件（那边有自己的 24h 定时清理）。
#
# 用法： nas-nl-pull.sh [--dry-run]
#===============================================================================
set -uo pipefail

PULL_HEAD

    cat >> "$tmp" <<EOF
NL_HOST="${NL_HOST}"
FWD_PORT="${FWD_PORT}"
SSH_USER="${SSH_USER}"
REMOTE_DIR="${REMOTE_DIR}"
LOCAL_DEST="${LOCAL_DEST}"
PARALLEL="${PULL_PARALLEL}"
KEY_FILE="${KEY_FILE}"
KNOWN_HOSTS="${KNOWN_HOSTS}"
LOG="${PULL_LOG}"
STABLE_SEC="${PULL_STABLE_SEC}"
REMOTE_USED_DIR="${REMOTE_USED_DIR}"
EOF

    cat >> "$tmp" <<'PULL_BODY'

DRY_RUN=0
MODE=normal
PATTERN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --recall)  MODE=recall; PATTERN="${2:-}"
                   [ -n "$PATTERN" ] || { echo "--recall 需要一个文件名（可用子串）"; exit 2; }
                   shift ;;
        *) echo "未知参数：$1（可用：--dry-run / --recall <名字>）"; exit 2 ;;
    esac
    shift
done

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# 日志太大就留最近 500 行，避免无限增长
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 500 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
fi

SSH_COMMON="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${KNOWN_HOSTS} -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o Compression=no -o IPQoS=throughput"

start=$(date +%s)

# ---- 1. 等隧道的本地转发端口就绪 ----
i=0
while [ "$i" -lt 60 ]; do
    if nc -z 127.0.0.1 "$FWD_PORT" >/dev/null 2>&1; then break; fi
    sleep 1; i=$((i + 1))
done
if ! nc -z 127.0.0.1 "$FWD_PORT" >/dev/null 2>&1; then
    log "本地转发端口 127.0.0.1:${FWD_PORT} 未就绪（hysteria 没起来？），跳过本次"
    exit 1
fi

# ---- 1b. --recall：把归档区里匹配的文件挪回待拉区，下一轮会重新传一遍 ----
# （放在落地卷检查之前：就算外置盘没挂载也能用）
if [ "$MODE" = recall ]; then
    pb=$(printf '%s' "$PATTERN" | base64 | tr -d '\n')
    out=$(ssh -p "$FWD_PORT" $SSH_COMMON -i "$KEY_FILE" "${SSH_USER}@127.0.0.1" \
        "pat=\$(printf '%s' '$pb' | base64 -d)
         cd '$REMOTE_USED_DIR' 2>/dev/null || { echo NOUSED; exit 0; }
         n=0
         while IFS= read -r -d '' r; do
             [ -n \"\$r\" ] || continue
             case \"\$r\" in *\"\$pat\"*)
                 d=\$(dirname \"\$r\")
                 mkdir -p \"$REMOTE_DIR/\$d\" 2>/dev/null
                 mv -f -- \"\$r\" \"$REMOTE_DIR/\$r\" && n=\$((n+1)) ;;
             esac
         done < <(find . -mindepth 1 -type f -printf '%P\\0' 2>/dev/null)
         echo \"RECALL:\$n\"" 2>&1)
    if printf '%s' "$out" | grep -q '^NOUSED$'; then
        echo "归档目录不存在：$REMOTE_USED_DIR"
    else
        cnt=$(printf '%s\n' "$out" | sed -n 's/^RECALL:\([0-9]*\)$/\1/p' | tail -1)
        echo "已把 ${cnt:-0} 个文件挪回待拉区（匹配「${PATTERN}」）；下一轮拉取会重新传输它们。"
    fi
    exit 0
fi

# ---- 1c. 落地卷检查（外置盘没挂载就别往内置盘写） ----
case "$LOCAL_DEST" in
    /Volumes/*)
        vol=$(printf '%s' "$LOCAL_DEST" | cut -d/ -f1-3)
        if ! mount | grep -q " on ${vol} "; then
            log "外置卷 ${vol} 未挂载，跳过本次拉取"
            exit 0
        fi
        ;;
esac
mkdir -p "$LOCAL_DEST" 2>/dev/null || { log "无法创建落地目录 ${LOCAL_DEST}，跳过"; exit 1; }

# ---- 1d. 写入权限探测：外置卷受 macOS TCC 保护，launchd 任务默认被拒 ----
probe="${LOCAL_DEST}/.nas-nl-write-probe.$$"
if ! ( : > "$probe" ) 2>/dev/null; then
    log "无法写入 ${LOCAL_DEST}：Operation not permitted"
    log "  原因：macOS TCC 保护外置卷，而本任务由 launchd 以 /bin/bash 拉起（平台二进制不会弹窗，直接拒绝）"
    log "  解决（二选一）："
    log "   A) 系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 点 + → Cmd+Shift+G 输入 /bin/bash → 添加并勾选"
    log "   B) 把落地目录改到内置盘，例如 --dest \"\$HOME/NAS\"（内置盘不受此限制）"
    exit 1
fi
rm -f "$probe" 2>/dev/null

# ---- 3. 列出远端文件 ----
LIST=$(mktemp) || { log "无法创建临时文件"; exit 1; }
CTRL=$(mktemp) || { log "无法创建临时文件"; exit 1; }
trap 'rm -f "$LIST" "$CTRL"' EXIT

# shellcheck disable=SC2086
if ! ssh -p "$FWD_PORT" $SSH_COMMON -i "$KEY_FILE" "${SSH_USER}@127.0.0.1" \
        "find '$REMOTE_DIR' -type f -printf '%s\t%T@\t%P\0' 2>/dev/null" > "$LIST"; then
    log "SSH 列目录失败（隧道/密钥/账号？），跳过本次"
    exit 1
fi

# 预扫描：aria2 没下完时一定存在同名 `.aria2` 控制文件（下完自动删除）。
# 这条比 mtime 更硬：慢速/暂停的任务可能长时间不写盘，光靠静默阈值会漏。
while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    r="${rec##*	}"
    case "$r" in *[.]aria2) printf '%s\n' "${r%[.]aria2}" >> "$CTRL" ;; esac
done < "$LIST"

total=0; need=0; ok=0; fail=0; skipped=0; waiting=0; ariaing=0
delivered=(); pids=(); names=(); sizes=()
now_ts=$(date +%s)

# 先落一条「开始」日志：传输中也能看到本轮在跑，卡住时便于排查
log "开始检查：远端 ${REMOTE_DIR}（并发 ${PARALLEL}，静默阈值 ${STABLE_SEC}s）"

# ---- 4. 逐个比对，只拉「已下完」的 ----
while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    sz="${rec%%	*}"
    rest="${rec#*	}"
    mt="${rest%%	*}"
    rel="${rest#*	}"
    [ -n "$rel" ] || continue
    total=$((total + 1))

    # (a) 跳过下载器产生的半成品与控制文件
    case "$rel" in
        *.!qB|*.aria2|*.part|*.parts|*.unwanted)
            skipped=$((skipped + 1)); continue ;;
    esac

    # (a2) aria2 还在下这个文件（同名 .aria2 控制文件还在）→ 一定没下完
    if [ -s "$CTRL" ] && grep -qxF "$rel" "$CTRL" 2>/dev/null; then
        ariaing=$((ariaing + 1)); continue
    fi

    # (b) 只拉「已经静默 STABLE_SEC 秒」的文件。
    #     正在下载的文件 mtime 一直在变（aria2/qb 都是边下边写），
    #     这里靠远端 mtime 把它挡在门外，避免把半成品反复拉回来。
    #     注意 age 小于 0 的情况：aria2 下完后会把 mtime 设成源站的 Last-Modified，
    #     源站时钟不准时这个时间可能在未来。那种文件永远等不到「静默够久」，
    #     会被无声地卡住，所以按已下完处理（age>=0 才参与判断）。
    if [ "$STABLE_SEC" -gt 0 ]; then
        mt_i="${mt%%.*}"
        case "$mt_i" in ''|*[!0-9]*) mt_i=0 ;; esac
        age=$(( now_ts - mt_i ))
        if [ "$mt_i" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt "$STABLE_SEC" ]; then
            waiting=$((waiting + 1)); continue
        fi
    fi

    local_path="${LOCAL_DEST}/${rel}"
    local_sz=""
    [ -f "$local_path" ] && local_sz=$(stat -f %z "$local_path" 2>/dev/null || echo "")

    # (c) 本地同路径、同大小 → 已经送达过：不需要再传，但要把远端那份挪进归档区
    if [ -n "$local_sz" ] && [ "$local_sz" = "$sz" ]; then
        delivered+=("$rel"); continue
    fi

    need=$((need + 1))
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "需拉取：${rel}（远端 ${sz}，本地 ${local_sz:-缺失}）"
        continue
    fi

    # 等并发槽位
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PARALLEL" ]; do sleep 0.3; done

    (
        mkdir -p "$(dirname "$local_path")" 2>/dev/null || exit 1
        errf=$(mktemp 2>/dev/null || echo "/tmp/nasnl-err.$$")
        # shellcheck disable=SC2086
        scp -P "$FWD_PORT" $SSH_COMMON -i "$KEY_FILE" -p \
            "${SSH_USER}@127.0.0.1:${REMOTE_DIR}/${rel}" "$local_path" >/dev/null 2>"$errf"
        rc=$?
        if [ "$rc" -ne 0 ] && [ -s "$errf" ]; then
            { printf '[%s] scp 报错(%s): ' "$(date '+%F %T')" "$rel"
              tail -n 3 "$errf" | tr '\n' ' ' | sed 's/  */ /g'; printf '\n'; } >> "$LOG"
        fi
        rm -f "$errf"
        exit "$rc"
    ) &
    pids+=("$!")
    names+=("$rel")
    sizes+=("$sz")
done < "$LIST"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "共 ${total} 个文件：已送达待归档 ${#delivered[@]} 个、下载中跳过 ${waiting} 个、aria2 未下完 ${ariaing} 个、半成品跳过 ${skipped} 个、需拉取 ${need} 个（dry-run 未实际传输）"
    exit 0
fi

# ---- 5. 收集结果 ----
idx=0
while [ "$idx" -lt "${#pids[@]}" ]; do
    if wait "${pids[$idx]}"; then
        got=""
        [ -f "${LOCAL_DEST}/${names[$idx]}" ] && got=$(stat -f %z "${LOCAL_DEST}/${names[$idx]}" 2>/dev/null || echo "")
        if [ "$got" = "${sizes[$idx]}" ]; then
            # 只有完整落地才算送达；半成品不算，下一轮会重试
            delivered+=("${names[$idx]}")
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            log "拉取不完整（远端 ${sizes[$idx]}，本地 ${got:-缺失}，本轮不记账，下轮重试）：${names[$idx]}"
        fi
    else
        fail=$((fail + 1))
        log "拉取失败：${names[$idx]}"
    fi
    idx=$((idx + 1))
done

# ---- 6. 已送达的赶紧归档：把远端那份 mv 进 $REMOTE_USED_DIR ----
# 这是「只传一遍」的实现：文件被挪出待拉目录后，Mac 永远不会再看到它，
# 于是你在本地怎么整理（挪进子文件夹/改名/删掉）都不会触发重传。
# 必须先确认本地大小 == 远端大小才算送达，否则半成品会把源文件也搬走。
moved=0; tdel=0
if [ "${#delivered[@]}" -gt 0 ]; then
    # 远端助手负责：① mv 进归档目录 ② 把「内容已全部搬空」的 qB 种子从面板删掉
    # （只删种子不删文件；正在下载中的种子一律不碰）。助手路径固定为 /opt/nas-server/archive.sh。
    move_out=$(printf '%s\0' "${delivered[@]}" | \
        ssh -p "$FWD_PORT" $SSH_COMMON -i "$KEY_FILE" "${SSH_USER}@127.0.0.1" \
        'bash /opt/nas-server/archive.sh' 2>&1)
    moved=$(printf '%s\n' "$move_out" | sed -n 's/^MOVED:\([0-9]*\)$/\1/p' | tail -1)
    tdel=$(printf '%s\n' "$move_out" | sed -n 's/^TORRENTS-DELETED:\([0-9]*\)$/\1/p' | tail -1)
    moved=${moved:-0}; tdel=${tdel:-0}
    printf '%s\n' "$move_out" | sed -n 's/^FAIL://p' | while IFS= read -r f; do
        log "归档失败（远端仍然保留，下轮会重试）：${f}"
    done
    if printf '%s' "$move_out" | grep -q '^NOINBOX$'; then
        log "远端待拉目录不存在：${REMOTE_DIR}"; moved=0
    fi
    [ "$moved" -gt 0 ] && log "已归档到 ${REMOTE_USED_DIR}：${moved} 个（本地已确认送达）"
    [ "$tdel" -gt 0 ] && log "已从 qBittorrent 移除 ${tdel} 个内容已搬空的种子（只删种子，未删文件）"
fi

elapsed=$(( $(date +%s) - start ))
if [ "$total" -gt 0 ] || [ "$need" -gt 0 ] || [ "$waiting" -gt 0 ]; then
    extra=""
    [ "$moved" -gt 0 ] && extra="${extra}，归档 ${moved}"
    [ "${tdel:-0}" -gt 0 ] && extra="${extra}，清种子 ${tdel}"
    [ "$waiting" -gt 0 ] && extra="${extra}，下载中跳过 ${waiting}"
    [ "$ariaing" -gt 0 ] && extra="${extra}，aria2 未下完 ${ariaing}"
    [ "$skipped" -gt 0 ] && extra="${extra}，半成品跳过 ${skipped}"
    log "扫描 ${total} 个文件，需拉取 ${need} 个 → 成功 ${ok}，失败 ${fail}${extra}（耗时 ${elapsed}s）"
fi
[ "$fail" -eq 0 ] || exit 1
exit 0
PULL_BODY

    sudo mkdir -p "$(dirname "$PULL_SCRIPT")" || die "无法创建目录"
    sudo cp "$tmp" "$PULL_SCRIPT" || die "写入 $PULL_SCRIPT 失败"
    sudo chmod 755 "$PULL_SCRIPT"
    rm -f "$tmp"
    log_ok "已生成拉取脚本：$PULL_SCRIPT"
}

write_pull_plist() {
    local tmp; tmp=$(mktemp) || die "无法创建临时文件"
    write_plist_header > "$tmp"
    cat >> "$tmp" <<EOF
	<key>Label</key>
	<string>${LABEL_PULL}</string>

	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${PULL_SCRIPT}</string>
	</array>

	<key>UserName</key>
	<string>${RUN_USER}</string>

	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>${PULL_INTERVAL}</integer>
	<key>ProcessType</key>
	<string>Background</string>

	<key>StandardOutPath</key>
	<string>${LOG_DIR}/pull-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/pull-launchd.log</string>
</dict>
</plist>
EOF
    install_plist "$LABEL_PULL" "$tmp" "$PLIST_PULL"
    rm -f "$tmp"
}

nl_phase3_pullscript() {
    log_step "阶段 3/5：生成拉取脚本"
    write_pull_script
}

#-------------------------------------------------------------------------------
# 阶段 4：launchd
#-------------------------------------------------------------------------------
nl_phase4_launchd() {
    log_step "阶段 4/5：写入 launchd（开机自启 + 定时拉取）"

    sudo mkdir -p "$LAUNCHD_DIR" "$LOG_DIR" "$CONF_DIR"
    sudo chown "$RUN_USER:$RUN_GROUP" "$LOG_DIR" "$CONF_DIR"

    # known_hosts 要可写（accept-new 会往里追加）
    [ -f "$KNOWN_HOSTS" ] || : > "$KNOWN_HOSTS" 2>/dev/null || true
    sudo chown "$RUN_USER:$RUN_GROUP" "$KNOWN_HOSTS" 2>/dev/null || true

    log_info "先起隧道，再挂定时拉取"
    write_hy2_plist
    sleep 2
    write_pull_plist

    if wait_for_port "$FWD_PORT" 30; then
        log_ok "隧道已就绪：127.0.0.1:${FWD_PORT} → 荷兰机 127.0.0.1:${REMOTE_SSH_PORT}"
    else
        log_warn "本地转发端口 ${FWD_PORT} 未就绪，日志：${LOG_DIR}/hysteria.log"
        [ -f "${LOG_DIR}/hysteria.log" ] && tail -n 15 "${LOG_DIR}/hysteria.log" | sed 's/^/      /'
    fi
}

#-------------------------------------------------------------------------------
# 阶段 5：自检与汇总
#-------------------------------------------------------------------------------
nl_selftest_tunnel() {
    log_info "自检 1/4：hysteria2 隧道（本地转发端口）..."
    if wait_for_port "$FWD_PORT" 20; then
        log_ok "127.0.0.1:${FWD_PORT} 已监听"
        return 0
    fi
    log_err "127.0.0.1:${FWD_PORT} 未监听，日志：${LOG_DIR}/hysteria.log"
    [ -f "${LOG_DIR}/hysteria.log" ] && tail -n 15 "${LOG_DIR}/hysteria.log" | sed 's/^/      /'
    return 1
}

nl_selftest_ssh() {
    log_info "自检 2/4：经隧道登录荷兰机（${SSH_USER}@127.0.0.1:${FWD_PORT}）..."
    local out
    out=$(ssh_run 'uname -s; id -un' 2>&1) || {
        log_err "SSH 失败：$out"
        log_err "常见原因：荷兰机没装你的公钥 / 账号不对 / SNI 与证书不匹配"
        return 1
    }
    log_ok "SSH 正常：$(printf '%s' "$out" | tr '\n' ' ')"
    return 0
}

# 远端文件数（按引擎选不同的数法）
remote_count() {
    ssh_run "find '$REMOTE_DIR' -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d ' '
}

nl_selftest_list() {
    log_info "自检 3/4：列远端目录 ${REMOTE_DIR} ..."
    local n
    n=$(remote_count)
    if [ -z "$n" ]; then
        log_err "无法列出 ${REMOTE_DIR}"
        return 1
    fi
    log_ok "远端 ${REMOTE_DIR} 当前有 ${n} 个文件"
    return 0
}

nl_selftest_dest() {
    log_info "自检 4/4：本机落地目录 ${LOCAL_DEST} ..."
    local vol; vol=$(dest_volume_name)
    if [ -n "$vol" ] && ! dest_volume_mounted; then
        log_warn "外置卷 ${vol} 未挂载 —— 拉取任务会跳过（这是预期行为，不报错）"
        return 0
    fi
    if [ ! -d "$LOCAL_DEST" ]; then
        mkdir -p "$LOCAL_DEST" 2>/dev/null || { log_err "无法创建 $LOCAL_DEST"; return 1; }
    fi
    [ -w "$LOCAL_DEST" ] && { log_ok "$LOCAL_DEST 可写"; return 0; }
    log_err "$LOCAL_DEST 不可写"
    return 1
}

nl_run_selftests() {
    local rc=0
    nl_selftest_tunnel  || rc=1
    nl_selftest_ssh     || rc=1
    nl_selftest_list    || rc=1
    nl_selftest_dest    || rc=1
    return "$rc"
}

nl_print_summary() {
    log_raw ""
    log_raw "${C_GREEN}${C_BOLD}════════════ Mac 端（荷兰机拉取）部署完成 ════════════${C_RESET}"
    log_raw ""
    log_raw "  荷兰机     ： ${NL_HOST}:${NL_HY2_PORT}（UDP，SNI ${NL_SNI}）"
    log_raw "  隧道       ： 127.0.0.1:${FWD_PORT} → 荷兰机 127.0.0.1:${REMOTE_SSH_PORT}"
    if [ "$SOCKS_PORT" != "0" ]; then
        log_raw "  SOCKS5 入口： 127.0.0.1:${SOCKS_PORT}（走荷兰机 UDP 出网）"
        log_raw "                丢包严重打不开面板时，把浏览器代理指到它（只对 *.${NL_SNI#*.} 生效即可）"
    fi
    log_raw "  拉取       ： ${SSH_USER}@荷兰机:${REMOTE_DIR}"
    log_raw "  落地       ： ${LOCAL_DEST}"
    log_raw "  节奏       ： 每 ${PULL_INTERVAL} 秒，并发 ${PULL_PARALLEL}"
    log_raw "  只拉已下完 ： 远端文件需静默 ${PULL_STABLE_SEC} 秒（正在下载的会被跳过；0=关闭）"
    log_raw "  源文件     ： 拉取后**不删**，由荷兰机自己的 24h 定时清理"
    log_raw ""
    log_raw "${C_BOLD}两个 launchd 服务：${C_RESET}"
    log_raw "  ${LABEL_HY2} : $(launchd_state "$LABEL_HY2")"
    log_raw "  ${LABEL_PULL} : $(launchd_state "$LABEL_PULL")"
    log_raw ""
    log_raw "${C_BOLD}文件位置：${C_RESET}"
    log_raw "  配置目录   ： ${CONF_DIR}/"
    log_raw "  运行日志   ： ${LOG_DIR}/（拉取日志 ${PULL_LOG}）"
    log_raw "  拉取脚本   ： ${PULL_SCRIPT}"
    log_raw "  归档目录   ： 荷兰机 ${REMOTE_USED_DIR}（拉走并校验成功后，远端那份会 mv 到这里）"
    log_raw "  hysteria   ： ${HY2_BIN}（与国内那套共用，卸载时不会删）"
    log_raw ""
    log_raw "${C_BOLD}与国内那套的隔离：${C_RESET}"
    log_raw "  · 标签 com.nas.nl.* ≠ com.nas.tunnel.* / com.openlist.server"
    log_raw "  · 配置 ${CONF_DIR}/ ≠ /usr/local/etc/nas-tunnel/"
    log_raw "  · 端口 ${FWD_PORT} ≠ 1080(socks5)${C_RESET}$( [ "$SOCKS_PORT" != "0" ] && printf '；本套 SOCKS5 用 %s' "$SOCKS_PORT" )${C_RESET}"
    local vol; vol=$(dest_volume_name)
    if [ -n "$vol" ]; then
        log_raw ""
        log_raw "${C_YELLOW}${C_BOLD}⚠ 落地目录在外置卷 ${vol} 上：macOS TCC 需要一次授权${C_RESET}"
        log_raw "  拉取任务由 launchd 以 /bin/bash 拉起。首次拉取前请授予它「完全磁盘访问权限」："
        log_raw "    系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 点 + → Cmd+Shift+G →"
        log_raw "    ${C_BOLD}/bin/bash${C_RESET} → 打开，然后在列表里把开关打开"
        log_raw "    （若添加后列表里看不到，退出「系统设置」再打开即可——这是 macOS 的刷新问题）"
        log_raw "  未授权时 ${PULL_LOG} 会出现 Operation not permitted，脚本会打印同样的提示"
        log_raw "  不想授权也行： bash ${SCRIPT_NAME} --dest \"\$HOME/NAS\"（内置盘不受此限制）"
    fi
    log_raw ""
    log_raw "${C_BOLD}常用运维命令：${C_RESET}"
    log_raw "  bash ${SCRIPT_NAME} --status"
    log_raw "  bash ${SCRIPT_NAME} --pull-now"
    log_raw "  bash ${SCRIPT_NAME} --self-test"
    log_raw "  bash ${SCRIPT_NAME} --uninstall"
    log_raw "  tail -f ${PULL_LOG}"
    log_raw "  sudo launchctl print system/${LABEL_HY2}"
}

nl_phase5_summary() {
    log_step "阶段 5/5：端到端自检与汇总"
    save_state
    if nl_run_selftests; then
        log_ok "四项自检全部通过"
    else
        log_warn "自检未全部通过，请按上面的提示排查；服务与配置均已保留"
    fi
    nl_print_summary
}

#-------------------------------------------------------------------------------
# --status
#-------------------------------------------------------------------------------
do_status() {
    [ -f "$STATE_FILE" ] || log_warn "未找到状态文件（${STATE_FILE}），部分信息可能缺失"
    load_state || true

    log_step "荷兰机拉取（Mac 端）当前状态"

    log_raw "  服务状态（launchd）："
    log_raw "    ${LABEL_HY2} : $(launchd_state "$LABEL_HY2")"
    log_raw "    ${LABEL_PULL} : $(launchd_state "$LABEL_PULL")"
    log_raw ""
    log_raw "  端口监听："
    if port_listening "$FWD_PORT"; then
        log_raw "    隧道转发 ${FWD_PORT} : ${C_GREEN}监听中${C_RESET}"
    else
        log_raw "    隧道转发 ${FWD_PORT} : ${C_RED}未监听${C_RESET}"
    fi
    if [ "${SOCKS_PORT:-0}" != "0" ]; then
        if port_listening "$SOCKS_PORT"; then
            log_raw "    SOCKS5 ${SOCKS_PORT}   : ${C_GREEN}监听中${C_RESET}"
        else
            log_raw "    SOCKS5 ${SOCKS_PORT}   : ${C_RED}未监听${C_RESET}"
        fi
    fi
    log_raw ""
    log_raw "  参数："
    log_raw "    荷兰机      ： ${NL_HOST:-未知}:${NL_HY2_PORT:-未知}（UDP）"
    log_raw "    SNI         ： ${NL_SNI:-未知}"
    log_raw "    远端目录    ： ${REMOTE_DIR:-未知}"
    log_raw "    落地目录    ： ${LOCAL_DEST:-未知}"
    log_raw "    间隔/并发   ： ${PULL_INTERVAL:-未知}s / ${PULL_PARALLEL:-未知}"
    log_raw "    静默阈值    ： ${PULL_STABLE_SEC:-未知}s（下载中的文件会被跳过）"
    local vol; vol=$(dest_volume_name)
    if [ -n "$vol" ]; then
        if dest_volume_mounted; then
            log_raw "    落地卷      ： ${vol} ${C_GREEN}已挂载${C_RESET}"
        else
            log_raw "    落地卷      ： ${vol} ${C_YELLOW}未挂载（拉取会被跳过）${C_RESET}"
        fi
    fi

    if port_listening "$FWD_PORT"; then
        local n
        n=$(remote_count)
        log_raw ""
        if [ -n "$n" ]; then
            log_ok "链路在线：远端 ${REMOTE_DIR} 有 ${n} 个文件待拉取"
        else
            log_warn "能连上端口但列目录失败（公钥/账号/引擎配置？）"
        fi
    fi

    log_raw ""
    log_raw "  最近拉取日志："
    if [ -f "$PULL_LOG" ]; then
        tail -n 5 "$PULL_LOG" | sed 's/^/    /'
    else
        log_raw "    （暂无）"
    fi
}

#-------------------------------------------------------------------------------
# --recall
#-------------------------------------------------------------------------------
do_recall() {
    load_state 2>/dev/null || true
    log_step "把归档目录里匹配「${RECALL_PATTERN}」的文件挪回待拉目录"
    [ -x "$PULL_SCRIPT" ] || die "还没部署（找不到 ${PULL_SCRIPT}），先运行 bash ${SCRIPT_NAME}"
    bash "$PULL_SCRIPT" --recall "$RECALL_PATTERN"
    log_ok "下一轮拉取会重新传输被挪回的文件"
}

#-------------------------------------------------------------------------------
# --pull-now
#-------------------------------------------------------------------------------
do_pull_now() {
    load_state 2>/dev/null || true
    log_step "立刻拉取一次"
    [ -x "$PULL_SCRIPT" ] || die "还没部署（找不到 ${PULL_SCRIPT}），先运行 bash ${SCRIPT_NAME}"
    bash "$PULL_SCRIPT"
    log_ok "拉取结束，日志：$PULL_LOG"
    if [ -f "$PULL_LOG" ]; then
        tail -n 8 "$PULL_LOG" | sed 's/^/    /'
    fi
}

#-------------------------------------------------------------------------------
# --self-test
#-------------------------------------------------------------------------------
do_self_test() {
    load_state 2>/dev/null || true
    log_step "只执行端到端自检"
    if nl_run_selftests; then
        log_ok "四项自检全部通过"
    else
        die "自检未通过，请根据上面的输出排查"
    fi
}

#-------------------------------------------------------------------------------
# --uninstall
#-------------------------------------------------------------------------------
do_uninstall() {
    log_step "卸载：移除荷兰机拉取相关的 launchd 与配置"

    load_state 2>/dev/null || true

    log_raw "  · 卸载并删除 launchd：${LABEL_HY2}、${LABEL_PULL}"
    log_raw "  · 归档并删除配置目录：${CONF_DIR}/"
    log_raw "  · 删除拉取脚本：${PULL_SCRIPT}"
    log_raw "  · ${C_GREEN}保留 ${HY2_BIN}${C_RESET}（国内那套可能还在用）"
    log_raw "  · ${C_GREEN}保留落地目录 ${LOCAL_DEST}${C_RESET}"
    log_raw ""
    if [ "$ASSUME_YES" -eq 0 ]; then
        confirm "确认继续？" n || die "已取消"
    fi

    launchd_unload "$LABEL_PULL" "$PLIST_PULL"
    launchd_unload "$LABEL_HY2" "$PLIST_HY2"
    sudo rm -f "$PLIST_PULL" "$PLIST_HY2"
    log_ok "已卸载并删除 launchd 单元"

    local ts backup
    ts=$(date +%Y%m%d-%H%M%S)
    backup="/tmp/nas-nl-backup-${ts}"
    mkdir -p "$backup" 2>/dev/null || true
    [ -d "$CONF_DIR" ] && sudo cp -a "$CONF_DIR" "$backup/" 2>/dev/null || true
    [ -d "$LOG_DIR" ]  && sudo cp -a "$LOG_DIR"  "$backup/" 2>/dev/null || true
    sudo chown -R "$RUN_USER:$RUN_GROUP" "$backup" 2>/dev/null || true
    log_ok "配置与日志已归档到：$backup"

    sudo rm -f "$PULL_SCRIPT"
    sudo rm -rf "$CONF_DIR" "$LOG_DIR"
    log_ok "已删除配置目录与日志目录"

    log_raw ""
    log_ok "卸载完成（hysteria 二进制与落地目录均保留）"
}

#-------------------------------------------------------------------------------
# 主流程
#-------------------------------------------------------------------------------
main() {
    # 先读状态文件，再解析命令行 —— 命令行优先级更高，不会被状态文件覆盖
    load_state 2>/dev/null || true
    parse_args "$@"

    # -y 模式：必填项必须在命令行给出，先报错，别白等 sudo
    if [ "$ASSUME_YES" -eq 1 ]; then
        [ -n "$NL_HOST" ]     || { echo "错误：-y 模式缺少 --nl-host" >&2; exit 2; }
        [ -n "$NL_HY2_PASS" ] || { echo "错误：-y 模式缺少 --nl-pass" >&2; exit 2; }
        [ -n "$NL_SNI" ]      || { echo "错误：-y 模式缺少 --nl-sni" >&2; exit 2; }
    fi

    init_log
    log_raw ""
    log_raw "${C_CYAN}${C_BOLD}  NAS 荷兰机拉取脚本 v${SCRIPT_VERSION}  （Mac mini 端）${C_RESET}"
    log_raw "${C_CYAN}  hysteria2(UDP) 隧道 + 每 ${PULL_INTERVAL}s 并行拉取，全部 launchd 自启${C_RESET}"
    log_raw ""

    if [ "$DO_STATUS" -eq 1 ]; then do_status; exit 0; fi
    if [ "$DO_RECALL" -eq 1 ]; then do_recall; exit 0; fi
    if [ "$DO_UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi
    if [ "$SELF_TEST_ONLY" -eq 1 ]; then do_self_test; exit 0; fi

    nl_phase0_env
    nl_phase1_params
    nl_phase2_hysteria
    nl_phase3_pullscript
    nl_phase4_launchd

    if [ "$DO_PULL_NOW" -eq 1 ]; then
        nl_phase5_summary
        do_pull_now
        exit 0
    fi

    nl_phase5_summary
}

main "$@"
