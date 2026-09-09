"""头像与头像框清单的服务端校验。

**这里是「授权检查」，数据库那条正则只是「格式检查」。** 两层各管一段：

    数据库约束      长得像不像（挡住超长、怪字符、SQL 里的怪东西）
    这个模块        这个 id 存不存在、有没有资格用

不能因为正则过了就放行。会发生的具体事情：有人（改过的客户端，或者直接拿
令牌打接口的人）发 PATCH /v1/me {"avatar": "preset:超级限定头像"} ——
正则完全通过，于是库里存进一个不存在的 id。今天最坏结果只是头像显示空白
（所有头像免费）；等头像变成活动奖励或付费内容，同一个洞就是白嫖限定头像，
而且到那时还要处理已经写进去的脏数据。

同理 `upload:` 这个 scheme：正则允许它是为了以后接自定义上传时不用改数据库，
**但功能没做之前一律拒绝**。

清单本身在 data/avatars.json —— 后端部署是整仓 clone，读得到。
"""

from __future__ import annotations

import json
import os
import pathlib
import re

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_CATALOG_PATH = pathlib.Path(
    os.environ.get("GLORY_AVATAR_CATALOG", _REPO_ROOT / "data" / "avatars.json")
)

# 与 database/004_profile_display.sql 的 avatar_format / avatar_frame_format 一致。
# 这里再判一次不是重复：数据库那层是最后一道防线，报的是 500；
# 这一层能给出 400 和一句人能看懂的话。
_VALUE = re.compile(r"^(preset|upload):[A-Za-z0-9_-]{1,64}$")

_cache: tuple[float, dict] | None = None


class AvatarRejected(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _load() -> dict:
    """读清单，按 mtime 缓存。

    读不到就抛 —— 与词表不同，**这个不能降级成空表**：
    空清单意味着任何头像都不合法，玩家会发现自己改不了头像却没有任何提示，
    而运维那边什么错都看不到。宁可让接口 500 并在日志里留下原因。
    """
    global _cache
    mtime = _CATALOG_PATH.stat().st_mtime
    if _cache is not None and _cache[0] == mtime:
        return _cache[1]

    data = json.loads(_CATALOG_PATH.read_text(encoding="utf-8"))
    avatars = {str(e["id"]) for e in data.get("avatars", [])}
    frames = {str(e["id"]) for e in data.get("frames", [])}
    parsed = {
        "avatars": avatars,
        "frames": frames,
        "default_avatar": str(data["default_id"]),
        "default_frame": str(data["default_frame_id"]),
    }
    if parsed["default_avatar"] not in avatars:
        raise ValueError("avatars.json 的 default_id 不在清单里")
    if parsed["default_frame"] not in frames:
        raise ValueError("avatars.json 的 default_frame_id 不在清单里")
    _cache = (mtime, parsed)
    return parsed


def default_avatar() -> str:
    return "preset:%s" % _load()["default_avatar"]


def default_frame() -> str:
    return "preset:%s" % _load()["default_frame"]


def avatar_ids() -> list[str]:
    """给客户端拉可选清单用。排序是为了让响应稳定、可缓存、可断言。"""
    return sorted(_load()["avatars"])


def _check(value: str, key: str, label: str) -> str:
    if not _VALUE.match(value):
        raise AvatarRejected("format", "%s格式不对" % label)
    scheme, _, ident = value.partition(":")
    if scheme == "upload":
        # 正则允许，但功能没做。放行等于往库里写一个永远指不到文件的值。
        raise AvatarRejected("upload_not_supported", "暂不支持自定义上传")
    if ident not in _load()[key]:
        raise AvatarRejected("unknown_id", "没有这个%s" % label)
    return value


def check_avatar(value: str) -> str:
    return _check(value, "avatars", "头像")


def check_frame(value: str) -> str:
    return _check(value, "frames", "头像框")
