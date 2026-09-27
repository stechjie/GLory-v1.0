# -*- coding: utf-8 -*-
"""重建某个交付夹的 `_sha256清单.txt`（从夹内实际文件反推）。

用法: python resync_manifest.py <夹路径> [<夹路径> ...]
"""
import hashlib
import os
import sys

SKIP = {"_说明.txt", "_sha256清单.txt"}


def rebuild(root: str) -> int:
    rows = []
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, root)
            if rel in SKIP:
                continue
            with open(p, "rb") as fh:
                rows.append((rel, hashlib.sha256(fh.read()).hexdigest()))
    rows.sort()
    body = "\r\n".join("%s  %s" % (h, rel.replace(os.sep, "\\")) for rel, h in rows)
    with open(os.path.join(root, "_sha256清单.txt"), "wb") as fh:
        fh.write(body.encode("utf-8"))
    print("重建 %s -> %d 条" % (os.path.basename(root), len(rows)))
    return len(rows)


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        raise SystemExit(2)
    for r in args:
        if not os.path.isdir(r):
            print("[abort] 不是目录:", r)
            raise SystemExit(3)
        rebuild(r)
