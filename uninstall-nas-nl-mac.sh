#!/bin/bash
#===============================================================================
# NAS 荷兰机拉取 —— Mac 端 一键卸载 / 重置脚本
#
# 用途：
#   把 deploy-nas-nl-mac.sh 在 Mac 上部署的东西**全部清除**，让你可以从 0
#   重新跑一次部署脚本。（遇到问题想推倒重来时用这个）
#
# 默认会删：
#   · launchd 服务：com.nas.nl.hysteria、com.nas.nl.pull（含 plist）
#   · 配置目录：/usr/local/etc/nas-nl/
#   · 日志目录：/usr/local/var/log/nas-nl/
#   · 拉取脚本：/usr/local/bin/nas-nl-pull.sh
#   · 正在进行的拉取 / 隧道进程
#
# 默认**绝对不动**（避免误伤）：
#   · /usr/local/bin/hysteria  —— 与「国内那套」(deploy-nas-tunnel-mac.sh) 共用
#   · ~/.ssh/id_ed25519        —— 你的 SSH 密钥，可能别处在用
#   · 落地目录里的文件          —— 你辛苦下载回来的资源
#   · /usr/local/etc/nas-tunnel/ 等国内那套的任何东西
#
# 需要时用开关显式清理（都会再次确认）：
#   --purge            连落地目录里的文件一起删
#   --purge-key        删掉 ~/.ssh/id_ed25519(.pub)
#   --purge-hysteria   删掉 /usr/local/bin/hysteria（先检查国内那套是否在用它）
#
# 用法：
#   bash uninstall-nas-nl-mac.sh --list        # 只列出当前装了什么（只读）
#   bash uninstall-nas-nl-mac.sh --dry-run     # 只显示会删什么，不真删
#   bash uninstall-nas-nl-mac.sh               # 交互式清理
#   bash uninstall-nas-nl-mac.sh -y            # 不交互（默认范围）
#   bash uninstall-nas-nl-mac.sh -y --purge    # 连落地文件一起删
#
# 运行要求：普通用户运行（不要 sudo bash），脚本内部会自己调用 sudo。
#
# 版本：1.0.0
#===============================================================================

set -o pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="uninstall-nas-nl-mac.sh"

readonly CONF_DIR="/usr/local/etc/nas-nl"
readonly LOG_DIR="/usr/local/var/log/nas-nl"
readonly PULL_SCRIPT="/usr/local/bin/nas-nl-pull.sh"
readonly STATE_FILE="${CONF_DIR}/state.env"
readonly HY2_BIN="/usr/local/bin/hysteria"

readonly LAUNCHD_DIR="/Library/LaunchDaemons"
readonly LABEL_HY2="com.nas.nl.hysteria"
readonly LABEL_PULL="com.nas.nl.pull"
readonly PLIST_HY2="${LAUNCHD_DIR}/${LABEL_HY2}.plist"
readonly PLIST_PULL="${LAUNCHD_DIR}/${LABEL_PULL}.plist"

# 国内那套的痕迹：用来判断 hysteria 二进制是不是「共用中」
readonly CN_PLIST="/Library/LaunchDaemons/com.nas.tunnel.hysteria.plist"
readonly CN_CONF_DIR="/usr/local/etc/nas-tunnel"

# 颜色
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step() { printf '\n%s%s==> %s%s\n' "$C_CYAN" "$C_BOLD" "$*" "$C_RESET"; }
die()  { err "$*"; exit 1; }

#-------------------------------------------------------------------------------
# 参数
#-------------------------------------------------------------------------------
DO_LIST=0
DRY_RUN=0
ASSUME_YES=0
PURGE_DATA=0
PURGE_KEY=0
PURGE_HY2=0

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --list)            DO_LIST=1; shift ;;
            --dry-run)         DRY_RUN=1; shift ;;
            -y|--yes)          ASSUME_YES=1; shift ;;
            --purge)           PURGE_DATA=1; shift ;;
            --purge-key)       PURGE_KEY=1; shift ;;
            --purge-hysteria)  PURGE_HY2=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            -v|--version)      echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
            *) echo "未知参数：$1" >&2; echo "使用 --help 查看用法" >&2; exit 2 ;;
        esac
    done
}

confirm() {
    local prompt="$1" default="${2:-n}" answer="" hint
    if [ "$ASSUME_YES" -eq 1 ]; then [ "$default" = "y" ]; return $?; fi
    if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "$prompt $hint: " answer || true
    answer="${answer:-$default}"
    case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

require_normal_user() {
    if [ "$(id -u)" -eq 0 ]; then
        err "不要用 sudo 跑本脚本（内部会自己调用 sudo）"
        err "正确用法： bash ${SCRIPT_NAME}"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# 清点现状
#-------------------------------------------------------------------------------
list_state() {
    step "当前状态清点"
    local n=0

    printf '  %-34s %s\n' "launchd ${LABEL_HY2}" "$( [ -f "$PLIST_HY2" ] && echo "已安装" || echo "未安装" )"
    printf '  %-34s %s\n' "launchd ${LABEL_PULL}" "$( [ -f "$PLIST_PULL" ] && echo "已安装" || echo "未安装" )"
    printf '  %-34s %s\n' "配置目录 ${CONF_DIR}" "$( [ -d "$CONF_DIR" ] && echo "存在" || echo "不存在" )"
    printf '  %-34s %s\n' "日志目录 ${LOG_DIR}" "$( [ -d "$LOG_DIR" ] && echo "存在" || echo "不存在" )"
    printf '  %-34s %s\n' "拉取脚本 ${PULL_SCRIPT}" "$( [ -f "$PULL_SCRIPT" ] && echo "存在" || echo "不存在" )"
    printf '  %-34s %s\n' "隧道端口 127.0.0.1:2222" "$( lsof -nP -iTCP:2222 -sTCP:LISTEN >/dev/null 2>&1 && echo "监听中" || echo "未监听" )"

    local dest=""
    [ -f "$STATE_FILE" ] && dest=$(grep -E '^LOCAL_DEST=' "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    printf '  %-34s %s\n' "落地目录" "${dest:-（未知，需读 state.env）}"
    if [ -n "$dest" ] && [ -d "$dest" ]; then
        local cnt sz
        cnt=$(find "$dest" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
        sz=$(du -sh "$dest" 2>/dev/null | awk '{print $1}')
        printf '  %-34s %s\n' "落地目录内容" "${cnt} 项 / ${sz}"
    fi

    printf '  %-34s %s\n' "hysteria 二进制" "$( [ -x "$HY2_BIN" ] && echo "存在（与国内那套共用）" || echo "不存在" )"
    printf '  %-34s %s\n' "国内那套是否在用" "$( [ -f "$CN_PLIST" ] || [ -d "$CN_CONF_DIR" ] && echo "是（会被保留）" || echo "否" )"
    printf '  %-34s %s\n' "SSH 密钥 ~/.ssh/id_ed25519" "$( [ -f "$HOME/.ssh/id_ed25519" ] && echo "存在（默认保留）" || echo "不存在" )"

    echo
    info "以上为只读清点，没有做任何改动"
}

#-------------------------------------------------------------------------------
# 停止并删除 launchd
#-------------------------------------------------------------------------------
stop_services() {
    step "停止并移除 launchd 服务"
    local label plist domain
    for label in "$LABEL_PULL" "$LABEL_HY2"; do
        case "$label" in
            "$LABEL_PULL") plist="$PLIST_PULL" ;;
            "$LABEL_HY2")  plist="$PLIST_HY2" ;;
        esac
        # system 域（脚本部署的位置）+ gui 域（手工 submit 可能残留的位置）
        for domain in system "gui/$(id -u)"; do
            if sudo launchctl print "$domain/$label" >/dev/null 2>&1; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    info "[dry-run] launchctl bootout $domain/$label"
                else
                    sudo launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
                    ok "已停止 $domain/$label"
                fi
            fi
        done
        if [ -f "$plist" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                info "[dry-run] 删除 $plist"
            else
                sudo rm -f "$plist" && ok "已删除 $plist"
            fi
        fi
    done
}

kill_running() {
    step "结束正在进行的拉取/隧道进程"
    local pats=('nas-nl-pull[.]sh' 'hysteria client --config /usr/local/etc/nas-nl' 'nas@127[.]0[.]0[.]1')
    local p hit=0
    for p in "${pats[@]}"; do
        if pgrep -f "$p" >/dev/null 2>&1; then
            hit=1
            if [ "$DRY_RUN" -eq 1 ]; then
                info "[dry-run] 结束进程：$(pgrep -f "$p" | tr '\n' ' ')"
            else
                pkill -f "$p" >/dev/null 2>&1 || true
                ok "已结束匹配 「${p}」 的进程"
            fi
        fi
    done
    [ "$hit" -eq 0 ] && info "没有正在运行的拉取/隧道进程"
    return 0
}

remove_files() {
    step "删除配置、日志与拉取脚本"
    local target
    for target in "$PULL_SCRIPT" "$CONF_DIR" "$LOG_DIR"; do
        if [ -e "$target" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                info "[dry-run] 删除 $target"
            else
                sudo rm -rf "$target" && ok "已删除 $target"
            fi
        else
            info "不存在，跳过：$target"
        fi
    done
}

#-------------------------------------------------------------------------------
# 可选：清理数据 / 密钥 / 二进制
#-------------------------------------------------------------------------------
purge_data() {
    step "清理落地目录里的文件"
    local dest=""
    [ -f "$STATE_FILE" ] && dest=$(grep -E '^LOCAL_DEST=' "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    if [ -z "$dest" ]; then
        warn "读不到落地目录（state.env 已删或未记录），跳过"
        return 0
    fi
    [ -d "$dest" ] || { info "落地目录不存在：$dest"; return 0; }

    local cnt sz
    cnt=$(find "$dest" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
    sz=$(du -sh "$dest" 2>/dev/null | awk '{print $1}')
    warn "将删除 ${dest} 里的 ${cnt} 项（${sz}），这是你下载回来的资源！"
    if [ "$ASSUME_YES" -eq 0 ] && ! confirm "确认删除里面的文件？" n; then
        info "已跳过（目录保留）"; return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 清空 $dest"
    else
        rm -rf "${dest:?}"/* 2>/dev/null || true
        ok "已清空 $dest（目录本身保留）"
    fi
}

purge_key() {
    step "清理 SSH 密钥"
    if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        info "没有 $HOME/.ssh/id_ed25519，跳过"; return 0
    fi
    local pub=""
    [ -f "$HOME/.ssh/id_ed25519.pub" ] && pub=$(awk '{print $NF}' "$HOME/.ssh/id_ed25519.pub")
    warn "将删除 $HOME/.ssh/id_ed25519(.pub)${pub:+（注释：$pub）}"
    warn "如果这把密钥还给别的地方在用，删了那边就连不上了！"
    if [ "$ASSUME_YES" -eq 0 ] && ! confirm "确认删除这把密钥？" n; then
        info "已跳过"; return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 删除 ~/.ssh/id_ed25519(.pub)"
    else
        rm -f "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub" && ok "已删除 SSH 密钥"
        warn "服务器 ~nas/.ssh/authorized_keys 里那一行还留着，建议一并清掉："
        warn "  ssh root@<服务器IP> 'grep -v \"${pub}\" /home/nas/.ssh/authorized_keys > /tmp/ak && mv /tmp/ak /home/nas/.ssh/authorized_keys'"
    fi
}

purge_hysteria() {
    step "清理 hysteria 二进制"
    [ -x "$HY2_BIN" ] || { info "没有 $HY2_BIN，跳过"; return 0; }

    if [ -f "$CN_PLIST" ] || [ -d "$CN_CONF_DIR" ]; then
        warn "检测到「国内那套」还在（${CN_PLIST} 或 ${CN_CONF_DIR}）——它也用这个二进制！"
        warn "删了会让国内那套隧道起不来，请先跑它自己的 --uninstall。"
        if [ "$ASSUME_YES" -eq 0 ] && ! confirm "确定还是要删吗？" n; then
            info "已跳过（保留 $HY2_BIN）"; return 0
        fi
    else
        if [ "$ASSUME_YES" -eq 0 ] && ! confirm "确认删除 $HY2_BIN ？" n; then
            info "已跳过"; return 0
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[dry-run] 删除 $HY2_BIN"
    else
        sudo rm -f "$HY2_BIN" && ok "已删除 $HY2_BIN"
    fi
}

#-------------------------------------------------------------------------------
# 收尾核对
#-------------------------------------------------------------------------------
verify() {
    step "核对清理结果"
    local bad=0

    [ -f "$PLIST_HY2" ]  && { warn "仍存在：$PLIST_HY2"; bad=1; }
    [ -f "$PLIST_PULL" ] && { warn "仍存在：$PLIST_PULL"; bad=1; }
    [ -d "$CONF_DIR" ]   && { warn "仍存在：$CONF_DIR"; bad=1; }
    [ -d "$LOG_DIR" ]    && { warn "仍存在：$LOG_DIR"; bad=1; }
    [ -f "$PULL_SCRIPT" ]&& { warn "仍存在：$PULL_SCRIPT"; bad=1; }

    if lsof -nP -iTCP:2222 -sTCP:LISTEN >/dev/null 2>&1; then
        warn "端口 2222 仍在监听（可能是别的程序占用）"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "这是 dry-run，以上「仍存在」属正常"
        return 0
    fi

    if [ "$bad" -eq 1 ]; then
        warn "有项目没删干净，请把上面的路径手动检查一下"
        return 1
    fi
    ok "已清理干净：launchd、配置、日志、拉取脚本全部移除"
    return 0
}

summary() {
    step "完成"
    cat <<EOF
已清除（Mac 侧）：
  · launchd：${LABEL_HY2}、${LABEL_PULL}
  · 配置：${CONF_DIR}
  · 日志：${LOG_DIR}
  · 拉取脚本：${PULL_SCRIPT}

保留（按设计）：
  · ${HY2_BIN}          —— 与国内那套共用
  · ~/.ssh/id_ed25519   —— 你的 SSH 密钥
  · 落地目录里的文件     —— 你的下载成果

要重新部署，直接跑：
  bash deploy-nas-nl-mac.sh
（它会重新生成密钥、写配置、装 launchd，并打印需要粘到服务器的那条命令）

两点提醒：
  1. macOS 的「完全磁盘访问权限」里给 /bin/bash 的授权**不会**被清掉，
     重新部署后仍直接可用，不用再授一次。想撤销就去系统设置里移除。
  2. 服务器侧的拉取账号公钥还留着。如果你连密钥一起删了（--purge-key），
     需要按上面的提示把旧公钥从服务器 authorized_keys 里去掉。
EOF
    if [ "$DRY_RUN" -eq 1 ]; then
        echo
        warn "注意：本次是 --dry-run，上面的东西**都没有真删**"
    fi
}

#-------------------------------------------------------------------------------
# 主流程
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"

    printf '\n%s%s  NAS 荷兰机拉取 · Mac 端 卸载/重置 v%s%s\n' "$C_CYAN" "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"

    [ "$(uname -s)" = "Darwin" ] || die "本脚本只能在 macOS 上运行"
    require_normal_user

    if [ "$DO_LIST" -eq 1 ]; then
        list_state
        exit 0
    fi

    step "计划执行"
    [ "$DRY_RUN" -eq 1 ] && info "模式：dry-run（只看不删）" || info "模式：真删"
    [ "$PURGE_DATA" -eq 1 ] && warn "会额外清空落地目录里的文件" || true
    [ "$PURGE_KEY" -eq 1 ]  && warn "会额外删除 SSH 密钥" || true
    [ "$PURGE_HY2" -eq 1 ]  && warn "会额外删除共用的 hysteria 二进制" || true

    echo
    info "后续需要 sudo（改 /Library/LaunchDaemons、/usr/local）；请先授权"
    sudo -v || die "无法获得 sudo 权限"
    ( while true; do sudo -n true 2>/dev/null || exit; kill -0 "$$" 2>/dev/null || exit; sleep 50; done ) &
    KEEPALIVE=$!
    trap 'kill "$KEEPALIVE" >/dev/null 2>&1 || true' EXIT

    if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
        echo
        if ! confirm "确认开始清理？" y; then die "已取消"; fi
    fi

    stop_services
    kill_running
    [ "$PURGE_DATA" -eq 1 ] && purge_data
    [ "$PURGE_KEY" -eq 1 ]  && purge_key
    [ "$PURGE_HY2" -eq 1 ]  && purge_hysteria
    remove_files
    verify || true
    summary
}

main "$@"
