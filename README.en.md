# osca-cloud-storage

A Hermes Agent skill that backs up the data in `~/.hermes` (memories, skills, session store,
study material) to an **S3-compatible object store**, leaving only live data on the machine. The
defaults are set up for the OSCA alliance cloud storage at IHEP, but MinIO / AWS S3 / Alibaba OSS /
Cloudflare R2 work the same way.

Run one script, give it an AccessKey / SecretKey, and it handles the rest.

[中文](README.md) · English

## Install in three steps

```bash
# 0. rclone (the script tells you how to install it if it is missing)
brew install rclone                      # macOS
# curl https://rclone.org/install.sh | sudo bash   # Linux

# 1. get the code (clone or unzip)
git clone https://github.com/lan1081210/osca-cloud-storage.git
cd osca-cloud-storage

# 2. interactive setup: endpoint / AK / SK / bucket, then a self-check (real upload, real delete)
bash scripts/setup_osca.sh

# 3. sync whenever you want
bash scripts/osca_sync.sh --dry-run      # see what would go up
bash scripts/osca_sync.sh                # actually upload
```

When setup finishes it installs the skill into `~/.hermes/skills/osca-cloud-storage/`, after which
you can just tell Hermes "sync ~/.hermes to the netdisk" or "fetch the Russian textbook from the
netdisk" and it knows what to do.

## What it actually does

`setup_osca.sh`

1. Checks for rclone and prints the install command for your platform if it is missing.
2. Asks for the endpoint (defaults to the OSCA gateway), a remote name, the AccessKey and the
   SecretKey (not echoed, not written to shell history).
3. Writes the remote with `rclone config create` and chmods the config to 600.
4. Lists the buckets on the account so you can pick one (and offers to create one if there are none).
5. **Probe**: uploads a 20-byte file, reads it back and compares, then deletes it. This is a real
   write, not a claim.
6. Stores `OSCA_REMOTE=osca:<bucket>` in `~/.hermes/osca.env` (600), which the sync script reads.

`osca_sync.sh`

- Takes a consistent snapshot of the running `state.db` with `sqlite3 .backup`, then `rclone copy`s it.
- Excludes `/cache /installs /tools /hermes-agent /lsp /logs`, `*.db-wal` and `*.db-shm` by default —
  regenerable binaries and caches should not eat the quota.
- Uses `copy`, not `sync`: a local mistake cannot wipe the remote.
- Measured: 140 MB across 740 objects in 20 seconds.

`verify_then_delete.py`

Verify first, delete second. Dry-run by default; a file is only deleted when it exists on the
remote with a matching byte count, and one unbacked file aborts the whole run.

```bash
python3 scripts/verify_then_delete.py ~/.hermes/shared/stamps/*.jpg
python3 scripts/verify_then_delete.py --delete ~/.hermes/shared/stamps/*.jpg
```

## Key handling

- AK/SK are read once during setup and written to `~/.config/rclone/rclone.conf` (600); nothing is
  hard-coded in the scripts.
- The SecretKey is not echoed and does not reach your shell history.
- `~/.hermes/osca.env` holds only the remote name, never a key.
- To rotate, edit `rclone.conf` or rerun `bash scripts/setup_osca.sh`.

## Pointing it at another S3 service

OSCA is only the default. A self-hosted MinIO works the same:

```bash
bash scripts/setup_osca.sh
> gateway endpoint: http://192.168.1.10:9000
> remote name: osca
> AccessKey ID: minioadmin
> SecretKey: ...
```

For AWS S3 use `https://s3.amazonaws.com` and set the real region (the script defaults to
`us-east-1`; override with the `OSCA_REGION` environment variable).

## Known traps (all hit for real)

- An rclone `--exclude` without a leading `/` matches at any depth: `hermes-agent/**` also excludes
  `skills/autonomous-ai-agents/hermes-agent/**`, and `cache/**` would eat `shared/stamps/cache/**`.
  The script anchors patterns with `/` — do not drop that.
- Copying a live `state.db` can capture torn pages; it has to go through `sqlite3 .backup`.
- The Homebrew build of rclone has no `mount` subcommand; use `rclone nfsmount` to mount it as a disk.
- A scheduled job does not push its output back into the chat (Hermes CLI cron output stays local);
  to be notified, set `deliver` to a platform such as Telegram.

## Layout

```
osca-cloud-storage/
├── SKILL.md                          # the skill description Hermes reads
├── README.md                         # Chinese
├── README.en.md                      # this file
├── LICENSE
└── scripts/
    ├── setup_osca.sh                 # one-shot setup + self-check
    ├── osca_sync.sh                  # everyday sync
    └── verify_then_delete.py         # verify, then delete
```

## Licence

MIT. Use it however you like; if it breaks something, that is on you.
