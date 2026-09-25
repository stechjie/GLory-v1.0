"""网页后台的登录与会话（docs/运营后台设计.md 第四节，database/018_admin.sql）。

## 登录两步

  1. 邮箱 + 密码 → Supabase 验（管理员是 Supabase Auth 里的邮箱用户，玩家是匿名用户，不是一批人）。
     密码对了，再查 admin_users 名单 —— **不在名单里的一律当成「账号或密码不对」**，不透露这个邮箱存不存在。
  2. 手机验证器 6 位码 → Supabase 验，拿到两步验证级别（aal2）的令牌才算登录。
     第一次登录还没绑验证器：先出二维码让他扫，扫完输一次码就绑上了。

两步之间的状态（第一步拿到的半个会话）存在进程内存里，10 分钟过期
（第一次绑验证器要在手机上手动输密钥时，5 分钟太紧）。

## 会话

登录成功后发一个我们自己的随机令牌，放在 HttpOnly Cookie 里（页面的 JS 读不到），
**Supabase 的令牌用完就丢**，不留在浏览器、也不留在服务器。
每个请求都重新查一次 admin_users：停用（active = false）的人下一个请求起就进不去。

会话在进程内存里：**账号服务器一重启，所有管理员都要重新登录。** 单实例（single_instance.py），
不需要跨进程共享；重启本来就少，重新登录一次的代价远小于把会话落库要多管的东西。

## 防跨站

Cookie 是 SameSite=Strict；所有写操作还要带 `X-Glory-Admin: 1` 头 ——
别的网站的页面发不出带自定义头的跨站请求（要过 CORS 预检，而我们不开 CORS）。
"""

from __future__ import annotations

import dataclasses
import hashlib
import logging
import secrets
import time
import uuid

import httpx
from fastapi import HTTPException, Request

from app import db
from app.config import get_settings
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.supabase_auth import AuthError, SupabaseAdminAuth

log = logging.getLogger("glory.admin")

SESSION_COOKIE = "glory_admin"
PENDING_COOKIE = "glory_admin_pending"
COOKIE_PATH = "/admin"
WRITE_HEADER = "x-glory-admin"

SESSION_TTL_SEC = 12 * 3600.0
PENDING_TTL_SEC = 600.0

# 登录尝试：每个来源 IP 15 分钟 10 次（密码和验证码合计）。
_login_limiter = SlidingWindowLimiter(10, 900.0)


@dataclasses.dataclass(frozen=True)
class Admin:
    auth_uid: uuid.UUID
    name: str


@dataclasses.dataclass
class _Session:
    auth_uid: uuid.UUID
    expires_at: float


@dataclasses.dataclass
class _Pending:
    auth_uid: uuid.UUID
    name: str
    access_token: str
    factor_id: str
    enrolling: bool
    expires_at: float


_sessions: dict[str, _Session] = {}
_pending: dict[str, _Pending] = {}


def _digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _new_token() -> str:
    return secrets.token_urlsafe(32)


def _prune(now: float) -> None:
    for store in (_sessions, _pending):
        for key in [k for k, v in store.items() if v.expires_at <= now]:
            del store[key]


def reset() -> None:
    """只给测试用。"""
    _sessions.clear()
    _pending.clear()


def auth_client() -> SupabaseAdminAuth:
    s = get_settings()
    client = SupabaseAdminAuth(s.supabase_url, s.supabase_publishable_key)
    if not client.configured:
        raise HTTPException(status_code=503, detail="服务器没配 Supabase（GLORY_SUPABASE_URL / PUBLISHABLE_KEY）")
    return client


def _client_ip(request: Request) -> str:
    # 同 routes/auth.py 的 _client_ip：只信本机 Caddy 转来的 X-Forwarded-For。
    from app.routes.auth import _client_ip as trusted_ip

    return trusted_ip(request)


def check_login_rate(request: Request) -> None:
    try:
        _login_limiter.check(_client_ip(request))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="登录尝试太多，%d 秒后再试" % exc.retry_after) from None


async def roster_name(auth_uid: uuid.UUID) -> str | None:
    """在名单里、没被停用 → 名字；否则 None。"""
    async with db.pool().acquire() as conn:
        name = await conn.fetchval(
            "select name from admin_users where auth_uid = $1 and active", auth_uid)
    return None if name is None else str(name)


_BAD_LOGIN = "账号或密码不对，或者这个账号不是管理员"
_UNREACHABLE = "连不上 Supabase（%s），稍后再试"


async def begin_login(client: SupabaseAdminAuth, email: str, password: str) -> tuple[str, dict]:
    """第一步：邮箱密码。返回 (两步之间的令牌, 给页面的回答)。"""
    try:
        login = await client.sign_in_password(email, password)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=_UNREACHABLE % type(exc).__name__) from None
    except AuthError as exc:
        if exc.status in (400, 401, 422):
            raise HTTPException(status_code=401, detail=_BAD_LOGIN) from None
        raise HTTPException(status_code=502, detail=str(exc)) from None
    auth_uid = uuid.UUID(login.auth_uid)
    name = await roster_name(auth_uid)
    if name is None:
        log.warning("后台登录：密码对了但不在管理员名单里 auth_uid=%s", auth_uid)
        raise HTTPException(status_code=401, detail=_BAD_LOGIN)

    answer: dict = {"step": "code"}
    factor_id = login.verified_factor
    enrolling = not factor_id
    if enrolling:
        # 上次扫了码没输对留下的半成品，不删的话 Supabase 不让再绑一个。
        try:
            for stale in login.unverified_factors:
                await client.unenroll(login.access_token, stale)
            enrollment = await client.enroll_totp(login.access_token, "glory-admin")
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=_UNREACHABLE % type(exc).__name__) from None
        except AuthError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from None
        factor_id = enrollment.factor_id
        answer = {"step": "enroll", "qr_code": enrollment.qr_code, "secret": enrollment.secret}

    token = _new_token()
    now = time.monotonic()
    _prune(now)
    _pending[_digest(token)] = _Pending(auth_uid, name, login.access_token, factor_id, enrolling,
                                        now + PENDING_TTL_SEC)
    return token, answer


async def finish_login(client: SupabaseAdminAuth, pending_token: str, code: str) -> tuple[str, str]:
    """第二步：验证码。返回 (会话令牌, 管理员名字)。"""
    now = time.monotonic()
    _prune(now)
    pending = _pending.get(_digest(pending_token))
    if pending is None:
        raise HTTPException(status_code=401, detail="登录已过期，请重新输入邮箱密码")
    try:
        await client.verify_totp(pending.access_token, pending.factor_id, code)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=_UNREACHABLE % type(exc).__name__) from None
    except AuthError as exc:
        if exc.status in (400, 401, 422):
            raise HTTPException(status_code=401, detail="验证码不对（看一下手机上的时间准不准）") from None
        raise HTTPException(status_code=502, detail=str(exc)) from None
    del _pending[_digest(pending_token)]
    # 两步之间被停用了也不放。
    if await roster_name(pending.auth_uid) is None:
        raise HTTPException(status_code=401, detail=_BAD_LOGIN)
    token = _new_token()
    _sessions[_digest(token)] = _Session(pending.auth_uid, now + SESSION_TTL_SEC)
    log.info("后台登录 admin=%s%s", pending.name, "（首次绑定验证器）" if pending.enrolling else "")
    return token, pending.name


def logout(token: str) -> None:
    _sessions.pop(_digest(token), None)


async def current_admin(request: Request) -> Admin:
    """所有后台接口的依赖。没登录 / 过期 / 被停用 → 401。"""
    token = request.cookies.get(SESSION_COOKIE, "")
    now = time.monotonic()
    session = _sessions.get(_digest(token)) if token else None
    if session is None or session.expires_at <= now:
        raise HTTPException(status_code=401, detail="没有登录或登录已过期")
    if not db.is_connected():
        raise HTTPException(status_code=503, detail="数据库未配置")
    name = await roster_name(session.auth_uid)
    if name is None:
        _sessions.pop(_digest(token), None)
        raise HTTPException(status_code=401, detail="这个管理员账号已被停用")
    return Admin(session.auth_uid, name)


async def writing_admin(request: Request) -> Admin:
    """会改东西的接口用这个：多一道防跨站。"""
    if request.headers.get(WRITE_HEADER) != "1":
        raise HTTPException(status_code=403, detail="缺少 X-Glory-Admin 头（只接受后台页面发来的请求）")
    return await current_admin(request)


def cookie_kwargs() -> dict:
    return {
        "httponly": True,
        "samesite": "strict",
        # 线上是 HTTPS；本机开发是 http://localhost，浏览器不会存 Secure 的 Cookie。
        "secure": not get_settings().is_dev,
        "path": COOKIE_PATH,
    }
