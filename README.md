# osca-cloud-storage

[English](README.en.md) · 中文

一个 Hermes Agent 技能：把 `~/.hermes` 里的数据（记忆、技能、会话库、学习资料）备份到
**S3 兼容网盘**，本机只留活数据。默认参数按中科院高能所 OSCA 联盟云存储写好，也能直接对接
MinIO / AWS S3 / 阿里 OSS / Cloudflare R2。

跑一个脚本，输入 AccessKey / SecretKey，剩下的它自己搞定。

## 三步装上

```bash
# 0. rclone（脚本没有会提示你装）
brew install rclone                      # macOS
# curl https://rclone.org/install.sh | sudo bash   # Linux

# 1. 拿到代码（克隆或解压都行）
git clone https://github.com/lan1081210/osca-cloud-storage.git
cd osca-cloud-storage

# 2. 交互式配置：endpoint / AK / SK / 桶，然后自检（真传一次再删）
bash scripts/setup_osca.sh

# 3. 想传就传
bash scripts/osca_sync.sh --dry-run      # 先看看会传什么
bash scripts/osca_sync.sh                # 真传
```

setup 结束时会把技能自动装到 `~/.hermes/skills/osca-cloud-storage/`，之后在 Hermes 里
直接说「把 ~/.hermes 同步到网盘」「从网盘取回俄语教材」它就懂了。

## 它到底做了什么

`setup_osca.sh`

1. 检查 rclone，没有就打印对应平台的安装命令
2. 依次问 endpoint（默认 OSCA 网关）、remote 名、AccessKey、SecretKey（不回显、不进 shell 历史）
3. `rclone config create` 写 remote，配置文件 chmod 600
4. 列出账号下的桶让你选（没有就当场建一个）
5. **探针**：传一个 20 字节文件 → 回读比对 → 删掉。这一步真的写了，不是嘴炮
6. 把 `OSCA_REMOTE=osca:<桶名>` 写进 `~/.hermes/osca.env`（600），同步脚本读它

`osca_sync.sh`

- `sqlite3 .backup` 给运行中的 `state.db` 拿一致性快照，再 `rclone copy` 上去
- 默认排除 `/cache /installs /tools /hermes-agent /lsp /logs`、`*.db-wal`、`*.db-shm`
  —— 可再生的二进制和缓存不占配额
- 用 `copy` 不用 `sync`：本地误删不会把远端一起抹掉
- 实测 140MB / 740 个对象，20 秒跑完

`verify_then_delete.py`

先验后删。默认 dry-run，比对远端存在且字节数一致才允许删；只要有一个文件没备份好就整体中止。

```bash
python3 scripts/verify_then_delete.py ~/.hermes/shared/stamps/*.jpg
python3 scripts/verify_then_delete.py --delete ~/.hermes/shared/stamps/*.jpg
```

## 密钥安全

- AK/SK 只在 setup 时读一次，写进 `~/.config/rclone/rclone.conf`（600），脚本里没有硬编码
- SecretKey 输入不回显，也不会打进命令历史
- `~/.hermes/osca.env` 只存 remote 名，不含密钥
- 想轮换：直接改 rclone.conf，或重跑 `bash scripts/setup_osca.sh`

## 换成别的 S3 服务

OSCA 只是默认值。MinIO 之类自建也一样：

```bash
bash scripts/setup_osca.sh
> 网关 endpoint: http://192.168.1.10:9000
> remote 名称: osca
> AccessKey ID: minioadmin
> SecretKey: ...
```

AWS S3 用 `https://s3.amazonaws.com`，并把 region 换成真实 region（脚本默认 `us-east-1`，
可用环境变量 `OSCA_REGION` 覆盖）。

## 已知坑（都是真踩过的）

- rclone 的 `--exclude` 不加前导 `/` 会匹配任意层级。`hermes-agent/**` 会把
  `skills/autonomous-ai-agents/hermes-agent/**` 一起排掉，`cache/**` 会误伤
  `shared/stamps/cache/**`。脚本里已经用 `/` 锚定，改脚本时别手滑去掉。
- 运行中的 `state.db` 直接 copy 可能拿到撕裂页，必须走 `sqlite3 .backup`。
- Homebrew 版 rclone 没有 `mount` 子命令，要挂载成盘用 `rclone nfsmount`。
- 定时任务不会把结果推回聊天窗口（Hermes CLI 的 cron 输出只落本地）；要通知就
  `deliver` 到 Telegram 之类的平台。

## 目录结构

```
osca-cloud-storage/
├── SKILL.md                          # 给 Hermes 看的技能说明
├── README.md                         # 你在看的这个
├── LICENSE
└── scripts/
    ├── setup_osca.sh                 # 一键配置 + 自检
    ├── osca_sync.sh                  # 日常同步
    └── verify_then_delete.py         # 先验后删
```

## 许可

MIT。随便用，出事别找我。
