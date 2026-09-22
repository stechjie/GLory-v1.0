"""对局历史接口（docs/排位系统设计.md 第七、八节）。

    POST /v1/battle/report    交一份战斗服务器签过章的战报
    GET  /v1/me/matches       我打过的局（新的在前）

## 谁交都一样，交几次都一样

战报里有全场六个座位的结果，所以**六个人里只要有一个交上来就够**。
六个人各交一份是设计如此，不是重复提交 —— 第二份起返回 `recorded=false`，
**200 而不是 409**：对客户端来说「已经记上了」和「我刚记上」都是成功。

## 不要求交的人是这局里的谁

战报的可信度**全部来自签名**，和谁交上来的无关。要求「必须是这局的座位之一」
既挡不住任何东西（签名已经挡了），又会让没带名片的座位交不上来。

交的人只写进**日志**，不进表 —— 那一列为什么是死路，见 database/013_match_history.sql。

## 没配公钥 = 503

同 `/v1/battle/card` 那条：服务器配置问题，客户端据此提示「稍后再试」，
而不是把路径写进响应。对局本身不受影响 —— 只是这一局不记历史。
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from app import battle_report, db, players
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

log = logging.getLogger("glory.battle_report")

router = APIRouter(prefix="/v1", tags=["battle_report"])

# 一个正常玩家 20~30 分钟才打完一局。给到 10/分钟是留给**重试**的：
# 交战报的那一刻正好是刚打完、网络可能还没稳。按 player_id 计，不按 IP
# （运营商 NAT 下同一出口 IP 是成片的正常玩家，同 routes/loadout.py）。
REPORT_PER_MINUTE = 10
_report_limiter = SlidingWindowLimiter(REPORT_PER_MINUTE, 60.0)

MATCHES_PER_MINUTE = 30
_matches_limiter = SlidingWindowLimiter(MATCHES_PER_MINUTE, 60.0)

# 一页最多多少局。历史界面一屏十几条，20 够翻一阵了。
DEFAULT_LIMIT = 20
MAX_LIMIT = 50


class ReportBody(BaseModel):
    # 不透明字符串。客户端从战斗服务器原样拿到、原样交上来，**不解析、不改**。
    report: str = Field(max_length=battle_report.MAX_WIRE_CHARS)


class ReportResponse(BaseModel):
    # False = 这局已经被同房间的别人交过了。**不是错误。**
    recorded: bool
    match_uid: str


class MatchesResponse(BaseModel):
    matches: list[dict]


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


@router.post("/battle/report", response_model=ReportResponse)
async def submit_report(
    body: ReportBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> ReportResponse:
    me = await _me(claims)
    _limit(_report_limiter, str(me.player_id))

    try:
        report = battle_report.verify(body.report)
    except battle_report.ReportKeyMissing as exc:
        # 日志里留原因，给玩家的只有一句「稍后再试」—— 路径不外传。
        log.error("收不了战报：%s", exc)
        raise HTTPException(status_code=503, detail="对战服务暂时不可用，稍后再试") from None
    except battle_report.ReportRejected as exc:
        # 🔴 签名验过了却被形状校验拒掉 = **我们自己的战斗服务器有 bug**，
        # 不是玩家的问题。这条要能在日志里一眼看见。
        level = log.warning if exc.code in ("report_bad_signature", "report_malformed") else log.info
        level("战报被拒 code=%s player=%s", exc.code, me.player_id)
        raise HTTPException(
            status_code=400,
            detail=exc.message,
            headers={"X-Glory-Reason": exc.code},
        ) from None

    recorded = await battle_report.record(report)
    if recorded:
        log.info(
            "记下一局 match=%s mode=%s rounds=%d outcome=%s by=%s",
            report["match_uid"], report["mode"], report["rounds"],
            report["outcome"], me.player_id,
        )
    return ReportResponse(recorded=recorded, match_uid=report["match_uid"])


@router.get("/me/matches", response_model=MatchesResponse)
async def my_matches(
    claims: Annotated[Claims, Depends(current_claims)],
    limit: Annotated[int, Query(ge=1, le=MAX_LIMIT)] = DEFAULT_LIMIT,
) -> MatchesResponse:
    me = await _me(claims)
    _limit(_matches_limiter, str(me.player_id))
    return MatchesResponse(matches=await battle_report.list_for_player(me.player_id, limit))
