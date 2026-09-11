"""私聊接口（docs/聊天系统设计.md 批次 C）。

    GET  /v1/me/chats                       会话列表：全部好友 + 各自的最后一条与未读
    GET  /v1/me/chats/{code}/messages       拉历史（?after=<message_id> 是增量）
    POST /v1/me/chats/{code}/messages       发一条
    POST /v1/me/chats/{code}/read           推进已读游标

一律用好友码定位，不用 player_id —— 同 routes/friends.py 顶部那条。

## 为什么发送走 HTTP、不走 WebSocket

发送需要一个**绑在这次请求上**的明确答复：发成功了（带 message_id）/ 你们已不是好友 /
发太快了 / 文字不合规。HTTP 本来就是一问一答，走的是和加好友同一条已经验过的路
（令牌校验、错误表、限流）。改用 WebSocket 发的话，就得自己再造一套
「请求编号 + 确认收到 + 超时重发」。

WebSocket 只负责一件事：把新消息**推**给对方。它断线重连期间照样能发，
漏掉的推送在重连后按游标补拉 —— 推送只是「快」，正确性全押在游标上。

## 推送不看隐身

对方在线就经 ② 的 WebSocket 推一条 {"t": "dm", ...}，**绝不查 presence_visibility**。
已定：隐身的人照样收私聊（设计文档第八节第 6 条）。隐身管的是「别人能不能看到我在线」，
与「消息能不能送到我这里」是两回事，混在一起会造出「我隐身了所以朋友的消息收不到」。
对方不在线就什么都不做：消息已经在库里，他下次打开时按游标拉。
"""

from __future__ import annotations

import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Query
from pydantic import BaseModel, Field

from app import chat, db, players, realtime, text_guard
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.friends import _norm
from app.routes.me import current_claims

log = logging.getLogger("glory.chat")

router = APIRouter(prefix="/v1", tags=["chat"])

# 推给客户端的消息类型。与客户端 ChatService.DM_TYPE 一致（tools/chat_check.gd 钉着）——
# 对不上的话推送全部落进 RealtimeService 的「未知类型」分支，不报错，就是收不到。
DM_TYPE = "dm"

# 每人每分钟最多发多少条。**只防刷屏**，不负责总量 ——
# 总量由「每对好友只存最近 200 条」在结构上封顶（见 database/007_chat.sql）。
#
# 按 player_id 计，**不按 IP**：运营商 NAT 下同一出口 IP 是成片的正常玩家
# （同交友文档第四节第 2 条）。进程内计数、重启清零 —— 对「防刷屏」无所谓。
SEND_PER_MINUTE = 30
_send_limiter = SlidingWindowLimiter(SEND_PER_MINUTE, 60.0)

# 业务拒绝 -> HTTP 状态码。理由同 routes/friends.py 的同名表：
# 这些 code 会出现在客户端的错误处理里，散在各处迟早会出现同一个 code 两种状态。
_STATUS_BY_CODE = {
    "player_not_found": 404,
    "not_friends": 403,
    "you_blocked_them": 403,
    "cannot_message_self": 400,
    "send_conflict": 409,
}


class MessageItem(BaseModel):
    message_id: int
    # 相对**这次请求的人**说的。服务端不把 player_id 发给客户端 —— 那是内部身份。
    from_me: bool
    body: str
    created_at: str


class ChatItem(BaseModel):
    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    online: bool
    unread: bool
    # null = 还没聊过。
    last_message: MessageItem | None = None


class ChatsResponse(BaseModel):
    """列表包一层对象，不返回顶层数组 —— 客户端 _request 只接受 Dictionary，
    顶层数组会静默变成空（有测试钉着，见 test_friends）。"""

    chats: list[ChatItem]


class MessagesResponse(BaseModel):
    messages: list[MessageItem]


class SendBody(BaseModel):
    # 这里只是请求体的粗上界。真正的 200 字判在 text_guard —— 规范化**之后**才数得准。
    body: str = Field(min_length=1, max_length=2000)
    # 客户端给每条消息生成的 uuid。重发同一条时靠它去重，见 chat.send()。
    client_msg_id: uuid.UUID


class SendResponse(BaseModel):
    message: MessageItem


class ReadBody(BaseModel):
    last_read_id: int = Field(ge=0)


# --- 组装 ---------------------------------------------------------------------


async def _me(claims: Claims) -> players.Player:
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    return player


def _reject(exc: chat.ChatRejected) -> HTTPException:
    return HTTPException(
        status_code=_STATUS_BY_CODE.get(exc.code, 400),
        detail=exc.message,
        headers={"X-Glory-Reason": exc.code},
    )


def _item(message: chat.Message, viewer_id: uuid.UUID) -> MessageItem:
    return MessageItem(
        message_id=message.message_id,
        from_me=message.sender_id == viewer_id,
        body=message.body,
        created_at=message.created_at.isoformat(),
    )


# --- 接口 ---------------------------------------------------------------------


@router.get("/me/chats", response_model=ChatsResponse)
async def my_chats(
    claims: Annotated[Claims, Depends(current_claims)],
) -> ChatsResponse:
    me = await _me(claims)
    rows = await chat.list_chats(me.player_id)
    return ChatsResponse(chats=[
        ChatItem(
            friend_code=r.friend_code,
            player_name=r.player_name,
            avatar=r.avatar,
            avatar_frame=r.avatar_frame,
            online=r.online,
            unread=r.unread,
            last_message=_item(r.last_message, me.player_id) if r.last_message else None,
        )
        for r in rows
    ])


@router.get("/me/chats/{code}/messages", response_model=MessagesResponse)
async def chat_messages(
    code: Annotated[str, Path(min_length=8, max_length=8)],
    claims: Annotated[Claims, Depends(current_claims)],
    after: Annotated[int, Query(ge=0)] = 0,
) -> MessagesResponse:
    me = await _me(claims)
    try:
        rows = await chat.history(me.player_id, _norm(code), after)
    except chat.ChatRejected as exc:
        raise _reject(exc) from None
    return MessagesResponse(messages=[_item(m, me.player_id) for m in rows])


@router.post("/me/chats/{code}/messages", response_model=SendResponse)
async def send_message(
    code: Annotated[str, Path(min_length=8, max_length=8)],
    body: SendBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> SendResponse:
    me = await _me(claims)
    try:
        _send_limiter.check(str(me.player_id))
    except RateLimited as exc:
        raise HTTPException(
            status_code=429,
            detail="发得太快了，%d 秒后再试" % exc.retry_after,
            headers={"Retry-After": str(exc.retry_after)},
        ) from None
    try:
        text = text_guard.clean_chat_message(body.body)
    except text_guard.TextRejected as exc:
        raise HTTPException(
            status_code=400, detail=exc.message, headers={"X-Glory-Reason": exc.code},
        ) from None
    try:
        result = await chat.send(me.player_id, _norm(code), text, body.client_msg_id)
    except chat.ChatRejected as exc:
        raise _reject(exc) from None

    if result.deliver_to is not None:
        # 事务已经提交了才推（chat.send 返回时）。反过来的话，对方可能先收到推送、
        # 再按游标去拉却拉不到这一条。
        delivered = await realtime.hub().send_to_player(result.deliver_to, {
            "t": DM_TYPE,
            "from": me.friend_code,
            "message": _item(result.message, result.deliver_to).model_dump(),
        })
        if delivered == 0:
            # 不在线不是错误：消息已经在库里，他下次打开时按游标拉。
            log.debug("私聊对方不在线，等他下次拉取 message_id=%d", result.message.message_id)

    return SendResponse(message=_item(result.message, me.player_id))


@router.post("/me/chats/{code}/read", status_code=204)
async def mark_read(
    code: Annotated[str, Path(min_length=8, max_length=8)],
    body: ReadBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> None:
    me = await _me(claims)
    try:
        await chat.mark_read(me.player_id, _norm(code), body.last_read_id)
    except chat.ChatRejected as exc:
        raise _reject(exc) from None
