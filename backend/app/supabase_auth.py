"""Supabase Auth 的最小客户端。

**这个文件是整个后端唯一知道 Supabase 存在的地方**（数据库那边是标准
PostgreSQL，不算）。换掉 Auth 提供方时要改的就只有这里 —— 这正是
docs/账号系统RFC.md 第二节说的「这个选型不锁死什么」。

只做两件事：开一个匿名会话、用 refresh token 换新的 access token。
凭证的存储、轮换、吊销全是 Supabase 的职责，我们一概不碰。

⚠️ 这里流过的全是凭证。任何日志、异常信息都**不准**带上 token 或 key ——
_redact() 负责这件事，改动本文件时先看它。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import httpx

log = logging.getLogger("glory.auth")

_TIMEOUT = httpx.Timeout(10.0, connect=5.0)


class AuthError(RuntimeError):
    """Supabase Auth 拒绝了请求。message 已经脱敏，可以安全地进日志。"""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True)
class Session:
    """一次成功登录的结果。

    access_token / refresh_token 是凭证，**不要写进日志**。
    """

    auth_uid: str
    access_token: str
    refresh_token: str
    expires_in: int


def _redact(text: str, limit: int = 200) -> str:
    """把上游返回体裁短，供报错使用。

    Supabase 的错误体本身不含 token，但我们不赌这一点：只取前 limit 个字符，
    且调用方永远不把请求体拼进去。
    """
    flat = " ".join(text.split())
    return flat[:limit] + ("…" if len(flat) > limit else "")


class SupabaseAuth:
    def __init__(
        self,
        base_url: str,
        publishable_key: str,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._base = base_url.rstrip("/")
        # 注册 / 登录是公开操作，用 publishable key 就够 —— 不要在这里用
        # secret key。secret key 只该出现在需要绕过 RLS 的数据库操作里。
        self._key = publishable_key
        # 测试注入点。生产上永远是 None，走真实网络。
        # 有了它，"匿名登录没开会给出什么提示"、"刷新失败的错误里会不会带上
        # token" 这类判据才能进自动化门禁 —— 否则只能靠真实凭据手测，
        # 而让门禁依赖某人本机的 .env 就是另一种假绿。
        self._transport = transport

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=_TIMEOUT, transport=self._transport)

    @property
    def configured(self) -> bool:
        return bool(self._base and self._key)

    def _headers(self) -> dict[str, str]:
        return {
            "apikey": self._key,
            "Authorization": f"Bearer {self._key}",
            "Content-Type": "application/json",
        }

    @staticmethod
    def _to_session(payload: dict) -> Session:
        user = payload.get("user") or {}
        auth_uid = str(user.get("id") or "")
        access = str(payload.get("access_token") or "")
        refresh = str(payload.get("refresh_token") or "")
        if not (auth_uid and access and refresh):
            # 缺哪一样都不能继续 —— 半个会话比没有会话更糟。
            missing = [
                name
                for name, val in (("user.id", auth_uid), ("access_token", access), ("refresh_token", refresh))
                if not val
            ]
            raise AuthError(f"Supabase 返回的会话缺少字段：{', '.join(missing)}")
        return Session(
            auth_uid=auth_uid,
            access_token=access,
            refresh_token=refresh,
            expires_in=int(payload.get("expires_in") or 3600),
        )

    async def sign_in_anonymously(self) -> Session:
        """开一个匿名会话。

        每次调用都会在 Supabase 建一个**新的**匿名用户 —— 这个接口天然不幂等。
        所以客户端手上有 refresh token 时必须走 refresh()，不能重复调这里，
        否则每次启动都会多一个玩家。客户端侧的判断在 AccountManager 里。
        """
        url = f"{self._base}/auth/v1/signup"
        async with self._client() as client:
            resp = await client.post(url, headers=self._headers(), json={})
        if resp.status_code >= 400:
            # 最常见的一种：项目没开匿名登录。直接把话说明白，
            # 免得对着一个 422 去翻文档。
            body = _redact(resp.text)
            if "anonymous" in body.lower() and "disabled" in body.lower():
                raise AuthError(
                    "Supabase 项目没有开启匿名登录："
                    "Dashboard → Authentication → Sign In / Providers → Allow anonymous sign-ins",
                    resp.status_code,
                )
            raise AuthError(f"匿名登录被拒绝（HTTP {resp.status_code}）：{body}", resp.status_code)
        return self._to_session(resp.json())

    async def refresh(self, refresh_token: str) -> Session:
        """用 refresh token 换一份新会话。

        Supabase 默认会轮换 refresh token，所以返回的那个可能和传入的不同 ——
        客户端必须存回返回的那个，否则下一次刷新会失败。
        """
        url = f"{self._base}/auth/v1/token"
        async with self._client() as client:
            resp = await client.post(
                url,
                headers=self._headers(),
                params={"grant_type": "refresh_token"},
                json={"refresh_token": refresh_token},
            )
        if resp.status_code >= 400:
            # 刻意不把 refresh_token 拼进错误信息 —— 它是凭证。
            raise AuthError(
                f"刷新会话被拒绝（HTTP {resp.status_code}）：{_redact(resp.text)}",
                resp.status_code,
            )
        return self._to_session(resp.json())
