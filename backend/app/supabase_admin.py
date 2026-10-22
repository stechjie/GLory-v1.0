"""Supabase Auth 的管理接口。只做一件事：注销账号时删掉 Supabase 那边的用户。

为什么单独一个文件：这里要用 **secret key**（能绕过一切权限），
而 supabase_auth.py 写明了不碰 secret key。两者分开，谁在用密钥一眼就看得出来。

为什么要删：绑了 Google / Apple 之后，Supabase 用户里有邮箱。只删游戏资料、留着它，
注销就没删干净（docs/三方登录设计.md 第七节第 6 条）。
"""

from __future__ import annotations

import httpx

from app.config import get_settings

_TIMEOUT = httpx.Timeout(10.0, connect=5.0)


class AdminUnavailable(RuntimeError):
    """删不掉。message 不含密钥，可以进日志。"""


def _headers(key: str) -> dict[str, str]:
    # 同 admin.py 传图那段：新式的 sb_secret_… 不是 JWT，只放 apikey；
    # 旧式的 service_role 密钥本身就是 JWT，要同时放进 Authorization。
    headers = {"apikey": key}
    if not key.startswith("sb_"):
        headers["Authorization"] = f"Bearer {key}"
    return headers


async def delete_user(auth_uid: str, transport: httpx.AsyncBaseTransport | None = None) -> None:
    """删掉这个 Supabase 用户，连同他绑的 Google / Apple 和邮箱。

    用户本来就不在（404）当成功：结果和预期一样。
    """
    s = get_settings()
    key = s.supabase_secret_key.strip()
    if not (s.supabase_url and key):
        raise AdminUnavailable("没配 GLORY_SUPABASE_URL 或 GLORY_SUPABASE_SECRET_KEY")
    url = f"{s.supabase_url.rstrip('/')}/auth/v1/admin/users/{auth_uid}"
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            resp = await client.delete(url, headers=_headers(key))
    except httpx.HTTPError as exc:
        raise AdminUnavailable(f"连不上 Supabase（{type(exc).__name__}）") from None
    if resp.status_code == 404:
        return
    if resp.status_code >= 400:
        # 不回显响应体：管理接口的报错里可能带内部信息。
        raise AdminUnavailable(f"Supabase 拒绝删除用户（HTTP {resp.status_code}）")
