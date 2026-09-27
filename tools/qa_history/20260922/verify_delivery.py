#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立复核交付夹：逐字节 sha256 对比「源」与「交付」，并检查有无多余/缺失文件。

**刻意不读**打包脚本写出来的 `_sha256清单.txt` —— 那是被核对的对象自己产出的，
拿它当基准就成了自证。这里直接从打包脚本 import 出 FILES 清单，重新算源文件的 sha256。

用法: python verify_delivery.py
"""
import hashlib
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DESK = r"C:\Users\WINDOWS\Desktop"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"


def load_maker(name):
    path = os.path.join(HERE, name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    mod = load_maker("make_delivery_927c")
    out_dir = os.path.join(DESK, mod.OUT)

    missing, mismatch, ok = [], [], 0
    for rel in mod.FILES:
        src = os.path.join(PROJ, rel)
        dst = os.path.join(out_dir, rel)
        if not os.path.isfile(dst):
            missing.append(rel)
            continue
        if sha256_of(src) != sha256_of(dst):
            mismatch.append(rel)
        else:
            ok += 1

    # 多余文件：交付夹里除了 FILES + 两个说明文件之外的都算多余。
    allowed = {os.path.normcase(os.path.join(out_dir, r)) for r in mod.FILES}
    allowed.add(os.path.normcase(os.path.join(out_dir, "_说明.txt")))
    allowed.add(os.path.normcase(os.path.join(out_dir, "_sha256清单.txt")))
    extra = []
    for root, _dirs, files in os.walk(out_dir):
        for f in files:
            p = os.path.join(root, f)
            if os.path.normcase(p) not in allowed:
                extra.append(os.path.relpath(p, out_dir))

    print("folder   :", mod.OUT)
    print("expected :", len(mod.FILES))
    print("identical:", ok)
    print("missing  :", missing)
    print("mismatch :", mismatch)
    print("extra    :", extra)
    good = not missing and not mismatch and not extra and ok == len(mod.FILES)
    print("VERIFY_OK" if good else "VERIFY_FAILED")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
