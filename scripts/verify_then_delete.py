#!/usr/bin/env python3
"""先验后删：确认本地文件在网盘上存在且字节数一致，才允许删除。

默认 dry-run 只报告；加 --delete 才真删。只要有任何一个文件没备份好，整体中止。

用法:
  python3 verify_then_delete.py shared/russian-a1/*.pdf
  python3 verify_then_delete.py --local-root ~/.hermes --remote-root osca:bucket/hermes --delete ...
  REMOTE=/tmp 用 --dry-run 观察

映射规则: 本地路径相对 --local-root，对应 --remote-root 下的同名相对路径。
默认值从 ~/.hermes/osca.env 读（OSCA_REMOTE / OSCA_LOCAL_ROOT）。
"""
import argparse
import os
import re
import subprocess
import sys


def load_env(path=os.path.expanduser("~/.hermes/osca.env")) -> dict:
    env = {}
    if not os.path.isfile(path):
        return env
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().strip('"').strip("'")
        v = re.sub(r"^\$HOME", os.path.expanduser("~"), v)   # osca.env 里写了 $HOME
        env[k.strip()] = v
    return env


def remote_sizes(remote_root: str) -> dict:
    """rclone lsf --format 'sp' -> {rel_path: size}"""
    out = subprocess.run(
        ["rclone", "lsf", remote_root, "-R", "--files-only", "--format", "sp"],
        capture_output=True, text=True, timeout=600,
    )
    if out.returncode != 0:
        sys.exit(f"rclone lsf 失败: {out.stderr.strip()[:300]}")
    sizes = {}
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split(";") if ";" in line else line.split(None, 1)
        if len(parts) != 2:
            continue
        size, path = parts[0].strip(), parts[1].strip()
        try:
            sizes[path] = int(size)
        except ValueError:
            continue
    return sizes


def main() -> int:
    env = load_env()
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="本地文件（可先由 shell 展开通配符）")
    ap.add_argument("--local-root", default=env.get("OSCA_LOCAL_ROOT", "~/.hermes"))
    ap.add_argument("--remote-root", default=(env["OSCA_REMOTE"] + "/hermes") if env.get("OSCA_REMOTE") else None)
    ap.add_argument("--delete", action="store_true", help="核对通过才真删；默认只报告")
    ap.add_argument("--dry-run", action="store_true", help="默认行为，写上只是图个明白")
    args = ap.parse_args()

    local_root = os.path.expanduser(args.local_root)
    if not args.remote_root:
        sys.exit("缺 --remote-root，且 ~/.hermes/osca.env 里没有 OSCA_REMOTE")

    sizes = remote_sizes(args.remote_root)
    safe, unsafe, freed = [], [], 0
    for p in args.paths:
        if not os.path.isfile(p):
            continue
        rel = os.path.relpath(os.path.abspath(p), os.path.abspath(local_root))
        local_size = os.path.getsize(p)
        rs = sizes.get(rel)
        if rs == local_size:
            safe.append(p)
            freed += local_size
        else:
            unsafe.append((rel, local_size, rs))

    print(f"核对通过 {len(safe)} 个，可释放 {freed / 1048576:.1f} MiB")
    for rel, ls, rs in unsafe:
        print(f"  UNSAFE {rel}  local={ls} remote={rs}  -> 不要删，先补传")
    if not args.delete:
        print("dry-run（加 --delete 才真删）")
        return 0
    if unsafe:
        print("存在未备份文件，整体中止，一个都没删。")
        return 1
    for p in safe:
        os.remove(p)
    print(f"已删除 {len(safe)} 个文件，释放 {freed / 1048576:.1f} MiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
