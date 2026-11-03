#!/usr/bin/env bash
# OSCA / S3 网盘一键配置
#   bash setup_osca.sh            # 交互式
#   bash setup_osca.sh --check    # 只体检，不改任何东西
# 干的事：检查 rclone → 问 endpoint/AK/SK/桶 → 建 remote → 列桶 → 写 ~/.hermes/osca.env
#         → 传一个 20 字节探针再删掉 → 装 skill 到 ~/.hermes/skills/
set -uo pipefail

REMOTE_NAME="${OSCA_REMOTE_NAME:-osca}"
DEFAULT_ENDPOINT="https://fgws3-ocloud.ihep.ac.cn"
ENVFILE="$HOME/.hermes/osca.env"
CONF="${RCLONE_CONFIG:-$HOME/.config/rclone/rclone.conf}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }

ask() {  # ask <提示> <默认值> -> 结果放 REPLY_VALUE
  local prompt="$1" def="${2:-}" ans=""
  if [ -n "$def" ]; then printf '%s [%s]: ' "$prompt" "$def" >&2
  else printf '%s: ' "$prompt" >&2; fi
  IFS= read -r ans || ans=""
  REPLY_VALUE="${ans:-$def}"
}

ask_secret() {  # 不回声、不进历史
  local prompt="$1" ans=""
  printf '%s: ' "$prompt" >&2
  if [ -t 0 ]; then
    stty -echo; IFS= read -r ans; stty echo; printf '\n' >&2
  else
    IFS= read -r ans || ans=""
  fi
  REPLY_VALUE="$ans"
}

# ── 1. rclone ───────────────────────────────────────────────────────────
say ""
say "== 1/6 检查 rclone =="
if ! command -v rclone >/dev/null 2>&1; then
  warn "没装 rclone"
  say "  macOS: brew install rclone"
  say "  Linux: curl https://rclone.org/install.sh | sudo bash"
  die "装完再跑一次这个脚本"
fi
ok "rclone $(rclone version | head -1 | awk '{print $2}')"

if [ "${1:-}" = "--check" ]; then
  say ""
  say "== 现有配置 =="
  [ -f "$ENVFILE" ] && { ok "环境文件 $ENVFILE"; sed 's/^/    /' "$ENVFILE"; } || warn "还没有 $ENVFILE，跑一次不带 --check 的 setup"
  [ -f "$CONF" ] && rclone listremotes | sed 's/^/    remote: /' || warn "还没有 rclone.conf"
  exit 0
fi

# ── 2. 参数 ─────────────────────────────────────────────────────────────
say ""
say "== 2/6 连接参数（回车用默认值）=="
ask "网关 endpoint" "$DEFAULT_ENDPOINT"; ENDPOINT="$REPLY_VALUE"
ask "remote 名称"   "$REMOTE_NAME";       REMOTE_NAME="$REPLY_VALUE"
ask "AccessKey ID"  "${OSCA_ACCESS_KEY:-}"; AK="$REPLY_VALUE"
if [ -z "$AK" ]; then die "AccessKey 不能为空"; fi
ask_secret "SecretKey（输入不回显）"; SK="$REPLY_VALUE"
if [ -z "$SK" ]; then die "SecretKey 不能为空"; fi
REGION="${OSCA_REGION:-us-east-1}"

# ── 3. 建 remote ────────────────────────────────────────────────────────
say ""
say "== 3/6 写 rclone remote: $REMOTE_NAME =="
rclone config create "$REMOTE_NAME" s3 \
  provider Other env_auth false \
  access_key_id "$AK" secret_access_key "$SK" \
  region "$REGION" endpoint "$ENDPOINT" acl private \
  --non-interactive >/dev/null 2>&1 || die "rclone config create 失败"
chmod 600 "$CONF" 2>/dev/null
ok "已写入 ${CONF}（600）"

# ── 4. 列桶 / 选桶 ──────────────────────────────────────────────────────
say ""
say "== 4/6 列桶 =="
BUCKETS="$(rclone lsf "$REMOTE_NAME:" --dirs-only --max-depth 1 2>/dev/null | sed 's:/$::')"
if [ -z "$BUCKETS" ]; then
  warn "这个账号下没有桶，或凭据/endpoint 不对"
  ask "新建桶名（留空则退出）" ""; BUCKET="$REPLY_VALUE"
  [ -z "$BUCKET" ] && die "没有可用桶"
  rclone mkdir "$REMOTE_NAME:$BUCKET" || die "建桶失败"
  ok "已建桶 $BUCKET"
else
  say "  可用桶："
  printf '%s\n' "$BUCKETS" | sed 's/^/    - /'
  FIRST="$(printf '%s\n' "$BUCKETS" | head -1)"
  ask "用哪个桶" "$FIRST"; BUCKET="$REPLY_VALUE"
fi
[ -z "${BUCKET:-}" ] && die "没选桶"

# ── 5. 探针（真的写一次再删）────────────────────────────────────────────
say ""
say "== 5/6 连通性探针 =="
PROBE="$(mktemp)"; printf 'osca probe %s\n' "$(date +%s)" > "$PROBE"
if rclone copyto "$PROBE" "$REMOTE_NAME:$BUCKET/.osca-probe" >/dev/null 2>&1; then
  ok "上传 OK"
  if diff -q <(rclone cat "$REMOTE_NAME:$BUCKET/.osca-probe") "$PROBE" >/dev/null 2>&1; then
    ok "回读一致"
  else
    warn "回读内容不一致（可能被服务端改写）"
  fi
  rclone deletefile "$REMOTE_NAME:$BUCKET/.osca-probe" >/dev/null 2>&1 && ok "探针已清理"
else
  rm -f "$PROBE"
  die "上传失败：检查 AK/SK、桶名、endpoint、账号余额/配额"
fi
rm -f "$PROBE"

# ── 6. 落盘 + 装 skill ──────────────────────────────────────────────────
say ""
say "== 6/6 写环境文件 =="
mkdir -p "$HOME/.hermes"
umask 077
cat > "$ENVFILE" <<EOF
# 由 setup_osca.sh 生成；同步脚本 source 这个文件
OSCA_REMOTE=$REMOTE_NAME:$BUCKET
OSCA_LOCAL_ROOT="\$HOME/.hermes"
EOF
umask 022
chmod 600 "$ENVFILE"
ok "${ENVFILE}（600）"

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_SRC="$(cd "$HERE/.." && pwd)"
if [ -f "$SKILL_SRC/SKILL.md" ]; then
  DEST="$HOME/.hermes/skills/$(basename "$SKILL_SRC")"
  if [ "$SKILL_SRC" != "$DEST" ]; then
    mkdir -p "$DEST"
    cp -R "$SKILL_SRC/." "$DEST/"
    ok "技能已装到 $DEST"
  else
    ok "技能已在 $DEST"
  fi
fi

say ""
say "完成。下一步："
say "  bash $HERE/osca_sync.sh --dry-run     # 预演"
say "  bash $HERE/osca_sync.sh               # 真传"
say "  hermes cron 建 no_agent 任务每天跑       # 自动备份"
