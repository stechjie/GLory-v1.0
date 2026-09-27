"""客户端版本：每个请求都带的 X-Glory-Client 头（scripts/autoload/AccountManager.gd 的 client_header_line）。

    X-Glory-Client: protocol=32; build=16

build 是安装包的 versionCode；在编辑器里跑没有 build_info.json，记 0。

**很老的包不带这个头** —— 它是后来才加的，已经发出去的包补不上。所以「没带头」要当成
最老的那一档处理，不能当成最新。
"""

from __future__ import annotations

import re

_BUILD = re.compile(r"(?:^|;)\s*build=(\d{1,9})\s*(?:;|$)")


def build_of(header: str | None) -> int | None:
    """None = 没带头或读不出来（当作很老的包）；0 = 编辑器 / 没有 build_info 的开发包。"""
    if not header:
        return None
    match = _BUILD.search(header)
    return int(match.group(1)) if match else None
