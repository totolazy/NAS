#!/usr/bin/env bash
#═══════════════════════════════════════════════════════════════════════════════
#  nas-n.sh —— 国外下载服务器 一键部署脚本（单文件、自包含）
#
#  只负责这一台「国外下载服务器」。国内中转机与 Mac mini 不在本脚本范围内，
#  但它们需要怎么配合，脚本里写清楚了（见 `./nas-n.sh macmini`）。
#
#  部署内容
#    1. Docker + qBittorrent + aria2 + AriaNg（本机端口映射，WebUI 只绑 127.0.0.1）
#    2. OpenList（用官方脚本 https://res.oplist.org/script/v4.sh 安装）
#    3. 回传通道（默认 direct）：本机跑 frps，Mac mini 主动连过来注册自己的 SSH
#       （Mac mini 无需公网 IP，无需第三方中转；也可切 relay 模式接一台中转机）
#    4. Caddy + Cloudflare 域名与 HTTPS（只追加配置，绝不动本机已有站点）
#    5. 下载完成 → 经 frp 通道高速回传 Mac mini → 保留 24 小时后自动清理本机副本
#
#  用法
#    sudo ./nas-n.sh                 交互式完整部署
#    sudo ./nas-n.sh check           只读预检，不改动系统
#    sudo ./nas-n.sh reconfigure     重新问答并覆盖配置
#    sudo ./nas-n.sh transfer        立即回传一次（可加 --force）
#    sudo ./nas-n.sh cleanup         立即按保留策略清理一次
#    sudo ./nas-n.sh status          查看运行状态
#    sudo ./nas-n.sh ports           打印端口映射表
#    ./nas-n.sh macmini              打印 Mac mini 侧对接说明（写 macmini 脚本时对齐用）
#    sudo ./nas-n.sh uninstall       卸载（默认保留下载数据）
#    ./nas-n.sh --emit <name>        打印内置生成物（调试用：compose/trigger/transfer/
#                                    cleanup/healthcheck/frpc/hy2/rclone/caddy）
#
#  兼容：Debian 12 / Ubuntu（apt）与 RHEL 系（dnf/yum），systemd，x86_64 / arm64。
#═══════════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail

VERSION="1.0.0"

#───────────────────────────────────────────────────────────────────────────────
# 0. 路径与默认值
#───────────────────────────────────────────────────────────────────────────────
CONF="/etc/nas-n/nas-n.conf"          # 全部参数（含口令），权限 600
APP="/opt/nas-n"                      # 脚本生成物与二进制
DATA="/srv/nas-n"                     # 数据目录（下载文件、容器配置）
STATE="/var/lib/nas-n"                # 运行状态（队列、锁、日志、触发器）

CERT_DIR="/etc/nas-n/certs"
RCLONE_CONF="/etc/nas-n/rclone.conf"
FRPC_CONF="/etc/nas-n/frpc.toml"
HY2_CONF="/etc/nas-n/hysteria-client.yaml"
SSH_KEY="/etc/nas-n/ssh/id_ed25519"

LOG="/var/log/nas-n.log"

#───────────────────────────────────────────────────────────────────────────────
# 1. 日志与通用工具
#───────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; B=$'\033[1;34m'
  C=$'\033[1;36m'; BD=$'\033[1m'; N=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; C=''; BD=''; N=''
fi

say()   { printf '%s[%s]%s %s\n' "$B" "$(date '+%F %T')" "$N" "$*"; }
ok()    { printf '%s[  OK  ]%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '%s[ WARN ]%s %s\n' "$Y" "$N" "$*" >&2; }
err()   { printf '%s[ FAIL ]%s %s\n' "$R" "$N" "$*" >&2; }
die()   { err "$*"; exit 1; }
title() {
  printf '\n%s%s════════════════════════════════════════════════════════════════%s\n' "$BD$C" '' "$N"
  printf '%s  %s%s\n' "$BD$C" "$*" "$N"
  printf '%s%s════════════════════════════════════════════════════════════════%s\n' "$C" '' "$N"
}
sub() { printf '\n%s--> %s%s\n' "$BD" "$*" "$N"; }

have()      { command -v "$1" >/dev/null 2>&1; }
is_root()   { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
need_root() { is_root || die "需要 root 权限，请用： sudo $0 $*"; }

rand_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"; }
arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo arm ;;
    *) echo unknown ;;
  esac
}

env_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# 幂等写入：内容变化时 WRITE_CHANGED=1，否则 0。始终返回 0（避免 set -e 误触发）
WRITE_CHANGED=0
write_file() {
  local target="$1" mode="${2:-0644}" tmp
  WRITE_CHANGED=0
  tmp="$(mktemp)"; cat >"$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; return 0; fi
  mkdir -p "$(dirname "$target")"
  cat "$tmp" >"$target"; chmod "$mode" "$target"; rm -f "$tmp"
  WRITE_CHANGED=1
  return 0
}

# 更新配置文件里的一个 KEY
conf_set() {
  local key="$2" val="$3" tmp found=0 line l
  line="${key}=$(env_quote "$val")"
  mkdir -p "$(dirname "$1")"
  tmp="$(mktemp "$(dirname "$1")/.nasn.XXXXXX")"; chmod 600 "$tmp"
  if [[ -f "$1" ]]; then
    while IFS= read -r l || [[ -n "$l" ]]; do
      if [[ "$l" == "${key}="* ]]; then printf '%s\n' "$line" >>"$tmp"; found=1
      else printf '%s\n' "$l" >>"$tmp"; fi
    done <"$1"
  fi
  [[ $found -eq 1 ]] || printf '%s\n' "$line" >>"$tmp"
  mv -f "$tmp" "$1"; chmod 600 "$1"
}

conf_load() {
  [[ -f "$CONF" ]] || return 1
  set -a; . "$CONF"; set +a
}

port_in_use() {
  ss -H -t -l -n "sport = :$1" 2>/dev/null | grep -q . && return 0
  ss -H -u -l -n "sport = :$1" 2>/dev/null | grep -q . && return 0
  return 1
}
port_owner() { ss -H -t -l -n -p "sport = :$1" 2>/dev/null | head -1 | sed 's/.*users:((//; s/)).*//'; }

# 判断端口占用者是不是本项目自己的组件（重跑时不应被当成冲突）
is_own_service() {
  case "$1" in
    *docker-proxy*|*openlist*|*hysteria*|*frps*|*frpc*|*caddy*|*aria2*|*qbittorrent*) return 0 ;;
    *) return 1 ;;
  esac
}

# 进程名读不到时的兜底：这个端口对应的本项目组件是否正在运行
port_owned_by_nasn() {
  local port="$1"
  case "$port" in
    "${OPENLIST_PORT:-5244}")  svc_active openlist.service && return 0 ;;
    "${FRPS_PORT:-7000}")      svc_active nas-n-frps.service && return 0 ;;
    "${QB_WEBUI_PORT:-8080}"|"${QB_BT_PORT:-6881}")
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nas-n-qbittorrent' && return 0 ;;
    "${ARIA2_RPC_PORT:-6800}"|"${TRACKER_BT_PORT:-6888}")
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nas-n-aria2' && return 0 ;;
    "${ARIANG_PORT:-8081}")
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nas-n-ariang' && return 0 ;;
    "${HY2_SOCKS_PORT:-1081}"|"${MACMINI_SSH_PORT:-2222}")
        svc_active nas-n-hysteria.service && return 0 ;;
  esac
  return 1
}

http_download() {
  local url="$1" out="$2" tries="${3:-3}" i=1
  mkdir -p "$(dirname "$out")"
  while (( i <= tries )); do
    if curl -fL --connect-timeout 15 --retry 2 --retry-delay 3 -o "${out}.part" "$url"; then
      mv -f "${out}.part" "$out"; return 0
    fi
    warn "下载失败（第 $i/$tries 次）：$url"; sleep $((i * 2)); ((i++))
  done
  rm -f "${out}.part"; return 1
}

pkg_install() {
  [[ $# -eq 0 ]] && return 0
  if have apt-get; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
  elif have dnf; then dnf install -y -q "$@"
  elif have yum; then yum install -y -q "$@"
  else die "无法识别的包管理器，请手动安装：$*"; fi
}

svc_reload()  { systemctl daemon-reload; }
svc_active()  { systemctl is-active --quiet "$1"; }
svc_enable()  { systemctl enable --now "$1" >/dev/null 2>&1 || systemctl enable "$1" >/dev/null 2>&1 || true; }

unit_put() {
  local src="$1" name="$2"
  write_file "/etc/systemd/system/$name" 0644 <"$src"
  [[ $WRITE_CHANGED -eq 1 ]] && ok "写入单元 $name"
  return 0
}

# 只读列出缺失依赖（check 模式用，不安装任何东西）
deps_report() {
  local c missing=()
  for c in curl tar gzip openssl unzip rsync ss python3; do have "$c" || missing+=("$c"); done
  if [[ ${#missing[@]} -eq 0 ]]; then ok "基础依赖齐全"
  else warn "缺少依赖：${missing[*]}（安装阶段会自动补齐）"; fi
}

#───────────────────────────────────────────────────────────────────────────────
# 2. 交互配置
#───────────────────────────────────────────────────────────────────────────────
RECONFIGURE=0
ASSUME_YES=0

def_defaults() {
  TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || echo Asia/Shanghai)}"
  DL_ROOT="${DL_ROOT:-$DATA/downloads}"
  DL_TORRENT_DIR="${DL_TORRENT_DIR:-$DL_ROOT/torrents}"
  DL_ARIA_DIR="${DL_ARIA_DIR:-$DL_ROOT/aria2}"
  DL_INCOMPLETE_DIR="${DL_INCOMPLETE_DIR:-$DL_ROOT/incomplete}"

  OPENLIST_PORT="${OPENLIST_PORT:-5244}"
  QB_WEBUI_PORT="${QB_WEBUI_PORT:-8080}"
  QB_BT_PORT="${QB_BT_PORT:-6881}"
  ARIA2_RPC_PORT="${ARIA2_RPC_PORT:-6800}"
  ARIANG_PORT="${ARIANG_PORT:-8081}"
  TRACKER_BT_PORT="${TRACKER_BT_PORT:-6888}"

  OPENLIST_USER="${OPENLIST_USER:-admin}"; OPENLIST_PASS="${OPENLIST_PASS:-}"
  QB_USER="${QB_USER:-admin}";             QB_PASS="${QB_PASS:-}"
  ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-}"

  CF_BASE_DOMAIN="${CF_BASE_DOMAIN:-}"
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  CF_PROXIED="${CF_PROXIED:-false}"
  ACME_MODE="${ACME_MODE:-auto}"                 # auto | dns | off
  CADDY_MODE="${CADDY_MODE:-import}"             # import | off
  DOMAIN_OPENLIST="${DOMAIN_OPENLIST:-}"
  DOMAIN_QB="${DOMAIN_QB:-}"
  DOMAIN_ARIA="${DOMAIN_ARIA:-}"

  TUNNEL_MODE="${TUNNEL_MODE:-direct}"        # direct | relay | none
  CN_HOST="${CN_HOST:-}"
  FRPS_PORT="${FRPS_PORT:-7000}"
  FRP_TOKEN="${FRP_TOKEN:-}"
  FRP_PROTOCOL="${FRP_PROTOCOL:-tcp}"
  FRP_VIA_HY2="${FRP_VIA_HY2:-false}"
  FRP_REMOTE_OPENLIST="${FRP_REMOTE_OPENLIST:-15244}"
  FRP_REMOTE_QB="${FRP_REMOTE_QB:-18080}"
  FRP_REMOTE_ARIA="${FRP_REMOTE_ARIA:-18081}"

  HY2_ENABLE="${HY2_ENABLE:-true}"
  HY2_SERVER_PORT="${HY2_SERVER_PORT:-443}"
  HY2_AUTH="${HY2_AUTH:-}"
  HY2_SNI="${HY2_SNI:-}"
  HY2_OBFS_PASS="${HY2_OBFS_PASS:-}"
  HY2_UP_MBPS="${HY2_UP_MBPS:-}"
  HY2_DOWN_MBPS="${HY2_DOWN_MBPS:-}"
  HY2_SOCKS_PORT="${HY2_SOCKS_PORT:-1081}"

  MACMINI_SSH_HOST="${MACMINI_SSH_HOST:-127.0.0.1}"
  MACMINI_SSH_PORT="${MACMINI_SSH_PORT:-2222}"
  MACMINI_SSH_REMOTE_PORT="${MACMINI_SSH_REMOTE_PORT:-12222}"
  MACMINI_SSH_USER="${MACMINI_SSH_USER:-nas}"
  MACMINI_SSH_KEY="${MACMINI_SSH_KEY:-$SSH_KEY}"

  # 直连模式：frps 跑在本机，Mac mini 主动连过来，它的 SSH 直接落在 127.0.0.1:<远程端口>
  if [[ "$TUNNEL_MODE" == "direct" ]]; then
    MACMINI_SSH_HOST="127.0.0.1"
    MACMINI_SSH_PORT="$MACMINI_SSH_REMOTE_PORT"
  fi

  TRANSFER_ENGINE="${TRANSFER_ENGINE:-rclone}"
  TRANSFER_STABLE_SEC="${TRANSFER_STABLE_SEC:-120}"
  TRANSFER_PARALLEL="${TRANSFER_PARALLEL:-4}"
  TRANSFER_VERIFY="${TRANSFER_VERIFY:-size}"
  RETENTION_HOURS="${RETENTION_HOURS:-24}"
  HEALTH_WEBHOOK="${HEALTH_WEBHOOK:-}"
  TRANSFER_MAP="${TRANSFER_MAP:-${DL_TORRENT_DIR}:/Volumes/Media/Downloads/torrents;${DL_ARIA_DIR}:/Volumes/Media/Downloads/aria2}"
}

ask() {
  local __v="$1" __p="$2" __d="${3:-}" __allow_empty="${4:-0}" __a=""
  if [[ "$ASSUME_YES" == "1" && -n "$__d" ]]; then printf -v "$__v" '%s' "$__d"; return 0; fi
  while :; do
    if [[ -n "$__d" ]]; then read -r -p "$__p [$__d]: " __a || true
    else read -r -p "$__p: " __a || true; fi
    [[ -z "$__a" ]] && __a="$__d"
    if [[ -n "$__a" || "$__allow_empty" == "1" ]]; then printf -v "$__v" '%s' "$__a"; return 0; fi
    warn "该项不能为空"
  done
}

ask_secret() {
  local __v="$1" __p="$2" __d="${3:-}" __a="" hint=""
  [[ -n "$__d" ]] && hint=" [已设置，回车保持不变]"
  if [[ "$ASSUME_YES" == "1" && -n "$__d" ]]; then printf -v "$__v" '%s' "$__d"; return 0; fi
  read -r -p "$__p$hint: " __a || true
  [[ -z "$__a" ]] && __a="$__d"
  printf -v "$__v" '%s' "$__a"
}

ask_port() {
  local __v="$1" __p="$2" __d="${3:-}" __a=""
  while :; do
    ask __a "$__p" "$__d"
    if [[ "$__a" =~ ^[0-9]+$ ]] && (( __a >= 1 && __a <= 65535 )); then printf -v "$__v" '%s' "$__a"; return 0; fi
    warn "端口必须是 1-65535 的整数，收到：'$__a'"
  done
}

ask_int() {
  local __v="$1" __p="$2" __d="${3:-}" __min="${4:-0}" __max="${5:-2147483647}" __a=""
  while :; do
    ask __a "$__p" "$__d"
    if [[ "$__a" =~ ^[0-9]+$ ]] && (( __a >= __min && __a <= __max )); then printf -v "$__v" '%s' "$__a"; return 0; fi
    warn "请输入 ${__min}-${__max} 之间的整数，收到：'$__a'"
  done
}

ask_hostname() {
  local __v="$1" __p="$2" __d="${3:-}" __a=""
  while :; do
    ask __a "$__p" "$__d"
    if [[ "$__a" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      printf -v "$__v" '%s' "$__a"; return 0
    fi
    warn "域名格式不正确：'$__a'"
  done
}

ask_map() {
  local __v="$1" __p="$2" __d="${3:-}" __a="" __e __bad=0
  while :; do
    ask __a "$__p" "$__d"
    __bad=0
    IFS=';' read -r -a __entries <<<"$__a"
    for __e in "${__entries[@]}"; do
      [[ -z "$__e" ]] && continue
      if [[ "$__e" != *:* || "$__e" == :* || "$__e" == *: ]]; then
        warn "映射项格式错误（应为 本机目录:Mac mini目录）：'$__e'"; __bad=1; break
      fi
    done
    (( __bad == 0 )) && { printf -v "$__v" '%s' "$__a"; return 0; }
  done
}

confirm() {
  local __p="$1" __d="${2:-n}" __a=""
  if [[ "$ASSUME_YES" == "1" ]]; then [[ "$__d" == "y" ]]; return; fi
  if [[ "$__d" == "y" ]]; then read -r -p "$__p [Y/n]: " __a || true; [[ -z "$__a" || "$__a" =~ ^[Yy] ]]
  else read -r -p "$__p [y/N]: " __a || true; [[ "$__a" =~ ^[Yy] ]]; fi
}

prompt_all() {
  title "交互式配置"

  cat <<'EOT'

本向导依次询问：端口、口令、域名与证书、国内中转机、hysteria2、Mac mini 回传目录。
所有答案保存到 /etc/nas-n/nas-n.conf（权限 600），下次重跑直接复用。
（每一步直接回车即使用方括号里的默认值）

EOT

  sub "端口规划（WebUI/RPC 只绑 127.0.0.1，由 Caddy / frp 对外暴露）"
  ask_port OPENLIST_PORT "OpenList 端口" "$OPENLIST_PORT"
  ask_port QB_WEBUI_PORT  "qBittorrent WebUI 端口" "$QB_WEBUI_PORT"
  ask_port QB_BT_PORT     "qBittorrent BT 端口（TCP+UDP，需公网可达）" "$QB_BT_PORT"
  ask_port ARIA2_RPC_PORT "aria2 RPC 端口" "$ARIA2_RPC_PORT"
  ask_port ARIANG_PORT    "AriaNg 端口" "$ARIANG_PORT"

  sub "访问口令（直接回车自动生成 20~24 位强随机口令）"
  ask_secret OPENLIST_PASS "OpenList 管理员($OPENLIST_USER)密码" "$OPENLIST_PASS"
  [[ -z "$OPENLIST_PASS" ]] && OPENLIST_PASS="$(rand_secret 20)"
  ask_secret QB_PASS "qBittorrent WebUI 密码（用户 $QB_USER，至少 6 位）" "$QB_PASS"
  [[ -z "$QB_PASS" ]] && QB_PASS="$(rand_secret 20)"
  while (( ${#QB_PASS} < 6 )); do
    warn "qBittorrent 密码至少 6 位"
    ask_secret QB_PASS "qBittorrent WebUI 密码（至少 6 位）" ""
    [[ -z "$QB_PASS" ]] && { QB_PASS="$(rand_secret 20)"; ok "已自动生成随机口令"; }
  done
  ask_secret ARIA2_RPC_SECRET "aria2 RPC 密钥" "$ARIA2_RPC_SECRET"
  [[ -z "$ARIA2_RPC_SECRET" ]] && ARIA2_RPC_SECRET="$(rand_secret 24)"

  sub "域名与证书（Cloudflare 托管）"
  say "本机 80/443 由既有 Caddy 监听，脚本只「追加」站点配置，不会删除你已有的站点。"
  ask_hostname CF_BASE_DOMAIN "你的主域名（例如 dickgroup.xyz）" "$CF_BASE_DOMAIN"
  ask_hostname DOMAIN_OPENLIST "OpenList 访问域名" "${DOMAIN_OPENLIST:-ol.$CF_BASE_DOMAIN}"
  ask_hostname DOMAIN_QB       "qBittorrent 访问域名" "${DOMAIN_QB:-qb.$CF_BASE_DOMAIN}"
  ask_hostname DOMAIN_ARIA     "AriaNg 访问域名（aria2 RPC 走同域 /jsonrpc）" "${DOMAIN_ARIA:-aria.$CF_BASE_DOMAIN}"

  cat <<'EOT'

证书申请方式：
  1) auto —— Caddy 自动 HTTPS（HTTP-01 / TLS-ALPN-01），不需要插件和 Token。【推荐】
  2) dns  —— acme.sh + Cloudflare API 走 DNS-01，适合 80/443 被封或需要泛域名。
  3) off  —— 只生成配置，不申请证书。

EOT
  local m=""
  ask m "请选择证书方式 [auto/dns/off]" "$ACME_MODE"
  case "$m" in auto|dns|off) ACME_MODE="$m" ;; *) warn "无效输入，回退 auto"; ACME_MODE="auto" ;; esac

  if [[ "$ACME_MODE" == "dns" ]]; then
    ask_secret CF_API_TOKEN "Cloudflare API Token（Zone:DNS:Edit 权限）" "$CF_API_TOKEN"
    [[ -z "$CF_API_TOKEN" ]] && { warn "未提供 Token，回退为 auto"; ACME_MODE="auto"; }
  fi
  if [[ "$ACME_MODE" == "auto" ]]; then
    local ocf="" d="n"
    [[ "$CF_PROXIED" == "true" ]] && d="y"
    ask ocf "这三个域名的 A 记录是否走了 Cloudflare 橙云代理？(y/n)" "$d"
    [[ "$ocf" =~ ^[Yy] ]] && CF_PROXIED="true" || CF_PROXIED="false"
  fi

  sub "回传通道的连接方式"
  cat <<'EOT'

  1) direct —— 在【本机】跑 frps，Mac mini 主动连过来并把自己的 SSH 注册上来。【推荐】
                Mac mini 不需要公网 IP，也不需要任何第三方服务器中转。
                回传时本机直接连 127.0.0.1:<远程端口>。
  2) relay  —— 本机做客户端（frpc/hysteria2），连到另一台中转服务器的 frps。
                只有在 Mac mini 连不上本机、或想额外加一个国内加速入口时才用。
  3) none   —— 暂不配置连通层，之后随时可以 reconfigure。

EOT
  local tm=""
  ask tm "请选择 [direct/relay/none]" "$TUNNEL_MODE"
  case "$tm" in
    direct|relay|none) TUNNEL_MODE="$tm" ;;
    *) warn "无效输入，回退 direct"; TUNNEL_MODE="direct" ;;
  esac

  if [[ "$TUNNEL_MODE" == "direct" ]]; then
    ask_port FRPS_PORT "本机 frps 监听端口（Mac mini 连它，需公网可达）" "$FRPS_PORT"
    [[ -z "$FRP_TOKEN" ]] && { FRP_TOKEN="$(rand_secret 32)"; ok "已自动生成 frp token"; }
    ask_secret FRP_TOKEN "frp token（Mac mini 侧要填同一个）" "$FRP_TOKEN"
    echo
    say "Mac mini 的 SSH 会出现在本机 127.0.0.1:<远程端口>（只绑本机，不会暴露到公网）。"
    say "安全组/防火墙记得放行 TCP $FRPS_PORT。"

  elif [[ "$TUNNEL_MODE" == "relay" ]]; then
    ask CN_HOST "中转服务器公网 IP 或域名（输入 - 表示暂不配置）" "${CN_HOST:--}" 1
    if [[ -z "$CN_HOST" || "$CN_HOST" == "-" ]]; then
      CN_HOST=""
      warn "已跳过 relay 配置：稍后可在 $CONF 填好 CN_HOST 后执行  ./nas-n.sh reconfigure"
    else
      ask_port FRPS_PORT "中转机 frps 服务端口" "$FRPS_PORT"
      ask_secret FRP_TOKEN "frp token（必须与中转机 frps 一致）" "$FRP_TOKEN"
      local pr=""
      ask pr "frpc 连接协议 [tcp/quic]" "$FRP_PROTOCOL"
      case "$pr" in tcp|quic) FRP_PROTOCOL="$pr" ;; *) FRP_PROTOCOL="tcp" ;; esac
      echo
      say "以下是本机服务在中转机上要占用的「远程端口」（中转机需放行）："
      ask_port FRP_REMOTE_OPENLIST "OpenList    -> 中转机远程端口" "$FRP_REMOTE_OPENLIST"
      ask_port FRP_REMOTE_QB       "qBittorrent -> 中转机远程端口" "$FRP_REMOTE_QB"
      ask_port FRP_REMOTE_ARIA     "AriaNg      -> 中转机远程端口" "$FRP_REMOTE_ARIA"
      local v=""
      ask v "让 frpc 也走 hysteria2 的 SOCKS5 加速吗？(y/n)" "$FRP_VIA_HY2"
      [[ "$v" =~ ^[Yy] || "$v" == "true" ]] && FRP_VIA_HY2="true" || FRP_VIA_HY2="false"

      sub "hysteria2 客户端（跨境高速通道）"
      local en=""
      ask en "启用 hysteria2 加速吗？(y/n)" "$HY2_ENABLE"
      if [[ "$en" =~ ^[Nn] || "$en" == "false" ]]; then
        HY2_ENABLE="false"
        warn "已禁用 hysteria2：回传将直连中转机端口"
      else
        HY2_ENABLE="true"
        ask_port HY2_SERVER_PORT "中转机 hysteria2 监听端口(UDP)" "$HY2_SERVER_PORT"
        ask_secret HY2_AUTH "hysteria2 认证密码(auth)" "$HY2_AUTH"
        [[ -z "$HY2_AUTH" ]] && die "启用 hysteria2 时必须提供 auth 密码"
        ask HY2_SNI "hysteria2 TLS SNI（填中转机域名，或回车用上面的地址）" "${HY2_SNI:-$CN_HOST}"
        ask_secret HY2_OBFS_PASS "Salamander 混淆密码（没开就留空）" "$HY2_OBFS_PASS"
        ask HY2_UP_MBPS   "本机上行带宽 Mbps（留空=用 BBR）" "$HY2_UP_MBPS" 1
        ask HY2_DOWN_MBPS "本机下行带宽 Mbps（留空=用 BBR）" "$HY2_DOWN_MBPS" 1
      fi
    fi
  fi

  sub "Mac mini 回传通道与目录映射"
  ask MACMINI_SSH_USER "Mac mini 上的 SSH 用户名" "$MACMINI_SSH_USER"
  if [[ "$TUNNEL_MODE" == "direct" ]]; then
    ask_port MACMINI_SSH_REMOTE_PORT "Mac mini 的 SSH 在本机占用的端口（Mac mini 侧 frpc 的 remotePort）" "$MACMINI_SSH_REMOTE_PORT"
  else
    ask_port MACMINI_SSH_REMOTE_PORT "Mac mini 的 SSH 在中转机占用的远程端口（Mac mini 侧 frpc 用）" "$MACMINI_SSH_REMOTE_PORT"
    ask_port MACMINI_SSH_PORT "本机本地转发监听端口（hy2 把上面的远程端口映射到本机这个端口）" "$MACMINI_SSH_PORT"
  fi
  echo
  say "目录映射格式：\"本机目录:Mac mini 目录;本机目录:Mac mini 目录\""
  say "本机默认下载目录："
  say "    $DL_TORRENT_DIR   （qBittorrent）"
  say "    $DL_ARIA_DIR      （aria2）"
  ask_map TRANSFER_MAP "目录映射" "$TRANSFER_MAP"
  echo
  local eng="" par="" ver=""
  ask eng "回传引擎 [rclone/rsync]" "$TRANSFER_ENGINE"
  case "$eng" in rclone|rsync) TRANSFER_ENGINE="$eng" ;; *) TRANSFER_ENGINE="rclone" ;; esac
  ask_int TRANSFER_PARALLEL "回传并发数（越大越快，也更吃 CPU/带宽）" "$TRANSFER_PARALLEL" 1 32
  ask ver "回传校验方式 [size/hash/none]" "$TRANSFER_VERIFY"
  case "$ver" in size|hash|none) TRANSFER_VERIFY="$ver" ;; *) TRANSFER_VERIFY="size" ;; esac
  ask_int RETENTION_HOURS "回传成功后本机文件保留小时数（到期自动删除）" "$RETENTION_HOURS" 0 8760

  sub "其它"
  ask TZ "时区" "$TZ"
  ask_secret HEALTH_WEBHOOK "健康告警 Webhook（可选，ntfy/钉钉/企业微信机器人 URL）" "$HEALTH_WEBHOOK"
}

conf_save() {
  mkdir -p /etc/nas-n "$STATE/logs"; chmod 700 /etc/nas-n 2>/dev/null || true
  : >"$CONF"; chmod 600 "$CONF"
  local kv
  for kv in \
    "NASN_VERSION=$VERSION" "TZ=$TZ" "APP=$APP" "DATA=$DATA" "STATE=$STATE" \
    "DL_ROOT=$DL_ROOT" "DL_TORRENT_DIR=$DL_TORRENT_DIR" "DL_ARIA_DIR=$DL_ARIA_DIR" \
    "DL_INCOMPLETE_DIR=$DL_INCOMPLETE_DIR" \
    "OPENLIST_PORT=$OPENLIST_PORT" "QB_WEBUI_PORT=$QB_WEBUI_PORT" "QB_BT_PORT=$QB_BT_PORT" \
    "TRACKER_BT_PORT=$TRACKER_BT_PORT" "ARIA2_RPC_PORT=$ARIA2_RPC_PORT" "ARIANG_PORT=$ARIANG_PORT" \
    "OPENLIST_USER=$OPENLIST_USER" "OPENLIST_PASS=$OPENLIST_PASS" \
    "QB_USER=$QB_USER" "QB_PASS=$QB_PASS" "ARIA2_RPC_SECRET=$ARIA2_RPC_SECRET" \
    "CF_BASE_DOMAIN=$CF_BASE_DOMAIN" "CF_API_TOKEN=$CF_API_TOKEN" "CF_PROXIED=$CF_PROXIED" \
    "ACME_MODE=$ACME_MODE" "CADDY_MODE=$CADDY_MODE" \
    "DOMAIN_OPENLIST=$DOMAIN_OPENLIST" "DOMAIN_QB=$DOMAIN_QB" "DOMAIN_ARIA=$DOMAIN_ARIA" \
    "TUNNEL_MODE=$TUNNEL_MODE" \
    "CN_HOST=$CN_HOST" "FRPS_PORT=$FRPS_PORT" "FRP_TOKEN=$FRP_TOKEN" \
    "FRP_PROTOCOL=$FRP_PROTOCOL" "FRP_VIA_HY2=$FRP_VIA_HY2" \
    "FRP_REMOTE_OPENLIST=$FRP_REMOTE_OPENLIST" "FRP_REMOTE_QB=$FRP_REMOTE_QB" "FRP_REMOTE_ARIA=$FRP_REMOTE_ARIA" \
    "HY2_ENABLE=$HY2_ENABLE" "HY2_SERVER_PORT=$HY2_SERVER_PORT" "HY2_AUTH=$HY2_AUTH" \
    "HY2_SNI=$HY2_SNI" "HY2_OBFS_PASS=$HY2_OBFS_PASS" "HY2_UP_MBPS=$HY2_UP_MBPS" \
    "HY2_DOWN_MBPS=$HY2_DOWN_MBPS" "HY2_SOCKS_PORT=$HY2_SOCKS_PORT" \
    "MACMINI_SSH_HOST=$MACMINI_SSH_HOST" "MACMINI_SSH_PORT=$MACMINI_SSH_PORT" \
    "MACMINI_SSH_REMOTE_PORT=$MACMINI_SSH_REMOTE_PORT" "MACMINI_SSH_USER=$MACMINI_SSH_USER" \
    "MACMINI_SSH_KEY=$MACMINI_SSH_KEY" \
    "TRANSFER_ENGINE=$TRANSFER_ENGINE" "TRANSFER_MAP=$TRANSFER_MAP" \
    "TRANSFER_STABLE_SEC=$TRANSFER_STABLE_SEC" "TRANSFER_PARALLEL=$TRANSFER_PARALLEL" \
    "TRANSFER_VERIFY=$TRANSFER_VERIFY" "RETENTION_HOURS=$RETENTION_HOURS" \
    "HEALTH_WEBHOOK=$HEALTH_WEBHOOK" ; do
    conf_set "$CONF" "${kv%%=*}" "${kv#*=}"
  done
  ok "配置已写入 $CONF（权限 600）"
}

conf_show() {
  title "配置摘要"
  cat <<EOT
  下载目录      : $DL_ROOT
    qBittorrent : $DL_TORRENT_DIR
    aria2       : $DL_ARIA_DIR
  本机端口      : OpenList $OPENLIST_PORT / qB WebUI $QB_WEBUI_PORT / qB BT $QB_BT_PORT
                  aria2 RPC $ARIA2_RPC_PORT / AriaNg $ARIANG_PORT
  域名          : $DOMAIN_OPENLIST
                  $DOMAIN_QB
                  $DOMAIN_ARIA
  证书方式      : $ACME_MODE
  国内中转机    : ${CN_HOST:-<未配置>}${CN_HOST:+:$FRPS_PORT（frp）}
  hysteria2     : $HY2_ENABLE$([[ "$HY2_ENABLE" == "true" ]] && printf '  本地转发 127.0.0.1:%s -> 中转机:%s' "$MACMINI_SSH_PORT" "$MACMINI_SSH_REMOTE_PORT")
  Mac mini SSH  : $MACMINI_SSH_USER@$MACMINI_SSH_HOST:$MACMINI_SSH_PORT
  目录映射      : $TRANSFER_MAP
  回传引擎      : $TRANSFER_ENGINE（并发 $TRANSFER_PARALLEL，校验 $TRANSFER_VERIFY）
  本地保留      : $RETENTION_HOURS 小时
EOT
}

#───────────────────────────────────────────────────────────────────────────────
# 3. 预检
#───────────────────────────────────────────────────────────────────────────────
preflight_env() {
  title "预检：系统环境"
  [[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux（国外下载服务器）"
  local a; a="$(arch)"
  [[ "$a" == "unknown" ]] && die "不支持的 CPU 架构：$(uname -m)"
  ok "系统：$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" )  架构：$a"
  [[ -d /run/systemd/system ]] || die "未检测到 systemd"
  ok "systemd 可用"

  local ip; ip="$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] && ok "本机公网 IPv4：$ip" || warn "未探测到公网 IPv4"

  local free_mb; free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  if [[ -n "$free_mb" && "$free_mb" -lt 5120 ]]; then
    warn "根分区可用空间仅 ${free_mb}MB（<5GB），大文件下载回传可能失败"
  else
    ok "根分区可用空间：$(( ${free_mb:-0} / 1024 ))GB"
  fi
}

preflight_deps() {
  title "预检：基础依赖"
  local missing=()
  have curl    || missing+=(curl);    have tar  || missing+=(tar)
  have gzip    || missing+=(gzip);    have openssl || missing+=(openssl)
  have unzip   || missing+=(unzip);   have rsync || missing+=(rsync)
  have ss      || missing+=(iproute2); have python3 || missing+=(python3)
  if [[ ${#missing[@]} -gt 0 ]]; then say "安装缺失依赖：${missing[*]}"; pkg_install "${missing[@]}"; fi
  local still=()
  for c in curl tar gzip openssl unzip ss; do have "$c" || still+=("$c"); done
  [[ ${#still[@]} -eq 0 ]] || die "以下依赖仍不可用：${still[*]}"
  ok "基础依赖齐全"
}

preflight_ports() {
  title "预检：端口占用"
  local -a checks=(
    "OpenList|$OPENLIST_PORT" "qBittorrent WebUI|$QB_WEBUI_PORT"
    "qBittorrent BT|$QB_BT_PORT" "aria2 RPC|$ARIA2_RPC_PORT" "AriaNg|$ARIANG_PORT"
  )
  [[ "$TUNNEL_MODE" == "direct" ]] && checks+=("frps(本机服务端)|$FRPS_PORT")
  [[ "$TUNNEL_MODE" == "relay" && "$HY2_ENABLE" == "true" ]] && checks+=("hysteria2 SOCKS5|$HY2_SOCKS_PORT" "hysteria2 本地转发|$MACMINI_SSH_PORT")

  local item name port owner conflict=0
  for item in "${checks[@]}"; do
    name="${item%%|*}"; port="${item##*|}"
    if port_in_use "$port"; then
      owner="$(port_owner "$port")"
      if is_own_service "$owner" || port_owned_by_nasn "$port"; then
        ok "$name 端口 $port 已被本项目组件占用（预期）"
      else
        warn "$name 端口 $port 已被占用：${owner:-（无法识别占用进程）}"; conflict=1
      fi
    else
      ok "$name 端口 $port 空闲"
    fi
  done
  if [[ $conflict -eq 1 ]]; then
    warn "检测到疑似端口冲突，相关服务可能无法启动"
    if [[ "$ASSUME_YES" == "1" ]]; then
      warn "--yes 模式：继续执行，稍后请用 ./nas-n.sh status 核对"
    else
      confirm "是否仍要继续？" n || die "已被用户中止"
    fi
  fi
}

preflight_report() {
  title "本机现状快照"
  local s
  for s in caddy docker openlist; do
    if have "$s"; then ok "$s 已安装：$(command -v "$s")"; else say "$s 未安装（安装阶段将补齐）"; fi
  done
  if have caddy; then
    [[ -f /etc/caddy/Caddyfile ]] && { say "现有 Caddyfile 站点块："; grep -nE '^[^[:space:]#]+.*\{' /etc/caddy/Caddyfile 2>/dev/null | sed 's/^/    /' || true; }
    if caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
      ok "Caddy 自带 Cloudflare DNS 插件"
    else
      warn "Caddy 缺少 Cloudflare DNS 插件 → 证书默认走 HTTP-01 自动签发（无需插件）"
    fi
  fi
  [[ -f "$CONF" ]] && ok "检测到既有配置 $CONF（重跑会复用）"
  port_in_use 80  && ok "80 端口已被占用（Caddy 在跑，符合预期）" || warn "80 端口空闲"
  port_in_use 443 && ok "443 端口已被占用（Caddy 在跑，符合预期）" || warn "443 端口空闲"
}

#───────────────────────────────────────────────────────────────────────────────
# 4. Docker
#───────────────────────────────────────────────────────────────────────────────
compose() {
  docker compose -p nas-n --env-file "$APP/config/compose.env" -f "$APP/config/docker-compose.yml" "$@"
}

install_docker() {
  title "安装 Docker Engine"
  if have docker && docker compose version >/dev/null 2>&1; then
    ok "Docker 已就绪：$(docker --version 2>/dev/null)"; docker_tune; return 0
  fi

  if have apt-get; then
    local id codename a
    id="$(. /etc/os-release && echo "${ID:-debian}")"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    a="$(dpkg --print-architecture 2>/dev/null || arch)"
    if [[ ( "$id" == "debian" || "$id" == "ubuntu" ) && -n "$codename" ]]; then
      say "配置 Docker 官方 APT 源（$id/$codename/$a）"
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$id/gpg" -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$id
Suites: $codename
Components: stable
Architectures: $a
Signed-By: /etc/apt/keyrings/docker.asc
EOF
      DEBIAN_FRONTEND=noninteractive apt-get update -qq
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      local t; t="$(mktemp)"; http_download https://get.docker.com "$t"; sh "$t"; rm -f "$t"
    fi
  else
    local t; t="$(mktemp)"; http_download https://get.docker.com "$t"; sh "$t"; rm -f "$t"
  fi

  svc_enable docker; systemctl start docker >/dev/null 2>&1 || true
  have docker && docker compose version >/dev/null 2>&1 || die "Docker 安装失败，请手动安装后重试"
  ok "Docker 安装完成：$(docker --version 2>/dev/null)"
  docker_tune
}

docker_tune() {
  local f=/etc/docker/daemon.json
  if [[ -f "$f" ]]; then
    [[ -f "$f.nasn.suggest" ]] || cp -f "$f" "$f.nasn.suggest" 2>/dev/null || true
    say "已存在 $f，为安全起见不覆盖（建议配置见 $f.nasn.suggest）"
    return 0
  fi
  mkdir -p /etc/docker
  write_file "$f" 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
  ok "已写入 $f"; systemctl restart docker >/dev/null 2>&1 || true
}

#───────────────────────────────────────────────────────────────────────────────
# 5. 下载器（qBittorrent / aria2 / AriaNg）
#───────────────────────────────────────────────────────────────────────────────
QB_CT=nas-n-qbittorrent
ARIA2_CT=nas-n-aria2
ARIANG_CT=nas-n-ariang

gen_compose() {
  mkdir -p "$APP/config" "$DATA/docker/qbittorrent" "$DATA/docker/aria2" \
           "$DATA/docker/ariang" "$DATA/trigger" "$APP/hooks" "$DL_TORRENT_DIR" "$DL_ARIA_DIR" "$DL_INCOMPLETE_DIR"
  chmod 755 "$DATA/trigger"

  write_file "$APP/config/docker-compose.yml" 0644 < <(emit compose)
  write_file "$APP/config/compose.env" 0600 < <(emit compose_env)
  ok "已生成 compose 文件"
}

gen_hook() {
  write_file "$APP/hooks/trigger.sh" 0755 < <(emit trigger)
  chmod 0755 "$APP/hooks/trigger.sh"
  ok "已生成容器内钩子 $APP/hooks/trigger.sh"
}

qb_base() { printf 'http://127.0.0.1:%s' "$QB_WEBUI_PORT"; }

# 登录成功判定：
#   qBittorrent <=4.x 返回 200 + 正文 "Ok."
#   qBittorrent 5.x   返回 204 + Set-Cookie（正文为空）
# 所以统一以「cookie jar 里拿到会话 cookie」为准，兼容两代。
qb_login() {
  local jar="$1" user="$2" pass="$3"
  rm -f "$jar"
  curl -sS --max-time 15 -c "$jar" \
    -H "Referer: $(qb_base)/" -H "Origin: $(qb_base)" \
    --data-urlencode "username=$user" --data-urlencode "password=$pass" \
    "$(qb_base)/api/v2/auth/login" >/dev/null 2>&1 || true
  [[ -s "$jar" ]] && grep -q 'QBT_SID' "$jar" 2>/dev/null
}

qb_pbkdf2() {
  have python3 || return 1
  python3 - "$1" <<'PY'
import base64, hashlib, os, sys
pw = sys.argv[1].encode()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', pw, salt, 100000, 64)
print('@ByteArray(%s:%s)' % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
PY
}

qb_preseed() {
  local dir conf
  dir="$DATA/docker/qbittorrent/qBittorrent"; conf="$dir/qBittorrent.conf"
  [[ -f "$conf" && "$RECONFIGURE" != "1" ]] && { ok "qBittorrent 配置已存在，跳过预置"; return 0; }
  local hash
  if ! hash="$(qb_pbkdf2 "$QB_PASS")"; then
    warn "缺少 python3，无法预置口令；将改用容器日志里的临时密码"; return 0
  fi
  mkdir -p "$dir"
  write_file "$conf" 0664 <<EOF
[LegalNotice]
Accepted=true

[BitTorrent]
Session\\DefaultSavePath=/downloads/torrents
Session\\TempPath=/downloads/incomplete
Session\\TempPathEnabled=true
Session\\Port=$QB_BT_PORT
Session\\AnonymousModeEnabled=false
Session\\QueueingSystemEnabled=true
Session\\MaxActiveDownloads=5
Session\\MaxActiveTorrents=8
Session\\MaxActiveUploads=5
Session\\IgnoreSlowTorrentsForQueueing=true
Session\\GlobalMaxSeedingMinutes=-1
Session\\GlobalMaxRatio=-1
Session\\BTProtocol=0
Session\\Encryption=0
Session\\LSDEnabled=true
Session\\DHTEnabled=true
Session\\PeXEnabled=true
Session\\uTPEnabled=true
Session\\uTPMixedMode=1
Session\\DiskCache=256
Session\\DiskCacheTTL=60
Session\\DiskIOType=0
Session\\SendBufferWatermark=4096
Session\\SendBufferLowWatermark=1024
Session\\SendBufferWatermarkFactor=200
Session\\AsyncIOThreadsCount=4
Session\\HashingThreadsCount=2
Session\\FilePoolSize=100
Session\\CheckingMemUsage=32
Session\\ConnectionSpeed=200
Session\\AnnounceToAllTrackers=true
Session\\AnnounceToAllTiers=true
Session\\Preallocation=false
Session\\StartPausedEnabled=false

[Preferences]
WebUI\\Username=$QB_USER
WebUI\\Password_PBKDF2="$hash"
WebUI\\Port=$QB_WEBUI_PORT
WebUI\\Address=*
WebUI\\LocalHostAuth=false
WebUI\\CSRFProtection=true
WebUI\\ClickjackingProtection=true
WebUI\\HostHeaderValidation=false
WebUI\\SecureCookie=false
WebUI\\UseUPnP=false
WebUI\\MaxAuthenticationFailCount=5
WebUI\\BanDuration=3600
WebUI\\SessionTimeout=3600
WebUI\\AlternativeUIEnabled=false
WebUI\\HTTPS\\Enabled=false
WebUI\\ReverseProxySupportEnabled=false

Downloads\\SavePath=/downloads/torrents
Downloads\\TempPathEnabled=true
Downloads\\TempPath=/downloads/incomplete
Downloads\\AppendExtension=true
Downloads\\UseUnwantedFolder=false
Downloads\\Preallocation=false

AutoRun\\enabled=true
AutoRun\\program=/nasn-hooks/trigger.sh

[AutoRun]
enabled=true
program=/nasn-hooks/trigger.sh
EOF
  ok "已预置 qBittorrent 配置（用户 $QB_USER）"
}

qb_configure() {
  sub "通过 API 写入 qBittorrent 偏好"
  local jar="$STATE/qb.cookies" pass="$QB_PASS"
  if ! qb_login "$jar" "$QB_USER" "$pass"; then
    warn "用配置口令登录失败，尝试容器日志里的临时密码"
    local tmp; tmp="$(docker logs "$QB_CT" 2>&1 | sed -n 's/.*temporary password is provided for this session: *//p' | tail -1)"
    if [[ -n "$tmp" ]] && qb_login "$jar" admin "$tmp"; then
      pass="$tmp"; ok "已用临时密码登录，将立即改为配置里的口令"
    else
      warn "qBittorrent 登录失败，跳过 API 配置"
      warn "请访问 https://$DOMAIN_QB 手动设置，或重跑： ./nas-n.sh reconfigure"
      return 0
    fi
  fi

  local json
  json="$(cat <<EOF
{
  "save_path": "/downloads/torrents",
  "temp_path_enabled": true,
  "temp_path": "/downloads/incomplete",
  "listen_port": $QB_BT_PORT,
  "web_ui_username": "$QB_USER",
  "web_ui_password": "$pass",
  "web_ui_host_header_validation_enabled": false,
  "web_ui_csrf_protection_enabled": true,
  "web_ui_clickjacking_protection_enabled": true,
  "web_ui_secure_cookie_enabled": false,
  "web_ui_reverse_proxy_enabled": false,
  "autorun_enabled": true,
  "autorun_program": "/nasn-hooks/trigger.sh",
  "autorun_on_torrent_added_enabled": false,
  "incomplete_files_ext": true,
  "preallocate_all": false,
  "queueing_enabled": true,
  "max_active_downloads": 5,
  "max_active_torrents": 8,
  "max_active_uploads": 5,
  "dont_count_slow_torrents": true,
  "max_ratio_enabled": false,
  "max_seeding_time_enabled": false,
  "dht": true, "pex": true, "lsd": true,
  "encryption": 0, "anonymous_mode": false, "upnp": false,
  "max_connec": 3000, "max_connec_per_torrent": 300,
  "max_uploads": 200, "max_uploads_per_torrent": 50,
  "dl_limit": 0, "up_limit": 0, "scheduler_enabled": false,
  "async_io_threads": 4, "hashing_threads": 2,
  "disk_cache": 256, "disk_cache_ttl": 60, "disk_io_type": 0,
  "checking_memory_use": 32, "file_pool_size": 100,
  "send_buffer_watermark": 4096, "send_buffer_low_watermark": 1024,
  "send_buffer_watermark_factor": 200, "connection_speed": 200,
  "bittorrent_protocol": 0,
  "announce_to_all_trackers": true, "announce_to_all_tiers": true,
  "recheck_completed_torrents": false, "torrent_content_layout": "Original",
  "add_stopped_enabled": false, "delete_torrent_content_files": false
}
EOF
)"
  curl -sS --max-time 30 -b "$jar" -c "$jar" \
    -H "Referer: $(qb_base)/" -H "Origin: $(qb_base)" \
    --data-urlencode "json=$json" "$(qb_base)/api/v2/app/setPreferences" >/dev/null 2>&1 || true
  rm -f "$jar"
  if qb_login "$STATE/qb.check" "$QB_USER" "$QB_PASS"; then
    ok "qBittorrent 偏好已写入，口令校验通过"; rm -f "$STATE/qb.check"
  else
    warn "偏好已提交，但口令校验未通过（可访问 https://$DOMAIN_QB 手动确认）"
  fi
}

aria2_hook() {
  sub "配置 aria2 完成钩子"
  local conf="$DATA/docker/aria2/aria2.conf" i
  for i in $(seq 1 15); do [[ -f "$conf" ]] && break; sleep 2; done
  if [[ ! -f "$conf" ]]; then
    warn "未找到 $conf（容器可能还没初始化完），稍后重跑： ./nas-n.sh install"
    return 0
  fi
  # 刻意移除 p3terx 默认的 on-download-stop（删除任务即删文件），避免误删资源
  sed -i '/^[[:space:]]*on-download-stop=/d' "$conf"
  sed -i '/^[[:space:]]*on-download-complete=/d' "$conf"
  sed -i '/^[[:space:]]*on-bt-download-complete=/d' "$conf"
  sed -i '/^[[:space:]]*# nas-n/d' "$conf"
  cat >>"$conf" <<'EOF'

# nas-n：下载完成后触发宿主机回传（勿删）
# 说明：已刻意移除 p3terx 默认的 on-download-stop（删任务即删文件），避免误删资源
on-download-complete=/nasn-hooks/trigger.sh
on-bt-download-complete=/nasn-hooks/trigger.sh
EOF
  docker restart "$ARIA2_CT" >/dev/null 2>&1 || true
  sleep 8

  if grep -q 'on-download-complete=/nasn-hooks/trigger.sh' "$conf"; then
    ok "aria2 完成钩子已配置并在重启后保持"
  else
    warn "aria2 容器启动时重写了 aria2.conf，钩子未保留"
    warn "不影响功能：每 5 分钟的兜底扫描照样会回传（延迟最多 5 分钟）"
  fi
}

deploy_downloaders() {
  title "部署下载器（qBittorrent / aria2 / AriaNg）"
  gen_compose
  gen_hook
  qb_preseed

  sub "拉取镜像并启动容器"
  compose pull --quiet 2>/dev/null || warn "部分镜像拉取失败，继续尝试启动"
  compose up -d --remove-orphans

  sub "等待服务就绪"
  local i code
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$(qb_base)/" 2>/dev/null || true)"
    code="${code:-000}"
    [[ "$code" != "000" ]] && { ok "qBittorrent WebUI 已响应（HTTP $code）"; break; }
    sleep 2
    [[ $i -eq 60 ]] && warn "qBittorrent WebUI 等待超时，检查： docker logs $QB_CT"
  done
  for i in $(seq 1 30); do port_in_use "$ARIA2_RPC_PORT" && { ok "aria2 RPC 已监听 $ARIA2_RPC_PORT"; break; }; sleep 2; done
  for i in $(seq 1 30); do port_in_use "$ARIANG_PORT" && { ok "AriaNg 已监听 $ARIANG_PORT"; break; }; sleep 2; done

  qb_configure
  aria2_hook

  local c st
  for c in "$QB_CT" "$ARIA2_CT" "$ARIANG_CT"; do
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
    [[ "$st" == running ]] && ok "$c 运行中" || warn "$c 状态：$st"
  done
}

#───────────────────────────────────────────────────────────────────────────────
# 6. OpenList
#───────────────────────────────────────────────────────────────────────────────
install_openlist() {
  title "安装 OpenList"
  local OL=/opt/openlist

  if [[ -x "$OL/openlist" && "$RECONFIGURE" != "1" ]]; then
    ok "OpenList 已安装，跳过下载"
  else
    local t; t="$(mktemp -d)"
    say "下载官方安装脚本 https://res.oplist.org/script/v4.sh"
    http_download "https://res.oplist.org/script/v4.sh" "$t/install-openlist-v4.sh" \
      || { rm -rf "$t"; die "无法下载 OpenList 官方脚本，请检查网络"; }
    # 官方脚本安装流程会问「是否使用 GitHub 代理」，这里用空行回答（不使用代理）
    say "执行官方脚本（安装到 /opt/openlist）"
    ( cd "$t" && printf '\n' | bash ./install-openlist-v4.sh install /opt ) \
      || { rm -rf "$t"; die "OpenList 官方脚本执行失败"; }
    rm -rf "$t"
    [[ -x "$OL/openlist" ]] || die "OpenList 安装失败：找不到 $OL/openlist"
    ok "OpenList 二进制安装完成"
  fi

  svc_enable openlist
  systemctl restart openlist >/dev/null 2>&1 || true
  sleep 3

  # 收紧监听地址：外部访问统一走 Caddy 的 HTTPS 与 frp
  local cfg="$OL/data/config.json"
  if [[ -f "$cfg" ]]; then
    local changed=0
    if have python3; then
      python3 - "$cfg" "$OPENLIST_PORT" <<'PY' && changed=1 || true
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
with open(path, encoding='utf-8') as f:
    data = json.load(f)
scheme = data.setdefault('scheme', {})
changed = False
if scheme.get('address') != '127.0.0.1':
    scheme['address'] = '127.0.0.1'; changed = True
if int(scheme.get('http_port') or 0) != port:
    scheme['http_port'] = port; changed = True
if changed:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
sys.exit(0 if changed else 10)
PY
    else
      sed -i 's/"address"[[:space:]]*:[[:space:]]*"[^"]*"/"address": "127.0.0.1"/' "$cfg"
      sed -i "s/\"http_port\"[[:space:]]*:[[:space:]]*[0-9]*/\"http_port\": $OPENLIST_PORT/" "$cfg"
      changed=1
    fi
    if [[ $changed -eq 1 ]]; then
      ok "已设置 OpenList 监听 127.0.0.1:$OPENLIST_PORT"
      systemctl restart openlist >/dev/null 2>&1 || true; sleep 3
    fi
  fi

  if ( cd "$OL" && ./openlist admin set "$OPENLIST_PASS" >/dev/null 2>&1 ); then
    ok "OpenList 管理员口令已设置（用户 $OPENLIST_USER）"
  else
    warn "OpenList 口令设置失败，请在 WebUI 手动修改"
  fi

  local i
  for i in $(seq 1 30); do port_in_use "$OPENLIST_PORT" && { ok "OpenList 已监听 $OPENLIST_PORT"; return 0; }; sleep 2; done
  warn "OpenList 端口 $OPENLIST_PORT 未监听，检查： systemctl status openlist"
}

#───────────────────────────────────────────────────────────────────────────────
# 7. 穿透（frpc + hysteria2）
#───────────────────────────────────────────────────────────────────────────────
FRP_VERSION="v0.71.0"
HY2_BASE="https://github.com/apernet/hysteria/releases/latest/download"

tune_sysctl() {
  sub "优化内核网络参数（QUIC 与大文件回传）"
  write_file /etc/sysctl.d/99-nas-n.conf 0644 <<'EOF'
# 由 nas-n 生成：为 hysteria2(QUIC) 与大文件跨境回传优化
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 2621440
net.core.wmem_default = 2621440
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_rmem = 4096 87380 26214400
net.ipv4.tcp_wmem = 4096 65536 26214400
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 131072
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || warn "部分内核参数未应用（不影响部署）"
  ok "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)  UDP 缓冲区上限：$(sysctl -n net.core.rmem_max 2>/dev/null || echo ?)"
}

install_frpc() {
  mkdir -p "$APP/bin"
  if [[ -x "$APP/bin/frpc" && "$RECONFIGURE" != "1" ]]; then
    ok "frpc 已存在（$FRP_VERSION）"; return 0
  fi
  local a t url; a="$(arch)"; t="$(mktemp -d)"
  url="https://github.com/fatedier/frp/releases/download/$FRP_VERSION/frp_${FRP_VERSION#v}_linux_$a.tar.gz"
  say "下载 frp $FRP_VERSION（$a）"
  http_download "$url" "$t/frp.tar.gz" || { rm -rf "$t"; die "frp 下载失败：$url"; }
  tar -xzf "$t/frp.tar.gz" -C "$t"
  install -m 0755 "$(find "$t" -name frpc -type f | head -1)" "$APP/bin/frpc"
  rm -rf "$t"; ok "frpc 安装完成"
}

# 本机作为 frp 服务端（直连模式），Mac mini 作为客户端连过来
install_frps() {
  mkdir -p "$APP/bin"
  if [[ -x "$APP/bin/frps" && "$RECONFIGURE" != "1" ]]; then
    ok "frps 已存在（$FRP_VERSION）"; return 0
  fi
  local a t url; a="$(arch)"; t="$(mktemp -d)"
  url="https://github.com/fatedier/frp/releases/download/$FRP_VERSION/frp_${FRP_VERSION#v}_linux_$a.tar.gz"
  say "下载 frp $FRP_VERSION（$a）"
  http_download "$url" "$t/frp.tar.gz" || { rm -rf "$t"; die "frp 下载失败：$url"; }
  tar -xzf "$t/frp.tar.gz" -C "$t"
  install -m 0755 "$(find "$t" -name frps -type f | head -1)" "$APP/bin/frps"
  # 顺手放一份 frpc，方便你复制到 Mac mini 用同版本客户端
  [[ -x "$APP/bin/frpc" ]] || install -m 0755 "$(find "$t" -name frpc -type f | head -1)" "$APP/bin/frpc"
  rm -rf "$t"; ok "frps 安装完成（同版本 frpc 也放在 $APP/bin/frpc，可拷到 Mac mini）"
}

install_hy2() {
  mkdir -p "$APP/bin"
  if [[ -x "$APP/bin/hysteria" && "$RECONFIGURE" != "1" ]]; then
    ok "hysteria2 已存在"; return 0
  fi
  local a; a="$(arch)"
  say "下载 hysteria2 客户端（$a）"
  http_download "$HY2_BASE/hysteria-linux-$a" "$APP/bin/hysteria" || die "hysteria2 下载失败"
  chmod 0755 "$APP/bin/hysteria"; ok "hysteria2 安装完成"
}

# 直连模式：本机是 frps 服务端
gen_frps_conf() {
  {
    cat <<EOF
# 由 nas-n.sh 自动生成（改配置请改 $CONF 后重跑 ./nas-n.sh reconfigure）
# 本机是 frp 服务端；Mac mini 是 frpc 客户端，主动连过来并注册自己的 SSH。
bindAddr = "0.0.0.0"
bindPort = $FRPS_PORT

auth.method = "token"
auth.token = "$FRP_TOKEN"

# ★ 远程端口只绑本机：Mac mini 的 SSH 只会出现在 127.0.0.1:$MACMINI_SSH_REMOTE_PORT，
#   不会暴露到公网。回传就走这个地址。
proxyBindAddr = "127.0.0.1"

# 只允许注册 Mac mini 这一个端口，避免被当成公共 frp 服务端滥用
allowPorts = [
  { start = $MACMINI_SSH_REMOTE_PORT, end = $MACMINI_SSH_REMOTE_PORT }
]

transport.tcpMux = true
transport.maxPoolCount = 20
userConnTimeout = 10

log.to = "$STATE/logs/frps.log"
log.level = "info"
log.maxDays = 7
EOF
  } | write_file /etc/nas-n/frps.toml 0600
  chmod 600 /etc/nas-n/frps.toml
  ok "已生成 /etc/nas-n/frps.toml"
}

gen_frpc_conf() {
  mkdir -p /etc/nas-n
  {
    cat <<EOF
# 由 nas-n.sh 自动生成（改配置请改 $CONF 后重跑 ./nas-n.sh reconfigure）
serverAddr = "$CN_HOST"
serverPort = $FRPS_PORT
auth.method = "token"
auth.token = "$FRP_TOKEN"

transport.protocol = "$FRP_PROTOCOL"
transport.tcpMux = true
transport.heartbeatInterval = 15
transport.heartbeatTimeout = 60
transport.dialServerTimeout = 10
EOF
    if [[ "$FRP_VIA_HY2" == "true" && "$HY2_ENABLE" == "true" ]]; then
      cat <<EOF

# 让 frpc 的连接也走 hysteria2 的 SOCKS5（跨境 UDP 加速）
transport.proxyURL = "socks5://127.0.0.1:$HY2_SOCKS_PORT"
EOF
    fi
    cat <<EOF

log.to = "$STATE/logs/frpc.log"
log.level = "info"
log.maxDays = 7

[[proxies]]
name = "nasn-openlist"
type = "tcp"
localIP = "127.0.0.1"
localPort = $OPENLIST_PORT
remotePort = $FRP_REMOTE_OPENLIST

[[proxies]]
name = "nasn-qbittorrent"
type = "tcp"
localIP = "127.0.0.1"
localPort = $QB_WEBUI_PORT
remotePort = $FRP_REMOTE_QB

[[proxies]]
name = "nasn-ariang"
type = "tcp"
localIP = "127.0.0.1"
localPort = $ARIANG_PORT
remotePort = $FRP_REMOTE_ARIA
EOF
  } | write_file "$FRPC_CONF" 0600
  chmod 600 "$FRPC_CONF"; ok "已生成 $FRPC_CONF"
}

gen_hy2_conf() {
  {
    cat <<EOF
# 由 nas-n.sh 自动生成（改配置请改 $CONF 后重跑 ./nas-n.sh reconfigure）
server: $CN_HOST:$HY2_SERVER_PORT
auth: $HY2_AUTH
tls:
  sni: $HY2_SNI
  insecure: false
EOF
    if [[ -n "$HY2_OBFS_PASS" ]]; then
      cat <<EOF
obfs:
  type: salamander
  salamander:
    password: $HY2_OBFS_PASS
EOF
    fi
    cat <<EOF
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 41943040
  maxConnReceiveWindow: 41943040
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
EOF
    if [[ -n "$HY2_UP_MBPS" || -n "$HY2_DOWN_MBPS" ]]; then
      echo "bandwidth:"
      [[ -n "$HY2_UP_MBPS" ]]   && echo "  up: ${HY2_UP_MBPS} mbps"
      [[ -n "$HY2_DOWN_MBPS" ]] && echo "  down: ${HY2_DOWN_MBPS} mbps"
    fi
    cat <<EOF
lazy: false
fastOpen: false

# 供 frpc 使用（FRP_VIA_HY2=true 时）
socks5:
  listen: 127.0.0.1:$HY2_SOCKS_PORT

# ★ 关键：把中转机上的 Mac mini SSH 远程端口，映射到本机 127.0.0.1:$MACMINI_SSH_PORT
#   remote 由【中转机】解析，所以 127.0.0.1:$MACMINI_SSH_REMOTE_PORT 命中的就是 frps 的远程端口
tcpForwarding:
  - listen: 127.0.0.1:$MACMINI_SSH_PORT
    remote: 127.0.0.1:$MACMINI_SSH_REMOTE_PORT
EOF
  } | write_file "$HY2_CONF" 0600
  chmod 600 "$HY2_CONF"; ok "已生成 $HY2_CONF"
}

gen_tunnel_units() {
  if [[ "$TUNNEL_MODE" == "direct" ]]; then
    write_file /etc/systemd/system/nas-n-frps.service 0644 < <(emit unit_frps)
    # 清掉可能残留的 relay 模式单元
    systemctl disable --now nas-n-frpc.service nas-n-hysteria.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/nas-n-frpc.service /etc/systemd/system/nas-n-hysteria.service
  else
    write_file /etc/systemd/system/nas-n-frpc.service 0644 < <(emit unit_frpc)
    systemctl disable --now nas-n-frps.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/nas-n-frps.service
    if [[ "$HY2_ENABLE" == "true" ]]; then
      write_file /etc/systemd/system/nas-n-hysteria.service 0644 < <(emit unit_hy2)
    else
      systemctl disable --now nas-n-hysteria.service >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/nas-n-hysteria.service
    fi
  fi
  svc_reload
}

deploy_tunnel() {
  title "配置回传通道（本机 <-> Mac mini）"

  if [[ "$TUNNEL_MODE" == "none" ]]; then
    warn "TUNNEL_MODE=none：跳过连通层"
    warn "之后想启用：改 $CONF 里的 TUNNEL_MODE 后执行  ./nas-n.sh reconfigure"
    return 0
  fi

  # ============================ 直连模式 ============================
  if [[ "$TUNNEL_MODE" == "direct" ]]; then
    say "直连模式：本机跑 frps，Mac mini 主动连过来注册 SSH（本机无需能主动访问 Mac mini）"
    tune_sysctl
    install_frps
    gen_frps_conf
    gen_tunnel_units
    svc_enable nas-n-frps.service
    systemctl restart nas-n-frps.service >/dev/null 2>&1 || true
    sleep 3

    sub "frps 状态"
    if svc_active nas-n-frps.service; then
      ok "frps 运行中：0.0.0.0:$FRPS_PORT（远程端口只绑 127.0.0.1，不暴露公网）"
    else
      warn "frps 未运行： journalctl -u nas-n-frps -n 50"
    fi

    if port_in_use "$MACMINI_SSH_REMOTE_PORT"; then
      ok "Mac mini SSH 已就绪：127.0.0.1:$MACMINI_SSH_REMOTE_PORT"
    else
      warn "端口 $MACMINI_SSH_REMOTE_PORT 尚未监听 —— Mac mini 侧 frpc 跑起来后才会出现"
      warn "Mac mini 要做什么，看： ./nas-n.sh macmini"
    fi

    echo
    warn "别忘了两件事："
    warn "  1) 云厂商安全组/本机防火墙放行 TCP $FRPS_PORT（Mac mini 要连它）"
    warn "  2) Mac mini 侧用 frpc 连 $(_public_ip):$FRPS_PORT，token="$FRP_TOKEN"，remotePort=$MACMINI_SSH_REMOTE_PORT"
    return 0
  fi

  # ============================ relay 模式 ============================
  if [[ -z "$CN_HOST" ]]; then
    warn "relay 模式但未配置中转服务器地址，跳过连通层"
    warn "填好 $CONF 里的 CN_HOST 后执行： ./nas-n.sh reconfigure"
    return 0
  fi

  tune_sysctl
  install_frpc
  gen_frpc_conf
  if [[ "$HY2_ENABLE" == "true" ]]; then install_hy2; gen_hy2_conf; fi
  gen_tunnel_units

  svc_enable nas-n-frpc.service; systemctl restart nas-n-frpc.service >/dev/null 2>&1 || true
  if [[ "$HY2_ENABLE" == "true" ]]; then
    svc_enable nas-n-hysteria.service; systemctl restart nas-n-hysteria.service >/dev/null 2>&1 || true
  fi
  sleep 4

  sub "穿透组件状态"
  if [[ "$HY2_ENABLE" == "true" ]]; then
    if svc_active nas-n-hysteria.service; then
      ok "hysteria2 客户端运行中"
      port_in_use "$MACMINI_SSH_PORT" \
        && ok "本地转发 127.0.0.1:$MACMINI_SSH_PORT 已监听（-> 中转机 $MACMINI_SSH_REMOTE_PORT）" \
        || warn "本地转发端口 $MACMINI_SSH_PORT 未监听： journalctl -u nas-n-hysteria -n 50"
    else
      warn "hysteria2 未运行： journalctl -u nas-n-hysteria -n 50"
    fi
  fi
  if svc_active nas-n-frpc.service; then
    ok "frpc 运行中（-> $CN_HOST:$FRPS_PORT）"
    if [[ -f "$STATE/logs/frpc.log" ]] && grep -qi 'login to server success\|start proxy success' "$STATE/logs/frpc.log"; then
      ok "frpc 已成功登录中转机"
    else
      warn "frpc 尚未确认登录成功（端口未放行 / token 不一致？）： tail -50 $STATE/logs/frpc.log"
    fi
  else
    warn "frpc 未运行： journalctl -u nas-n-frpc -n 50"
  fi
}

#───────────────────────────────────────────────────────────────────────────────
# 8. 域名与 HTTPS（Caddy）
#───────────────────────────────────────────────────────────────────────────────
CADDY_MAIN=/etc/caddy/Caddyfile
CADDY_SITE=/etc/caddy/conf.d/nas-n.caddy
CADDY_IMPORT='import /etc/caddy/conf.d/*.caddy'

ensure_caddy() {
  if have caddy; then ok "Caddy 已安装：$(caddy version 2>/dev/null)"; return 0; fi
  warn "未检测到 Caddy，尝试从官方仓库安装"
  have apt-get || die "未安装 Caddy 且非 Debian 系，请手动安装后重跑"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || die "Caddy 源密钥导入失败"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    >/etc/apt/sources.list.d/caddy-stable.list || die "Caddy 源写入失败"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy || die "Caddy 安装失败"
  ok "Caddy 安装完成"
}

acme_dns() {
  [[ "$ACME_MODE" == "dns" ]] || return 0
  sub "acme.sh + Cloudflare 申请证书（DNS-01）"
  [[ -n "$CF_API_TOKEN" ]] || die "ACME_MODE=dns 但未提供 CF_API_TOKEN"

  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    local t; t="$(mktemp)"; http_download https://get.acme.sh "$t" || die "acme.sh 下载失败"
    sh "$t" >/dev/null 2>&1 || die "acme.sh 安装失败"; rm -f "$t"; ok "acme.sh 安装完成"
  else
    ok "acme.sh 已安装"
  fi

  mkdir -p "$CERT_DIR"; chmod 750 "$CERT_DIR"
  local acme=/root/.acme.sh/acme.sh
  export CF_Token="$CF_API_TOKEN"

  say "签发证书（SAN: $DOMAIN_OPENLIST, $DOMAIN_QB, $DOMAIN_ARIA）"
  "$acme" --issue --dns dns_cf --keylength ec-256 \
      -d "$DOMAIN_OPENLIST" -d "$DOMAIN_QB" -d "$DOMAIN_ARIA" \
    || die "DNS-01 证书签发失败（检查 CF Token 权限与域名归属）"

  "$acme" --install-cert -d "$DOMAIN_OPENLIST" --ecc \
    --key-file "$CERT_DIR/privkey.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem" \
    --reloadcmd "systemctl reload caddy" >/dev/null || die "证书安装失败"
  chown -R root:caddy "$CERT_DIR" 2>/dev/null || true
  chmod 640 "$CERT_DIR/privkey.pem" "$CERT_DIR/fullchain.pem"
  ok "证书已安装到 $CERT_DIR（acme.sh 自动续期，续期后自动 reload caddy）"
}

deploy_web() {
  title "配置域名与 HTTPS"
  if [[ "$ACME_MODE" == "off" && "$CADDY_MODE" == "off" ]]; then
    warn "ACME_MODE 与 CADDY_MODE 均为 off，跳过"; return 0
  fi

  ensure_caddy
  acme_dns

  mkdir -p /etc/caddy/conf.d
  write_file "$CADDY_SITE" 0644 < <(emit caddy)
  if ! caddy validate --adapter caddyfile --config "$CADDY_SITE" >/dev/null 2>&1; then
    warn "站点配置语法错误："
    caddy validate --adapter caddyfile --config "$CADDY_SITE" 2>&1 | sed 's/^/    /' | head -20
    die "请检查域名配置"
  fi
  ok "已写入 $CADDY_SITE 并通过语法校验"

  if [[ "$CADDY_MODE" == "off" ]]; then
    warn "CADDY_MODE=off：未修改 $CADDY_MAIN"
  else
    touch "$CADDY_MAIN"
    if grep -qF "$CADDY_IMPORT" "$CADDY_MAIN"; then
      ok "主配置已包含 import 行，未做改动"
    else
      [[ -f "$CADDY_MAIN.nasn.bak" ]] || cp -a "$CADDY_MAIN" "$CADDY_MAIN.nasn.bak" 2>/dev/null || true
      {
        printf '\n# ===== nas-n 追加：加载本项目站点配置（删除本行即可停用） =====\n'
        printf '%s\n' "$CADDY_IMPORT"
      } >>"$CADDY_MAIN"
      ok "已在 $CADDY_MAIN 末尾追加 import 行（原有站点保持不变，备份： $CADDY_MAIN.nasn.bak）"
    fi
  fi

  if ! caddy validate --adapter caddyfile --config "$CADDY_MAIN" >/dev/null 2>&1; then
    warn "整体 Caddyfile 校验失败："
    caddy validate --adapter caddyfile --config "$CADDY_MAIN" 2>&1 | sed 's/^/    /' | head -20
    if [[ -f "$CADDY_MAIN.nasn.bak" ]]; then cp -f "$CADDY_MAIN.nasn.bak" "$CADDY_MAIN"; warn "已回滚 $CADDY_MAIN"; fi
    die "Caddy 配置校验失败，未执行 reload"
  fi
  if svc_active caddy; then
    systemctl reload caddy 2>/dev/null && ok "Caddy 已热加载" || { systemctl restart caddy && ok "Caddy 已重启"; }
  else
    svc_enable caddy; ok "Caddy 未运行，已启动"
  fi

  sub "HTTPS 验证"
  local d code ip
  for d in "$DOMAIN_OPENLIST" "$DOMAIN_QB" "$DOMAIN_ARIA"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$d:443:127.0.0.1" "https://$d/" 2>/dev/null || true)"
    code="${code:-000}"
    case "$code" in
      000) warn "$d 本地 HTTPS 未就绪（证书可能还在申请，等 30 秒再试）" ;;
      2*|3*|401|403) ok "$d HTTPS 正常（HTTP $code）" ;;
      *) warn "$d 返回 HTTP $code" ;;
    esac
  done
  say "DNS 解析检查（A 记录需指向本机公网 IP）："
  for d in "$DOMAIN_OPENLIST" "$DOMAIN_QB" "$DOMAIN_ARIA"; do
    ip="$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
    [[ -n "$ip" ]] && say "    $d -> $ip" || warn "    $d 未解析（请在 Cloudflare 添加 A 记录）"
  done
}

#───────────────────────────────────────────────────────────────────────────────
# 9. 回传与清理（生成 tools + systemd 单元）
#───────────────────────────────────────────────────────────────────────────────
install_engine() {
  case "$TRANSFER_ENGINE" in
    rclone)
      mkdir -p "$APP/bin"
      if [[ -x "$APP/bin/rclone" && "$RECONFIGURE" != "1" ]]; then
        ok "rclone 已存在"; return 0
      fi
      local a t; a="$(arch)"; t="$(mktemp -d)"
      say "下载 rclone（$a）"
      http_download "https://downloads.rclone.org/rclone-current-linux-$a.zip" "$t/rclone.zip" \
        || { rm -rf "$t"; die "rclone 下载失败（可在 $CONF 里改 TRANSFER_ENGINE=rsync 后重跑）"; }
      unzip -q -o "$t/rclone.zip" -d "$t"
      install -m 0755 "$(find "$t" -type f -name rclone | head -1)" "$APP/bin/rclone"
      rm -rf "$t"; ok "rclone 安装完成"
      ;;
    rsync)
      have rsync || pkg_install rsync
      have rsync || die "rsync 不可用"
      ok "rsync 就绪：$(rsync --version 2>/dev/null | head -1)"
      ;;
    *) die "未知的 TRANSFER_ENGINE：$TRANSFER_ENGINE（可选 rclone / rsync）" ;;
  esac
}

gen_ssh_key() {
  mkdir -p "$(dirname "$SSH_KEY")"; chmod 700 "$(dirname "$SSH_KEY")"
  if [[ -f "$SSH_KEY" ]]; then
    ok "SSH 密钥已存在：$SSH_KEY"
  else
    ssh-keygen -t ed25519 -N '' -C "nas-n@$(hostname)" -f "$SSH_KEY" >/dev/null
    chmod 600 "$SSH_KEY"; ok "已生成 SSH 密钥：$SSH_KEY"
  fi
}

gen_rclone_conf() {
  [[ "$TRANSFER_ENGINE" == "rclone" ]] || return 0
  write_file "$RCLONE_CONF" 0600 <<EOF
# 由 nas-n.sh 自动生成
# known_hosts_file = none：rclone 默认就不校验主机密钥，这里显式关闭以消除告警
# （想开启校验就改成 /etc/nas-n/ssh/known_hosts 并用 ssh-keyscan 填充）
[macmini]
type = sftp
host = $MACMINI_SSH_HOST
port = $MACMINI_SSH_PORT
user = $MACMINI_SSH_USER
key_file = $MACMINI_SSH_KEY
known_hosts_file = none

# macOS 的 shell 与校验命令
shell_type = unix
md5sum_command = md5 -r
sha1sum_command = shasum -a 1

# 高延迟链路提速关键：SFTP 单包载荷提到 255k（协议上限 256k）
chunk_size = 255k
concurrency = 128
EOF
  chmod 600 "$RCLONE_CONF"; ok "已生成 $RCLONE_CONF"
}

gen_tools() {
  mkdir -p "$APP/tools" "$STATE/queue" "$STATE/locks" "$STATE/logs" "$STATE/trigger"
  chmod 755 "$STATE/trigger"
  write_file "$APP/tools/transfer.sh"    0755 < <(emit transfer);    chmod 0755 "$APP/tools/transfer.sh"
  write_file "$APP/tools/cleanup.sh"     0755 < <(emit cleanup);     chmod 0755 "$APP/tools/cleanup.sh"
  write_file "$APP/tools/healthcheck.sh" 0755 < <(emit healthcheck); chmod 0755 "$APP/tools/healthcheck.sh"
  write_file "$APP/tools/trigger.sh"     0755 < <(emit trigger);     chmod 0755 "$APP/tools/trigger.sh"
  ok "已生成 $APP/tools/{transfer,cleanup,healthcheck,trigger}.sh"
}

gen_app_units() {
  write_file /etc/systemd/system/nas-n-transfer.service    0644 < <(emit unit_transfer)
  write_file /etc/systemd/system/nas-n-transfer.path       0644 < <(emit unit_transfer_path)
  write_file /etc/systemd/system/nas-n-transfer.timer      0644 < <(emit unit_transfer_timer)
  write_file /etc/systemd/system/nas-n-cleanup.service     0644 < <(emit unit_cleanup)
  write_file /etc/systemd/system/nas-n-cleanup.timer       0644 < <(emit unit_cleanup_timer)
  write_file /etc/systemd/system/nas-n-healthcheck.service 0644 < <(emit unit_health)
  write_file /etc/systemd/system/nas-n-healthcheck.timer   0644 < <(emit unit_health_timer)
  svc_reload
  svc_enable nas-n-transfer.path
  svc_enable nas-n-transfer.timer
  svc_enable nas-n-cleanup.timer
  svc_enable nas-n-healthcheck.timer
  ok "回传/清理/巡检 的 systemd 单元与定时器已启用"
}

verify_link() {
  sub "回传链路连通性测试"
  local target="$MACMINI_SSH_USER@$MACMINI_SSH_HOST"
  local opts=(-p "$MACMINI_SSH_PORT" -i "$MACMINI_SSH_KEY" -o BatchMode=yes
              -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o Compression=no)
  if have ssh; then
    if ssh "${opts[@]}" "$target" 'echo nas-n-ok' 2>/dev/null | grep -q nas-n-ok; then
      ok "SSH 连通 $target:$MACMINI_SSH_PORT"
    else
      warn "SSH 暂时连不上 $target:$MACMINI_SSH_PORT（Mac mini 还没接入时属正常）"
      if [[ "${TUNNEL_MODE:-direct}" == "direct" ]]; then
        warn "  1) 本机 frps 是否在跑： systemctl status nas-n-frps"
        warn "  2) Mac mini 的 frpc 是否已连上并注册 remotePort=$MACMINI_SSH_REMOTE_PORT"
        warn "  3) 安全组是否放行 TCP $FRPS_PORT"
        warn "  4) Mac mini 是否已加入本机公钥（安装完成时会打印）"
        warn "  完整步骤： ./nas-n.sh macmini"
      else
        warn "  1) 中转机 frps 是否在跑、是否放行 $MACMINI_SSH_REMOTE_PORT"
        warn "  2) Mac mini 的 frpc 是否已注册 remotePort=$MACMINI_SSH_REMOTE_PORT"
        warn "  3) Mac mini 是否已加入本机公钥（安装完成时会打印）"
      fi
    fi
  fi
  if [[ "$TRANSFER_ENGINE" == "rclone" && -x "$APP/bin/rclone" ]]; then
    if "$APP/bin/rclone" lsd "macmini:" --config "$RCLONE_CONF" --timeout 15s >/dev/null 2>&1; then
      ok "rclone 可通过 SFTP 访问 Mac mini"
    else
      warn "rclone 暂时连不上 Mac mini（同上）"
    fi
  fi
}

deploy_transfer() {
  title "配置高速回传（下载服务器 -> Mac mini）"
  install_engine
  gen_ssh_key
  gen_rclone_conf
  gen_tools
  gen_app_units
  verify_link
}

#───────────────────────────────────────────────────────────────────────────────
# 10. 内置生成物（--emit）
#───────────────────────────────────────────────────────────────────────────────
emit() {
  case "$1" in
  compose)
    cat <<'EOS'
# 由 nas-n.sh 生成。WebUI/RPC 只绑 127.0.0.1；BT/DHT 绑 0.0.0.0（否则没速度）。
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: nas-n-qbittorrent
    environment:
      - PUID=0
      - PGID=0
      - TZ=${TZ}
      - WEBUI_PORT=${QB_WEBUI_PORT}
      - TORRENTING_PORT=${QB_BT_PORT}
    volumes:
      - ${QB_CONFIG_DIR}:/config
      - ${DL_ROOT}:/downloads
      - ${NASN_HOOKS_DIR}:/nasn-hooks:ro
      - ${NASN_TRIGGER_DIR}:/nasn-trigger
    ports:
      - "127.0.0.1:${QB_WEBUI_PORT}:${QB_WEBUI_PORT}"
      - "${QB_BT_PORT}:${QB_BT_PORT}/tcp"
      - "${QB_BT_PORT}:${QB_BT_PORT}/udp"
    restart: unless-stopped
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

  aria2:
    image: p3terx/aria2-pro
    container_name: nas-n-aria2
    environment:
      - PUID=0
      - PGID=0
      - UMASK_SET=022
      - TZ=${TZ}
      - RPC_SECRET=${ARIA2_RPC_SECRET}
      - RPC_PORT=${ARIA2_RPC_PORT}
      - LISTEN_PORT=${TRACKER_BT_PORT}
      - DISK_CACHE=64M
      - IPV6_MODE=false
      - UPDATE_TRACKERS=true
    volumes:
      - ${ARIA2_CONFIG_DIR}:/config
      - ${DL_ROOT}:/downloads
      - ${NASN_HOOKS_DIR}:/nasn-hooks:ro
      - ${NASN_TRIGGER_DIR}:/nasn-trigger
    ports:
      - "127.0.0.1:${ARIA2_RPC_PORT}:${ARIA2_RPC_PORT}"
      - "${TRACKER_BT_PORT}:${TRACKER_BT_PORT}/tcp"
      - "${TRACKER_BT_PORT}:${TRACKER_BT_PORT}/udp"
    restart: unless-stopped
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }

  ariang:
    image: p3terx/ariang
    container_name: nas-n-ariang
    ports:
      - "127.0.0.1:${ARIANG_PORT}:6880"
    restart: unless-stopped
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
EOS
    ;;
  compose_env)
    cat <<EOS
# 由 nas-n.sh 生成，供 docker compose --env-file 使用
TZ=$TZ
DL_ROOT=$DL_ROOT
QB_WEBUI_PORT=$QB_WEBUI_PORT
QB_BT_PORT=$QB_BT_PORT
ARIA2_RPC_PORT=$ARIA2_RPC_PORT
ARIANG_PORT=$ARIANG_PORT
TRACKER_BT_PORT=$TRACKER_BT_PORT
ARIA2_RPC_SECRET=$ARIA2_RPC_SECRET
QB_CONFIG_DIR=$DATA/docker/qbittorrent
ARIA2_CONFIG_DIR=$DATA/docker/aria2
NASN_HOOKS_DIR=$APP/hooks
NASN_TRIGGER_DIR=$DATA/trigger
EOS
    ;;
  trigger)
    cat <<'EOS'
#!/bin/sh
# nas-n 下载完成触发器（在容器内部执行）
# qBittorrent 的 Run on torrent finished 与 aria2 的 on-download-complete 调用它。
# 它只在本机共享的触发目录里打个标记，宿主机的 systemd path 单元随即启动回传。
DIR=/nasn-trigger
[ -d "$DIR" ] || exit 0
: >"$DIR/$(date +%s).flag" 2>/dev/null || true
exit 0
EOS
    ;;
  caddy)
    {
      echo "# 由 nas-n.sh 生成，重跑脚本会覆盖本文件。"
      echo "# 如需改域名：改 $CONF 后执行  ./nas-n.sh reconfigure"
      echo
      if [[ "$ACME_MODE" == "dns" ]]; then
        printf '# OpenList\n%s {\n\tencode gzip\n\ttls %s/fullchain.pem %s/privkey.pem\n\treverse_proxy 127.0.0.1:%s\n}\n\n' \
          "$DOMAIN_OPENLIST" "$CERT_DIR" "$CERT_DIR" "$OPENLIST_PORT"
        printf '# qBittorrent WebUI\n%s {\n\tencode gzip\n\ttls %s/fullchain.pem %s/privkey.pem\n\treverse_proxy 127.0.0.1:%s\n}\n\n' \
          "$DOMAIN_QB" "$CERT_DIR" "$CERT_DIR" "$QB_WEBUI_PORT"
        printf '# AriaNg（同域 /jsonrpc 反代到 aria2 RPC）\n%s {\n\tencode gzip\n\ttls %s/fullchain.pem %s/privkey.pem\n\thandle /jsonrpc* {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n\thandle {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n}\n' \
          "$DOMAIN_ARIA" "$CERT_DIR" "$CERT_DIR" "$ARIA2_RPC_PORT" "$ARIANG_PORT"
      else
        printf '# OpenList\n%s {\n\tencode gzip\n\treverse_proxy 127.0.0.1:%s\n}\n\n' \
          "$DOMAIN_OPENLIST" "$OPENLIST_PORT"
        printf '# qBittorrent WebUI\n%s {\n\tencode gzip\n\treverse_proxy 127.0.0.1:%s\n}\n\n' \
          "$DOMAIN_QB" "$QB_WEBUI_PORT"
        printf '# AriaNg（同域 /jsonrpc 反代到 aria2 RPC，浏览器无需跨域）\n%s {\n\tencode gzip\n\thandle /jsonrpc* {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n\thandle {\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n}\n' \
          "$DOMAIN_ARIA" "$ARIA2_RPC_PORT" "$ARIANG_PORT"
      fi
    }
    ;;
  unit_hy2)
    cat <<'EOS'
[Unit]
Description=nas-n Hysteria2 client (cross-border acceleration to CN relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/nas-n/bin/hysteria client --config /etc/nas-n/hysteria-client.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOS
    ;;
  unit_frps)
    cat <<'EOS'
[Unit]
Description=nas-n frp server (Mac mini dials in to register its SSH)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/nas-n/bin/frps -c /etc/nas-n/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOS
    ;;
  unit_frpc)
    cat <<'EOS'
[Unit]
Description=nas-n frp client (publish WebUI ports to CN relay)
After=network-online.target nas-n-hysteria.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/nas-n/bin/frpc -c /etc/nas-n/frpc.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOS
    ;;
  unit_transfer)
    cat <<'EOS'
[Unit]
Description=nas-n transfer finished downloads to Mac mini
After=network-online.target nas-n-hysteria.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/nas-n/tools/transfer.sh
TimeoutStartSec=0
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=5
EOS
    ;;
  unit_transfer_path)
    cat <<'EOS'
[Unit]
Description=Watch nas-n trigger dir (download finished -> transfer)

[Path]
PathChanged=/var/lib/nas-n/trigger
MakeDirectory=yes
Unit=nas-n-transfer.service

[Install]
WantedBy=multi-user.target
EOS
    ;;
  unit_transfer_timer)
    cat <<'EOS'
[Unit]
Description=Periodic nas-n transfer sweep (safety net for missed hooks)

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=nas-n-transfer.service

[Install]
WantedBy=timers.target
EOS
    ;;
  unit_cleanup)
    cat <<'EOS'
[Unit]
Description=nas-n cleanup: delete local copies after retention window

[Service]
Type=oneshot
ExecStart=/opt/nas-n/tools/cleanup.sh
TimeoutStartSec=0
Nice=10
EOS
    ;;
  unit_cleanup_timer)
    cat <<'EOS'
[Unit]
Description=Hourly nas-n cleanup

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
AccuracySec=1min
Persistent=true
Unit=nas-n-cleanup.service

[Install]
WantedBy=timers.target
EOS
    ;;
  unit_health)
    cat <<'EOS'
[Unit]
Description=nas-n healthcheck (services, disk, queue backlog)

[Service]
Type=oneshot
ExecStart=/opt/nas-n/tools/healthcheck.sh
TimeoutStartSec=120
Nice=10
EOS
    ;;
  unit_health_timer)
    cat <<'EOS'
[Unit]
Description=Run nas-n healthcheck every 10 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
AccuracySec=1min
Unit=nas-n-healthcheck.service

[Install]
WantedBy=timers.target
EOS
    ;;
  transfer) emit_transfer ;;
  cleanup)  emit_cleanup ;;
  healthcheck) emit_healthcheck ;;
  *) die "未知的 --emit 目标：$1（可用：compose compose_env trigger caddy unit_hy2 unit_frpc unit_frps unit_transfer unit_transfer_path unit_transfer_timer unit_cleanup unit_cleanup_timer unit_health unit_health_timer transfer cleanup healthcheck）" ;;
  esac
}

#──────────────── ── 内置：回传引擎 ─────────────────────────────────────────────
emit_transfer() {
  cat <<'EOS'
#!/usr/bin/env bash
#═══════════════════════════════════════════════════════════════════════════════
# nas-n 回传引擎（由 nas-n.sh 生成）
#
# 扫描 TRANSFER_MAP 里配置的本机下载目录，把「已完成且已静默」的资源推到 Mac mini。
# 触发：容器钩子 -> /var/lib/nas-n/trigger -> systemd path 单元；另有 5 分钟定时兜底。
# 幂等：已回传的会在 /var/lib/nas-n/queue 留记录，不会重传。
#
# 用法： transfer.sh [--only <本机路径>] [--force]
#═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

CONF="${NASN_CONF:-/etc/nas-n/nas-n.conf}"
[[ -r "$CONF" ]] || { echo "缺少配置文件 $CONF" >&2; exit 1; }
set -a; . "$CONF"; set +a

STATE_DIR="${STATE:-/var/lib/nas-n}"
QUEUE_DIR="$STATE_DIR/queue"
LOCK_FILE="$STATE_DIR/locks/transfer.lock"
LOG_FILE="$STATE_DIR/logs/transfer.log"
TRIGGER_DIR="$STATE_DIR/trigger"
RCLONE_BIN="${APP:-/opt/nas-n}/bin/rclone"
RCLONE_CONF="/etc/nas-n/rclone.conf"

mkdir -p "$QUEUE_DIR" "$STATE_DIR/locks" "$STATE_DIR/logs" "$TRIGGER_DIR"

ONLY_PATH=""; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY_PATH="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) shift ;;
  esac
done

log_line() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
say() { printf '%s\n' "$*"; log_line "$*"; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then log_line "已有回传进程在运行，本次跳过"; exit 0; fi
find "$TRIGGER_DIR" -maxdepth 1 -type f -name '*.flag' -delete 2>/dev/null || true
say "===== 回传任务开始 ====="

job_file() { printf '%s/%s.job' "$QUEUE_DIR" "$(printf '%s' "$1" | md5sum | awk '{print $1}')"; }

job_is_done() {
  local f; f="$(job_file "$1")"
  [[ -f "$f" ]] || return 1
  [[ "$(sed -n "s/^status='\(.*\)'$/\1/p" "$f" | tail -1)" == "done" ]]
}

is_complete() {
  local p="$1" newest now
  # 未完成标志：qBittorrent 的 .!qB、aria2 的 .aria2、部分下载的 .part
  if find "$p" \( -name '*.!qB' -o -name '*.aria2' -o -name '*.part' -o -name '*.unwanted' \) \
       -print -quit 2>/dev/null | grep -q .; then
    return 1
  fi
  newest="$(find "$p" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
  [[ -n "$newest" ]] || return 1
  now="$(date +%s)"
  # %T@ 带亚秒精度，必须取整后再比较
  awk -v n="$newest" -v now="$now" -v s="${TRANSFER_STABLE_SEC:-120}" \
      'BEGIN{ exit !((now - int(n)) >= s) }'
}

transfer_item() {
  local src="$1" remote_base="$2" name dest rc=0
  name="$(basename "$src")"; dest="${remote_base%/}/$name"

  if job_is_done "$src" && [[ "$FORCE" -ne 1 ]]; then return 0; fi

  say "--> 开始回传：$name"
  say "    本机    ：$src"
  say "    Mac mini：$dest"

  if [[ "${TRANSFER_ENGINE:-rclone}" == "rclone" ]]; then
    [[ -x "$RCLONE_BIN" ]] || { say "    !! rclone 不存在：$RCLONE_BIN"; return 1; }
    "$RCLONE_BIN" copy "$src" "macmini:$dest" \
      --config "$RCLONE_CONF" \
      --transfers "${TRANSFER_PARALLEL:-4}" \
      --checkers "$(( ${TRANSFER_PARALLEL:-4} * 2 ))" \
      --sftp-concurrency 128 --sftp-chunk-size 255k --buffer-size 32M \
      --retries 5 --retries-sleep 10s --low-level-retries 20 \
      --timeout 5m --contimeout 30s \
      --exclude '*.!qB' --exclude '*.aria2' --exclude '*.unwanted/**' \
      --stats 15s --stats-one-line \
      --log-file "$LOG_FILE" --log-level INFO || rc=$?
    [[ $rc -ne 0 ]] && { say "    !! rclone 复制失败（退出码 $rc），保留本地文件稍后重试"; return 1; }

    case "${TRANSFER_VERIFY:-size}" in
      size) "$RCLONE_BIN" check "$src" "macmini:$dest" --config "$RCLONE_CONF" \
              --size-only --one-way --log-level ERROR >>"$LOG_FILE" 2>&1 \
              || { say "    !! 大小校验失败，视为未完成"; return 1; } ;;
      hash) "$RCLONE_BIN" check "$src" "macmini:$dest" --config "$RCLONE_CONF" \
              --one-way --log-level ERROR >>"$LOG_FILE" 2>&1 \
              || { say "    !! 哈希校验失败，视为未完成"; return 1; } ;;
      none) : ;;
    esac
    say "    校验通过（${TRANSFER_VERIFY:-size}）"

  else
    local ssh_cmd="ssh -p ${MACMINI_SSH_PORT} -i ${MACMINI_SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o Compression=no -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o IPQoS=throughput"
    rsync -a --partial --partial-dir=.rsync-partial --inplace --no-compress --mkpath \
      --info=progress2 --human-readable -e "$ssh_cmd" \
      "$src" "${MACMINI_SSH_USER}@${MACMINI_SSH_HOST}:${remote_base%/}/" >>"$LOG_FILE" 2>&1 \
      || { say "    !! rsync 失败，保留本地文件稍后重试"; return 1; }

    local diff_out
    diff_out="$(rsync -a -n --itemize-changes --no-compress --mkpath -e "$ssh_cmd" \
      "$src" "${MACMINI_SSH_USER}@${MACMINI_SSH_HOST}:${remote_base%/}/" 2>/dev/null \
      | grep -v '^\.d' || true)"
    [[ -n "$diff_out" ]] && { say "    !! rsync 校验发现差异，视为未完成"; return 1; }
    say "    校验通过（rsync dry-run 无差异）"
  fi

  local f now size
  f="$(job_file "$src")"; now="$(date +%s)"; size="$(du -sb "$src" 2>/dev/null | awk '{print $1}')"
  {
    printf 'path=%s\n'          "'${src//\'/\'\\\'\'}'"
    printf 'remote=%s\n'        "'${dest//\'/\'\\\'\'}'"
    printf 'engine=%s\n'        "'${TRANSFER_ENGINE:-rclone}'"
    printf 'bytes=%s\n'         "'${size:-0}'"
    printf 'status=%s\n'        "'done'"
    printf 'finished_at=%s\n'   "'$now'"
    printf 'transferred_at=%s\n' "'$now'"
  } >"$f"
  chmod 600 "$f"
  say "    回传完成，${RETENTION_HOURS:-24} 小时后自动清理本机副本"
  return 0
}

TOTAL=0; DONE=0; FAILED=0
entry=""; ldir=""; rdir=""; item=""

if [[ -n "$ONLY_PATH" ]]; then
  IFS=';' read -r -a ENTRIES <<<"${TRANSFER_MAP:-}"
  matched=0
  for entry in "${ENTRIES[@]}"; do
    [[ -n "$entry" ]] || continue
    ldir="${entry%%:*}"; rdir="${entry#*:}"
    [[ "$ldir" == "$entry" ]] && continue
    case "$ONLY_PATH" in
      "$ldir"|"$ldir"/*) matched=1; TOTAL=1
        if transfer_item "$ONLY_PATH" "$rdir"; then DONE=1; else FAILED=1; fi ;;
    esac
  done
  [[ $matched -eq 1 ]] || say "!! 路径 $ONLY_PATH 不在 TRANSFER_MAP 覆盖范围内"
else
  IFS=';' read -r -a ENTRIES <<<"${TRANSFER_MAP:-}"
  [[ -z "${TRANSFER_MAP:-}" ]] && say "!! TRANSFER_MAP 为空，未配置任何目录映射"

  for entry in "${ENTRIES[@]}"; do
    [[ -n "$entry" ]] || continue
    ldir="${entry%%:*}"; rdir="${entry#*:}"
    if [[ "$ldir" == "$entry" ]]; then say "!! 映射格式错误（应为 本机目录:Mac mini目录）：$entry"; continue; fi
    [[ -d "$ldir" ]] || { say "!! 本机目录不存在：$ldir"; continue; }

    shopt -s nullglob dotglob
    local_items=("$ldir"/*)
    shopt -u nullglob dotglob

    for item in "${local_items[@]}"; do
      [[ -e "$item" ]] || continue
      [[ "$(basename "$item")" == .* ]] && continue
      TOTAL=$((TOTAL + 1))
      if ! is_complete "$item"; then
        [[ "$FORCE" -eq 1 ]] && say "--> $item 未通过完成度检查，但 --force 生效，强制回传" || continue
      fi
      if transfer_item "$item" "$rdir"; then DONE=$((DONE + 1)); else FAILED=$((FAILED + 1)); fi
    done
  done
fi

say "===== 回传任务结束：发现 $TOTAL 项，成功 $DONE 项，失败 $FAILED 项 ====="
exit 0
EOS
}

#──────────────── ── 内置：清理 ─────────────────────────────────────────────────
emit_cleanup() {
  cat <<'EOS'
#!/usr/bin/env bash
#═══════════════════════════════════════════════════════════════════════════════
# nas-n 本地副本清理（由 nas-n.sh 生成）
#
# 回传成功且超过 RETENTION_HOURS 小时后，删除本机副本，并把 qBittorrent /
# aria2 里对应的任务记录清掉（否则它们会因为文件消失而报错或重新下载）。
# 安全：只允许删除 TRANSFER_MAP 中本机目录「内部」的路径，越界一律拒绝并记日志。
#═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

CONF="${NASN_CONF:-/etc/nas-n/nas-n.conf}"
[[ -r "$CONF" ]] || { echo "缺少配置文件 $CONF" >&2; exit 1; }
set -a; . "$CONF"; set +a

STATE_DIR="${STATE:-/var/lib/nas-n}"
QUEUE_DIR="$STATE_DIR/queue"
LOG_FILE="$STATE_DIR/logs/cleanup.log"
mkdir -p "$QUEUE_DIR" "$STATE_DIR/logs" "$STATE_DIR/locks"

log_line() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }

exec 9>"$STATE_DIR/locks/cleanup.lock"
flock -n 9 || { log_line "已有清理进程在运行"; exit 0; }

NOW="$(date +%s)"
LIMIT=$(( ${RETENTION_HOURS:-24} * 3600 ))

ROOTS=()
IFS=';' read -r -a ENTRIES <<<"${TRANSFER_MAP:-}"
for entry in "${ENTRIES[@]}"; do
  [[ -n "$entry" ]] || continue
  ldir="${entry%%:*}"
  [[ "$ldir" == "$entry" ]] && continue
  ROOTS+=("$(realpath -m "$ldir" 2>/dev/null || printf '%s' "$ldir")")
done

safe_rm() {
  local p="$1" r canon
  [[ -n "$p" && "$p" != "/" ]] || { log_line "拒绝删除空路径或根路径：'$p'"; return 1; }
  canon="$(realpath -m "$p" 2>/dev/null || printf '%s' "$p")"
  for r in "${ROOTS[@]}"; do
    r="${r%/}"
    if [[ "$canon" == "$r"/* ]]; then
      if [[ -e "$canon" ]]; then rm -rf -- "$canon" && log_line "已删除本机副本：$canon"
      else log_line "本机副本已不存在：$canon"; fi
      return 0
    fi
  done
  log_line "拒绝删除越界路径（不在 TRANSFER_MAP 内）：$canon"
  return 1
}

qb_forget_path() {
  local p="$1" base="http://127.0.0.1:${QB_WEBUI_PORT}" jar r info hashes
  jar="$(mktemp)"
  r="$(curl -sS --max-time 10 -c "$jar" -H "Referer: $base/" \
        --data-urlencode "username=${QB_USER}" --data-urlencode "password=${QB_PASS}" \
        "$base/api/v2/auth/login" 2>/dev/null || true)"
  if [[ "$r" != "Ok." ]]; then rm -f "$jar"; log_line "qBittorrent 登录失败，跳过任务清理"; return 0; fi

  info="$(curl -sS --max-time 15 -b "$jar" -H "Referer: $base/" "$base/api/v2/torrents/info" 2>/dev/null || true)"
  hashes="$(printf '%s' "$info" | python3 -c '
import json, sys
target = sys.argv[1].rstrip("/")
try: data = json.load(sys.stdin)
except Exception: sys.exit(0)
out = []
for t in data:
    cp = (t.get("content_path") or "").rstrip("/")
    if cp == target or cp.startswith(target + "/"):
        out.append(t.get("hash", ""))
print("|".join(h for h in out if h))
' "$p" 2>/dev/null || true)"

  if [[ -n "$hashes" ]]; then
    curl -sS --max-time 15 -b "$jar" -H "Referer: $base/" -H "Origin: $base" \
      --data-urlencode "hashes=$hashes" --data-urlencode "deleteFiles=false" \
      "$base/api/v2/torrents/delete" >/dev/null 2>&1 || true
    log_line "已从 qBittorrent 移除任务：$hashes"
  fi
  rm -f "$jar"
}

aria2_purge() {
  curl -sS --max-time 10 \
    -d "jsonrpc=2.0&id=nasn&method=aria2.purgeDownloadResult&params=[\"token:${ARIA2_RPC_SECRET}\"]" \
    "http://127.0.0.1:${ARIA2_RPC_PORT}/jsonrpc" >/dev/null 2>&1 || true
}

DELETED=0; SKIPPED=0; PURGED=0
log_line "===== 清理开始（保留 ${RETENTION_HOURS:-24} 小时）====="

shopt -s nullglob
for job in "$QUEUE_DIR"/*.job; do
  unset path remote engine bytes status finished_at transferred_at
  . "$job" 2>/dev/null || { log_line "跳过损坏的队列文件：$job"; continue; }
  [[ "${status:-}" == "done" && -n "${transferred_at:-}" ]] || { SKIPPED=$((SKIPPED+1)); continue; }

  if [[ ! -e "${path:-}" ]]; then rm -f "$job"; continue; fi

  age=$(( NOW - transferred_at ))
  (( age < LIMIT )) && { SKIPPED=$((SKIPPED+1)); continue; }

  if safe_rm "$path"; then
    if [[ "${engine:-}" == "rclone" ]]; then qb_forget_path "$path"
    else aria2_purge; PURGED=1; fi
    rm -f "$job"
    DELETED=$((DELETED+1))
  fi
done
shopt -u nullglob

log_line "===== 清理结束：删除 $DELETED 项，保留 $SKIPPED 项 ====="
[[ $PURGED -eq 1 ]] && log_line "已清理 aria2 已完成任务记录"
exit 0
EOS
}

#──────────────── ── 内置：健康检查 ────────────────────────────────────────────
emit_healthcheck() {
  cat <<'EOS'
#!/usr/bin/env bash
#═══════════════════════════════════════════════════════════════════════════════
# nas-n 健康检查（由 nas-n.sh 生成）
# 检查关键服务/容器/端口/磁盘水位/回传通道，异常写日志并可选推送 Webhook。
#═══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

CONF="${NASN_CONF:-/etc/nas-n/nas-n.conf}"
[[ -r "$CONF" ]] || { echo "缺少配置文件 $CONF" >&2; exit 1; }
set -a; . "$CONF"; set +a

STATE_DIR="${STATE:-/var/lib/nas-n}"
LOG_FILE="$STATE_DIR/logs/health.log"
mkdir -p "$STATE_DIR/logs"
log_line() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }

PROBLEMS=()
problem() { PROBLEMS+=("$1"); log_line "异常：$1"; }
port_in_use() {
  ss -H -t -l -n "sport = :$1" 2>/dev/null | grep -q . && return 0
  ss -H -u -l -n "sport = :$1" 2>/dev/null | grep -q . && return 0
  return 1
}

check_unit() {
  systemctl list-unit-files "$1" >/dev/null 2>&1 || { [[ "$2" == required ]] && problem "单元 $1 未安装"; return 0; }
  systemctl is-active --quiet "$1" || problem "服务 $1 未运行（systemctl status $1）"
}
check_unit openlist.service required
check_unit caddy.service required
case "${TUNNEL_MODE:-direct}" in
  direct) check_unit nas-n-frps.service required ;;
  relay)  check_unit nas-n-frpc.service optional
          check_unit nas-n-hysteria.service optional ;;
esac

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for c in nas-n-qbittorrent nas-n-aria2 nas-n-ariang; do
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
    [[ "$st" == running ]] || problem "容器 $c 状态异常：$st"
  done
else
  problem "Docker 不可用"
fi

for p in "${OPENLIST_PORT:-5244}" "${QB_WEBUI_PORT:-8080}" "${ARIA2_RPC_PORT:-6800}" "${ARIANG_PORT:-8081}"; do
  port_in_use "$p" || problem "端口 $p 未监听"
done

if [[ -d "${DL_ROOT:-/srv/nas-n/downloads}" ]]; then
  use="$(df -P "$DL_ROOT" | awk 'NR==2{gsub("%","",$5); print $5}')"
  avail="$(df -Ph "$DL_ROOT" | awk 'NR==2{print $4}')"
  if [[ -n "$use" && "$use" -ge 90 ]]; then problem "下载分区使用率 ${use}%（剩余 $avail），检查回传/清理是否正常"
  else log_line "磁盘使用率 ${use}%（剩余 $avail）"; fi
fi

if [[ "${TUNNEL_MODE:-direct}" == "direct" ]]; then
  port_in_use "${MACMINI_SSH_REMOTE_PORT:-12222}" \
    || problem "Mac mini SSH 端口 ${MACMINI_SSH_REMOTE_PORT} 未监听（Mac mini 侧 frpc 可能没连上）"
elif [[ -n "${CN_HOST:-}" && "${HY2_ENABLE:-false}" == "true" ]]; then
  port_in_use "${MACMINI_SSH_PORT:-2222}" || problem "hysteria2 本地转发端口 ${MACMINI_SSH_PORT} 未监听"
fi

pending=0
shopt -s nullglob
for f in "$STATE_DIR"/queue/*.job; do pending=$((pending+1)); done
shopt -u nullglob
log_line "回传队列存量：$pending 项"

[[ ${#PROBLEMS[@]} -eq 0 ]] && { log_line "健康检查通过"; exit 0; }
log_line "健康检查发现 ${#PROBLEMS[@]} 个问题"

if [[ -n "${HEALTH_WEBHOOK:-}" ]]; then
  body="$(printf 'nas-n(%s) 健康检查告警：\n%s' "$(hostname)" "$(printf -- '- %s\n' "${PROBLEMS[@]}")")"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"msgtype":"text","text":{"content":sys.stdin.read()}}))' <<<"$body" 2>/dev/null || printf '{"text":"%s"}' "$body")"
  curl -sS --max-time 15 -X POST -H 'Content-Type: application/json' -d "$payload" "$HEALTH_WEBHOOK" >/dev/null 2>&1 \
    || log_line "Webhook 推送失败"
fi
exit 0
EOS
}

#───────────────────────────────────────────────────────────────────────────────
# 11. 报告 / 状态 / 端口表 / macmini 说明
#───────────────────────────────────────────────────────────────────────────────
public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS --connect-timeout 8 https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$ip" ]] || return 1
  printf '%s' "$ip"
}

_public_ip() { public_ipv4 2>/dev/null || echo '<本机公网IP>'; }

_relay_section() {
  case "${TUNNEL_MODE:-direct}" in
    direct)
      cat <<EOT
   本机是 frp 服务端（frps），Mac mini 主动连过来注册自己的 SSH：
     本机 frps 监听    : $(_public_ip):$FRPS_PORT
     frp token         : $FRP_TOKEN
     Mac mini remotePort: $MACMINI_SSH_REMOTE_PORT
     本机回传入口      : 127.0.0.1:$MACMINI_SSH_REMOTE_PORT（只绑本机，不暴露公网）
   完整说明： ./nas-n.sh macmini
EOT
      ;;
    relay)
      if [[ -n "$CN_HOST" ]]; then
        cat <<EOT
   本机已用 frpc 把端口发布到中转机 $CN_HOST：
   OpenList      $CN_HOST:$FRP_REMOTE_OPENLIST
   qBittorrent   $CN_HOST:$FRP_REMOTE_QB
   AriaNg        $CN_HOST:$FRP_REMOTE_ARIA
EOT
      else
        printf '   relay 模式但未配置中转服务器地址。\n'
      fi
      ;;
    *)
      printf '   未配置回传通道（TUNNEL_MODE=none）。\n'
      printf '   之后想启用：执行  ./nas-n.sh reconfigure\n'
      ;;
  esac
}

report() {
  local ip; ip="$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || echo '<本机公网IP>')"
  local b64=""
  have base64 && b64="$(printf '%s' "$ARIA2_RPC_SECRET" | base64 -w0 2>/dev/null || true)"

  title "部署完成"
  cat <<EOT

${BD}一、直连访问（域名指向本机 $ip，HTTPS 由 Caddy 自动续期）${N}
   OpenList      https://$DOMAIN_OPENLIST
   qBittorrent   https://$DOMAIN_QB      用户 $QB_USER
   AriaNg        https://$DOMAIN_ARIA

${BD}二、回传通道（Mac mini 回连信息）${N}
$(_relay_section)

${BD}三、口令（同时保存在 $CONF，权限 600）${N}
   OpenList      用户 $OPENLIST_USER / 口令 $OPENLIST_PASS
   qBittorrent   用户 $QB_USER / 口令 $QB_PASS
   aria2 RPC 密钥 $ARIA2_RPC_SECRET

${BD}四、AriaNg 连接 aria2${N}
   打开 https://$DOMAIN_ARIA → 设置 → RPC：
     协议 https | 主机 $DOMAIN_ARIA | 端口 443 | 路径 /jsonrpc | 密钥 $ARIA2_RPC_SECRET
   ${b64:+快捷链接（若无效请按上表手填）：https://$DOMAIN_ARIA/#!/settings/rpc/set/https/$DOMAIN_ARIA/443/jsonrpc/$b64}

${BD}五、下载与回传${N}
   qBittorrent 保存目录 : $DL_TORRENT_DIR
   aria2 保存目录       : $DL_ARIA_DIR
   目录映射             : $TRANSFER_MAP
   回传引擎             : $TRANSFER_ENGINE（并发 $TRANSFER_PARALLEL，校验 $TRANSFER_VERIFY）
   触发方式             : 下载完成钩子 + 每 5 分钟兜底扫描
   本地保留             : 回传成功后 $RETENTION_HOURS 小时自动删除

${BD}六、还需要你做的一件事（在 Mac mini 上）${N}
   1) 把下面这行公钥加到 Mac mini 的 ~/.ssh/authorized_keys（用户 $MACMINI_SSH_USER）：

$(cat "$SSH_KEY.pub" 2>/dev/null | sed 's/^/        /' || echo '        （密钥未生成）')

   2) 在 Mac mini 上跑 frpc 连到本机，注册它的 SSH：
        serverAddr = "$(_public_ip)"
        serverPort = $FRPS_PORT
        auth.token = "$FRP_TOKEN"
        [[proxies]]  name="macmini-ssh" type="tcp" localIP="127.0.0.1" localPort=22 remotePort=$MACMINI_SSH_REMOTE_PORT

   3) 云厂商安全组放行 TCP $FRPS_PORT。
   完整说明（含 launchd 配置与自测步骤）： ./nas-n.sh macmini

${BD}常用命令${N}
   ./nas-n.sh status                    查看状态
   ./nas-n.sh ports                     端口映射表
   ./nas-n.sh transfer --force          手动回传全部已完成资源
   ./nas-n.sh cleanup                   立即清理一次
   ./nas-n.sh macmini                   Mac mini 侧对接说明
   journalctl -u nas-n-transfer -n 100
   tail -f $STATE/logs/transfer.log
EOT
}

show_status() {
  title "运行状态"
  local u
  for u in openlist caddy nas-n-frps nas-n-frpc nas-n-hysteria; do
    if systemctl list-unit-files "$u.service" >/dev/null 2>&1; then
      printf '  %-22s %s\n' "$u" "$(systemctl is-active "$u.service" 2>/dev/null || echo unknown)"
    fi
  done
  echo
  if have docker && docker info >/dev/null 2>&1; then
    docker ps --filter name=nas-n --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  fi
  echo
  systemctl list-timers 'nas-n-*' --no-pager 2>/dev/null | head -8 || true
  echo
  sub "最近一次回传日志"
  tail -n 12 "$STATE/logs/transfer.log" 2>/dev/null || say "（暂无）"
}

show_ports() {
  conf_load 2>/dev/null || true
  def_defaults
  DOMAIN_OPENLIST="${DOMAIN_OPENLIST:-<未配置>}"
  DOMAIN_QB="${DOMAIN_QB:-<未配置>}"
  DOMAIN_ARIA="${DOMAIN_ARIA:-<未配置>}"
  title "端口映射表"
  cat <<EOT
${BD}一、本机监听${N}
   服务                      本机端口   绑定        对外暴露
   OpenList                  $OPENLIST_PORT      127.0.0.1   Caddy https://$DOMAIN_OPENLIST  / frpc -> 中转机 $FRP_REMOTE_OPENLIST
   qBittorrent WebUI         $QB_WEBUI_PORT      127.0.0.1   Caddy https://$DOMAIN_QB  / frpc -> 中转机 $FRP_REMOTE_QB
   qBittorrent BT            $QB_BT_PORT      0.0.0.0     TCP+UDP 直连公网（必须放行，否则没速度）
   aria2 RPC                 $ARIA2_RPC_PORT      127.0.0.1   Caddy https://$DOMAIN_ARIA/jsonrpc
   AriaNg                    $ARIANG_PORT      127.0.0.1   Caddy https://$DOMAIN_ARIA  / frpc -> 中转机 $FRP_REMOTE_ARIA
   aria2 BT/DHT              $TRACKER_BT_PORT      0.0.0.0     TCP+UDP 直连公网
   hysteria2 SOCKS5          $HY2_SOCKS_PORT      127.0.0.1   仅本机（frpc 加速用）
   hysteria2 转发入口         $MACMINI_SSH_PORT      127.0.0.1   ★ 回传入口：-> 中转机 127.0.0.1:$MACMINI_SSH_REMOTE_PORT
   Caddy                     80/443    0.0.0.0     公网（复用本机既有 Caddy）
   SSH                       22        0.0.0.0     公网（系统自带，本脚本不动）

${BD}二、回传通道（当前模式：$TUNNEL_MODE）${N}
   $FRPS_PORT/tcp        ★ frps 监听端口（本机是服务端，Mac mini 连它）→ 安全组必须放行
   $MACMINI_SSH_REMOTE_PORT/tcp      Mac mini 的 SSH 远程端口；frps 的 proxyBindAddr=127.0.0.1，
                    只绑本机，不暴露公网

${BD}三、回传链路走向${N}
   本机 rclone/rsync
     -> 连 127.0.0.1:$MACMINI_SSH_REMOTE_PORT   （frps 的远程端口，只绑本机）
       -> frps 隧道（由 Mac mini 主动建立的出站连接承载）
         -> Mac mini:22

${BD}四、容器端口映射${N}
   nas-n-qbittorrent  127.0.0.1:$QB_WEBUI_PORT->$QB_WEBUI_PORT (WebUI)  0.0.0.0:$QB_BT_PORT->$QB_BT_PORT tcp+udp (BT)
   nas-n-aria2        127.0.0.1:$ARIA2_RPC_PORT->$ARIA2_RPC_PORT (RPC)  0.0.0.0:$TRACKER_BT_PORT->$TRACKER_BT_PORT tcp+udp (BT/DHT)
   nas-n-ariang       127.0.0.1:$ARIANG_PORT->6880
   共享挂载： $DL_ROOT->/downloads    $APP/hooks->/nasn-hooks(ro)    $DATA/trigger->/nasn-trigger
EOT
}

show_macmini() {
  conf_load 2>/dev/null || true
  def_defaults
  local pub_ip ptok rport muser fport mode
  pub_ip="$(_public_ip)"
  ptok="${FRP_TOKEN:-}"; rport="$MACMINI_SSH_REMOTE_PORT"
  muser="$MACMINI_SSH_USER"; fport="$FRPS_PORT"; mode="${TUNNEL_MODE:-direct}"

  cat <<EOT
═══════════════════════════════════════════════════════════════════════════════
 Mac mini 侧实现方式注意事项（写 macmini 脚本时按这个对齐）
═══════════════════════════════════════════════════════════════════════════════

【本机扮演的角色】
  这台国外服务器同时是两件事：
    · frp 服务端（frps）—— Mac mini 主动连上来，把自己的 SSH 注册到本机
    · 回传发起方         —— 用 rclone / rsync 把下载好的资源推过去
  所以 Mac mini 只需要：开 sshd + 跑一个 frpc + 把本机公钥加进 authorized_keys。

【回传完整链路】
  本机 rclone/rsync
    -> 连 127.0.0.1:$rport        （frps 的远程端口，只绑本机）
      -> frps 隧道（由 Mac mini 主动建立的出站连接承载）
        -> Mac mini:22

  ★ proxyBindAddr = 127.0.0.1，所以 Mac mini 的 SSH 不会暴露到公网。
  ★ Mac mini 全程不需要公网 IP、不需要端口映射、不需要第三方中转。

【本机的实际参数（以 $CONF 为准）】
  回传通道模式        : $mode
  本机 frps 监听      : $pub_ip:$fport        ← Mac mini 连这里，安全组要放行 TCP $fport
  frp token           : $ptok
  Mac mini remotePort : $rport                ← Mac mini 侧 frpc 的 remotePort
  本机回传入口        : 127.0.0.1:$rport
  回传账号            : $muser
  目录映射            : $TRANSFER_MAP
  回传引擎            : $TRANSFER_ENGINE（并发 $TRANSFER_PARALLEL，校验 $TRANSFER_VERIFY）
  本地保留            : 回传成功后 $RETENTION_HOURS 小时自动删本机副本
EOT

  cat <<'EOT'

【Mac mini 必须做的 4 件事】

  1) 打开远程登录，准备回传账号
       sudo systemsetup -setremotelogin on        # 或 系统设置 -> 通用 -> 共享 -> 远程登录
     账号（上面那个用户名）对目标目录（如 /Volumes/Media/Downloads）必须有写权限。

  2) 加入本机的公钥
     公钥内容见本机 /etc/nas-n/ssh/id_ed25519.pub（安装完成时也会打印）。
       mkdir -p ~/.ssh && chmod 700 ~/.ssh
       echo '<本机公钥>' >> ~/.ssh/authorized_keys
       chmod 600 ~/.ssh/authorized_keys

  3) 跑 frpc，把 SSH 注册到本机（frp v1 TOML；本机 /opt/nas-n/bin/frpc 可直接拷到 Mac mini 用同版本）
       # /opt/frp/frpc.toml
       serverAddr = "<本机公网 IP>"
       serverPort = <FRPS_PORT>
       auth.method = "token"
       auth.token  = "<FRP_TOKEN>"
       transport.protocol = "tcp"
       transport.tcpMux   = true
       log.to    = "/var/log/frpc.log"
       log.level = "info"
       [[proxies]]
       name       = "macmini-ssh"
       type       = "tcp"
       localIP    = "127.0.0.1"
       localPort  = 22
       remotePort = <MACMINI_SSH_REMOTE_PORT>

     macOS 用 launchd 常驻（不是 systemd）：
       # ~/Library/LaunchAgents/com.nasn.frpc.plist
       Label=com.nasn.frpc
       ProgramArguments=[/opt/frp/frpc, -c, /opt/frp/frpc.toml]
       RunAtLoad=true   KeepAlive=true
       launchctl load -w ~/Library/LaunchAgents/com.nasn.frpc.plist

  4) macOS 三个坑
     · 外置盘没挂载 -> rclone 会把文件写进内置盘的同名空目录。
                       回传脚本里先判断： mount | grep /Volumes/Media
     · 系统休眠     -> sudo pmset -a sleep 0 disksleep 0，或 caffeinate -s 常驻
     · TCC 权限     -> 给 sshd-keygen-wrapper 授予「完全磁盘访问权限」
     时间同步： sudo systemsetup -setusingnetworktime on

【验收自测（按顺序，哪步失败修哪步）】
  ① Mac mini： tail -f /var/log/frpc.log
               期望看到 login to server success / start proxy success
  ② 本机：     systemctl status nas-n-frps
               ss -tlnp | grep <MACMINI_SSH_REMOTE_PORT>     # 有监听 = Mac mini 已连上
  ③ 本机：     ssh -p <MACMINI_SSH_REMOTE_PORT> -i /etc/nas-n/ssh/id_ed25519 \
                 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                 <MACMINI_SSH_USER>@127.0.0.1 'uname -a; df -h /Volumes/Media'
               看到 Darwin = 链路完全打通
  ④ 本机：     rclone lsd macmini: --config /etc/nas-n/rclone.conf
  ⑤ 本机：     ./nas-n.sh transfer --force   然后 tail -f /var/lib/nas-n/logs/transfer.log

  常见失败：
   · 本机连不上 127.0.0.1:<remotePort>  -> Mac mini 的 frpc 没起来，或 token 不一致
   · frpc 报 port not allowed           -> 本机 frps 的 allowPorts 里没有该 remotePort
   · 认证失败                           -> Mac mini 没加本机公钥，或用户名不对
   · 能连上但 permission denied         -> 目标目录权限 / TCC 完全磁盘访问

【速度调优】
  本机已自动完成：UDP/TCP 缓冲调优、BBR、rclone --sftp-chunk-size 255k
                  --sftp-concurrency 128、关闭 SSH 压缩（电影文件再压缩只会浪费 CPU）。
  Mac mini：目标盘尽量 SSD/雷电盘（机械 USB 盘往往 100~150MB/s 就是上限），
            网口至少 2.5GbE，别用 Wi-Fi 做回传。
  跨境丢包严重时：本机可另开 relay 模式，用 hysteria2(UDP/QUIC + 可选 Brutal)
            做加速层（需要一台中转服务器，见下）。

【可选的 relay 模式】
  如果以后你加了一台中转服务器（例如国内机器），想让跨境链路走 UDP 加速：
    1) 在那台机器上跑 frps
    2) 本机执行  ./nas-n.sh reconfigure  选 relay，填中转机地址/frps 端口/token
    3) Mac mini 的 frpc 改成连那台中转机（remotePort 保持不变）
  本机的回传入口会随之变成 127.0.0.1:<MACMINI_SSH_PORT>（经 hysteria2 转发到中转机）。
═══════════════════════════════════════════════════════════════════════════════
EOT
}

#───────────────────────────────────────────────────────────────────────────────
# 12. 卸载
#───────────────────────────────────────────────────────────────────────────────
do_uninstall() {
  local purge=0 dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) shift ;;
    esac
  done
  need_root uninstall

  run() { if [[ $dry -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

  title "卸载 nas-n"
  local u
  for u in nas-n-transfer.path nas-n-transfer.timer nas-n-transfer.service \
           nas-n-cleanup.timer nas-n-cleanup.service \
           nas-n-healthcheck.timer nas-n-healthcheck.service \
           nas-n-frps.service nas-n-frpc.service nas-n-hysteria.service; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then
      run systemctl disable --now "$u" >/dev/null 2>&1 || true
      run rm -f "/etc/systemd/system/$u"
      say "移除 $u"
    fi
  done
  run systemctl daemon-reload

  if have docker && docker info >/dev/null 2>&1; then
    if [[ $dry -eq 1 ]]; then printf '  [dry-run] docker compose -p nas-n down\n'
    else docker compose -p nas-n --env-file "$APP/config/compose.env" -f "$APP/config/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true; fi
    say "容器已停止（镜像与卷保留）"
  fi

  [[ -f "$CADDY_SITE" ]] && { run rm -f "$CADDY_SITE"; say "删除 $CADDY_SITE"; }
  if [[ -f "$CADDY_MAIN" ]] && grep -qF "$CADDY_IMPORT" "$CADDY_MAIN"; then
    if [[ $dry -eq 1 ]]; then printf '  [dry-run] 从 %s 移除 import 行\n' "$CADDY_MAIN"
    else
      grep -vF "$CADDY_IMPORT" "$CADDY_MAIN" | grep -v 'nas-n 追加：加载本项目站点配置' >"$CADDY_MAIN.nasn.tmp"
      mv -f "$CADDY_MAIN.nasn.tmp" "$CADDY_MAIN"
      caddy validate --adapter caddyfile --config "$CADDY_MAIN" >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true
      say "已从 $CADDY_MAIN 移除 import 行并 reload"
    fi
  fi

  [[ -f /etc/sysctl.d/99-nas-n.conf ]] && { run rm -f /etc/sysctl.d/99-nas-n.conf; say "删除内核参数优化"; }
  if [[ -d /etc/nas-n ]]; then
    run cp -a /etc/nas-n "/root/nas-n-conf-backup-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    run rm -rf /etc/nas-n; say "删除 /etc/nas-n（已备份到 /root/）"
  fi
  [[ -d "$APP" ]] && { run rm -rf "$APP"; say "删除 $APP"; }

  if [[ $purge -eq 1 ]]; then
    warn "将删除下载数据与状态目录"
    if [[ $dry -eq 0 ]] && ! confirm "确认删除 $DATA 与 $STATE ？" n; then die "已取消"; fi
    run rm -rf "$DATA" "$STATE"; say "已删除 $DATA 与 $STATE"
  fi

  title "卸载完成"
  cat <<EOT
已保留（如不需要请手动处理）：
  $DATA       下载数据（--purge 可一并删除）
  $STATE      队列与日志
  Docker 镜像与容器数据卷
  OpenList 本体（/opt/openlist）

本机原有的 Caddy 站点、video-dl 等服务未受影响。
EOT
}

#───────────────────────────────────────────────────────────────────────────────
# 13. 主流程
#───────────────────────────────────────────────────────────────────────────────
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

install_all() {
  need_root install
  preflight_env
  preflight_deps

  if [[ -f "$CONF" && "$RECONFIGURE" != "1" ]]; then
    conf_load; def_defaults
    ok "复用已有配置 $CONF"
    say "如需修改请执行： ./nas-n.sh reconfigure"
    conf_show
  else
    conf_load 2>/dev/null || true
    def_defaults
    if [[ "$ASSUME_YES" == "1" && ! -f "$CONF" ]]; then
      die "--yes 模式需要已存在的配置文件，请先交互式运行一次"
    fi
    prompt_all
    conf_save
    conf_show
  fi

  conf_load
  def_defaults
  preflight_ports

  install_docker
  deploy_downloaders
  install_openlist
  deploy_tunnel
  deploy_web
  deploy_transfer

  conf_load; def_defaults
  report
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    install)     shift || true
                 while [[ $# -gt 0 ]]; do
                   case "$1" in
                     --yes|-y) ASSUME_YES=1; shift ;;
                     --reconfigure) RECONFIGURE=1; shift ;;
                     *) die "未知参数：$1" ;;
                   esac
                 done
                 install_all ;;
    reconfigure) RECONFIGURE=1; install_all ;;
    check)       conf_load 2>/dev/null || true; def_defaults
                 preflight_env; preflight_report; deps_report; preflight_ports ;;
    transfer)    shift || true; need_root transfer; exec "$APP/tools/transfer.sh" "$@" ;;
    cleanup)     need_root cleanup; exec "$APP/tools/cleanup.sh" ;;
    status)      show_status ;;
    ports)       show_ports ;;
    macmini)     show_macmini ;;
    logs)        tail -n 50 "$STATE/logs/transfer.log" 2>/dev/null || say "（暂无日志）" ;;
    uninstall)   shift || true; do_uninstall "$@" ;;
    --emit)      shift || true; [[ -n "${1:-}" ]] || die "用法： $0 --emit <name>"; conf_load 2>/dev/null || true; def_defaults; emit "$1" ;;
    --version|-V) echo "nas-n.sh $VERSION" ;;
    --help|-h)   usage ;;
    *)           usage; exit 1 ;;
  esac
}

trap 'err "执行失败：第 $LINENO 行 -> $BASH_COMMAND"' ERR
main "$@"
