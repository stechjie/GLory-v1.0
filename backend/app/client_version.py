"""客户端版本：每个请求都带的 X-Glory-Client 头（scripts/autoload/AccountManager.gd 的 client_header_line）。

    X-Glory-Client: protocol=34; build=17; kinds=prep_skin

kinds 是这个客户端认识的**新**商品种类（逗号分隔）。旧包不带 kinds，更老的包连这个头都不带 ——
两种都当成「一个新种类都不认识」。

🔴 **别拿 build 做判断。** 本机 Godot 导出写的是 versionCode，tools/workspace 的安卓流水线不写、
iOS 流水线写成 build_number，编辑器里是 0：同一个数字在不同出包路子上意思不一样
（2026-09-28 查出来，同事出的包全都报 build=0，按 build 挡皮肤的规则就漏了）。
"""

from __future__ import annotations

import re

_KINDS = re.compile(r"(?:^|;)\s*kinds=([a-z0-9_,]{0,256})\s*(?:;|$)")


def kinds_of(header: str | None) -> frozenset[str]:
    """客户端声明认识的新商品种类。没带头、没带 kinds 或读不出来，都是空集。"""
    if not header:
        return frozenset()
    match = _KINDS.search(header)
    if not match:
        return frozenset()
    return frozenset(kind for kind in match.group(1).split(",") if kind)
