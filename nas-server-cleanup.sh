#!/usr/bin/env bash
# 由 nas-server.sh 生成：删除交换目录里超过保留时间的文件
# 用法： cleanup.sh            正常清理
#        DRY_RUN=1 cleanup.sh  只打印不删
set -uo pipefail

CONF="${NAS_SERVER_CONF:-/etc/nas-server/nas-server.conf}"
[[ -r "$CONF" ]] || { echo "缺少配置 $CONF" >&2; exit 1; }
set -a; . "$CONF"; set +a

EXCHANGE="${EXCHANGE:-/opt/nas}"
RETENTION_MINUTES="${RETENTION_MINUTES:-1440}"
LOG="${CLEANUP_LOG:-/var/log/nas-server-cleanup.log}"
DRY="${DRY_RUN:-0}"

{
  echo "[$(date '+%F %T')] ===== 清理开始：$EXCHANGE（保留 ${RETENTION_MINUTES} 分钟）====="
  if [[ ! -d "$EXCHANGE" ]]; then
    echo "目录不存在，跳过"; exit 0
  fi
  n=0
  while IFS= read -r -d '' f; do
    if [[ "$DRY" == "1" ]]; then echo "  [dry-run] 文件 $f"; continue; fi
    rm -rf -- "$f" && { echo "  删除文件 $f"; n=$((n+1)); }
  done < <(find "$EXCHANGE" -mindepth 1 -type f -mmin +"$RETENTION_MINUTES" -print0 2>/dev/null)

  while IFS= read -r -d '' d; do
    if [[ "$DRY" == "1" ]]; then echo "  [dry-run] 空目录 $d"; continue; fi
    rmdir -- "$d" 2>/dev/null && { echo "  删除空目录 $d"; n=$((n+1)); }
  done < <(find "$EXCHANGE" -mindepth 1 -depth -type d -empty -print0 2>/dev/null)

  echo "[$(date '+%F %T')] ===== 清理结束：共处理 $n 项 ====="
} >>"$LOG" 2>&1
