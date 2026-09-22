"""匹配队列接口（docs/排位系统设计.md 第五节）。

    POST   /v1/match/queue     进队列
    DELETE /v1/match/queue     退出（待确认阶段退出 = 拒绝，那一桌当场解散）
    GET    /v1/match/state     当前状态
    POST   /v1/match/accept    确认，六个人都确认才成局
    GET    /v1/match/window    排位窗口（不要登录）

## 推送是主路径，轮询是兜底

状态变化通过 WebSocket 推（`t: "match"`，见 app/matchmaking.py 那几个
`*_message`）。`GET /v1/match/state` 是给 WS 正好断着的客户端兜底的 ——
**推送不是唯一的送达路径**，不然切一次后台就卡在「匹配中」再也出不来。

## 匹配好之后名片在哪领

不在这里。六个人都确认之后，各自照常调 `POST /v1/battle/card` ——
那个接口会自动带上会合键与队伍（见 routes/loadout.py 里那段注释）。

这样名片的 60 秒有效期是从「他真的要连了」那一刻算起，而不是从匹配成功算起。

## 排位的三道闸

排位开了（第 5 步），但比休闲多三道（`ranked.queue_gate`）：

    1. 时间窗口   马来西亚时间 19:00–23:00（只管排位）
    2. 禁赛       跑路 / 没按准备累计出来的，有到期时间
    3. 信誉分     <70 不能排位，<60 连普通匹配都不行

三道都**明说原因**（`X-Glory-Reason`）。排在一条永远凑不齐的队里，
是最让人摸不着头脑的一种失败。
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db, matchmaking, players, ranked
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

log = logging.getLogger("glory.matchmaking")

router = APIRouter(prefix="/v1/match", tags=["matchmaking"])

# 进出队列的额度。正常玩家一局才进出一次；给到 30/分钟是留给「排到一半改主意」
# 那种反复横跳的人，以及断线重连时客户端自己补发的那几次。
QUEUE_PER_MINUTE = 30
_queue_limiter = SlidingWindowLimiter(QUEUE_PER_MINUTE, 60.0)

# 查状态宽松得多：WS 断着的时候客户端要靠它轮询。
STATE_PER_MINUTE = 120
_state_limiter = SlidingWindowLimiter(STATE_PER_MINUTE, 60.0)


class QueueBody(BaseModel):
    mode: str = matchmaking.CASUAL


class MatchStateResponse(BaseModel):
    # 与 WS 推送的那几条**同一个形状**（app/matchmaking.py 的 *_message）。
    # 两边形状不一样的话，客户端得写两套解析 —— 那是两处会分叉的地方。
    state: dict


class WindowResponse(BaseModel):
    accepting: bool
    open: bool
    opens_in_sec: int
    closes_in_sec: int


# 闸的文案。**不含任何内部细节** —— 它原样显示给玩家。
_GATE_TEXT = {
    ranked.GATE_WINDOW_CLOSED: "排位每天 19:00 - 23:00 开放",
    ranked.GATE_BANNED: "你被暂时禁止排队，稍后再试",
    ranked.GATE_CREDIT_TOO_LOW: "信誉分过低，暂时不能排这个模式",
}


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


def _limit(limiter: SlidingWindowLimiter, key: str) -> None:
    try:
        limiter.check(key)
    except RateLimited as exc:
        raise HTTPException(
            status_code=429,
            detail="操作太快了，%d 秒后再试" % exc.retry_after,
            headers={"Retry-After": str(exc.retry_after)},
        ) from None


@router.post("/queue", response_model=MatchStateResponse)
async def join_queue(
    body: QueueBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> MatchStateResponse:
    me = await _me(claims)
    _limit(_queue_limiter, str(me.player_id))
    mode = body.mode.strip()
    if mode not in matchmaking.KNOWN_MODES:
        raise HTTPException(
            status_code=400, detail="没有这个模式",
            headers={"X-Glory-Reason": "unknown_mode"})
    if mode not in matchmaking.OPEN_MODES:
        # 明说「还没开」，不要假装匹配得到 —— 排在一条永远凑不齐的队里
        # 是最让人摸不着头脑的一种失败。
        raise HTTPException(
            status_code=409, detail="这个模式还没开放",
            headers={"X-Glory-Reason": "mode_closed"})
    # 时间窗口 / 禁赛 / 信誉分。三道都明说原因。
    async with db.pool().acquire() as conn:
        reason = await ranked.queue_gate(conn, me.player_id, mode)
    if reason:
        raise HTTPException(
            status_code=409, detail=_GATE_TEXT.get(reason, "现在不能排这个模式"),
            headers={"X-Glory-Reason": reason})
    return MatchStateResponse(state=matchmaking.current().join(me.player_id, mode))


@router.delete("/queue", response_model=MatchStateResponse)
async def leave_queue(claims: Annotated[Claims, Depends(current_claims)]) -> MatchStateResponse:
    me = await _me(claims)
    _limit(_queue_limiter, str(me.player_id))
    return MatchStateResponse(state=matchmaking.current().leave(me.player_id))


@router.get("/state", response_model=MatchStateResponse)
async def match_state(claims: Annotated[Claims, Depends(current_claims)]) -> MatchStateResponse:
    me = await _me(claims)
    _limit(_state_limiter, str(me.player_id))
    return MatchStateResponse(state=matchmaking.current().state_of(me.player_id))


@router.post("/accept", response_model=MatchStateResponse)
async def accept_match(claims: Annotated[Claims, Depends(current_claims)]) -> MatchStateResponse:
    """确认。

    **重复确认不是错误** —— 弱网下客户端会重发，而且玩家点两下很正常。
    已经确认过就把当前状态再说一遍。
    """
    me = await _me(claims)
    _limit(_queue_limiter, str(me.player_id))
    return MatchStateResponse(state=matchmaking.current().accept(me.player_id))


@router.get("/window", response_model=WindowResponse)
async def ranked_window() -> WindowResponse:
    """排位窗口的当前状态。**不要登录** —— 它对所有人都一样，而且客户端在登录页
    就要拿它来决定「排位」按钮显示倒计时还是「可以排」。

    🔴 **只有服务器说了算。** 客户端改系统时区就能绕过本地判断，而排位是发分的
    （docs/排位系统设计.md 第二节）。这个接口是那条规则的落地方式。
    """
    return WindowResponse(**ranked.window_state())


class MyRankedResponse(BaseModel):
    # 段位是分数算出来的，**不是存的**（014 的文件头）。这里现算现发，
    # 客户端别自己再除一遍 —— 那就是第二个真相。
    season: int
    score: int
    tier: int
    tier_progress: int
    games: int
    wins: int
    win_streak: int
    # 信誉分只给自己看（第四节）。公开等于发一个新的骂人理由。
    credit: int
    credit_warn: bool
    banned_sec: int


# 🔴 这一条挂在 /v1/me 下，不在 /v1/match 下 —— 它是「我的资料」，不是「匹配状态」。
# 本文件的 router 带着 /v1/match 前缀，所以单开一个。
me_router = APIRouter(prefix="/v1/me", tags=["ranked"])


@me_router.get("/ranked", response_model=MyRankedResponse)
async def my_ranked(claims: Annotated[Claims, Depends(current_claims)]) -> MyRankedResponse:
    """我的排位分、段位与信誉分。资料页「战绩」块用（第 5c 步）。

    从没打过排位的人没有行 —— 回默认值，不建行。建行是结算时的事
    （`ranked._ranked_rows`），在这里建等于让「看一眼」也产生写入。
    """
    me = await _me(claims)
    _limit(_state_limiter, str(me.player_id))
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select season, score, games, wins, win_streak from player_ranked"
            " where player_id = $1", me.player_id)
        credit_row = await conn.fetchrow(
            "select score, banned_until from player_credit where player_id = $1", me.player_id)
    score = int(row["score"]) if row else 0
    credit = int(credit_row["score"]) if credit_row else ranked.CREDIT_START
    banned_until = credit_row["banned_until"] if credit_row else None
    banned_sec = 0
    if ranked.is_banned(banned_until):
        import datetime as _dt

        banned_sec = max(0, int((banned_until - _dt.datetime.now(_dt.UTC)).total_seconds()))
    return MyRankedResponse(
        season=int(row["season"]) if row else 1,
        score=score,
        tier=ranked.tier_of(score),
        tier_progress=ranked.tier_progress(score),
        games=int(row["games"]) if row else 0,
        wins=int(row["wins"]) if row else 0,
        win_streak=int(row["win_streak"]) if row else 0,
        credit=credit,
        credit_warn=credit < ranked.CREDIT_WARN,
        banned_sec=banned_sec,
    )
