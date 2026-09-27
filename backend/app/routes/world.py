"""世界频道接口（docs/聊天系统设计.md 批次 E，app/world_chat.py）。

    GET  /v1/world/messages              打开页签：最近 100 条（进程内，不查库）
    GET  /v1/world/messages?before=<id>  往上翻：比这条更早的一页（查库，最远 7 天前）
    POST /v1/world/messages              发一条

收新消息不走这里：客户端在 WebSocket 上订阅（{"t": "sub", "topic": "world"}），见 world_chat 顶部。
发送走 HTTP 的理由同私聊（routes/chat.py 顶部）：要一个绑在这次请求上的明确答复。
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from app import text_guard, world_chat
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.chat import _me
from app.routes.me import current_claims

router = APIRouter(prefix="/v1", tags=["world"])

# 🔴 都按 player_id 计，**不按 IP**：运营商 NAT 下同一出口 IP 是成片的正常玩家（同私聊）。
# 进程内计数、重启清零 —— 对 8 秒 CD 无所谓（设计文档第四节那条「CD 可以用 rate_limit，配额不行」）。
_cooldown = SlidingWindowLimiter(1, world_chat.COOLDOWN_SEC)
_global = SlidingWindowLimiter(world_chat.GLOBAL_PER_SEC, 1.0)
# 往上翻：每人每分钟最多翻几页。只防有人写个循环把 7 天的库一页页拖走。
HISTORY_PER_MINUTE = 30
_history_limiter = SlidingWindowLimiter(HISTORY_PER_MINUTE, 60.0)


class WorldItem(BaseModel):
    message_id: int
    # 发言人的好友码。「是不是我发的」由客户端拿它和自己的好友码比 —— 推送是同一份发给所有人的。
    from_code: str
    name: str
    avatar: str
    avatar_frame: str
    body: str
    created_at: str


class WorldPage(BaseModel):
    """旧到新。has_more = 往上翻还可能有（客户端据此决定要不要显示「更早的消息」）。"""

    messages: list[WorldItem]
    has_more: bool


class WorldSendBody(BaseModel):
    # 请求体的粗上界。真正的 100 字判在 text_guard —— 规范化之后才数得准。
    body: str = Field(min_length=1, max_length=1000)
    # 客户端给每条消息生成的 uuid。网络重试同一条时靠它去重（同私聊）。
    client_msg_id: uuid.UUID


class WorldSendResponse(BaseModel):
    message: WorldItem


def _unavailable() -> HTTPException:
    return HTTPException(status_code=503, detail="世界频道暂时不可用，请稍后再试",
                         headers={"X-Glory-Reason": "world_unavailable"})


def _limited(exc: RateLimited, message: str, reason: str) -> HTTPException:
    return HTTPException(status_code=429, detail=message % exc.retry_after,
                         headers={"Retry-After": str(exc.retry_after), "X-Glory-Reason": reason})


@router.get("/world/messages", response_model=WorldPage)
async def world_messages(
    claims: Annotated[Claims, Depends(current_claims)],
    before: Annotated[int | None, Query(ge=1)] = None,
    limit: Annotated[int, Query(ge=1, le=world_chat.PAGE_MAX)] = world_chat.RING_SIZE,
) -> WorldPage:
    me = await _me(claims)
    try:
        if before is None:
            items = await world_chat.latest(limit)
        else:
            try:
                _history_limiter.check(str(me.player_id))
            except RateLimited as exc:
                raise _limited(exc, "翻得太快了，%d 秒后再试", "history_rate") from None
            items = await world_chat.older(before, limit)
    except world_chat.WorldUnavailable:
        raise _unavailable() from None
    return WorldPage(messages=[WorldItem(**m.to_client()) for m in items], has_more=len(items) >= limit)


@router.post("/world/messages", response_model=WorldSendResponse)
async def send_world_message(
    body: WorldSendBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> WorldSendResponse:
    me = await _me(claims)
    # 同一条的重试（上一次其实发出去了、响应在路上丢了）：直接回上次那条。
    # 放在 CD 前面 —— 否则重试会被 8 秒 CD 挡掉，玩家看到「发得太快了」，那条却已经在频道里了。
    replayed = world_chat.channel().replayed_post(me.player_id, body.client_msg_id)
    if replayed is not None:
        return WorldSendResponse(message=WorldItem(**replayed.to_client()))
    if not world_chat.can_speak_in_world(me):
        raise HTTPException(status_code=403, detail="暂时还不能在世界频道发言",
                            headers={"X-Glory-Reason": "not_allowed"})
    # 文字先判、CD 后判：一条被拦下来的话（留了电话号码）改一改马上能重发，不用干等 8 秒。
    try:
        text = text_guard.clean_world_message(body.body)
    except text_guard.TextRejected as exc:
        raise HTTPException(status_code=400, detail=exc.message,
                            headers={"X-Glory-Reason": exc.code}) from None
    try:
        _cooldown.check(str(me.player_id))
    except RateLimited as exc:
        raise _limited(exc, "发得太快了，%d 秒后再发", "cooldown") from None
    try:
        _global.check(world_chat.TOPIC)
    except RateLimited as exc:
        raise _limited(exc, "世界频道现在太挤了，%d 秒后再试", "busy") from None
    try:
        message, _created = await world_chat.post(me, text, body.client_msg_id)
    except world_chat.Muted as exc:
        raise HTTPException(status_code=403, detail=exc.mute.message(),
                            headers={"X-Glory-Reason": "muted"}) from None
    except world_chat.WorldUnavailable:
        raise _unavailable() from None
    return WorldSendResponse(message=WorldItem(**message.to_client()))
