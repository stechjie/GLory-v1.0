"""登录接口。

    POST /v1/auth/anonymous   开一个新的匿名账号（只在客户端手上没有 refresh
                              token 时调用 —— 它天然不幂等，每次都建新玩家）
    POST /v1/auth/refresh     用 refresh token 换新会话（第二次及以后的启动走这条）
    POST /v1/auth/provider    用 Google / Apple 登录（新装、换手机、切换账号）
    POST /v1/auth/link        把 Google / Apple 绑到当前账号
    GET  /v1/auth/identities  当前账号绑了哪些

客户端的判断逻辑写在 AccountManager 里：
    有 refresh token → refresh；没有 → 玩家在启动页选游客（anonymous）或 Google / Apple（provider）。
Google / Apple 的设计见 docs/三方登录设计.md。
"""

from __future__ import annotations

import logging
import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Request, Depends, Header
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app import admin_auth, bans, db, players, login_sessions, realtime, shop
from app.config import get_settings
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.supabase_auth import AuthError, Session, SupabaseAuth
from app.routes.me import current_claims
from app.jwt_verify import Claims

log = logging.getLogger("glory.auth")

router = APIRouter(prefix="/v1/auth", tags=["auth"])


@router.post("/logout")
async def logout(claims: Annotated[Claims, Depends(current_claims)],
                 x_glory_session: Annotated[str, Header()]) -> dict:
    async with login_sessions.ownership_lock:
        await login_sessions.require(claims.auth_uid, x_glory_session)
        await login_sessions.release(claims.auth_uid, x_glory_session)
        player = await players.get_by_auth_uid(claims.auth_uid)
        if player is not None:
            await realtime.hub().disconnect_player(player.player_id, 1000, {"t": "signed_out"})
    return {"ok": True}

# 进程内共用。限流状态是内存里的，每请求新建一个等于没限流。
_settings = get_settings()
_anonymous_limiter = SlidingWindowLimiter(_settings.rate_limit_anonymous_per_hour, 3600.0)
_refresh_limiter = SlidingWindowLimiter(_settings.rate_limit_refresh_per_hour, 3600.0)
# /provider 和 /anonymous 一样会凭空造出新号，额度一样紧（各算各的）。
_provider_limiter = SlidingWindowLimiter(_settings.rate_limit_anonymous_per_hour, 3600.0)
# 绑定按玩家算。正常人一分钟点不了几次系统弹窗，这个数只挡客户端出 bug 时的狂点。
LINK_PER_MINUTE = 6
_link_limiter = SlidingWindowLimiter(LINK_PER_MINUTE, 60.0)


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
    _enforce_key(limiter, _client_ip(request))


def _enforce_key(limiter: SlidingWindowLimiter, key: str) -> None:
    try:
        limiter.check(key)
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
    session_id: uuid.UUID | None = None


class SessionResponse(BaseModel):
    player_id: uuid.UUID
    player_name: str
    created: bool
    access_token: str
    refresh_token: str
    expires_in: int
    session_id: str
    # 这个号以前玩过（等级 ≥ 2 或者已经有宠物）。教学进度只存在手机本地，
    # 换手机 / 重装后登回老号时，客户端据此跳过新手教学（docs/三方登录设计.md）。
    # 只在开新的登录会话时算；续期（带 session_id）不算，恒为 false —— 客户端只在登录时看它。
    onboarded: bool = False


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


async def _onboarded(player_id: uuid.UUID) -> bool:
    """这个号以前玩过没有：等级 ≥ 2，或者已经有宠物（2026-10-22 拍板）。

    查不到（等级表还没建、宠物表读不出来、连接池出状况）就当没玩过 —— 最坏是多看一遍教学，
    **绝不能因为这个让登录失败**，所以两处都接住一切异常。
    """
    try:
        async with db.pool().acquire() as conn:
            level = await conn.fetchval(
                "select level from player_progression where player_id = $1", player_id)
        if level is not None and int(level) >= 2:
            return True
    except Exception as exc:
        log.warning("读等级失败，按没玩过处理 player_id=%s：%s", player_id, type(exc).__name__)
    try:
        return bool((await shop.read_pets(player_id)).owned)
    except Exception as exc:  # 宠物表（data/pets/pets.json）读不出来也不能挡住登录
        log.warning("读宠物失败，按没玩过处理 player_id=%s：%s", player_id, type(exc).__name__)
        return False


async def _respond(session: Session, proposed: uuid.UUID | None, existing: uuid.UUID | None = None) -> SessionResponse:
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
    async with login_sessions.ownership_lock:
        if existing is not None:
            await login_sessions.require(session.auth_uid, str(existing))
            sid = str(existing)
        else:
            sid = await login_sessions.issue(session.auth_uid)
            await realtime.hub().disconnect_player(player.player_id, realtime.CLOSE_KICKED,
                                                   {"t": "kicked", "reason": "another_device"})
    onboarded = existing is None and not player.created and await _onboarded(player.player_id)
    return SessionResponse(
        player_id=player.player_id,
        player_name=player.player_name,
        created=player.created,
        access_token=session.access_token,
        refresh_token=session.refresh_token,
        expires_in=session.expires_in,
        session_id=sid,
        onboarded=onboarded,
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
    if body.session_id is not None:
        await login_sessions.require_refresh(body.session_id)
    client = _auth_client()
    # 🔴 被封期间换出来的新凭证寄存在这里（database/016 的 ban_refresh_handoff，为什么见那里）。
    # 还封着就直接 403，**不碰 Supabase** —— 拿旧凭证再去续会被当成重放，整条会话作废。
    handoff = await bans.find_handoff(body.refresh_token)
    if handoff is not None:
        await bans.ensure_not_banned(handoff.player_id)
    token = body.refresh_token if handoff is None else handoff.next_token
    try:
        session = await client.refresh(token)
    except AuthError as exc:
        # 401：这个 refresh token 不能用了（过期、已轮换、被吊销）。
        # 客户端收到 401 应当丢掉本地凭证、重新走 /anonymous。
        status = 401 if exc.status in (400, 401, 403) else 502
        raise HTTPException(status_code=status, detail=str(exc)) from None
    try:
        response = await _respond(session, None, body.session_id)
    except bans.AccountBanned as exc:
        # Supabase 已经把玩家手上那张换掉了，新的这张不能丢（见上）。
        await bans.hold_handoff(body.refresh_token, exc.ban.player_id, session.refresh_token)
        raise
    if handoff is not None:
        # 解封后第一次回来。**不删行、改存最新的一张**：这次的回复要是没送到，
        # 客户端还会拿同一张旧凭证来，那时还能接上。玩家一续期，存着的这张就作废了。
        await bans.hold_handoff(body.refresh_token, handoff.player_id, session.refresh_token)
    return response


# --- Google / Apple（docs/三方登录设计.md）--------------------------------------------

# Supabase 回这两种，意思都是「这个 Google / Apple 已经属于别的号」：
#   identity_already_exists —— 这个 Google 本身绑在别的号上
#   email_exists            —— 它的邮箱已经属于别的号（同一个人在两个号上分别绑了同邮箱的 Google 和 Apple）
# 一律按「不合并」处理，客户端弹「切换到那个账号 / 取消」。
IDENTITY_TAKEN_CODES = frozenset({"identity_already_exists", "email_exists"})
IDENTITY_TAKEN = "identity_taken"


class ProviderLoginRequest(BaseModel):
    provider: Literal["google", "apple"]
    # 身份证明本身。是凭证（一小时内能拿它登录），不进日志。
    id_token: str = Field(min_length=1, max_length=8192)
    # Apple 要：原文给这里，SHA-256 给 Apple。
    nonce: str | None = Field(default=None, max_length=256)
    # 同 /anonymous：新装时本机签的 id，只在这个 Google 第一次建号时用得上。
    player_id: uuid.UUID | None = None


class LinkRequest(BaseModel):
    provider: Literal["google", "apple"]
    id_token: str = Field(min_length=1, max_length=8192)
    nonce: str | None = Field(default=None, max_length=256)


class LinkedIdentityOut(BaseModel):
    provider: str
    email: str  # 打过码


class IdentitiesResponse(BaseModel):
    is_anonymous: bool
    identities: list[LinkedIdentityOut]


def mask_email(email: str) -> str:
    """ab***@gmail.com。资料页只给看个大概：手机借给别人时，邮箱不该整个露出来。"""
    name, at, domain = email.partition("@")
    if not at:
        return ""
    return (name[:2] if len(name) > 2 else name[:1]) + "***@" + domain


def _bearer(authorization: str) -> str:
    # current_claims 已经验过这个头；这里只是把令牌取出来，原样交给 Supabase。
    return authorization.partition(" ")[2].strip()


def _id_token_failure(exc: AuthError) -> HTTPException:
    """身份证明过期、无效、nonce 对不上 → Supabase 回 4xx → 400，客户端提示重试。其余算上游故障。"""
    status = 400 if exc.status is not None and 400 <= exc.status < 500 else 502
    return HTTPException(status_code=status, detail=str(exc))


async def _require_player(claims: Claims) -> None:
    # 被封的人在这里抛 AccountBanned → 403。必须在动 Supabase **之前**查：先绑上再拒绝就晚了。
    if await players.get_by_auth_uid(claims.auth_uid) is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")


@router.post("/provider", response_model=SessionResponse)
async def provider_login(body: ProviderLoginRequest, request: Request) -> SessionResponse:
    """用 Google / Apple 登录。绑过号的回到那个号；从没见过的 Google 用它开一个新号。"""
    _enforce(_provider_limiter, request)
    _require_db()
    client = _auth_client()
    try:
        session = await client.sign_in_with_id_token(body.provider, body.id_token, body.nonce)
    except AuthError as exc:
        raise _id_token_failure(exc) from None
    if await admin_auth.is_admin_account(uuid.UUID(session.auth_uid)):
        raise HTTPException(status_code=403, detail="这是运营后台的管理员账号，不能用来登录游戏，请换一个账号")
    return await _respond(session, body.player_id)


@router.post("/link", response_model=SessionResponse)
async def link(
    body: LinkRequest,
    claims: Annotated[Claims, Depends(current_claims)],
    authorization: Annotated[str, Header()],
    x_glory_session: Annotated[str, Header()],
) -> SessionResponse | JSONResponse:
    """把 Google / Apple 绑到当前账号。编号、宠物、钻石、段位都不变。

    Supabase 绑完会发一套新凭证，照 /refresh 的格式回给客户端 —— **客户端必须存回新的那张**。
    """
    _enforce_key(_link_limiter, claims.auth_uid)
    _require_db()
    await _require_player(claims)
    client = _auth_client()
    try:
        session = await client.link_identity(_bearer(authorization), body.provider, body.id_token, body.nonce)
    except AuthError as exc:
        if exc.code in IDENTITY_TAKEN_CODES:
            # 不用 HTTPException：客户端要按 code 分辨，而 409 还有一种是 session_replaced。
            return JSONResponse(status_code=409, content={
                "code": IDENTITY_TAKEN, "detail": "这个账号已经绑定了另一个游戏账号"})
        raise _id_token_failure(exc) from None
    if session.auth_uid != claims.auth_uid:
        # 不该发生：绑定只会挂到令牌所属的那个用户上。真发生了，就别把别人的会话交出去。
        log.error("绑定后用户对不上 expected=%s got=%s", claims.auth_uid, session.auth_uid)
        raise HTTPException(status_code=502, detail="绑定结果对不上当前账号")
    response = await _respond(session, None, uuid.UUID(x_glory_session))
    log.info("绑定登录方式 player_id=%s provider=%s", response.player_id, body.provider)
    return response


@router.get("/identities", response_model=IdentitiesResponse)
async def identities(
    claims: Annotated[Claims, Depends(current_claims)],
    authorization: Annotated[str, Header()],
) -> IdentitiesResponse:
    """资料页「账号与登录」区块用。邮箱每次现查 Supabase，我们的数据库不存。"""
    _require_db()
    await _require_player(claims)
    try:
        anonymous, linked = await _auth_client().linked_identities(_bearer(authorization))
    except AuthError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from None
    return IdentitiesResponse(
        is_anonymous=anonymous,
        identities=[LinkedIdentityOut(provider=i.provider, email=mask_email(i.email)) for i in linked],
    )
