"""登录接口。

    POST /v1/auth/anonymous   开一个新的匿名账号（只在客户端手上没有 refresh
                              token 时调用 —— 它天然不幂等，每次都建新玩家）
    POST /v1/auth/refresh     用 refresh token 换新会话（第二次及以后的启动走这条）

客户端的判断逻辑很简单，写在 AccountManager 里：
    有 refresh token → refresh；失败或没有 → anonymous。
"""

from __future__ import annotations

import logging
import uuid

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app import db, players
from app.config import get_settings
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.supabase_auth import AuthError, Session, SupabaseAuth

log = logging.getLogger("glory.auth")

router = APIRouter(prefix="/v1/auth", tags=["auth"])

# 进程内共用。限流状态是内存里的，每请求新建一个等于没限流。
_settings = get_settings()
_anonymous_limiter = SlidingWindowLimiter(_settings.rate_limit_anonymous_per_hour, 3600.0)
_refresh_limiter = SlidingWindowLimiter(_settings.rate_limit_refresh_per_hour, 3600.0)


# 可信反向代理。**只有从这些地址进来的请求，X-Forwarded-For 才作数。**
#
# 生产部署里 Caddy 与后端在同一台机器上，后端只监听 127.0.0.1
# （见 deploy/glory-backend.service），所以可信来源就是本机回环。
TRUSTED_PROXIES = frozenset({"127.0.0.1", "::1"})


def _client_ip(request: Request) -> str:
    """限流用的来源标识。

    ### 为什么不能直接读 X-Forwarded-For

    那个头是**客户端可以随便写的**。盲信它的话，攻击者每次请求换一个假 IP
    就完全绕过限流 —— 比不限流还糟，因为你以为限住了。

    所以判断顺序是：**先看这个请求是不是从可信代理来的**。
      - 不是（有人绕过 Caddy 直连 8099）→ 一个字都不信，用真实对端；
      - 是 → 才采信 X-Forwarded-For。

    ### 为什么这样是安全的

    两层：Caddyfile 里是 `header_up X-Forwarded-For {remote_host}`，
    **覆盖**而不是追加 —— 玩家自己塞的假值在 Caddy 那一层就被丢掉了；
    这里再确认一次请求确实来自 Caddy。

    ### 前提：Caddy 前面没有别的代理

    现在 Caddy 直接面向公网，所以这个头里只有一个 IP，取整段就是玩家的。
    以后若在前面再加一层（Cloudflare 之类），头会变成 `真实IP, 中间代理...`
    的链条，那时**必须**改成按可信代理数量从右往左取，否则取到的是代理的 IP，
    等于全体又共用一个额度。改动前先回来看这段。

    ### 它挡不住什么

    同一出口 IP 的人共用额度（办公室、校园网、手机运营商 NAT），
    以及手上有大量 IP 的攻击者。那是按 IP 限流的固有边界，
    真要解决得靠设备标识或人机验证。
    """
    peer = request.client.host if request.client else "unknown"
    if peer not in TRUSTED_PROXIES:
        return peer
    forwarded = request.headers.get("X-Forwarded-For", "").strip()
    if not forwarded:
        return peer
    # 即便当前只会有一个值，也按逗号切一下取第一段 —— 万一哪天 Caddy 的配置
    # 从覆盖改成了追加，这里不会把整串当成一个 key（那会让每次请求都是新 key，
    # 限流静默失效）。
    return forwarded.split(",")[0].strip() or peer


def _enforce(limiter: SlidingWindowLimiter, request: Request) -> None:
    try:
        limiter.check(_client_ip(request))
    except RateLimited as exc:
        raise HTTPException(
            status_code=429,
            detail=str(exc),
            headers={"Retry-After": str(exc.retry_after)},
        ) from None


class AnonymousRequest(BaseModel):
    # 客户端设备首次读档时签发的 UUIDv4（见 SaveSchema.new_player_id）。
    # 可选：不传就由服务端签。传了的好处是本地存档与服务器账号从第一天起
    # 就是同一个 id，不会出现「两个 player_id」的歧义。
    #
    # 注意它**不是**身份凭证 —— 能不能登录完全由 Supabase 的 auth_uid 决定。
    player_id: uuid.UUID | None = None


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1, max_length=4096)


class SessionResponse(BaseModel):
    player_id: uuid.UUID
    player_name: str
    created: bool
    access_token: str
    refresh_token: str
    expires_in: int


def _auth_client() -> SupabaseAuth:
    s = get_settings()
    client = SupabaseAuth(s.supabase_url, s.supabase_publishable_key)
    if not client.configured:
        raise HTTPException(
            status_code=503,
            detail="Supabase 未配置：backend/.env 里缺 GLORY_SUPABASE_URL 或 GLORY_SUPABASE_PUBLISHABLE_KEY",
        )
    return client


def _require_db() -> None:
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )


async def _respond(session: Session, proposed: uuid.UUID | None) -> SessionResponse:
    try:
        player = await players.resolve_or_create(session.auth_uid, proposed)
    except players.PlayerIdConflict:
        # 客户端提议的 id 被占了。不接管别人的账号，让它重签一个。
        #
        # 这里刻意**不**回退到服务端签发：那样客户端本地的 id 会和服务器不一致，
        # 而客户端那边有「签发一次、永不改变」的不变量（tools/player_identity_check）。
        # 让客户端明确知道要重签，比两边悄悄不一致好。
        raise HTTPException(
            status_code=409,
            detail="proposed player_id 已被占用，请重新签发一个后重试",
        ) from None

    log.info(
        "登录成功 player_id=%s created=%s",  # 只记 player_id，绝不记 token
        player.player_id,
        player.created,
    )
    return SessionResponse(
        player_id=player.player_id,
        player_name=player.player_name,
        created=player.created,
        access_token=session.access_token,
        refresh_token=session.refresh_token,
        expires_in=session.expires_in,
    )


@router.post("/anonymous", response_model=SessionResponse)
async def anonymous(body: AnonymousRequest, request: Request) -> SessionResponse:
    """开一个新的匿名账号。

    ⚠️ 每次调用都会新建一个玩家。客户端手上有 refresh token 时必须走
    /refresh，否则每次启动都会多一个账号。

    限流最紧的就是这个端点：它是唯一会**凭空造出数据**的公开接口。
    """
    _enforce(_anonymous_limiter, request)
    _require_db()
    client = _auth_client()
    try:
        session = await client.sign_in_anonymously()
    except AuthError as exc:
        # AuthError 的 message 已经脱敏（见 supabase_auth._redact），可以外传。
        raise HTTPException(status_code=502, detail=str(exc)) from None
    return await _respond(session, body.player_id)


@router.post("/refresh", response_model=SessionResponse)
async def refresh(body: RefreshRequest, request: Request) -> SessionResponse:
    """用 refresh token 换新会话。

    Supabase 默认轮换 refresh token，返回的那个可能和传入的不同 ——
    **客户端必须存回返回的那个**，否则下次刷新会失败。
    """
    _enforce(_refresh_limiter, request)
    _require_db()
    client = _auth_client()
    try:
        session = await client.refresh(body.refresh_token)
    except AuthError as exc:
        # 401：这个 refresh token 不能用了（过期、已轮换、被吊销）。
        # 客户端收到 401 应当丢掉本地凭证、重新走 /anonymous。
        status = 401 if exc.status in (400, 401, 403) else 502
        raise HTTPException(status_code=status, detail=str(exc)) from None
    return await _respond(session, None)
