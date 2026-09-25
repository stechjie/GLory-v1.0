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

import base64
import json
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


# --- 网页后台：邮箱密码 + 手机验证器（docs/运营后台设计.md 第四节）------------------------
#
# 只给管理员用。玩家从来不走这几条 —— 玩家是匿名账号。
# 这几个调用拿的都是**管理员自己的**会话令牌，不是 secret key。


@dataclass(frozen=True)
class PasswordLogin:
    """密码对了之后的一半会话（aal1）。还要过手机验证器才算登录。"""

    auth_uid: str
    access_token: str
    # 已经绑好的手机验证器（TOTP）的 factor id。空 = 还没绑。
    verified_factor: str
    # 绑到一半（扫了码没输对）留下的，重新绑之前要删掉。
    unverified_factors: tuple[str, ...]


@dataclass(frozen=True)
class Enrollment:
    factor_id: str
    qr_code: str   # data:image/svg+xml;base64,… 直接放进 <img src>（见 qr_data_uri）
    secret: str    # 扫不了码时手动输入


def jwt_claim(token: str, name: str) -> str:
    """读 JWT 里的一个字段，**不验签**。只用在刚从 Supabase 直接拿回来的令牌上。"""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return str(json.loads(base64.urlsafe_b64decode(payload)).get(name, ""))
    except (IndexError, ValueError):
        return ""


_SVG_URI_PREFIX = "data:image/svg+xml;utf-8,"


def qr_data_uri(qr_code: str) -> str:
    """Supabase 给的二维码 → 能直接放进 <img src> 的地址。

    🔴 Supabase 的接口直接回**原始 SVG 代码**（`<svg …>`），「前面拼上 data:image/svg+xml;utf-8,」
    是它的 JS 客户端库自己做的 —— 我们不走那个库，拿到的就是裸代码，直接当图片地址 = 显示不出来
    （2026-09-25 第一次连真 Supabase 踩到，假服务回的是带前缀的）。
    就算带了那个前缀也不能直接用：SVG 里的颜色写法 `#000` 在图片地址里会被当成「#」后面的锚点截掉。
    所以一律转成 base64 形式，两种回法都能显示。
    """
    raw = qr_code.strip()
    if raw.startswith("data:image/svg+xml;base64,"):
        return raw
    if raw.startswith(_SVG_URI_PREFIX):
        raw = raw[len(_SVG_URI_PREFIX):]
    return "data:image/svg+xml;base64," + base64.b64encode(raw.encode("utf-8")).decode("ascii")


class SupabaseAdminAuth(SupabaseAuth):
    def _as_user(self, access_token: str) -> dict[str, str]:
        return {"apikey": self._key, "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json"}

    async def _post_json(self, path: str, headers: dict, body: dict, what: str,
                         params: dict | None = None) -> dict:
        async with self._client() as client:
            resp = await client.post(f"{self._base}{path}", headers=headers, json=body, params=params)
        if resp.status_code >= 400:
            # 不把请求体拼进错误：里面有密码 / 验证码。
            raise AuthError(f"{what}被拒绝（HTTP {resp.status_code}）：{_redact(resp.text)}", resp.status_code)
        return resp.json()

    async def sign_in_password(self, email: str, password: str) -> PasswordLogin:
        payload = await self._post_json(
            "/auth/v1/token", self._headers(), {"email": email, "password": password}, "邮箱密码登录",
            params={"grant_type": "password"})
        user = payload.get("user") or {}
        verified = ""
        unverified: list[str] = []
        for factor in user.get("factors") or []:
            if str(factor.get("factor_type", "")) != "totp":
                continue
            if str(factor.get("status", "")) == "verified":
                verified = verified or str(factor.get("id", ""))
            else:
                unverified.append(str(factor.get("id", "")))
        access = str(payload.get("access_token") or "")
        uid = str(user.get("id") or "")
        if not (access and uid):
            raise AuthError("Supabase 返回的登录结果缺少 access_token 或 user.id")
        return PasswordLogin(uid, access, verified, tuple(u for u in unverified if u))

    async def unenroll(self, access_token: str, factor_id: str) -> None:
        async with self._client() as client:
            resp = await client.delete(f"{self._base}/auth/v1/factors/{factor_id}",
                                       headers=self._as_user(access_token))
        if resp.status_code >= 400 and resp.status_code != 404:
            raise AuthError(f"清理没绑完的验证器被拒绝（HTTP {resp.status_code}）：{_redact(resp.text)}",
                            resp.status_code)

    async def enroll_totp(self, access_token: str, friendly_name: str) -> Enrollment:
        payload = await self._post_json(
            "/auth/v1/factors", self._as_user(access_token),
            {"factor_type": "totp", "friendly_name": friendly_name, "issuer": "Glory 运营后台"},
            "绑定手机验证器")
        totp = payload.get("totp") or {}
        factor_id = str(payload.get("id") or "")
        if not factor_id or not totp.get("qr_code"):
            raise AuthError("Supabase 没有返回验证器的二维码（项目里可能没开 MFA 的 TOTP）")
        return Enrollment(factor_id, qr_data_uri(str(totp.get("qr_code"))), str(totp.get("secret") or ""))

    async def verify_totp(self, access_token: str, factor_id: str, code: str) -> str:
        """出一道题再用验证码答它。返回过了两步验证（aal2）的 access token。"""
        challenge = await self._post_json(
            f"/auth/v1/factors/{factor_id}/challenge", self._as_user(access_token), {}, "验证器出题")
        payload = await self._post_json(
            f"/auth/v1/factors/{factor_id}/verify", self._as_user(access_token),
            {"challenge_id": str(challenge.get("id") or ""), "code": code}, "验证码")
        token = str(payload.get("access_token") or "")
        if jwt_claim(token, "aal") != "aal2":
            raise AuthError("验证码通过了，但 Supabase 返回的令牌不是两步验证级别（aal2）")
        return token
