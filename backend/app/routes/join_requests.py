"""好友界面「加入」要好友同意（2026-11-26）。规则见 app/join_requests.py 的文件头。

三个接口，全是「转一条实时推送」：
  POST   /v1/me/join-requests                 我向好友申请进他的房间
  POST   /v1/me/join-requests/{id}/reply      我回复别人发给我的申请（同意 / 拒绝）
  DELETE /v1/me/join-requests                 我撤回自己发出去的申请

推送三种（客户端 Main._on_join_request_realtime）：
  room_join_request   给被申请的好友：谁想进哪个房间
  room_join_reply     给申请人：对方同意 / 拒绝
  room_join_cancel    给被申请的好友：对方撤回了（或改去申请别人了），把问询框收掉
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field

from app import db, friends, join_requests, players, profile, realtime
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

log = logging.getLogger("glory.join_requests")

router = APIRouter(prefix="/v1/me/join-requests", tags=["join-requests"])
# 连点「加入」不该刷屏对方：3 秒一次。
_request_limiter = SlidingWindowLimiter(1, 3.0)


class RequestBody(BaseModel):
    friend_code: str = Field(min_length=8, max_length=8)
    room_id: int = Field(gt=0)


class RequestResponse(BaseModel):
    request_id: str
    expires_sec: int


class ReplyBody(BaseModel):
    accept: bool


async def _me(claims: Claims) -> players.Player:
    if not db.is_connected():
        raise HTTPException(status_code=503, detail="账号数据库暂不可用")
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        # 不用 404：客户端把 404 / 405 当成「这台服务器还没有这个接口」（旧版本），
        # 会退回老的直接加入。账号本身有问题不能走那条退路。
        raise HTTPException(status_code=401, detail="找不到玩家账号，请重新登录")
    return player


@router.post("", response_model=RequestResponse)
async def request_join(body: RequestBody,
                       claims: Annotated[Claims, Depends(current_claims)]) -> RequestResponse:
    me = await _me(claims)
    code = body.friend_code.strip().upper()
    try:
        _request_limiter.check(str(me.player_id))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="点得太快了，请稍后再试") from exc
    try:
        relation = await friends.relation_to(me.player_id, code)
    except friends.FriendsRejected:
        relation = "none"
    if relation != "friends":
        raise HTTPException(status_code=403, detail="只能申请加入好友的房间")
    target = await profile.get_by_friend_code(code)
    if target is None or not realtime.hub().is_online(target.player_id):
        raise HTTPException(status_code=409, detail="好友当前不在线")
    request, replaced = join_requests.current().create(me.player_id, target.player_id, body.room_id)
    if replaced is not None and replaced.id != request.id:
        # 上一张申请作废：让上一位好友那边的问询框收掉，别留一个点了没用的框。
        await realtime.hub().send_to_player(replaced.target, {
            "t": "room_join_cancel", "request_id": replaced.id})
    await realtime.hub().send_to_player(target.player_id, {
        "t": "room_join_request", "request_id": request.id, "room_id": request.room_id,
        "from_code": me.friend_code, "from_name": me.player_name,
        "expires_sec": int(join_requests.TTL_SEC),
    })
    return RequestResponse(request_id=request.id, expires_sec=int(join_requests.TTL_SEC))


@router.post("/{request_id}/reply", status_code=204)
async def reply_join(request_id: str, body: ReplyBody,
                     claims: Annotated[Claims, Depends(current_claims)]) -> Response:
    me = await _me(claims)
    request = join_requests.current().take(request_id, me.player_id)
    if request is None:
        raise HTTPException(status_code=409, detail="这条申请已经过期")
    await realtime.hub().send_to_player(request.requester, {
        "t": "room_join_reply", "request_id": request.id, "accept": bool(body.accept),
        "room_id": request.room_id,
        "from_code": me.friend_code, "from_name": me.player_name,
    })
    return Response(status_code=204)


@router.delete("", status_code=204)
async def cancel_join(claims: Annotated[Claims, Depends(current_claims)]) -> Response:
    me = await _me(claims)
    request = join_requests.current().cancel(me.player_id)
    if request is not None:
        await realtime.hub().send_to_player(request.target, {
            "t": "room_join_cancel", "request_id": request.id})
    return Response(status_code=204)
