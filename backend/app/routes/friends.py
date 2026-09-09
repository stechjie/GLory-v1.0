"""交友接口。

    GET    /v1/me/friends                        好友列表（含在线状态与房间号）
    GET    /v1/me/friends/requests               收到的 + 发出的，一次拿全
    POST   /v1/me/friends/requests               发起
    POST   /v1/me/friends/requests/{code}/accept 通过
    DELETE /v1/me/friends/requests/{code}        拒绝 / 取消（都是删记录）
    DELETE /v1/me/friends/{code}                 删好友（双向）
    GET    /v1/me/blocks                         拉黑列表
    POST   /v1/me/blocks                         拉黑
    DELETE /v1/me/blocks/{code}                  解除拉黑

设计文档：docs/交友系统设计.md。

**一律用好友码定位，不用 player_id** —— 沿用 docs/玩家资料系统设计.md 第六节：
player_id 是内部身份，没必要出现在客户端可见的地址里。

好友码大小写不敏感（玩家会照着截图手抄），库里一律存大写。
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path
from pydantic import BaseModel, Field

from app import db, friends, players
from app.jwt_verify import Claims
from app.routes.me import current_claims

log = logging.getLogger("glory.friends")

router = APIRouter(prefix="/v1", tags=["friends"])

# 业务拒绝 -> HTTP 状态码。
#
# 单独列一张表而不是在每个 raise 处写状态码：这些 code 会出现在客户端的
# 错误处理里，散在各处迟早会出现同一个 code 在两处返回不同状态。
# 漏登记的一律 400（见 _reject）—— 保守，且会在测试里立刻暴露。
_STATUS_BY_CODE = {
    "player_not_found": 404,
    "no_pending_request": 404,
    "not_friends": 404,
    "not_blocked": 404,
    "already_friends": 409,
    "already_requested": 409,
    "friend_limit_reached": 409,
    "request_conflict": 409,
    "daily_quota_exceeded": 429,
    "request_refused": 403,
    "you_blocked_them": 403,
    "cannot_add_self": 400,
    "cannot_block_self": 400,
    "cannot_accept_own": 400,
    "bad_friend_code": 400,
}


class FriendCodeBody(BaseModel):
    friend_code: str = Field(min_length=8, max_length=8)


class FriendItem(BaseModel):
    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    online: bool
    # null = 不在房间 / 不在线 / 对方关掉了房间可见性。
    # 三种情况对观众刻意**不可分辨** —— 同 to_public 的处理。
    room_id: int | None = None


class RequestItem(BaseModel):
    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    created_at: str


class RequestsResponse(BaseModel):
    incoming: list[RequestItem]
    outgoing: list[RequestItem]


class BlockItem(BaseModel):
    friend_code: str
    player_name: str
    avatar: str
    created_at: str


class FriendsResponse(BaseModel):
    """列表**包一层对象**，不返回顶层数组。

    两个理由，第二个是硬的：
      1. 顶层数组没法扩展 —— 以后要加分页/总数就得破坏性改接口。
      2. **客户端的 AccountManager._request 只接受 Dictionary 响应体**
         （JSON 解析后 typeof != TYPE_DICTIONARY 就丢弃）。返回顶层数组的话，
         好友列表会**静默变成空**，不报错、不崩溃 —— 最难查的那一类。
         有测试钉着「任何接口都不许返回顶层数组」。
    """

    friends: list[FriendItem]


class BlocksResponse(BaseModel):
    blocks: list[BlockItem]


class SendRequestResponse(BaseModel):
    # 'pending' 或 'accepted'。后者是交叉请求：对方已经先加过我，直接成为好友。
    # 客户端要据此决定是提示"已发送"还是"已成为好友"。
    result: str


# --- 组装 ---------------------------------------------------------------------


def _require_db() -> None:
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )


def _reject(exc: friends.FriendsRejected) -> HTTPException:
    return HTTPException(
        status_code=_STATUS_BY_CODE.get(exc.code, 400),
        detail=exc.message,
        headers={"X-Glory-Reason": exc.code},
    )


def _norm(code: str) -> str:
    """好友码归一：去空白 + 转大写。

    库里一律存大写（004）。玩家会照着截图手抄，不该因为按了大写锁失败。
    """
    return code.strip().upper()


async def _me(claims: Claims):
    _require_db()
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    return player.player_id


# --- 好友列表 -----------------------------------------------------------------


@router.get("/me/friends", response_model=FriendsResponse)
async def my_friends(
    claims: Annotated[Claims, Depends(current_claims)],
) -> FriendsResponse:
    rows = await friends.list_friends(await _me(claims))
    return FriendsResponse(friends=[
        FriendItem(
            friend_code=r.friend_code,
            player_name=r.player_name,
            avatar=r.avatar,
            avatar_frame=r.avatar_frame,
            online=r.online,
            room_id=r.room_id,
        )
        for r in rows
    ])


@router.get("/me/friends/requests", response_model=RequestsResponse)
async def my_requests(
    claims: Annotated[Claims, Depends(current_claims)],
) -> RequestsResponse:
    """收到的 + 发出的**一次拿全**。

    刻意不拆成两个接口：拆开会让界面发两个并发请求，
    多一处会出「收到的到了、发出的没到」的中间态
    （同 docs/玩家资料系统设计.md 第六节那次调整）。
    """
    data = await friends.list_requests(await _me(claims))

    def pack(items) -> list[RequestItem]:
        return [
            RequestItem(
                friend_code=i.friend_code,
                player_name=i.player_name,
                avatar=i.avatar,
                avatar_frame=i.avatar_frame,
                created_at=i.created_at.isoformat(),
            )
            for i in items
        ]

    return RequestsResponse(incoming=pack(data["incoming"]), outgoing=pack(data["outgoing"]))


# --- 请求 ---------------------------------------------------------------------


@router.post("/me/friends/requests", response_model=SendRequestResponse)
async def send_request(
    body: FriendCodeBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> SendRequestResponse:
    me = await _me(claims)
    try:
        result = await friends.send_request(me, _norm(body.friend_code))
    except friends.FriendsRejected as exc:
        raise _reject(exc) from None
    log.info("friend request %s -> %s", me, result)
    return SendRequestResponse(result=result)


@router.post("/me/friends/requests/{code}/accept", status_code=204)
async def accept_request(
    code: Annotated[str, Path(min_length=8, max_length=8)],
    claims: Annotated[Claims, Depends(current_claims)],
) -> None:
    try:
        await friends.accept_request(await _me(claims), _norm(code))
    except friends.FriendsRejected as exc:
        raise _reject(exc) from None


@router.delete("/me/friends/requests/{code}", status_code=204)
async def drop_request(
    code: Annotated[str, Path(min_length=8, max_length=8)],
    claims: Annotated[Claims, Depends(current_claims)],
) -> None:
    """拒绝收到的 / 取消发出的。**两者都是删掉那一行**，没有 'rejected' 状态。

    已确认的产品决定：留 rejected 的话误拒的人永远加不回来；
    删掉则靠每日配额（friend_request_log）与拉黑防重发。
    """
    try:
        await friends.remove_request(await _me(claims), _norm(code))
    except friends.FriendsRejected as exc:
        raise _reject(exc) from None


# --- 好友 ---------------------------------------------------------------------


@router.delete("/me/friends/{code}", status_code=204)
async def drop_friend(
    code: Annotated[str, Path(min_length=8, max_length=8)],
    claims: Annotated[Claims, Depends(current_claims)],
) -> None:
    """删好友。**双向消失，且不通知对方。**

    界面要提示操作者「对方也会从他的列表里消失」—— 那是给操作的人看的，
    不是通知被删的人（通知等于制造对抗，而且对方也做不了什么）。
    """
    try:
        await friends.remove_friend(await _me(claims), _norm(code))
    except friends.FriendsRejected as exc:
        raise _reject(exc) from None


# --- 拉黑 ---------------------------------------------------------------------


@router.get("/me/blocks", response_model=BlocksResponse)
async def my_blocks(
    claims: Annotated[Claims, Depends(current_claims)],
) -> BlocksResponse:
    rows = await friends.list_blocks(await _me(claims))
    return BlocksResponse(blocks=[
        BlockItem(
            friend_code=r.friend_code,
            player_name=r.player_name,
            avatar=r.avatar,
            created_at=r.created_at.isoformat(),
        )
        for r in rows
    ])


@router.post("/me/blocks", status_code=204)
async def add_block(
    body: FriendCodeBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> None:
    """拉黑。**同一事务里删掉已有关系与待处理请求** —— 见 friends.block()。

    与举报是两件事：举报是给我们看的、异步的；拉黑即时生效。
    界面上位置要明显不同（资料页已经有举报按钮）。
    """
    try:
        await friends.block(await _me(claims), _norm(body.friend_code))
    except friends.FriendsRejected as exc:
        raise _reject(exc) from None


@router.delete("/me/blocks/{code}", status_code=204)
async def remove_block(
    code: Annotated[str, Path(min_length=8, max_length=8)],
    claims: Annotated[Claims, Depends(current_claims)],
) -> None:
    """解除拉黑。**不恢复好友关系** —— 拉黑是一次明确的断交，
    要重新做好友得重新走请求流程。
    """
    try:
        await friends.unblock(await _me(claims), _norm(code))
    except friends.FriendsRejected as exc:
        raise _reject(exc) from None
