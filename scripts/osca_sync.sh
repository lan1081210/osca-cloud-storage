#!/usr/bin/env bash
# 把 Hermes 数据同步到 S3 网盘（读 ~/.hermes/osca.env）
#   bash osca_sync.sh             # 真传
#   bash osca_sync.sh --dry-run   # 只列出会传什么
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

SNAP="$(mktemp -d)/state.db"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

command -v rclone >/dev/null || { echo "没装 rclone" >&2; exit 1; }

# 1) state.db 一致性快照（库在运行中也稳妥）
if command -v sqlite3 >/dev/null && [ -f "$LOCAL/state.db" ]; then
  sqlite3 "$LOCAL/state.db" ".backup '$SNAP'" && log "state.db 快照 ok" || log "state.db 快照失败，跳过"
fi

# 2) 数据本体。过滤规则一律 / 开头锚定，否则会误伤深层同名目录
log "同步 $LOCAL -> $REMOTE/hermes"
rclone copy "$LOCAL/" "$REMOTE/hermes/" $DRY --transfers 8 --checkers 16 \
  --exclude "/cache/**" --exclude "/installs/**" --exclude "/tools/**" \
  --exclude "/hermes-agent/**" --exclude "/lsp/**" --exclude "/logs/**" \
  --exclude "*.db-wal" --exclude "*.db-shm" --exclude "state.db" \
  --exclude ".git/**" --exclude "node_modules/**"

# 3) 快照单独上传
if [ -f "$SNAP" ]; then
  rclone copyto "$SNAP" "$REMOTE/hermes/state.db" $DRY && log "state.db 已上传"
fi

log "完成"
