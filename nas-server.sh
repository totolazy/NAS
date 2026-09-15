#!/usr/bin/env bash
#═══════════════════════════════════════════════════════════════════════════════
#  nas-server.sh —— 国外下载服务器 一键部署脚本（单文件、自包含）
#
#  部署内容
#    1. Docker + qBittorrent + aria2 + AriaNg
#       · 容器端口全部映射到本机（WebUI/RPC 默认只绑 127.0.0.1，由 Caddy 对外）
#       · qb 与 aria2 统一下载到「交换目录」
#    2. OpenList（用官方一键脚本安装： https://res.oplist.org/script/v4.sh）
#    3. Caddy + 自动 HTTPS（没装就装；只追加站点片段，绝不动本机已有站点）
#       · 用域名 HTTPS 访问 OpenList / qBittorrent / AriaNg
#    4. hysteria2 服务端（纯 UDP）—— 给 Mac mini 拉取文件用
#    5. 交换目录（默认 /opt/nas）+ systemd 定时器：超过保留时间的文件自动清除
#
#  互传方向：Mac mini 每隔 5 分钟主动来「拉」。
#  本脚本只负责服务器端；不含任何 Mac mini 脚本（`macmini` 子命令只打印对接参数）。
#
#  用法
#    sudo ./nas-server.sh                交互式完整部署
#    sudo ./nas-server.sh reconfigure    重新问答并覆盖配置
#    sudo ./nas-server.sh cleanup        立即执行一次交换目录清理
#    sudo ./nas-server.sh status         查看运行状态
#    sudo ./nas-server.sh ports          打印端口映射表
#    sudo ./nas-server.sh macmini        打印 Mac mini 侧对接参数（只打印，不写脚本）
#    sudo ./nas-server.sh uninstall      卸载（默认保留交换目录数据）
#    ./nas-server.sh --emit <name>       打印内置生成物（调试用）
#═══════════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail

VERSION="1.5.0"

#───────────────────────────────────────────────────────────────────────────────
# 0. 路径与常量
#───────────────────────────────────────────────────────────────────────────────
CONF="/etc/nas-server/nas-server.conf"      # 全部参数（含口令），权限 600
APP="/opt/nas-server"                       # 脚本自身产物（compose、清理脚本、Caddy 片段）
STATE="/var/lib/nas-server"                 # 运行状态（日志、锁）
TLS_DIR="/etc/nas-server/tls"               # 给 hysteria2 用的证书副本

LOG="/var/log/nas-server.log"
CLEANUP_LOG="/var/log/nas-server-cleanup.log"

CADDY_MAIN="/etc/caddy/Caddyfile"
CADDY_SITE="/etc/caddy/conf.d/nas-server.caddy"
CADDY_IMPORT='import /etc/caddy/conf.d/*.caddy'

OPENLIST_DIR="/opt/openlist"                # 官方脚本固定装到这里
HY2_CONF="/etc/hysteria/config.yaml"        # hysteria2 官方脚本固定用这个路径
HY2_SERVICE="hysteria-server.service"

# 容器里两个挂载点，各管一件事：
#   /downloads / $DOWNLOAD_SRC —— OpenList 的临时目录（两处同名挂载）。
#                 OpenList 的「离线下载」会把宿主机绝对路径交给下载器，所以容器里
#                 必须有同名路径；/downloads 只是顺带保留的别名。
#   /Mac       —— 源目录是交换目录 ${EXCHANGE}，也就是 Mac mini 拉取的来源。
#                 qB/aria2 的**默认下载目录**指向它，所以普通下载下完就会被 Mac 拉走。
readonly DEF_DOWNLOAD_SRC="$OPENLIST_DIR/data/temp"   # /downloads 的源目录
readonly DEF_MAC_DIR="/Mac"                           # Mac 目录在容器里的名字


LEGACY_UNITS=(
  nas-n-transfer.path nas-n-transfer.timer nas-n-transfer.service
  nas-n-cleanup.timer nas-n-cleanup.service
  nas-n-healthcheck.timer nas-n-healthcheck.service
  nas-n-frps.service nas-n-frpc.service nas-n-hysteria.service
)
LEGACY_CONTAINERS=(nas-n-qbittorrent nas-n-aria2 nas-n-ariang)

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
  printf '%s%s════════════════════════════════════════════════════════════%s\n' "$C" '' "$N"
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
    *) echo unknown ;;
  esac
}

env_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# 幂等写入：内容变化时 WRITE_CHANGED=1
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

conf_set() {
  local key="$2" val="$3" tmp found=0 line l
  line="${key}=$(env_quote "$val")"
  mkdir -p "$(dirname "$1")"
  tmp="$(mktemp "$(dirname "$1")/.nassrv.XXXXXX")"; chmod 600 "$tmp"
  if [[ -f "$1" ]]; then
    while IFS= read -r l || [[ -n "$l" ]]; do
      if [[ "$l" == "${key}="* ]]; then printf '%s\n' "$line" >>"$tmp"; found=1
      else printf '%s\n' "$l" >>"$tmp"; fi
    done <"$1"
  fi
  [[ $found -eq 1 ]] || printf '%s\n' "$line" >>"$tmp"
  mv -f "$tmp" "$1"; chmod 600 "$1"
}

conf_load() { [[ -f "$CONF" ]] || return 1; set -a; . "$CONF"; set +a; }

port_in_use() {
  ss -H -t -l -n "sport = :$1" 2>/dev/null | grep -q . && return 0
  ss -H -u -l -n "sport = :$1" 2>/dev/null | grep -q . && return 0
  return 1
}

pkg_install() {
  [[ $# -eq 0 ]] && return 0
  if have apt-get; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
  elif have dnf; then dnf install -y -q "$@"
  elif have yum; then yum install -y -q "$@"
  else die "无法识别的包管理器，请手动安装：$*"; fi
}

svc_active() { systemctl is-active --quiet "$1"; }
svc_reload() { systemctl daemon-reload; }

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

#───────────────────────────────────────────────────────────────────────────────
# 2. 交互问答
#───────────────────────────────────────────────────────────────────────────────
RECONFIGURE=0
ASSUME_YES=0

def_defaults() {
  TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || echo Asia/Shanghai)}"

  # 交换目录（qb/aria2 都下载到这里，Mac mini 也来这里拉）
  EXCHANGE="${EXCHANGE:-/opt/nas}"
  # 容器内挂载点（qb/aria2 在容器里看到的路径，映射到上面的交换目录）
  # 容器内 /downloads 的源目录（qb/aria2 的默认下载目录）
  DOWNLOAD_SRC="${DOWNLOAD_SRC:-$DEF_DOWNLOAD_SRC}"
  # 额外挂给 Mac mini 的挂载点在容器里的名字（源目录 = 交换目录 ${EXCHANGE}）
  MAC_DIR="${MAC_DIR:-$DEF_MAC_DIR}"
  # 「已送达归档」：Mac 拉走并校验成功后，会把它从 ${EXCHANGE} 挪到这里（服务器端 mv）。
  # 这样待拉区里永远是「还没送出去」的东西，天然不会重复拉取。
  EXCHANGE_USED="${EXCHANGE_USED:-/opt/nas-used}"
  # 待拉区保留多久（默认 7 天）：没送出去的文件不会太快被删
  INBOX_RETENTION_MINUTES="${INBOX_RETENTION_MINUTES:-10080}"
  # qB/aria2 的默认下载目录：默认就是上面的 Mac 目录，这样"下完即被 Mac 拉走"。
  # 想改回 OpenList 临时目录就把它设成 /downloads（改 conf 后重跑脚本）。
  DEFAULT_SAVE_DIR="${DEFAULT_SAVE_DIR:-$MAC_DIR}"
  # 拉取账号（Mac 用 SSH/SFTP 登录这个账号）
  PULL_USER="${PULL_USER:-nas}"
  MIRROR_PUBKEY="${MIRROR_PUBKEY:-}"

  # 容器运行身份（部署时按拉取账号自动填，这里给 set -u 兜底）
  PUID="${PUID:-}"; PGID="${PGID:-}"

  # 端口
  OPENLIST_PORT="${OPENLIST_PORT:-5244}"
  QB_WEBUI_PORT="${QB_WEBUI_PORT:-8080}"
  QB_BT_PORT="${QB_BT_PORT:-6881}"
  ARIA2_RPC_PORT="${ARIA2_RPC_PORT:-6800}"
  ARIA2_BT_PORT="${ARIA2_BT_PORT:-6888}"
  ARIANG_PORT="${ARIANG_PORT:-8081}"
  BIND_LOCAL="${BIND_LOCAL:-127.0.0.1}"      # WebUI/RPC 绑定地址

  # 口令
  OPENLIST_USER="${OPENLIST_USER:-admin}"; OPENLIST_PASS="${OPENLIST_PASS:-}"
  QB_USER="${QB_USER:-admin}";             QB_PASS="${QB_PASS:-}"
  ARIA2_RPC_SECRET="${ARIA2_RPC_SECRET:-}"

  # 域名与证书
  CF_BASE_DOMAIN="${CF_BASE_DOMAIN:-}"
  DOMAIN_OPENLIST="${DOMAIN_OPENLIST:-}"
  DOMAIN_QB="${DOMAIN_QB:-}"
  DOMAIN_ARIA="${DOMAIN_ARIA:-}"

  # hysteria2（纯 UDP 通道）
  HY2_PORT="${HY2_PORT:-8443}"
  HY2_PASS="${HY2_PASS:-}"
  HY2_SNI="${HY2_SNI:-}"

  # 交换目录保留时间（分钟），超过就清除
  RETENTION_MINUTES="${RETENTION_MINUTES:-1440}"
  CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-10min}"
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
  local __v="$1" __p="$2" __d="${3:-}" __allow_empty="${4:-0}" __a=""
  while :; do
    ask __a "$__p" "$__d" "$__allow_empty"
    if [[ -z "$__a" && "$__allow_empty" == "1" ]]; then printf -v "$__v" '%s' ""; return 0; fi
    if [[ "$__a" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      printf -v "$__v" '%s' "$__a"; return 0
    fi
    warn "域名格式不正确：'$__a'"
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

本向导依次询问：交换目录、端口、口令、域名、hysteria2、Mac mini 对接公钥。
所有答案保存到 /etc/nas-server/nas-server.conf（权限 600），下次重跑直接复用。
（每一步直接回车即使用方括号里的默认值）

EOT

  sub "交换目录（qb/aria2 下载到这里，Mac mini 也来这里拉）"
  ask EXCHANGE "交换目录" "$EXCHANGE"
  say "目录映射：容器内 $MAC_DIR  ->  本机 $EXCHANGE （qB/aria2 默认下载 + Mac 拉取）"
  say "          容器内 /downloads  ->  本机 $DOWNLOAD_SRC （OpenList 临时目录）"

  sub "Mac mini 拉取账号（SSH/SFTP）"
  ask PULL_USER "服务器上给 Mac mini 用的账号名" "$PULL_USER"
  cat <<'EOT'

粘贴 Mac mini 的 SSH 公钥（形如 ssh-ed25519 AAAA... 结尾一串）。
可以留空：之后把公钥追加到服务器 ~PULL_USER/.ssh/authorized_keys 即可。
EOT
  ask MIRROR_PUBKEY "Mac mini 公钥（可留空）" "$MIRROR_PUBKEY" 1

  sub "端口规划（WebUI/RPC 默认只绑 127.0.0.1，由 Caddy 对外提供 HTTPS）"
  ask_port OPENLIST_PORT    "OpenList 端口" "$OPENLIST_PORT"
  ask_port QB_WEBUI_PORT    "qBittorrent WebUI 端口" "$QB_WEBUI_PORT"
  ask_port QB_BT_PORT       "qBittorrent BT 端口（TCP+UDP，需公网可达）" "$QB_BT_PORT"
  ask_port ARIA2_RPC_PORT   "aria2 RPC 端口" "$ARIA2_RPC_PORT"
  ask_port ARIA2_BT_PORT    "aria2 BT 端口（TCP+UDP，需公网可达）" "$ARIA2_BT_PORT"
  ask_port ARIANG_PORT      "AriaNg 端口" "$ARIANG_PORT"
  say "绑定地址：127.0.0.1 只有本机能连（推荐，外部走 Caddy 的 HTTPS）；0.0.0.0 则公网可直连。"
  ask BIND_LOCAL "WebUI/RPC 监听地址 [127.0.0.1/0.0.0.0]" "$BIND_LOCAL"

  sub "访问口令（直接回车自动生成强随机口令）"
  ask_secret OPENLIST_PASS "OpenList 管理员($OPENLIST_USER)密码" "$OPENLIST_PASS"
  [[ -z "$OPENLIST_PASS" ]] && OPENLIST_PASS="$(rand_secret 20)"
  ask_secret QB_PASS "qBittorrent WebUI 密码（用户 ${QB_USER}，至少 6 位）" "$QB_PASS"
  [[ -z "$QB_PASS" ]] && QB_PASS="$(rand_secret 20)"
  while (( ${#QB_PASS} < 6 )); do
    warn "qBittorrent 密码至少 6 位"
    ask_secret QB_PASS "qBittorrent WebUI 密码（至少 6 位）" ""
    [[ -z "$QB_PASS" ]] && { QB_PASS="$(rand_secret 20)"; ok "已自动生成随机口令"; }
  done
  ask_secret ARIA2_RPC_SECRET "aria2 RPC 密钥" "$ARIA2_RPC_SECRET"
  [[ -z "$ARIA2_RPC_SECRET" ]] && ARIA2_RPC_SECRET="$(rand_secret 24)"

  sub "域名与 HTTPS（Caddy 自动申请证书）"
  say "需要三个域名的 A 记录都已指向本机公网 IP，且未走 Cloudflare 橙云代理。"
  ask_hostname CF_BASE_DOMAIN "你的主域名（例如 example.com，用于生成默认值）" "$CF_BASE_DOMAIN" 1
  ask_hostname DOMAIN_OPENLIST "OpenList 访问域名" "${DOMAIN_OPENLIST:-${CF_BASE_DOMAIN:+dllist.$CF_BASE_DOMAIN}}"
  ask_hostname DOMAIN_QB       "qBittorrent 访问域名" "${DOMAIN_QB:-${CF_BASE_DOMAIN:+qb.$CF_BASE_DOMAIN}}"
  ask_hostname DOMAIN_ARIA     "AriaNg 访问域名（aria2 RPC 走同域 /jsonrpc）" "${DOMAIN_ARIA:-${CF_BASE_DOMAIN:+aria.$CF_BASE_DOMAIN}}"

  sub "hysteria2 通道（纯 UDP，给 Mac mini 拉取用）"
  say "本机 443/UDP 通常已被 Caddy 的 HTTP/3 占用，建议换一个端口（默认 ${HY2_PORT}）。"
  ask_port HY2_PORT "hysteria2 UDP 监听端口" "$HY2_PORT"
  ask_secret HY2_PASS "hysteria2 认证密码" "$HY2_PASS"
  [[ -z "$HY2_PASS" ]] && { HY2_PASS="$(rand_secret 24)"; ok "已自动生成 hysteria2 密码"; }
  say "SNI 用上面某个域名的证书（Caddy 签发后自动复制给 hysteria2）。"
  ask_hostname HY2_SNI "hysteria2 TLS SNI（建议用 OpenList 域名或另给一个已解析的域名）" "${HY2_SNI:-$DOMAIN_OPENLIST}"

  sub "交换目录清理"
  say "交换目录里「最后修改时间」超过保留时长的文件会被删除（Mac 每 5 分钟来拉，24 小时足够）。"
  ask_int RETENTION_MINUTES "保留时长（分钟，1440 = 1 天）" "$RETENTION_MINUTES" 10 525600

  sub "其它"
  ask TZ "时区" "$TZ"
}

conf_save() {
  # 目录权限必须是 711（可穿越、不可列目录），不能用 700：
  # hysteria 以独立的 hysteria 用户运行，需要能 stat 到
  # /etc/nas-server/tls/hy2.crt；目录 700 会把它挡在外面，表现为
  #   FATAL tls.cert: stat /etc/nas-server/tls/hy2.crt: permission denied
  # 配置文件本身仍是 600，所以 711 不会泄露口令。
  mkdir -p /etc/nas-server "$STATE/logs"; chmod 711 /etc/nas-server 2>/dev/null || true
  : >"$CONF"; chmod 600 "$CONF"
  local kv
  for kv in \
    "NAS_SERVER_VERSION=$VERSION" "TZ=$TZ" "APP=$APP" "STATE=$STATE" \
    "EXCHANGE=$EXCHANGE" "EXCHANGE_USED=$EXCHANGE_USED" \
    "INBOX_RETENTION_MINUTES=$INBOX_RETENTION_MINUTES" \
    "DOWNLOAD_SRC=$DOWNLOAD_SRC" "MAC_DIR=$MAC_DIR" \
    "DEFAULT_SAVE_DIR=$DEFAULT_SAVE_DIR" "PULL_USER=$PULL_USER" "MIRROR_PUBKEY=$MIRROR_PUBKEY" \
    "PUID=$PUID" "PGID=$PGID" \
    "OPENLIST_PORT=$OPENLIST_PORT" "QB_WEBUI_PORT=$QB_WEBUI_PORT" "QB_BT_PORT=$QB_BT_PORT" \
    "ARIA2_RPC_PORT=$ARIA2_RPC_PORT" "ARIA2_BT_PORT=$ARIA2_BT_PORT" "ARIANG_PORT=$ARIANG_PORT" \
    "BIND_LOCAL=$BIND_LOCAL" \
    "OPENLIST_USER=$OPENLIST_USER" "OPENLIST_PASS=$OPENLIST_PASS" \
    "QB_USER=$QB_USER" "QB_PASS=$QB_PASS" "ARIA2_RPC_SECRET=$ARIA2_RPC_SECRET" \
    "CF_BASE_DOMAIN=$CF_BASE_DOMAIN" "DOMAIN_OPENLIST=$DOMAIN_OPENLIST" \
    "DOMAIN_QB=$DOMAIN_QB" "DOMAIN_ARIA=$DOMAIN_ARIA" \
    "HY2_PORT=$HY2_PORT" "HY2_PASS=$HY2_PASS" "HY2_SNI=$HY2_SNI" \
    "RETENTION_MINUTES=$RETENTION_MINUTES" "CLEANUP_INTERVAL=$CLEANUP_INTERVAL" ; do
    conf_set "$CONF" "${kv%%=*}" "${kv#*=}"
  done
  ok "配置已写入 ${CONF}（权限 600）"
}

conf_show() {
  title "配置摘要"
  cat <<EOT
  待拉目录      : $EXCHANGE        （容器内映射为 ${MAC_DIR}；Mac 只从这里拉）
  已送达归档    : $EXCHANGE_USED        （Mac 拉走后 mv 到这里，${RETENTION_MINUTES} 分钟后删）
  默认下载目录  : $DEFAULT_SAVE_DIR        （容器内路径，qB/aria2 都下到这里）
  OpenList 临时 : $DOWNLOAD_SRC        （容器内 /downloads，给离线下载用）
  拉取账号      : $PULL_USER${MIRROR_PUBKEY:+  （已提供 Mac 公钥）}
  本机端口      : OpenList $OPENLIST_PORT / qB WebUI $QB_WEBUI_PORT / qB BT $QB_BT_PORT
                  aria2 RPC $ARIA2_RPC_PORT / aria2 BT $ARIA2_BT_PORT / AriaNg $ARIANG_PORT
  监听地址      : $BIND_LOCAL ($( [[ "$BIND_LOCAL" == "127.0.0.1" ]] && echo "仅本机，外部走 Caddy" || echo "公网可直连" ))
  域名          : $DOMAIN_OPENLIST
                  $DOMAIN_QB
                  $DOMAIN_ARIA
  hysteria2     : UDP :$HY2_PORT   SNI=$HY2_SNI
  清理策略      : 超过 $RETENTION_MINUTES 分钟自动删除，每 $CLEANUP_INTERVAL 检查一次
EOT
}

#───────────────────────────────────────────────────────────────────────────────
# 3. 预检
#───────────────────────────────────────────────────────────────────────────────
preflight_env() {
  title "预检：系统环境"
  [[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux"
  [[ "$(arch)" == "unknown" ]] && die "不支持的 CPU 架构：$(uname -m)"
  ok "系统：$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" )  架构：$(arch)"
  [[ -d /run/systemd/system ]] || die "未检测到 systemd"
  ok "systemd 可用"
  local ip; ip="$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] && ok "本机公网 IPv4：$ip" || warn "未探测到公网 IPv4"
}

preflight_deps() {
  title "预检：基础依赖"
  local missing=()
  have curl    || missing+=(curl);    have tar  || missing+=(tar)
  have gzip    || missing+=(gzip);    have openssl || missing+=(openssl)
  have unzip   || missing+=(unzip);   have rsync || missing+=(rsync)
  have ss      || missing+=(iproute2); have python3 || missing+=(python3)
  have gpg     || missing+=(gnupg)
  # setfacl：OpenList 离线下载要用默认 ACL 让下载器能写进它（root）建的子目录
  have setfacl || missing+=(acl)
  # 精简版 Debian 常常没有 ca-certificates，缺了会让所有 https 下载报
  # curl: (77) error setting certificate file
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if [[ ${#missing[@]} -gt 0 ]]; then say "安装缺失依赖：${missing[*]}"; pkg_install "${missing[@]}"; fi
  local still=()
  for c in curl tar gzip openssl unzip ss python3; do have "$c" || still+=("$c"); done
  [[ ${#still[@]} -eq 0 ]] || die "以下依赖仍不可用：${still[*]}"
  ok "基础依赖齐全"
}

# 端口是否被「本项目自己」占用（重跑时不该被当成冲突）
port_is_ours() {
  local port="$1"
  if have docker && docker info >/dev/null 2>&1; then
    docker ps --filter 'name=nas-' --format '{{.Ports}}' 2>/dev/null \
      | grep -qE "[:.]${port}->" && return 0
  fi
  [[ "$port" == "${OPENLIST_PORT:-}" ]] && svc_active openlist && return 0
  [[ "$port" == "${HY2_PORT:-}" ]] && svc_active "$HY2_SERVICE" && return 0
  return 1
}

preflight_ports() {
  title "预检：端口占用"
  local -a checks=(
    "OpenList|$OPENLIST_PORT" "qBittorrent WebUI|$QB_WEBUI_PORT" "qBittorrent BT|$QB_BT_PORT"
    "aria2 RPC|$ARIA2_RPC_PORT" "aria2 BT|$ARIA2_BT_PORT" "AriaNg|$ARIANG_PORT"
  )
  local item name port conflict=0
  for item in "${checks[@]}"; do
    name="${item%%|*}"; port="${item##*|}"
    if ! port_in_use "$port"; then
      ok "$name 端口 $port 空闲"
    elif port_is_ours "$port"; then
      ok "$name 端口 $port 已被本项目占用（预期，重跑正常）"
    else
      warn "$name 端口 $port 已被其他程序占用"; conflict=1
    fi
  done
  if ! port_in_use "$HY2_PORT"; then
    ok "hysteria2 端口 $HY2_PORT/UDP 空闲"
  elif port_is_ours "$HY2_PORT"; then
    ok "hysteria2 端口 $HY2_PORT/UDP 已被本项目占用（预期）"
  else
    warn "hysteria2 端口 $HY2_PORT/UDP 已被其他程序占用"; conflict=1
  fi
  if [[ $conflict -eq 1 ]]; then
    warn "检测到端口冲突，相关服务可能无法启动"
    [[ "$ASSUME_YES" == "1" ]] || confirm "是否仍要继续？" n || die "已被用户中止"
  fi
}

#───────────────────────────────────────────────────────────────────────────────
# 4. 清理旧部署（nas-n.sh 那套）
#───────────────────────────────────────────────────────────────────────────────
remove_legacy() {
  title "检查旧部署（nas-n.sh 那套）"
  local found=0 u c

  for u in "${LEGACY_UNITS[@]}"; do
    if [[ -f "/etc/systemd/system/$u" ]]; then
      found=1
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/$u"
      say "移除单元 $u"
    fi
  done

  if have docker && docker info >/dev/null 2>&1; then
    for c in "${LEGACY_CONTAINERS[@]}"; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
        found=1
        docker rm -f "$c" >/dev/null 2>&1 || true
        say "移除容器 $c"
      fi
    done
  fi

  # 旧 Caddy 片段（import 行保留给新脚本复用）
  if [[ -f /etc/caddy/conf.d/nas-n.caddy ]]; then
    found=1
    rm -f /etc/caddy/conf.d/nas-n.caddy; say "移除 /etc/caddy/conf.d/nas-n.caddy"
  fi

  # 旧目录
  [[ -d /opt/nas-n ]] && { found=1; rm -rf /opt/nas-n; say "移除 /opt/nas-n"; }
  if [[ -d /etc/nas-n ]]; then
    found=1
    cp -a /etc/nas-n "/root/nas-n-conf-backup-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    rm -rf /etc/nas-n; say "移除 /etc/nas-n（已备份到 /root/）"
  fi
  [[ -d /var/lib/nas-n ]] && { found=1; rm -rf /var/lib/nas-n; say "移除 /var/lib/nas-n"; }

  # ★ 只有确认存在旧部署时，才连 OpenList 一起卸掉。
  #   否则重跑本脚本会把刚装好的 OpenList 自己删掉。
  if [[ $found -eq 1 && -d "$OPENLIST_DIR" ]]; then
    systemctl disable --now openlist >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/openlist.service /usr/local/bin/openlist /usr/bin/openlist 2>/dev/null || true
    rm -rf "$OPENLIST_DIR"; say "移除旧 OpenList（${OPENLIST_DIR}）"
  fi

  if [[ $found -eq 1 ]]; then
    svc_reload
    ok "旧部署已清理（/srv/nas-n 下载数据保留）"
  else
    ok "未发现旧部署，跳过"
  fi
}

#───────────────────────────────────────────────────────────────────────────────
# 5. Docker
#───────────────────────────────────────────────────────────────────────────────
install_docker() {
  title "安装 Docker Engine"
  if have docker && docker compose version >/dev/null 2>&1; then
    ok "Docker 已就绪：$(docker --version 2>/dev/null)"
  else
    say "使用 Docker 官方脚本安装：https://get.docker.com"
    http_download https://get.docker.com /tmp/get-docker.sh || die "下载 Docker 官方脚本失败"
    sh /tmp/get-docker.sh || die "Docker 安装失败"
    rm -f /tmp/get-docker.sh
    ok "Docker 安装完成"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker 守护进程未运行，请检查 systemctl status docker"
}

#───────────────────────────────────────────────────────────────────────────────
# 6. 拉取账号 + 交换目录
#───────────────────────────────────────────────────────────────────────────────

# Mac 端每 5 分钟会并发拉取（默认 8 路）。Debian 默认 MaxStartups 10:30:100 会在
# 未认证连接超过 10 个时随机丢弃新连接，表现为偶发 "Connection reset by peer"。
# 这里用 drop-in 抬高上限，校验通过才 reload，失败自动回滚。
tune_sshd() {
  title "调优 sshd 并发上限（配合 Mac 端并发拉取）"
  local drop=/etc/ssh/sshd_config.d/99-nas-server.conf

  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    warn "sshd_config 未包含 drop-in 目录，跳过（可手工把 MaxStartups 调大）"
    return 0
  fi

  write_file "$drop" 0644 <<'EOF'
# 由 nas-server.sh 添加：抬高 SSH 并发握手上限。
# Mac 端每 5 分钟并发拉取（默认 8 路），默认 MaxStartups 10:30:100 会让超过
# 10 个未认证连接被随机丢弃，表现为偶发 "Connection reset by peer"。
MaxStartups 100:30:200
MaxSessions 64
EOF
  [[ $WRITE_CHANGED -eq 0 ]] && { ok "sshd 并发上限已是最新"; return 0; }

  if sshd -t >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    ok "已抬高 sshd 并发上限：$(sshd -T 2>/dev/null | grep -i '^maxstartups' || echo 'MaxStartups 100:30:200')"
  else
    rm -f "$drop"
    warn "sshd 配置校验失败，已回滚（保持系统默认）"
  fi
  return 0
}

deploy_pull_user() {
  title "准备交换目录与拉取账号"

  if id "$PULL_USER" >/dev/null 2>&1; then
    ok "账号 $PULL_USER 已存在"
  else
    useradd -m -s /bin/bash "$PULL_USER" || die "创建账号 $PULL_USER 失败"
    ok "已创建账号 $PULL_USER"
  fi
  PUID="$(id -u "$PULL_USER")"
  PGID="$(id -g "$PULL_USER")"
  ok "PUID=$PUID PGID=${PGID}（容器以此身份写文件，Mac 直接可读）"

  mkdir -p "$EXCHANGE" "$EXCHANGE_USED"
  chown "$PULL_USER:$PULL_USER" "$EXCHANGE" "$EXCHANGE_USED"
  chmod 2775 "$EXCHANGE" "$EXCHANGE_USED"
  ok "待拉目录：$EXCHANGE"
  ok "已送达归档：$EXCHANGE_USED（Mac 拉走后 mv 到这里）"

  local home sshd ak
  home="$(getent passwd "$PULL_USER" | cut -d: -f6)"
  sshd="$home/.ssh"; ak="$sshd/authorized_keys"
  mkdir -p "$sshd"; chmod 700 "$sshd"
  touch "$ak"; chmod 600 "$ak"
  chown -R "$PULL_USER:$PULL_USER" "$sshd"

  if [[ -n "$MIRROR_PUBKEY" ]]; then
    if grep -qF "$MIRROR_PUBKEY" "$ak"; then
      ok "Mac mini 公钥已存在：$ak"
    else
      printf '%s\n' "$MIRROR_PUBKEY" >>"$ak"
      ok "Mac mini 公钥已写入：$ak"
    fi
  else
    warn "未提供 Mac 公钥；稍后手动追加到 $ak 即可"
  fi

  # 只允许密钥登录该账号，禁止密码
  local pw_status
  pw_status="$(passwd -S "$PULL_USER" 2>/dev/null | awk '{print $2}' || echo '')"
  [[ "$pw_status" == "L" || "$pw_status" == "NP" ]] || passwd -l "$PULL_USER" >/dev/null 2>&1 || true
  ok "账号 $PULL_USER 已锁定密码（仅允许密钥登录）"
}

#───────────────────────────────────────────────────────────────────────────────
# 7. 下载器（qBittorrent / aria2 / AriaNg）
#───────────────────────────────────────────────────────────────────────────────
compose() { docker compose -p nas-server --env-file "$APP/compose.env" -f "$APP/docker-compose.yml" "$@"; }

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
  dir="$APP/volumes/qbittorrent/qBittorrent"
  conf="$dir/qBittorrent.conf"
  # 已有配置就别覆盖（容器自己会往里面写状态）；换口令请用 reconfigure
  if [[ -f "$conf" && "$RECONFIGURE" != "1" ]]; then
    ok "qBittorrent 配置已存在，跳过预置"
    return 0
  fi
  mkdir -p "$dir"
  local hash
  if ! hash="$(qb_pbkdf2 "$QB_PASS")"; then
    warn "缺少 python3，无法预置 qBittorrent 口令，将使用容器日志里的临时密码"; return 0
  fi
  write_file "$conf" 0664 <<EOF
[LegalNotice]
Accepted=true

[BitTorrent]
Session\\DefaultSavePath=$DEFAULT_SAVE_DIR
Session\\TempPath=$DEFAULT_SAVE_DIR
Session\\TempPathEnabled=false
Session\\Port=$QB_BT_PORT
Session\\QueueingSystemEnabled=true
Session\\MaxActiveDownloads=5
Session\\MaxActiveTorrents=8
Session\\MaxActiveUploads=5
Session\\GlobalMaxSeedingMinutes=-1
Session\\GlobalMaxRatio=-1
Session\\AppendExtension=true
Session\\Encryption=0
Session\\LSDEnabled=true
Session\\DHTEnabled=true
Session\\PeXEnabled=true
Session\\uTPEnabled=true
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
WebUI\\SessionTimeout=3600
WebUI\\AlternativeUIEnabled=false
WebUI\\HTTPS\\Enabled=false
WebUI\\ReverseProxySupportEnabled=false

Downloads\\SavePath=$DEFAULT_SAVE_DIR
Downloads\\TempPathEnabled=false
Downloads\\Preallocation=false
EOF
  chmod 664 "$conf"
  ok "已预置 qBittorrent 配置（用户 ${QB_USER}，下载目录 ${DEFAULT_SAVE_DIR}）"
}

# 把已存在的 qBittorrent 配置里的默认下载路径校正到 ${DEFAULT_SAVE_DIR}。
# 必须在容器停止后做：qB 退出时会把自己内存里的路径写回配置文件，先改会被覆盖。
qb_path_fix() {
  local conf="$APP/volumes/qbittorrent/qBittorrent/qBittorrent.conf"
  [[ -f "$conf" ]] || return 0
  # 只动那三个保存路径的键，不碰别的（qB 配置里可能有 /downloads 结尾的其它值）
  local changed=0
  for key in 'Session\\DefaultSavePath' 'Session\\TempPath' 'Downloads\\SavePath'; do
    [[ -n "$(sed -n "s@^${key}=\(.*\)@\1@p" "$conf")" ]] || continue
    sed -i "s@^${key}=.*@${key}=${DEFAULT_SAVE_DIR}@" "$conf"
    changed=1
  done
  [[ "$changed" = "1" ]] && ok "qBittorrent 的默认下载路径已设为 $DEFAULT_SAVE_DIR"
  return 0
}

# aria2 官方镜像每次启动都会执行 /etc/cont-init.d/28-fix，里面有一行
#   sed -i "s@^\(dir=\).*@\1/downloads@" /config/aria2.conf
# 把下载目录强写回 /downloads（= 挂载的 OpenList 临时目录）。我们的默认下载目录是
# ${DEFAULT_SAVE_DIR}，所以得在它之后再把 dir 钉回来 —— 否则 aria2 会安静地下到
# OpenList 的临时目录里（Mac 永远拉不到）。
# 做法：写一个排号 99 的 cont-init 脚本挂进容器，字典序排在 28-fix 之后执行；
# 不复制、不篡改镜像自带脚本。
aria2_init_patch() {
  local dir="$APP/volumes/aria2-init"
  mkdir -p "$dir"
  write_file "$dir/99-aria2-dir" 0755 < <(emit aria2_dir_hook)
  # 宿主机上的配置文件也改一致，方便直接看文件
  local conf="$APP/volumes/aria2/aria2.conf"
  [[ -f "$conf" ]] && sed -i "s@^dir=.*@dir=$DEFAULT_SAVE_DIR@" "$conf"
  local sconf="$APP/volumes/aria2/script.conf"
  [[ -f "$sconf" ]] && sed -i "s@^dest-dir=.*@dest-dir=$DEFAULT_SAVE_DIR/completed@" "$sconf"
  ok "aria2 启动钩子就绪（默认下载目录钉在 ${DEFAULT_SAVE_DIR}）"
  return 0
}

# 归档助手 + 环境文件（助手以 nas 用户跑，读不到 600 的 nas-server.conf，
# 所以单独给一份 640 root:nas 的最小配置）
deploy_archive_helper() {
  write_file "$APP/archive.sh" 0755 < <(emit archive_helper)
  write_file "$APP/archive.env" 0640 <<EOF
# 由 nas-server.sh 生成：归档助手（以 $PULL_USER 用户运行）用的最小配置
EXCHANGE=$EXCHANGE
EXCHANGE_USED=$EXCHANGE_USED
# qB API 给的是容器内路径，检查文件是否存在时要映射回宿主机路径
MAC_DIR=$MAC_DIR
DOWNLOAD_SRC=$DOWNLOAD_SRC
QB_WEBUI_PORT=$QB_WEBUI_PORT
QB_USER=$QB_USER
QB_PASS=$QB_PASS
EOF
  chown "root:$PULL_USER" "$APP/archive.env" 2>/dev/null || true
  chmod 0640 "$APP/archive.env" 2>/dev/null || true
  ok "归档助手就绪：$APP/archive.sh（归档 + 清理内容已搬空的 qB 种子）"
}

# 真正落实：问 aria2 RPC 它当前生效的 dir 是什么
aria2_dir_check() {
  local out plain
  out="$(curl -s --max-time 10 "http://127.0.0.1:$ARIA2_RPC_PORT/jsonrpc" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"nas\",\"method\":\"aria2.getGlobalOption\",\"params\":[\"token:$ARIA2_RPC_SECRET\"]}" 2>/dev/null || true)"
  # JSON 会把路径里的 / 转义成 \/（"dir":"\/Mac"），先去转义再比对
  plain="$(printf '%s' "$out" | tr -d '\\')"
  if [[ "$plain" == *"\"dir\":\"$DEFAULT_SAVE_DIR\""* ]]; then
    ok "aria2 生效的下载目录：$DEFAULT_SAVE_DIR"
  elif [[ -n "$out" ]]; then
    warn "aria2 生效的下载目录不是 ${DEFAULT_SAVE_DIR}（钩子丢了？重跑脚本）：$(printf '%s' "$out" | grep -o '"dir":"[^"]*"')"
  else
    warn "aria2 RPC 无响应，跳过下载目录校验"
  fi
}

# qB 必须给「未完成文件」加 .!qB 后缀。否则它预分配的文件在磁盘上就是满大小，
# Mac 用「远端大小 == 本地大小」判断是否送达会误判：会把没下完的文件当成下完的拉走，
# 并把服务器上的源文件归档（剩下那部分就永远拿不到了）。
# 各版本配置键名不一致，这里统一用 WebUI API 校正，幂等。
qb_ensure_incomplete_ext() {
  local jar; jar="$(mktemp)"
  curl -sS --max-time 15 -c "$jar" -H "Referer: http://127.0.0.1:$QB_WEBUI_PORT/" \
    --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
    "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/auth/login" >/dev/null 2>&1 || true
  local prefs cur
  prefs="$(curl -sS --max-time 15 -b "$jar" "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/app/preferences" 2>/dev/null || true)"
  [[ -n "$prefs" ]] || { rm -f "$jar"; return 0; }   # 登录失败时 qb_login_check 已经报过了
  cur="$(printf '%s' "$prefs" | grep -o '"incomplete_files_ext":[a-z]*' | cut -d: -f2)"
  if [[ "$cur" == "true" ]]; then
    ok "qBittorrent 已开启「未完成文件加 .!qB 后缀」"
  else
    curl -sS --max-time 15 -b "$jar" -X POST -H "Referer: http://127.0.0.1:$QB_WEBUI_PORT/" \
      --data-urlencode 'json={"incomplete_files_ext":true}' \
      "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/app/setPreferences" >/dev/null 2>&1 || true
    ok "已打开 qBittorrent 的「未完成文件加 .!qB 后缀」（防止 Mac 拉到半成品）"
  fi
  rm -f "$jar"
}

qb_dir_check() {
  local jar; jar="$(mktemp)"
  curl -sS --max-time 15 -c "$jar" -H "Referer: http://127.0.0.1:$QB_WEBUI_PORT/" \
    --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
    "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/auth/login" >/dev/null 2>&1 || true
  local p
  p="$(curl -sS --max-time 15 -b "$jar" "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/app/preferences" 2>/dev/null || true)"
  rm -f "$jar"
  # 没拿到偏好设置就闭嘴：登录失败时 qb_login_check 已经报过一次了
  [[ "$p" == *'"save_path"'* ]] || return 0
  case "$p" in
    *"\"save_path\":\"$DEFAULT_SAVE_DIR\""*) ok "qBittorrent 生效的下载目录：$DEFAULT_SAVE_DIR" ;;
    *) warn "qBittorrent 生效的下载目录不是 ${DEFAULT_SAVE_DIR}（面板里可改：设置 → 下载 → 默认保存路径）" ;;
  esac
}

deploy_downloaders() {
  title "部署下载器（qBittorrent / aria2 / AriaNg）"
  mkdir -p "$APP/volumes/qbittorrent" "$APP/volumes/aria2" "$APP/volumes/ariang"
  qb_preseed

  write_file "$APP/docker-compose.yml" 0644 < <(emit compose)
  write_file "$APP/compose.env" 0600 < <(emit compose_env)
  ok "已生成 $APP/docker-compose.yml"

  sub "拉取镜像并启动容器"
  compose pull --quiet 2>/dev/null || warn "部分镜像拉取失败，继续尝试启动"

  # 先停：qB 退出时会用内存里的旧路径覆盖配置文件，必须在它停下之后才改
  compose down --remove-orphans >/dev/null 2>&1 || true
  qb_path_fix
  aria2_init_patch

  # /downloads 的源目录（OpenList 的临时目录）必须先建好并交给容器身份：
  # 挂载源不存在时 Docker 会自动建一个 root:root 的目录，容器里的下载器
  # （以 PUID=$PUID 运行）就写不进去，表现为「下载完成但文件不见」。
  mkdir -p "$DOWNLOAD_SRC"
  if [[ "$DOWNLOAD_SRC" == "$OPENLIST_DIR/"* ]]; then
    # 别把 OpenList 的数据目录权限放松了，里面有 config.json 和 data.db
    chmod 700 "$(dirname "$DOWNLOAD_SRC")" 2>/dev/null || true
  fi
  chown "$PUID:$PGID" "$DOWNLOAD_SRC" 2>/dev/null || true
  chmod 2775 "$DOWNLOAD_SRC" 2>/dev/null || true

  # OpenList 以 root 运行，会在临时目录下建 <temp>/qBittorrent/<任务ID> 这类子目录，
  # 再把【宿主机绝对路径】交给下载器。下载器以 PUID 运行，而 root 建的目录默认 755，
  # 它进不去也写不了 —— qB 日志里就是 file_open(...) error: Permission denied。
  # 给目录挂一条默认 ACL，之后 root 新建的子目录/文件会自动带上 PUID 的权限，
  # 不必把下载器改成 root 运行。
  if have setfacl; then
    setfacl -m "u:$PUID:rwx" -m "d:u:$PUID:rwx" -m "d:g:$PGID:rwx" "$DOWNLOAD_SRC" 2>/dev/null \
      || warn "setfacl 失败：OpenList 的离线下载可能仍报 Permission denied"
    ok "已给 $DOWNLOAD_SRC 加默认 ACL（新建子目录自动允许 uid $PUID 写入）"
  else
    warn "缺少 setfacl：OpenList 离线下载到容器可能报 Permission denied"
  fi
  ok "下载目录就绪：${DOWNLOAD_SRC}（容器内 /downloads 与 ${DOWNLOAD_SRC}，属主 $PUID:${PGID}）"
  deploy_archive_helper

  compose up -d --remove-orphans

  sub "等待服务就绪"
  local i code
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$QB_WEBUI_PORT/" 2>/dev/null || true)"
    [[ "${code:-000}" != "000" ]] && { ok "qBittorrent WebUI 已响应（HTTP ${code}）"; break; }
    sleep 2
  done
  for i in $(seq 1 30); do port_in_use "$ARIA2_RPC_PORT" && { ok "aria2 RPC 已监听 $ARIA2_RPC_PORT"; break; }; sleep 2; done
  for i in $(seq 1 30); do port_in_use "$ARIANG_PORT" && { ok "AriaNg 已监听 $ARIANG_PORT"; break; }; sleep 2; done

  if qb_login_check; then
    ok "qBittorrent 口令校验通过（用户 ${QB_USER}）"
  else
    warn "qBittorrent 口令校验未通过：可访问面板确认，或重跑 sudo $0 reconfigure"
  fi

  # 校验两个下载器真的把文件往挂载目录写，而不是往容器内部
  qb_dir_check
  qb_ensure_incomplete_ext
  aria2_dir_check

  local c st
  for c in nas-qbittorrent nas-aria2 nas-ariang; do
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
    [[ "$st" == running ]] && ok "$c 运行中" || warn "$c 状态：$st"
  done
}

qb_login_check() {
  local jar; jar="$(mktemp)"
  curl -sS --max-time 15 -c "$jar" \
    -H "Referer: http://127.0.0.1:$QB_WEBUI_PORT/" \
    --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
    "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/auth/login" >/dev/null 2>&1 || true
  local okflag=1
  [[ -s "$jar" ]] && grep -q 'QBT_SID' "$jar" && okflag=0
  rm -f "$jar"
  return $okflag
}

#───────────────────────────────────────────────────────────────────────────────
# 8. OpenList（官方一键脚本）
#───────────────────────────────────────────────────────────────────────────────
install_openlist() {
  title "安装 OpenList（官方一键脚本）"
  # 已装就跳过。官方脚本对「已存在的安装目录」会先 rm -rf 再恢复 data/：
  #   1) 容器里的 /downloads 正指着 ${DEF_DOWNLOAD_SRC}，目录被重建会让运行中的容器
  #      绑到一个已删除的旧 inode —— 文件照写，宿主机上却再也找不到；
  #   2) 中间那段时间下载的文件靠它的备份/恢复兜着，能不冒险就不冒险。
  # 要升级 OpenList 就手动跑一次官方脚本的 update。
  if [[ -x "$OPENLIST_DIR/openlist" ]] && systemctl cat openlist >/dev/null 2>&1; then
    ok "OpenList 已安装（${OPENLIST_DIR}/openlist），跳过重装"
    say "如需升级： bash install-openlist-v4.sh update"
    systemctl enable --now openlist >/dev/null 2>&1 || true
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  say "下载官方脚本： https://res.oplist.org/script/v4.sh"
  http_download "https://res.oplist.org/script/v4.sh" "$tmp/install-openlist-v4.sh" \
    || { rm -rf "$tmp"; die "下载 OpenList 官方脚本失败"; }

  say "执行官方命令： bash install-openlist-v4.sh install /opt"
  say "（官方脚本会问一次 GitHub 代理，这里自动回车＝不使用代理）"
  ( cd "$tmp" && printf '\n' | bash ./install-openlist-v4.sh install /opt ) \
    || { rm -rf "$tmp"; die "OpenList 官方安装失败"; }
  rm -rf "$tmp"

  [[ -x "$OPENLIST_DIR/openlist" ]] || die "官方脚本执行完但找不到 $OPENLIST_DIR/openlist"
  ok "OpenList 二进制安装完成（${OPENLIST_DIR}）"
  systemctl enable --now openlist >/dev/null 2>&1 || true
}

configure_openlist() {
  sub "配置 OpenList"
  local cfg="$OPENLIST_DIR/data/config.json" i
  for i in $(seq 1 30); do [[ -f "$cfg" ]] && break; sleep 1; done
  if [[ -f "$cfg" ]]; then
    python3 - "$cfg" "$OPENLIST_PORT" <<'PY' || true
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
with open(path, encoding='utf-8') as f:
    data = json.load(f)
s = data.setdefault('scheme', {})
changed = False
if s.get('address') != '127.0.0.1':
    s['address'] = '127.0.0.1'; changed = True
if int(s.get('http_port') or 0) != port:
    s['http_port'] = port; changed = True
if changed:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
PY
    ok "OpenList 监听已设为 127.0.0.1:$OPENLIST_PORT"
    systemctl restart openlist >/dev/null 2>&1 || true; sleep 3
  else
    warn "未找到 ${cfg}，跳过监听地址调整"
  fi

  if ( cd "$OPENLIST_DIR" && ./openlist admin set "$OPENLIST_PASS" >/dev/null 2>&1 ); then
    ok "OpenList 管理员口令已设置（用户 ${OPENLIST_USER}）"
  else
    warn "OpenList 口令设置失败，可执行： cd $OPENLIST_DIR && ./openlist admin set '<新口令>'"
  fi

  local i
  for i in $(seq 1 30); do port_in_use "$OPENLIST_PORT" && { ok "OpenList 已监听 $OPENLIST_PORT"; return 0; }; sleep 2; done
  warn "OpenList 端口 $OPENLIST_PORT 未监听： systemctl status openlist"
}

#───────────────────────────────────────────────────────────────────────────────
# 9. Caddy + HTTPS
#───────────────────────────────────────────────────────────────────────────────
ensure_caddy() {
  if have caddy; then ok "Caddy 已安装：$(caddy version 2>/dev/null)"; return 0; fi
  warn "未检测到 Caddy，从官方仓库安装"
  have apt-get || die "未安装 Caddy 且非 Debian 系，请手动安装后重跑"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg || die "Caddy 源密钥导入失败"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    >/etc/apt/sources.list.d/caddy-stable.list || die "Caddy 源写入失败"
  apt-get update -qq || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy || die "Caddy 安装失败"
  ok "Caddy 安装完成"
}

deploy_caddy() {
  title "配置 Caddy 域名与 HTTPS"
  ensure_caddy
  mkdir -p /etc/caddy/conf.d
  write_file "$CADDY_SITE" 0644 < <(emit caddy)
  if ! caddy validate --adapter caddyfile --config "$CADDY_SITE" >/dev/null 2>&1; then
    caddy validate --adapter caddyfile --config "$CADDY_SITE" 2>&1 | sed 's/^/    /' | head -20
    die "Caddy 站点片段语法校验失败"
  fi
  ok "已写入 $CADDY_SITE 并通过语法校验"

  touch "$CADDY_MAIN"
  if grep -qF "$CADDY_IMPORT" "$CADDY_MAIN"; then
    ok "$CADDY_MAIN 已包含 import 行"
  else
    [[ -f "$CADDY_MAIN.nassrv.bak" ]] || cp -a "$CADDY_MAIN" "$CADDY_MAIN.nassrv.bak" 2>/dev/null || true
    { [[ -s "$CADDY_MAIN" ]] && printf '\n'; printf '# nas-server 追加：加载本项目站点配置\n%s\n' "$CADDY_IMPORT"; } >>"$CADDY_MAIN"
    ok "已在 $CADDY_MAIN 追加 import 行（备份：$CADDY_MAIN.nassrv.bak）"
  fi

  if ! caddy validate --adapter caddyfile --config "$CADDY_MAIN" >/dev/null 2>&1; then
    warn "整体 Caddyfile 校验失败："
    caddy validate --adapter caddyfile --config "$CADDY_MAIN" 2>&1 | sed 's/^/    /' | head -20
    [[ -f "$CADDY_MAIN.nassrv.bak" ]] && { cp -f "$CADDY_MAIN.nassrv.bak" "$CADDY_MAIN"; warn "已回滚 $CADDY_MAIN"; }
    die "Caddy 配置校验失败，未执行 reload"
  fi

  if svc_active caddy; then
    systemctl reload caddy 2>/dev/null && ok "Caddy 已热加载" || { systemctl restart caddy && ok "Caddy 已重启"; }
  else
    systemctl enable --now caddy >/dev/null 2>&1 || true; ok "Caddy 已启动"
  fi
}

#───────────────────────────────────────────────────────────────────────────────
# 10. hysteria2 服务端（纯 UDP）
#───────────────────────────────────────────────────────────────────────────────
install_hy2() {
  if have hysteria && [[ -f /etc/systemd/system/$HY2_SERVICE ]]; then
    ok "hysteria2 已安装：$(hysteria version 2>/dev/null | head -1)"
    return 0
  fi
  say "使用 hysteria2 官方脚本安装： https://get.hy2.sh/"
  http_download https://get.hy2.sh/ /tmp/get-hy2.sh || die "下载 hysteria2 官方脚本失败"
  # 官方脚本会写一份示例 config.yaml 并创建 hysteria-server.service
  bash /tmp/get-hy2.sh || die "hysteria2 安装失败"
  rm -f /tmp/get-hy2.sh
  ok "hysteria2 安装完成"
}

# 从 Caddy 的证书存储里找某个域名的证书
find_caddy_cert() {
  local d="$1" base="/var/lib/caddy/.local/share/caddy/certificates" f
  FOUND_CRT=""; FOUND_KEY=""
  [[ -d "$base" ]] || return 1
  FOUND_CRT="$(find "$base" -type f -name "$d.crt" 2>/dev/null | head -1)"
  FOUND_KEY="$(find "$base" -type f -name "$d.key" 2>/dev/null | head -1)"
  [[ -n "$FOUND_CRT" && -n "$FOUND_KEY" ]]
}

sync_hy2_cert() {
  local changed=0
  mkdir -p "$TLS_DIR"; chmod 750 "$TLS_DIR"
  # 兜底：旧版本可能把上级目录留成 700，导致 hysteria 用户读不到证书
  chmod 711 "$(dirname "$TLS_DIR")" 2>/dev/null || true
  if getent group hysteria >/dev/null 2>&1; then chgrp hysteria "$TLS_DIR" 2>/dev/null || true; fi

  if find_caddy_cert "$HY2_SNI"; then
    if [[ ! -f "$TLS_DIR/hy2.crt" ]] || ! cmp -s "$FOUND_CRT" "$TLS_DIR/hy2.crt"; then
      cp -f "$FOUND_CRT" "$TLS_DIR/hy2.crt"; changed=1
    fi
    if [[ ! -f "$TLS_DIR/hy2.key" ]] || ! cmp -s "$FOUND_KEY" "$TLS_DIR/hy2.key"; then
      cp -f "$FOUND_KEY" "$TLS_DIR/hy2.key"; changed=1
    fi
  else
    if [[ ! -f "$TLS_DIR/hy2.crt" || ! -f "$TLS_DIR/hy2.key" ]]; then
      warn "Caddy 尚未签发 $HY2_SNI 的证书，先生成自签证书兜底"
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$TLS_DIR/hy2.key" -out "$TLS_DIR/hy2.crt" -days 3650 -nodes \
        -subj "/CN=$HY2_SNI" >/dev/null 2>&1 || die "生成自签证书失败"
      changed=1
    fi
  fi

  chmod 640 "$TLS_DIR/hy2.crt" "$TLS_DIR/hy2.key"
  if getent group hysteria >/dev/null 2>&1; then
    chown root:hysteria "$TLS_DIR/hy2.crt" "$TLS_DIR/hy2.key" 2>/dev/null || true
  fi
  return $(( changed == 1 ? 0 : 1 ))
}

deploy_hy2() {
  title "部署 hysteria2 服务端（纯 UDP）"
  install_hy2

  sub "准备 TLS 证书"
  local i
  for i in $(seq 1 20); do
    find_caddy_cert "$HY2_SNI" && break
    say "等待 Caddy 为 $HY2_SNI 签发证书…（$i/20）"; sleep 6
  done
  sync_hy2_cert && ok "证书已同步到 $TLS_DIR" || ok "证书已是最新"

  sub "写入 hysteria2 配置"
  write_file "$HY2_CONF" 0644 < <(emit hy2)
  chmod 640 "$HY2_CONF"
  if getent group hysteria >/dev/null 2>&1; then chown root:hysteria "$HY2_CONF" 2>/dev/null || true; fi
  ok "已写入 $HY2_CONF"

  systemctl daemon-reload
  systemctl enable "$HY2_SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$HY2_SERVICE" >/dev/null 2>&1 || true
  sleep 3

  if svc_active "$HY2_SERVICE"; then
    ok "hysteria2 运行中：UDP :${HY2_PORT}（SNI=${HY2_SNI}）"
  else
    warn "hysteria2 未运行： journalctl -u $HY2_SERVICE -n 50"
  fi

  # 证书续期后自动同步
  write_file "$APP/sync-hy2-cert.sh" 0755 < <(emit sync_cert)
  write_file "/etc/systemd/system/nas-server-cert-sync.service" 0644 < <(emit unit_cert_sync)
  write_file "/etc/systemd/system/nas-server-cert-sync.timer" 0644 < <(emit unit_cert_sync_timer)
  svc_reload
  systemctl enable --now nas-server-cert-sync.timer >/dev/null 2>&1 || true
  ok "已启用证书同步定时器（每天检查一次）"
}

#───────────────────────────────────────────────────────────────────────────────
# 11. 交换目录清理
#───────────────────────────────────────────────────────────────────────────────
deploy_cleanup() {
  title "配置交换目录定时清理"
  mkdir -p "$STATE"
  write_file "$APP/cleanup.sh" 0755 < <(emit cleanup)
  write_file "/etc/systemd/system/nas-server-cleanup.service" 0644 < <(emit unit_cleanup)
  write_file "/etc/systemd/system/nas-server-cleanup.timer" 0644 < <(emit unit_cleanup_timer)
  svc_reload
  systemctl enable --now nas-server-cleanup.timer >/dev/null 2>&1 || true
  if svc_active nas-server-cleanup.timer; then
    ok "清理定时器已启用：每 ${CLEANUP_INTERVAL} 检查一次"
  say "  已送达归档 $EXCHANGE_USED：超过 ${RETENTION_MINUTES} 分钟删除"
  say "  待拉目录   $EXCHANGE：超过 ${INBOX_RETENTION_MINUTES} 分钟删除"
  else
    warn "清理定时器未启用： systemctl status nas-server-cleanup.timer"
  fi
}

#───────────────────────────────────────────────────────────────────────────────
# 12. 内置生成物
#───────────────────────────────────────────────────────────────────────────────
emit() {
  case "$1" in
  compose)
    cat <<EOF
# 由 nas-server.sh 生成，重跑脚本会覆盖本文件
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: nas-qbittorrent
    environment:
      PUID: "\${PUID}"
      PGID: "\${PGID}"
      TZ: "\${TZ}"
      WEBUI_PORT: "\${QB_WEBUI_PORT}"
      TORRENTING_PORT: "\${QB_BT_PORT}"
    volumes:
      - "\${APP}/volumes/qbittorrent:/config"
      - "\${DOWNLOAD_SRC}:/downloads"
      # OpenList 的「离线下载」会把**宿主机绝对路径**（<temp_dir>/qBittorrent/<任务ID>）
      # 原样交给下载器，所以容器里必须存在同名路径，否则下载器会去建 /opt/... 而失败。
      - "\${DOWNLOAD_SRC}:\${DOWNLOAD_SRC}"
      - "\${EXCHANGE}:\${MAC_DIR}"
    ports:
      - "\${BIND_LOCAL}:\${QB_WEBUI_PORT}:\${QB_WEBUI_PORT}"
      - "\${QB_BT_PORT}:\${QB_BT_PORT}/tcp"
      - "\${QB_BT_PORT}:\${QB_BT_PORT}/udp"
    restart: unless-stopped

  aria2:
    image: p3terx/aria2-pro
    container_name: nas-aria2
    environment:
      PUID: "\${PUID}"
      PGID: "\${PGID}"
      TZ: "\${TZ}"
      RPC_SECRET: "\${ARIA2_RPC_SECRET}"
      RPC_PORT: "\${ARIA2_RPC_PORT}"
      LISTEN_PORT: "\${ARIA2_BT_PORT}"
      DISK_CACHE: "64M"
      IPV6_MODE: "false"
      UPDATE_TRACKERS: "true"
      SPECIAL_MODE: "false"
    volumes:
      - "\${APP}/volumes/aria2:/config"
      - "\${DOWNLOAD_SRC}:/downloads"
      # OpenList 的「离线下载」会把**宿主机绝对路径**（<temp_dir>/qBittorrent/<任务ID>）
      # 原样交给下载器，所以容器里必须存在同名路径，否则下载器会去建 /opt/... 而失败。
      - "\${DOWNLOAD_SRC}:\${DOWNLOAD_SRC}"
      - "\${EXCHANGE}:\${MAC_DIR}"
      # aria2 镜像每次启动都把 dir 写回 /downloads，这个钩子排在它之后把 dir 钉回
      # 默认下载目录，否则 aria2 下完的文件会落在 OpenList 临时目录里、Mac 拉不到
      - "\${APP}/volumes/aria2-init/99-aria2-dir:/etc/cont-init.d/99-aria2-dir:ro"
    ports:
      - "\${BIND_LOCAL}:\${ARIA2_RPC_PORT}:\${ARIA2_RPC_PORT}"
      - "\${ARIA2_BT_PORT}:\${ARIA2_BT_PORT}/tcp"
      - "\${ARIA2_BT_PORT}:\${ARIA2_BT_PORT}/udp"
    restart: unless-stopped

  ariang:
    image: p3terx/ariang
    container_name: nas-ariang
    command: --port 6880
    ports:
      - "\${BIND_LOCAL}:\${ARIANG_PORT}:6880"
    restart: unless-stopped
EOF
    ;;
  archive_helper)
    cat <<'EOS'
#!/usr/bin/env bash
# 由 nas-server.sh 生成：处理「已送达」的文件
#   1) 把待拉目录里的文件 mv 进归档目录（保留子目录结构）
#   2) 把 qBittorrent 里「数据已经被搬空」的种子从面板删掉（只删种子，不删文件）
#
# 为什么删种子：归档后 qB 会把这些种子标成 missingFiles（做种数据没了）。不删的话，
# 仍在下载中的多文件种子可能把已归档的那部分重新下载，形成「传了又下」的循环。
#
# 删除条件（三个都满足才删，宁可不删也不误删）：
#   1) 状态不在下载类（下载中/排队/校验中/暂停中一律不碰）
#   2) 进度 100%（没下完的绝不删）
#   3) 它的**每一个文件**在磁盘上都不存在（用文件列表逐个核对，不看 content_path）
#
# 用法： archive.sh [--dry-run]                  从 stdin 读 NUL 分隔的相对路径并归档
#        archive.sh --prune-torrents [--dry-run] 不搬文件，只清理数据已搬空的种子
set -uo pipefail

ARCHIVE_ENV="${ARCHIVE_ENV:-/opt/nas-server/archive.env}"
if [[ ! -r "$ARCHIVE_ENV" ]]; then echo "NOENV"; exit 1; fi
set -a; . "$ARCHIVE_ENV"; set +a

EXCHANGE="${EXCHANGE:-/opt/nas}"
EXCHANGE_USED="${EXCHANGE_USED:-/opt/nas-used}"
QB_WEBUI_PORT="${QB_WEBUI_PORT:-8080}"
QB_USER="${QB_USER:-admin}"

DRY=0; MODE=move
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --prune-torrents) MODE=prune ;;
  esac
done

moved=0
if [[ "$MODE" = move ]]; then
  cd "$EXCHANGE" 2>/dev/null || { echo NOINBOX; exit 0; }
  while IFS= read -r -d '' r; do
    [[ -n "$r" ]] || continue
    d="$(dirname "$r")"
    if [[ "$DRY" = "1" ]]; then echo "DRY-FILE:$r"; moved=$((moved+1)); continue; fi
    mkdir -p "$EXCHANGE_USED/$d" 2>/dev/null
    if mv -f -- "$r" "$EXCHANGE_USED/$r" 2>/dev/null; then
      moved=$((moved+1))
    else
      echo "FAIL:$r"
    fi
  done
  echo "MOVED:$moved"
fi

# ---- 清理「数据已搬空」的种子 ----
deleted=0
jar="$(mktemp)"
qapi() { curl -sS --max-time 15 -b "$jar" "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/$1" 2>/dev/null || true; }

if curl -sS --max-time 15 -c "$jar" -H "Referer: http://127.0.0.1:$QB_WEBUI_PORT/" \
     --data-urlencode "username=$QB_USER" --data-urlencode "password=${QB_PASS:-}" \
     "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/auth/login" >/dev/null 2>&1; then
  # 候选：非下载中 且 进度 100%
  cands="$(qapi torrents/info | python3 -c '
import json, sys
DL = {"downloading","forcedDL","metaDL","allocating","checkingDL","queuedDL",
      "stalledDL","pausedDL","moving","checkingResumeData","unknown"}
try:
    ts = json.load(sys.stdin)
except Exception:
    ts = []
for t in ts:
    if t.get("state") in DL:
        continue
    try:
        if float(t.get("progress") or 0) < 1.0:
            continue
    except Exception:
        continue
    print(t["hash"], t.get("save_path",""))' 2>/dev/null || true)"
  while read -r h sp; do
    [[ -n "$h" ]] || continue
    # 这个种子的每个文件都必须在磁盘上不存在，才认为「数据已搬空」
    # qB 给的是容器内路径（/Mac、/downloads），要映射回宿主机路径再判断
    sp_host="$(printf '%s' "$sp" | sed "s#^${MAC_DIR:-/Mac}#$EXCHANGE#; s#^/downloads#$DOWNLOAD_SRC#")"
    gone="$(qapi "torrents/files?hash=$h" | SP="$sp_host" python3 -c '
import json, os, sys
sp = os.environ.get("SP", "")
try:
    fs = json.load(sys.stdin)
except Exception:
    print("0"); raise SystemExit
if not fs:
    print("0"); raise SystemExit
for f in fs:
    p = os.path.join(sp, f.get("name", ""))
    if os.path.exists(p):
        print("0"); raise SystemExit
print("1")' 2>/dev/null || echo 0)"
    if [[ "$gone" = "1" ]]; then
      if [[ "$DRY" = "1" ]]; then echo "DRY-DEL:$h"; deleted=$((deleted+1)); continue; fi
      # 注意：qB 有时会在返回响应前断连，curl 会报非 0，但删除其实已经生效，
      # 所以这里按「已发请求」计数（qB 日志是最终依据）。
      curl -sS --max-time 15 -b "$jar" -X POST -H "Referer: http://127.0.0.1:$QB_WEBUI_PORT/" \
           --data-urlencode "hashes=$h" --data 'deleteFiles=false' \
           "http://127.0.0.1:$QB_WEBUI_PORT/api/v2/torrents/delete" >/dev/null 2>&1 || true
      deleted=$((deleted+1))
    fi
  done <<< "$cands"
fi
rm -f "$jar"
echo "TORRENTS-DELETED:$deleted"
EOS
    ;;
  aria2_dir_hook)
    cat <<EOF
#!/usr/bin/with-contenv bash
# 由 nas-server.sh 生成，挂到容器 /etc/cont-init.d/99-aria2-dir。
# 镜像自带的 28-fix 每次启动都会把 dir 写成 /downloads；本脚本排号 99，排在它之后执行，
# 把默认下载目录钉回 ${DEFAULT_SAVE_DIR}（Mac 拉取的目录）。否则 aria2 会安静地下到
# OpenList 的临时目录里 —— 下得再快，Mac 也永远拉不到。
. /etc/init-base
[[ -n "\${ARIA2_CONF:-}" ]] || ARIA2_CONF=/config/aria2.conf
[[ -f "\$ARIA2_CONF" ]] && sed -i "s@^\\(dir=\\).*@\\1$DEFAULT_SAVE_DIR@" "\$ARIA2_CONF"
[[ -f /config/script.conf ]] && sed -i "s@^\\(dest-dir=\\).*@\\1$DEFAULT_SAVE_DIR/completed@" /config/script.conf
exit 0
EOF
    ;;
  compose_env)
    cat <<EOF
APP=$APP
EXCHANGE=$EXCHANGE
DOWNLOAD_SRC=$DOWNLOAD_SRC
MAC_DIR=$MAC_DIR
PUID=$PUID
PGID=$PGID
TZ=$TZ
QB_WEBUI_PORT=$QB_WEBUI_PORT
QB_BT_PORT=$QB_BT_PORT
ARIA2_RPC_PORT=$ARIA2_RPC_PORT
ARIA2_BT_PORT=$ARIA2_BT_PORT
ARIA2_RPC_SECRET=$ARIA2_RPC_SECRET
ARIANG_PORT=$ARIANG_PORT
BIND_LOCAL=$BIND_LOCAL
EOF
    ;;
  caddy)
    cat <<EOF
# 由 nas-server.sh 生成，重跑脚本会覆盖本文件。

# OpenList
$DOMAIN_OPENLIST {
	encode gzip
	reverse_proxy 127.0.0.1:$OPENLIST_PORT
}

# qBittorrent WebUI
$DOMAIN_QB {
	encode gzip
	reverse_proxy 127.0.0.1:$QB_WEBUI_PORT
}

# AriaNg（同域 /jsonrpc 反代到 aria2 RPC，浏览器无需跨域）
$DOMAIN_ARIA {
	encode gzip
	handle /jsonrpc* {
		reverse_proxy 127.0.0.1:$ARIA2_RPC_PORT
	}
	handle {
		reverse_proxy 127.0.0.1:$ARIANG_PORT
	}
}
EOF
    ;;
  hy2)
    cat <<EOF
# 由 nas-server.sh 生成，重跑脚本会覆盖本文件
listen: :$HY2_PORT

tls:
  cert: $TLS_DIR/hy2.crt
  key: $TLS_DIR/hy2.key

auth:
  type: password
  password: $HY2_PASS

masquerade:
  type: proxy
  proxy:
    url: https://$DOMAIN_OPENLIST
    rewriteHost: true
EOF
    ;;
  cleanup)
    cat <<'EOS'
#!/usr/bin/env bash
# 由 nas-server.sh 生成：按各自的保留时间清理两个目录
#   $EXCHANGE      待拉目录（还没被 Mac 拉走）         —— 默认 7 天（10080 分钟）
#   $EXCHANGE_USED 已送达归档（Mac 拉走后挪过来的）   —— 默认 24 小时（1440 分钟）
# 用法： cleanup.sh            正常清理
#        DRY_RUN=1 cleanup.sh  只打印不删
set -uo pipefail

CONF="${NAS_SERVER_CONF:-/etc/nas-server/nas-server.conf}"
[[ -r "$CONF" ]] || { echo "缺少配置 $CONF" >&2; exit 1; }
set -a; . "$CONF"; set +a

EXCHANGE="${EXCHANGE:-/opt/nas}"
EXCHANGE_USED="${EXCHANGE_USED:-/opt/nas-used}"
RETENTION_MINUTES="${RETENTION_MINUTES:-1440}"
INBOX_RETENTION_MINUTES="${INBOX_RETENTION_MINUTES:-10080}"
LOG="${CLEANUP_LOG:-/var/log/nas-server-cleanup.log}"
DRY="${DRY_RUN:-0}"

# 清理一个目录：超期文件 + 清空后残留的空目录
clean_one() {
  local dir="$1" mins="$2" n=0
  echo "[$(date '+%F %T')] ----- $dir（保留 ${mins} 分钟）-----"
  if [[ ! -d "$dir" ]]; then
    echo "  目录不存在，跳过"
    return 0
  fi
  while IFS= read -r -d '' f; do
    if [[ "$DRY" == "1" ]]; then echo "  [dry-run] 文件 $f"; continue; fi
    rm -rf -- "$f" && { echo "  删除文件 $f"; n=$((n+1)); }
  done < <(find "$dir" -mindepth 1 -type f -mmin +"$mins" -print0 2>/dev/null)

  while IFS= read -r -d '' d; do
    if [[ "$DRY" == "1" ]]; then echo "  [dry-run] 空目录 $d"; continue; fi
    rmdir -- "$d" 2>/dev/null && { echo "  删除空目录 $d"; n=$((n+1)); }
  done < <(find "$dir" -mindepth 1 -depth -type d -empty -print0 2>/dev/null)

  echo "  本目录处理 $n 项"
  return 0
}

{
  echo "[$(date '+%F %T')] ===== 清理开始 ====="
  clean_one "$EXCHANGE_USED" "$RETENTION_MINUTES"
  clean_one "$EXCHANGE" "$INBOX_RETENTION_MINUTES"
  echo "[$(date '+%F %T')] ===== 清理结束 ====="
} >>"$LOG" 2>&1
EOS
    ;;
  unit_cleanup)
    cat <<EOF
[Unit]
Description=清理 nas-server 目录（已送达归档 $RETENTION_MINUTES 分钟 / 待拉目录 $INBOX_RETENTION_MINUTES 分钟）
After=network.target

[Service]
Type=oneshot
ExecStart=$APP/cleanup.sh
EOF
    ;;
  unit_cleanup_timer)
    cat <<EOF
[Unit]
Description=定时清理 nas-server 交换目录

[Timer]
OnBootSec=10min
OnUnitActiveSec=$CLEANUP_INTERVAL
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    ;;
  sync_cert)
    cat <<'EOS'
#!/usr/bin/env bash
# 由 nas-server.sh 生成：把 Caddy 为 HY2_SNI 签发的证书同步给 hysteria2，变了就重启
set -uo pipefail

CONF="${NAS_SERVER_CONF:-/etc/nas-server/nas-server.conf}"
[[ -r "$CONF" ]] || exit 1
set -a; . "$CONF"; set +a

HY2_SNI="${HY2_SNI:?}"
TLS_DIR="${TLS_DIR:-/etc/nas-server/tls}"
SERVICE="${HY2_SERVICE:-hysteria-server.service}"
BASE="/var/lib/caddy/.local/share/caddy/certificates"

crt="$(find "$BASE" -type f -name "$HY2_SNI.crt" 2>/dev/null | head -1)"
key="$(find "$BASE" -type f -name "$HY2_SNI.key" 2>/dev/null | head -1)"
[[ -n "$crt" && -n "$key" ]] || exit 0

mkdir -p "$TLS_DIR"; chmod 750 "$TLS_DIR"
chmod 711 "$(dirname "$TLS_DIR")" 2>/dev/null || true
changed=0
if [[ ! -f "$TLS_DIR/hy2.crt" ]] || ! cmp -s "$crt" "$TLS_DIR/hy2.crt"; then cp -f "$crt" "$TLS_DIR/hy2.crt"; changed=1; fi
if [[ ! -f "$TLS_DIR/hy2.key" ]] || ! cmp -s "$key" "$TLS_DIR/hy2.key"; then cp -f "$key" "$TLS_DIR/hy2.key"; changed=1; fi
chmod 640 "$TLS_DIR/hy2.crt" "$TLS_DIR/hy2.key"
getent group hysteria >/dev/null 2>&1 && chown root:hysteria "$TLS_DIR/hy2.crt" "$TLS_DIR/hy2.key" 2>/dev/null || true

if [[ $changed -eq 1 ]]; then
  systemctl restart "$SERVICE" >/dev/null 2>&1 || true
  echo "[$(date '+%F %T')] 证书已更新并重启 $SERVICE"
fi
EOS
    ;;
  unit_cert_sync)
    cat <<EOF
[Unit]
Description=同步 Caddy 证书给 hysteria2

[Service]
Type=oneshot
ExecStart=$APP/sync-hy2-cert.sh
EOF
    ;;
  unit_cert_sync_timer)
    cat <<'EOT'
[Unit]
Description=每天同步一次 hysteria2 证书

[Timer]
OnBootSec=15min
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOT
    ;;
  *) die "未知的 --emit 目标：$1（可用：compose compose_env aria2_dir_hook archive_helper caddy hy2 cleanup unit_cleanup unit_cleanup_timer sync_cert unit_cert_sync unit_cert_sync_timer）" ;;
  esac
}

#───────────────────────────────────────────────────────────────────────────────
# 13. 报告 / 状态
#───────────────────────────────────────────────────────────────────────────────
report() {
  local ip; ip="$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || echo '<本机公网IP>')"
  title "部署完成"

  cat <<EOT

一、域名访问（Caddy 自动 HTTPS，证书自动续期）
   OpenList      https://$DOMAIN_OPENLIST
   qBittorrent   https://$DOMAIN_QB      用户 $QB_USER
   AriaNg        https://$DOMAIN_ARIA

二、口令（同时保存在 ${CONF}，权限 600）
   OpenList       用户 $OPENLIST_USER / 口令 $OPENLIST_PASS
   qBittorrent    用户 $QB_USER / 口令 $QB_PASS
   aria2 RPC 密钥 $ARIA2_RPC_SECRET

三、AriaNg 连接 aria2（打开 https://$DOMAIN_ARIA 后到「设置 → RPC」）
   协议 https | 主机 $DOMAIN_ARIA | 端口 443 | 路径 /jsonrpc | 密钥 $ARIA2_RPC_SECRET

四、交换目录（qb / aria2 都下载到这里）
   $EXCHANGE            （容器内路径 ${MAC_DIR}，给 Mac mini 拉取）
   $EXCHANGE -> $MAC_DIR       （容器内路径，qB/aria2 默认下载到这里，Mac 每 5 分钟拉走）
   $DOWNLOAD_SRC            （容器内路径 /downloads，OpenList 离线下载的中转目录）
   清理策略：最后修改时间超过 $RETENTION_MINUTES 分钟自动删除，每 $CLEANUP_INTERVAL 检查一次
   立即清理一次： sudo $0 cleanup

五、Mac mini 拉取通道（服务器端已就绪；Mac 端脚本你自己写）
   hysteria2 服务端 : UDP $ip:$HY2_PORT
   SNI              : $HY2_SNI
   认证密码         : $HY2_PASS
   TLS              : $TLS_DIR/hy2.crt（由 Caddy 证书同步而来）
   拉取账号         : $PULL_USER
   SSH 端口         : 22（建议 Mac 端 hy2 客户端用 tcpForwarding 把
                      127.0.0.1:2222 映射到服务器的 127.0.0.1:22，再用 rclone/rsync 连本地 2222）
   详细参数： sudo $0 macmini

六、端口映射（宿主机 -> 容器）
   OpenList      $BIND_LOCAL:$OPENLIST_PORT  ->  5244
   qB WebUI      $BIND_LOCAL:$QB_WEBUI_PORT  ->  $QB_WEBUI_PORT
   qB BT         $QB_BT_PORT/tcp+udp
   aria2 RPC     $BIND_LOCAL:$ARIA2_RPC_PORT ->  $ARIA2_RPC_PORT
   aria2 BT      $ARIA2_BT_PORT/tcp+udp
   AriaNg        $BIND_LOCAL:$ARIANG_PORT    ->  6880

常用命令
   sudo $0 status       查看状态
   sudo $0 ports        端口映射表
   sudo $0 cleanup      立即清理交换目录
   sudo $0 macmini      Mac mini 对接参数
   sudo $0 uninstall    卸载（保留交换目录数据）
   journalctl -u $HY2_SERVICE -n 100
EOT
}

show_ports() {
  conf_load 2>/dev/null || true; def_defaults
  printf '%-14s %-28s %s\n' "服务" "宿主机" "容器"
  printf '%-14s %-28s %s\n' "OpenList"  "$BIND_LOCAL:$OPENLIST_PORT" "5244"
  printf '%-14s %-28s %s\n' "qB WebUI"  "$BIND_LOCAL:$QB_WEBUI_PORT" "$QB_WEBUI_PORT"
  printf '%-14s %-28s %s\n' "qB BT"     "$QB_BT_PORT/tcp+udp" "$QB_BT_PORT"
  printf '%-14s %-28s %s\n' "aria2 RPC" "$BIND_LOCAL:$ARIA2_RPC_PORT" "$ARIA2_RPC_PORT"
  printf '%-14s %-28s %s\n' "aria2 BT"  "$ARIA2_BT_PORT/tcp+udp" "$ARIA2_BT_PORT"
  printf '%-14s %-28s %s\n' "AriaNg"    "$BIND_LOCAL:$ARIANG_PORT" "6880"
  printf '%-14s %-28s %s\n' "hysteria2" "UDP :$HY2_PORT" "-"
}

show_macmini() {
  conf_load 2>/dev/null || true; def_defaults
  local ip; ip="$(curl -4 -fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || echo '<公网IP>')"
  cat <<EOT
═══════════════════════════════════════════════════════════════════════════════
 Mac mini 侧对接参数（本脚本不生成 Mac 端脚本，这里只给参数）
═══════════════════════════════════════════════════════════════════════════════

【通道】纯 UDP 的 hysteria2（服务端已在本机跑起来）
  server      : $ip:$HY2_PORT        （UDP）
  auth        : $HY2_PASS
  tls.sni     : $HY2_SNI
  tls.insecure: 证书是 Caddy 签发的 LE 证书，正常校验即可（false）

【建议的用法】Mac 端 hy2 客户端里加一条本地转发，把服务器 SSH 拉到本地：
  tcpForwarding:
    - listen: 127.0.0.1:2222
      remote: 127.0.0.1:22
  然后 rclone / rsync / scp 直接连 127.0.0.1:2222 即可（等价于连服务器 22）。

【拉取账号】
  user        : $PULL_USER
  auth        : 仅公钥（服务器已写入你提供的公钥；没有的话把 Mac 公钥追加到
                ~$PULL_USER/.ssh/authorized_keys）

【拉什么、从哪拉】
  目录        : $EXCHANGE
  容器内路径  : ${MAC_DIR}（= 默认下载目录，Mac 从这里拉）
  /downloads  : ${DOWNLOAD_SRC}（OpenList 离线下载中转，Mac 不拉）
  清理        : 服务器上超过 $RETENTION_MINUTES 分钟没被改动的文件会被删除，
                所以 Mac 侧建议每 5 分钟拉一次，并做增量（只传新的/变了的）。

【自测顺序】
  1) Mac: hy2 客户端连上后， ssh -p 2222 $PULL_USER@127.0.0.1 'ls -la $EXCHANGE'
  2) Mac: rclone/rsync 拉一个文件下来，校验大小
  3) 服务器: ls -la $EXCHANGE   确认文件被取走（拉取不删除，删除由定时器负责）
EOT
}

show_status() {
  conf_load 2>/dev/null || true; def_defaults
  title "运行状态"
  local s
  for s in openlist caddy docker "$HY2_SERVICE"; do
    printf '  %-24s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
  done
  echo
  if have docker && docker info >/dev/null 2>&1; then
    docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep '^nas-' || echo "  （没有 nas-* 容器）"
  else
    warn "Docker 不可用"
  fi
  echo
  sub "定时器"
  systemctl list-timers --no-pager 2>/dev/null | grep -E 'nas-server|NEXT' || true
  echo
  sub "交换目录（${EXCHANGE}）"
  if [[ -d "$EXCHANGE" ]]; then
    du -sh "$EXCHANGE" 2>/dev/null || true
    find "$EXCHANGE" -mindepth 1 -maxdepth 1 | head -20
  else
    warn "目录不存在"
  fi
  echo
  sub "最近一次清理日志"
  tail -n 6 "$CLEANUP_LOG" 2>/dev/null || say "（暂无）"
  echo
  sub "hysteria2 最近日志"
  journalctl -u "$HY2_SERVICE" -n 8 --no-pager 2>/dev/null | tail -8 || true
}

do_cleanup() {
  need_root cleanup
  [[ -x "$APP/cleanup.sh" ]] || die "还没部署（找不到 $APP/cleanup.sh），先运行 sudo $0"
  DRY_RUN="${DRY_RUN:-0}" "$APP/cleanup.sh"
  ok "清理完成，日志：$CLEANUP_LOG"
  tail -n 8 "$CLEANUP_LOG" 2>/dev/null | sed 's/^/    /' || true
}

do_uninstall() {
  local purge=0 dry=0 a
  for a in "$@"; do
    case "$a" in
      --purge) purge=1 ;;
      --dry-run) dry=1 ;;
    esac
  done
  need_root uninstall
  run() { if [[ $dry -eq 1 ]]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

  title "卸载 nas-server"
  run systemctl disable --now nas-server-cleanup.timer nas-server-cleanup.service \
      nas-server-cert-sync.timer nas-server-cert-sync.service "$HY2_SERVICE" >/dev/null 2>&1 || true
  run systemctl disable --now openlist >/dev/null 2>&1 || true
  run rm -f /etc/systemd/system/nas-server-cleanup.timer /etc/systemd/system/nas-server-cleanup.service \
      /etc/systemd/system/nas-server-cert-sync.timer /etc/systemd/system/nas-server-cert-sync.service
  run svc_reload

  if have docker && docker info >/dev/null 2>&1; then
    if [[ $dry -eq 1 ]]; then printf '  [dry-run] docker compose down\n'
    else compose down --remove-orphans >/dev/null 2>&1 || true; fi
    say "容器已停止（镜像与卷保留）"
  fi

  [[ -f "$CADDY_SITE" ]] && { run rm -f "$CADDY_SITE"; say "删除 $CADDY_SITE"; }
  if [[ -f "$CADDY_MAIN" ]] && grep -qF "$CADDY_IMPORT" "$CADDY_MAIN"; then
    if [[ $dry -eq 1 ]]; then printf '  [dry-run] 从 %s 移除 import 行\n' "$CADDY_MAIN"
    else
      grep -vF "$CADDY_IMPORT" "$CADDY_MAIN" | grep -v 'nas-server 追加' >"$CADDY_MAIN.nassrv.tmp" || true
      mv -f "$CADDY_MAIN.nassrv.tmp" "$CADDY_MAIN"
      caddy validate --adapter caddyfile --config "$CADDY_MAIN" >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true
      say "已从 $CADDY_MAIN 移除 import 行并 reload"
    fi
  fi

  [[ -d "$APP" ]] && { run rm -rf "$APP"; say "删除 $APP"; }
  [[ -d /etc/nas-server ]] && { run rm -rf /etc/nas-server; say "删除 /etc/nas-server"; }
  [[ -d "$STATE" ]] && { run rm -rf "$STATE"; say "删除 $STATE"; }
  run rm -f "$LOG" "$CLEANUP_LOG"

  if [[ $purge -eq 1 ]]; then
    warn "将删除交换目录与 OpenList"
    if [[ $dry -eq 0 ]] && ! confirm "确认删除 $EXCHANGE 与 $OPENLIST_DIR ？" n; then die "已取消"; fi
    run rm -rf "$EXCHANGE" "$OPENLIST_DIR"; say "已删除 $EXCHANGE 与 $OPENLIST_DIR"
  fi

  title "卸载完成"
  cat <<EOT
已保留（如不需要请手动处理）：
  $EXCHANGE           下载/交换数据（--purge 可一并删除）
  $OPENLIST_DIR       OpenList 本体
  Docker 镜像与容器数据卷
  Caddy 与 hysteria2 本体

本机原有的 Caddy 站点未受影响。
EOT
}

#───────────────────────────────────────────────────────────────────────────────
# 14. 主流程
#───────────────────────────────────────────────────────────────────────────────
usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

install_all() {
  need_root install
  preflight_env
  preflight_deps

  if [[ -f "$CONF" && "$RECONFIGURE" != "1" ]]; then
    conf_load; def_defaults
    ok "复用已有配置 $CONF"
    say "如需修改请执行： sudo $0 reconfigure"
    conf_show
  else
    conf_load 2>/dev/null || true
    def_defaults
    prompt_all
    conf_save
    conf_show
  fi

  conf_load; def_defaults

  remove_legacy
  preflight_ports

  deploy_pull_user          # 先定 PUID/PGID
  conf_set "$CONF" PUID "$PUID"; conf_set "$CONF" PGID "$PGID"
  tune_sshd
  install_docker
  install_openlist
  configure_openlist
  # 下载器最后一个装：默认下载目录要靠 OpenList 的目录铺好之后再定，
  # 必须在 OpenList 把自己的目录铺好之后，才能把属主和权限定下来。
  deploy_downloaders
  deploy_caddy
  deploy_hy2
  deploy_cleanup

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
    cleanup)     do_cleanup ;;
    status)      show_status ;;
    ports)       show_ports ;;
    macmini)     show_macmini ;;
    uninstall)   shift || true; do_uninstall "$@" ;;
    --emit)      shift || true; [[ -n "${1:-}" ]] || die "用法： $0 --emit <name>"
                 conf_load 2>/dev/null || true; def_defaults; emit "$1" ;;
    --version|-V) echo "nas-server.sh $VERSION" ;;
    --help|-h)   usage ;;
    *)           usage; exit 1 ;;
  esac
}

trap 'err "执行失败：第 $LINENO 行 -> $BASH_COMMAND"' ERR
main "$@"
