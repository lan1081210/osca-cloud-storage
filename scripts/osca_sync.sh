#!/usr/bin/env bash
# 把 Hermes 数据同步到 S3 网盘（读 ~/.hermes/osca.env）
#   bash osca_sync.sh             # 真传
#   bash osca_sync.sh --dry-run   # 只列出会传什么
# 退出码：0 = 全部成功；1 = 有失败（rclone 失败 / state.db 快照拿不到），cron 可据此告警
set -uo pipefail

ENVFILE="$HOME/.hermes/osca.env"
[ -f "$ENVFILE" ] || { echo "缺 $ENVFILE，先跑 setup_osca.sh" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENVFILE"

REMOTE="${OSCA_REMOTE:?osca.env 里缺 OSCA_REMOTE}"
LOCAL="${OSCA_LOCAL_ROOT:-$HOME/.hermes}"
LOCAL="${LOCAL/#\~/$HOME}"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

SNAPDIR="$(mktemp -d)" || { echo "mktemp 失败" >&2; exit 1; }
SNAP="$SNAPDIR/state.db"
trap 'rm -rf "$SNAPDIR"' EXIT
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

command -v rclone >/dev/null || { echo "没装 rclone" >&2; exit 1; }

FAILURES=0
fail() { FAILURES=$((FAILURES+1)); log "$*"; }

# 1) state.db 一致性快照（库在运行中也稳妥）
# 拿不到快照时，下面 rclone copy 又把 state.db 整个排除——等于本次没备它，
# 这种缺口必须让退出码暴露出来，不能只打一行「跳过」
if [ -f "$LOCAL/state.db" ]; then
  if command -v sqlite3 >/dev/null; then
    if sqlite3 "$LOCAL/state.db" ".backup '$SNAP'"; then
      log "state.db 快照 ok"
    else
      rm -f "$SNAP"   # 失败的快照可能是半截文件，别让第 3 步传上去
      fail "state.db 快照失败：本次备份不含 state.db"
    fi
  else
    fail "没装 sqlite3，拿不到一致快照：本次备份不含 state.db（brew install sqlite3 / apt install sqlite3）"
  fi
fi

# 2) 数据本体。过滤规则一律 / 开头锚定，否则会误伤深层同名目录
log "同步 $LOCAL -> $REMOTE/hermes"
rclone copy "$LOCAL/" "$REMOTE/hermes/" $DRY --transfers 8 --checkers 16 \
  --exclude "/cache/**" --exclude "/installs/**" --exclude "/tools/**" \
  --exclude "/hermes-agent/**" --exclude "/lsp/**" --exclude "/logs/**" \
  --exclude "*.db-wal" --exclude "*.db-shm" --exclude "/state.db" \
  --exclude ".git/**" --exclude "node_modules/**" \
  || fail "rclone copy 失败（退出码 $?）"

# 3) 快照单独上传
if [ -f "$SNAP" ]; then
  rclone copyto "$SNAP" "$REMOTE/hermes/state.db" $DRY \
    && log "state.db 已上传" \
    || fail "state.db 上传失败"
fi

if [ "$FAILURES" -gt 0 ]; then
  log "完成，但有 $FAILURES 处失败（退出码 1）"
  exit 1
fi
log "完成"
