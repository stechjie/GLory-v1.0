"""在线状态接口。

    PUT /v1/me/presence             心跳：{room_id | null}
    GET /v1/me/presence/visibility  两个开关
    PUT /v1/me/presence/visibility  两个开关

设计文档：docs/交友系统设计.md 第二节与第四节。

**刻意没有「查某人在不在线」的接口。** 在线状态只随好友列表一起返回
（GET /v1/me/friends）。单独提供一个按好友码查在线的接口，等于给任何人
一个「这个玩家现在在不在」的探测器 —— 而这个信息只该对好友开放。

## 🔴 限流按 player_id，不能按 IP

心跳是**每个在线玩家都在发**的东西。app/rate_limit.py 是按 IP 的，
它自己的注释就写了局限：「同一出口 IP 的人共用额度 —— 办公室、校园网，
**手机运营商 NAT 尤其严重**」。按 IP 限流会把同一个基站下的正常玩家批量误杀。

心跳接口本来就要带令牌，所以按 player_id 计。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app import db, players, presence, rate_limit
from app.jwt_verify import Claims
from app.routes.me import current_claims

router = APIRouter(prefix="/v1", tags=["presence"])

# 客户端每 HEARTBEAT_INTERVAL_SEC(60) 发一次，另外进出房间时会立刻补发一次。
# 额度给到 30/分钟：正常用法用不到 3 次，剩下的余量留给
# 「连续切换房间」这种真实但不常见的操作。超过就是客户端写错了或有人在刷。
_LIMITER = rate_limit.SlidingWindowLimiter(30, 60.0)


class HeartbeatBody(BaseModel):
    # null = 在线但不在任何房间（主菜单等）。
    # **不传和传 null 是同一个意思** —— 这里没有「不动」的语义，
    # 心跳本来就是整份覆盖当前位置。
    room_id: int | None = None


class VisibilityBody(BaseModel):
    presence_visibility: str = Field(default="friends")
    room_visibility: str = Field(default="friends")


class VisibilityResponse(BaseModel):
    presence_visibility: str
    room_visibility: str


def _require_db() -> None:
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )


async def _me(claims: Claims):
    _require_db()
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    return player.player_id


@router.put("/me/presence", status_code=204)
async def heartbeat(
    body: HeartbeatBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> None:
    player_id = await _me(claims)
    try:
        # 按 player_id 而不是 IP —— 理由见本文件顶部。
        _LIMITER.check(str(player_id))
    except rate_limit.RateLimited as exc:
        raise HTTPException(
            status_code=429, detail=str(exc), headers={"Retry-After": str(exc.retry_after)}
        ) from None
    try:
        await presence.heartbeat(player_id, body.room_id)
    except presence.PresenceRejected as exc:
        raise HTTPException(status_code=400, detail=exc.message) from None


@router.get("/me/presence/visibility", response_model=VisibilityResponse)
async def get_visibility(
    claims: Annotated[Claims, Depends(current_claims)],
) -> VisibilityResponse:
    return VisibilityResponse(**await presence.get_visibility(await _me(claims)))


@router.put("/me/presence/visibility", response_model=VisibilityResponse)
async def set_visibility(
    body: VisibilityBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> VisibilityResponse:
    """两个开关**整份覆盖**，不是打补丁。

    已确认：在线状态只对好友可见，所以只有 friends / nobody 两档，
    没有 'public'。列上留着文本枚举是为了以后要加档位时不用写迁移（同 004）。
    """
    try:
        updated = await presence.set_visibility(
            await _me(claims), body.presence_visibility, body.room_visibility
        )
    except presence.PresenceRejected as exc:
        raise HTTPException(status_code=400, detail=exc.message) from None
    return VisibilityResponse(**updated)
