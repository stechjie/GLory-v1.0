# -*- coding: utf-8 -*-
"""复核两个交付夹的 _sha256清单.txt 是否与夹内文件逐一相符。

用法: python verify_deliver_923.py
"""
import hashlib
import os
import sys

ROOTS = [
    r"C:\Users\WINDOWS\Desktop\9.23交付_01_音效BGM资源_同路径备份",
    r"C:\Users\WINDOWS\Desktop\9.23交付_02_代码修改_同路径备份",
]


def main() -> int:
    total_bad = 0
    for root in ROOTS:
        manifest = os.path.join(root, "_sha256清单.txt")
        if not os.path.isfile(manifest):
            print("[abort] 缺清单:", manifest)
            return 3
        n = 0
        bad = 0
        listed = set()
        with open(manifest, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\r\n")
                if not line:
                    continue
                h, rel = line.split("  ", 1)
                rel_os = rel.replace("\\", os.sep)
                listed.add(rel_os)
                p = os.path.join(root, rel_os)
                n += 1
                if not os.path.isfile(p):
                    print("  缺文件", rel)
                    bad += 1
                    continue
                got = hashlib.sha256(open(p, "rb").read()).hexdigest()
                if got != h:
                    print("  不一致", rel)
                    bad += 1
        # 反向：夹里有没有清单没列的文件（_说明.txt / _sha256清单.txt 除外）
        extra = []
        for dirpath, _dirs, files in os.walk(root):
            for f in files:
                rel = os.path.relpath(os.path.join(dirpath, f), root)
                if rel in ("_说明.txt", "_sha256清单.txt"):
                    continue
                if rel not in listed:
                    extra.append(rel)
        print("%s  核对 %d 条 / 不一致 %d / 未列入清单 %d %s"
              % (os.path.basename(root), n, bad, len(extra), extra[:5]))
        total_bad += bad + len(extra)
    return 0 if total_bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
