"""游戏上报事件的入口（app/client_events.py，docs/运营数据.md 第六节）。

    POST /v1/events    {sent_at, install_id, events: [{id, name, t, sid, props}]}

要登录（事件记在令牌对应的那个玩家名下，**不收请求体里的 player_id**）。
回 {accepted, duplicate, rejected}，客户端据此删队列；503 = 先留着，以后再发。
"""

from __future__ import annotations

import logging
import re
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field, StringConstraints

from app import client_events, db, players
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

log = logging.getLogger("glory.events")

router = APIRouter(prefix="/v1", tags=["events"])

# 客户端每 15 秒发一次，积压时连着发几批。按 player_id 计（运营商 NAT 下同一个 IP 是成片的玩家）。
EVENTS_PER_MINUTE = 20
_limiter = SlidingWindowLimiter(EVENTS_PER_MINUTE, 60.0)

# 客户端每条字符串截到 160，这里给宽一点；超了整批 422，客户端丢掉这一批。
PropValue = Annotated[str, StringConstraints(max_length=500)] | int | float | bool | None

# X-Glory-Client: protocol=34; build=123; kinds=prep_skin（AccountManager.client_header_line）
_BUILD_RE = re.compile(r"\bbuild=(\d{1,9})\b")


class EventIn(BaseModel):
    id: uuid.UUID
    name: str = Field(max_length=40)
    t: int
    sid: uuid.UUID | None = None
    props: dict[str, PropValue] = Field(default_factory=dict, max_length=32)


class EventsBody(BaseModel):
    sent_at: int
    install_id: uuid.UUID | None = None
    events: list[EventIn] = Field(max_length=client_events.BATCH_MAX)


@router.post("/events")
async def post_events(
    body: EventsBody,
    request: Request,
    claims: Annotated[Claims, Depends(current_claims)],
) -> dict:
    if not db.is_connected():
        raise HTTPException(status_code=503, detail="数据库未配置")
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    try:
        _limiter.check(str(player.player_id))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="发得太快了",
                            headers={"Retry-After": str(exc.retry_after)}) from None
    match = _BUILD_RE.search(request.headers.get("x-glory-client", ""))
    build = int(match.group(1)) if match else None
    try:
        return await client_events.record(
            player.player_id, [e.model_dump() for e in body.events], body.sent_at, body.install_id, build)
    except client_events.NotReady as exc:
        log.warning("收不了游戏上报的事件：%s", exc)
        raise HTTPException(status_code=503, detail="暂时收不了，稍后再发") from None
