"""把 PrepBoardController.gd 从「人王交换 bug 变异态」还原回修复态，并**按 sha256 验收**。

为什么会走到这一步（事故记录，别再犯）：
  1. `mutate_swap_fix.py` 是**两阶段**脚本（`backup` 施加变异 / `restore` 还原），
     我把它**不带参数**跑了一次（等价于 `backup`），于是**变异留在了工作树上**；
  2. 它第二次跑 `backup` 时，`.mutbak` 被**变异后的内容**覆盖 —— `.mutbak` 也失效，
     `restore` 只会把变异贴回来；
  3. 它用**文本模式**读写（`io.open` / `newline=""`），把全文件 CRLF 静默归一化成了 LF。

教训：变异脚本必须是**单次调用内 try/finally 自还原 + 二进制读写**，见同批的
`mutate_cold_parse_922.py`。`mutate_swap_fix.py` 稍后同样改掉。

还原办法：直接把 OLD 片段逐字节换回 FIXED 片段（两个片段都从
`mutate_swap_fix.py` 里 import，**不手抄** —— 手抄必然在行尾 / 续行反斜杠上出错），
再把行尾统一回 CRLF，最后拿 sha256 验收，不一致就**不落盘**。

用法: python restore_prep_swap_922.py
"""
import hashlib
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = r"C:\Users\WINDOWS\Desktop\GLory-work\scenes\prep\PrepBoardController.gd"
EXPECT_SHA = "e1237b7504cbac8cec784d1502b33cacc32351984f377c3944492be458d18dc5"


def load_mutator():
    spec = importlib.util.spec_from_file_location(
        "mutate_swap_fix", os.path.join(HERE, "mutate_swap_fix.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    mod = load_mutator()
    fixed = mod.FIXED.encode("utf-8")
    old = mod.OLD.encode("utf-8")

    raw = open(PATH, "rb").read()
    print("[in ] sha =", hashlib.sha256(raw).hexdigest())
    print("[in ] CRLF =", raw.count(b"\r\n"), " bareLF =", raw.count(b"\n") - raw.count(b"\r\n"))

    n_old = raw.count(old)
    n_fixed = raw.count(fixed)
    print("[scan] OLD 片段出现 %d 次 / FIXED 片段出现 %d 次" % (n_old, n_fixed))
    if n_old != 1:
        print("[abort] OLD 片段不唯一（或不存在），拒绝猜")
        return 3

    restored = raw.replace(old, fixed, 1)
    restored = restored.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")

    got = hashlib.sha256(restored).hexdigest()
    print("[out ] sha =", got)
    print("[out ] CRLF =", restored.count(b"\r\n"))
    if got != EXPECT_SHA:
        print("[abort] 与 known-good 不一致，**不落盘**")
        return 4

    open(PATH, "wb").write(restored)
    bak = PATH + ".mutbak"
    if os.path.exists(bak):
        os.remove(bak)
        print("[clean] 已删除失效的 .mutbak")
    print("[done] 还原完成，sha 验收通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
