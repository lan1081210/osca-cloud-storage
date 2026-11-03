---
name: osca-cloud-storage
description: Store/restore Hermes data on an S3 netdisk via rclone.
version: 1.0.0
author: MER
license: MIT
metadata:
  hermes:
    tags: [storage, backup, s3, rclone, netdisk, osca]
    related_skills: [hermes-agent]
---

# OSCA / S3 网盘存取

把 Hermes 的数据（记忆、技能、会话库、资料）放到 S3 兼容网盘上，本机只留活数据。
默认按中科院高能所 **OSCA 联盟云存储** 写的参数，任何 S3 兼容服务（MinIO、AWS S3、
阿里 OSS、七牛、Cloudflare R2）改一下 endpoint 就能用。

## When to Use

- 第一次配置网盘（跑 `scripts/setup_osca.sh`）
- 要把 `~/.hermes` 备份 / 同步到网盘，或从网盘取回某个文件
- 要腾本机磁盘，先确认网盘有副本再删本地文件（`scripts/verify_then_delete.py`，先验后删）
- 排查「传了没」「远端比本地多什么」「为什么某个目录被漏掉」

## 安装（使用者视角）

```bash
# 1. rclone（脚本会检测，没有就提示装法）
brew install rclone            # macOS
# curl https://rclone.org/install.sh | sudo bash      # Linux

# 2. 配置：交互式问 endpoint / AK / SK / 桶名，然后自检
bash scripts/setup_osca.sh

# 3. 之后直接说「把 ~/.hermes 同步到网盘」即可，或手动跑
bash scripts/osca_sync.sh
```

`setup_osca.sh` 会把 remote 写进 `~/.config/rclone/rclone.conf`（600），把
`OSCA_REMOTE=osca:<桶名>` 写进 `~/.hermes/osca.env`（600），同步脚本读这个文件。
密钥**不落地到脚本里**，也不会打印出来。

## 连接参数（OSCA 默认值）

| 项 | 值 |
|---|---|
| endpoint | `https://fgws3-ocloud.ihep.ac.cn` |
| region | `us-east-1`（S3 兼容服务给什么都行，占位） |
| 签名 | SigV4，path-style |
| 桶 | 账号下自建，形如 `22134-<用户名>` |
| rclone remote 名 | `osca` |

非交互创建（等价于 setup 脚本干的事）：

```bash
rclone config create osca s3 provider Other env_auth false \
  access_key_id <AK> secret_access_key <SK> region us-east-1 \
  endpoint https://fgws3-ocloud.ihep.ac.cn acl private --non-interactive
rclone lsd osca: --max-depth 1     # 验证：列出桶
```

## 日常同步

`scripts/osca_sync.sh`（`--dry-run` 预演）：

1. `sqlite3 ~/.hermes/state.db ".backup <tmp>"` 拿一致性快照
2. `rclone copy ~/.hermes/` → `<REMOTE>/hermes/`
3. 快照单独 `rclone copyto` 成 `hermes/state.db`

排除项：`/cache /installs /tools /hermes-agent /lsp /logs`、`*.db-wal`、`*.db-shm`、
`state.db`（改用快照）。实测 140MB / 740 对象，20 秒传完。

定时：`hermes cron` 建一个 `no_agent` 任务指向脚本，或系统 crontab
`10 23 * * * /path/to/osca_sync.sh`。

## 坑（都是真踩过的）

- **rclone `--exclude` 不加前导 `/` 会匹配任意层级**：`hermes-agent/**` 会把
  `skills/autonomous-ai-agents/hermes-agent/**` 一起排掉，`cache/**` 会误伤
  `shared/stamps/cache/**`。一律写 `--exclude "/hermes-agent/**"`。
- **用 `copy` 不用 `sync`**：远端不会因为本地误删而消失。要镜像再加 `--backup-dir`。
- **运行中的 `state.db` 必须用 `sqlite3 .backup`**，直接 copy 可能拿到撕裂页；
  快照和线上库哈希本来就不同，别当失败。
- **删本地文件前先验远端**：`verify_then_delete.py` 默认 dry-run，比对远端存在且
  字节数一致才允许删。
- Homebrew 版 rclone 没有 `mount`，挂载用 `rclone nfsmount`。
- 未装 aws cli / boto3 也行，rclone 一个就够。
- OSCA 的缩略图/直链域名和 S3 路径不是一回事，别拿 `rclone link` 当公网 URL 用。

## 校验

```bash
rclone size "$OSCA_REMOTE/hermes"
rclone lsf "$OSCA_REMOTE/hermes" -R --files-only | wc -l    # 与本地过滤后的 find 对齐
rclone cat "$OSCA_REMOTE/hermes/memories/USER.md" | shasum -a 256   # 抽样比哈希
rclone copyto "$OSCA_REMOTE/hermes/state.db" /tmp/s.db && sqlite3 /tmp/s.db 'PRAGMA integrity_check'
```

## 取回

```bash
rclone copy "$OSCA_REMOTE/hermes/memories/" ~/.hermes/memories/
rclone copy "$OSCA_REMOTE/hermes/shared/" ~/.hermes/shared/
rclone lsjson "$OSCA_REMOTE/hermes" --recursive | head      # 不知道路径时先看清单
```

大文件用完即删本地副本，留在网盘。
