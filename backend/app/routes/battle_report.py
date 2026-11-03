"""对局历史接口（docs/排位系统设计.md 第七、八节）。

    POST /v1/battle/report             玩家手机转交一份战斗服务器签过章的战报
    POST /v1/internal/battle/report    战斗服务器自己交（只收本机直连）
    GET  /v1/me/matches                我打过的局（新的在前）

## 为什么战斗服务器也要自己交（2026-11-03）

只靠手机转交的前提是「结束那一刻有人连着」。AI 补位开的桌只有一个真人，
他一退出（或掉线超时）这局就作废 —— 战报签了，可一个连着的人都没有，
账号服务器收不到就不结算：跑路不扣信誉分、不扣排位分，历史里也没有这局。
11-02 测试服上作废的 5 局一局都没记上。

两条路交的是**同一串字节**，下面按 match_uid 只记第一份，所以谁先到都一样。
手机那条留着兜底：战斗服务器交不上（账号服务器正好在重启）时，有人连着就还能补上。

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

## 战斗服务器那条只收「本机、没经过 Caddy」的请求

两个服务在同一台机器上，战斗服务器直接打 127.0.0.1:8099。但 Caddy 也在这台机器上，
它把公网的**所有**路径都转给 8099 —— TCP 那一层对端同样是 127.0.0.1。
区别是 Caddy 每次都写 X-Forwarded-For（deploy/Caddyfile 的 `header_up`，覆盖不是追加，
玩家删不掉），所以两样都看：对端必须是回环，**并且**不能带 `X-Forwarded-*`。
（uvicorn 默认还会按这个头把对端改写成玩家 IP，11-03 本机实测如此；但那取决于
uvicorn 的启动参数，不能只靠它。）

就算漏过去也伪造不了结果（可信度全在签名上），挡它是为了别让公网白白耗这边的验章 CPU。
两台服务器以后分开放时，这条会把跨机器的请求全拒掉 —— 那时要另加鉴权，不是放宽这里。
"""

from __future__ import annotations

import logging
import re
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from app import matchmaking, battle_report, db, players, ranked
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.auth import TRUSTED_PROXIES
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
REWARD_PER_MINUTE = 60
_reward_limiter = SlidingWindowLimiter(REWARD_PER_MINUTE, 60.0)

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


class RankedRewardResponse(BaseModel):
    status: str
    result: str | None = None
    coin: int | None = None
    score_before: int | None = None
    score_after: int | None = None
    coin_balance_after: int | None = None
    tier_before: int | None = None
    tier_after: int | None = None
    tier_progress: int | None = None
    tier_span: int | None = None


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


def direct_from_this_machine(request: Request) -> bool:
    """本机直连、没经过 Caddy。理由见文件头「战斗服务器那条」一节。"""
    peer = request.client.host if request.client else ""
    if peer not in TRUSTED_PROXIES:
        return False
    return not any(name.lower().startswith("x-forwarded-") for name in request.headers.keys())


async def _accept(wire: str, by: str) -> ReportResponse:
    """验章 → 入库（含结算）→ 划掉匹配名册。两条交法共用，`by` 只进日志。"""
    try:
        report = battle_report.verify(wire)
    except battle_report.ReportKeyMissing as exc:
        # 日志里留原因，给玩家的只有一句「稍后再试」—— 路径不外传。
        log.error("收不了战报：%s", exc)
        raise HTTPException(status_code=503, detail="对战服务暂时不可用，稍后再试") from None
    except battle_report.ReportRejected as exc:
        # 🔴 签名验过了却被形状校验拒掉 = **我们自己的战斗服务器有 bug**，
        # 不是玩家的问题。这条要能在日志里一眼看见。
        level = log.warning if exc.code in ("report_bad_signature", "report_malformed") else log.info
        level("战报被拒 code=%s by=%s", exc.code, by)
        raise HTTPException(
            status_code=400,
            detail=exc.message,
            headers={"X-Glory-Reason": exc.code},
        ) from None

    recorded = await battle_report.record(report)
    # Verification plus successful DB commit/deduplication is the terminal event.
    # Match by ID so delayed reports never clear a player's newer assignment.
    matchmaking.current().finish_match(report["match_uid"])
    if recorded:
        log.info(
            "记下一局 match=%s mode=%s rounds=%d outcome=%s by=%s",
            report["match_uid"], report["mode"], report["rounds"],
            report["outcome"], by,
        )
    return ReportResponse(recorded=recorded, match_uid=report["match_uid"])


@router.post("/battle/report", response_model=ReportResponse)
async def submit_report(
    body: ReportBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> ReportResponse:
    me = await _me(claims)
    _limit(_report_limiter, str(me.player_id))
    return await _accept(body.report, str(me.player_id))


@router.post("/internal/battle/report", response_model=ReportResponse)
async def submit_report_from_battle_server(body: ReportBody, request: Request) -> ReportResponse:
    """战斗服务器直交（scripts/multiplayer/BattleReportUplink.gd）。

    不要玩家身份、不限流：调用方只可能是本机进程，可信度照旧全在签名上。
    """
    if not direct_from_this_machine(request):
        log.warning("战报直交被拒：不是本机直连 peer=%s",
                    request.client.host if request.client else "unknown")
        raise HTTPException(status_code=403, detail="这个接口只收本机战斗服务器直接交的战报")
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )
    return await _accept(body.report, "battle_server")


@router.get("/me/matches", response_model=MatchesResponse)
async def my_matches(
    claims: Annotated[Claims, Depends(current_claims)],
    limit: Annotated[int, Query(ge=1, le=MAX_LIMIT)] = DEFAULT_LIMIT,
) -> MatchesResponse:
    me = await _me(claims)
    _limit(_matches_limiter, str(me.player_id))
    return MatchesResponse(matches=await battle_report.list_for_player(me.player_id, limit))


@router.get("/me/matches/{match_uid}/reward", response_model=RankedRewardResponse)
async def my_ranked_reward(
    match_uid: str,
    claims: Annotated[Claims, Depends(current_claims)],
) -> RankedRewardResponse:
    """The player's committed ranked or casual reward; missing rows remain pending."""
    if re.fullmatch(r"[0-9a-f]{32}", match_uid) is None:
        raise HTTPException(status_code=400, detail="对局编号格式不对")
    me = await _me(claims)
    _limit(_reward_limiter, str(me.player_id))
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select result, coin, score_before, score_after, coin_balance_after "
            "from ranked_reward_receipts where match_uid = $1 and player_id = $2",
            match_uid, me.player_id,
        )
    if row is None:
        # Casual payouts already live in the immutable wallet ledger. Read the
        # committed transaction rather than rerolling rewards or granting twice.
        async with db.pool().acquire() as conn:
            casual = await conn.fetchrow(
                "select case when not s.online_at_end then 'lose' "
                "when m.outcome = 'draw' then 'draw' "
                "when m.outcome = case when s.team = 0 then 'team_a' else 'team_b' end "
                "then 'win' else 'lose' end as result, "
                "l.delta as coin, l.balance_after as coin_balance_after "
                "from match_records m join match_seats s on s.match_uid = m.match_uid "
                "join wallet_ledger l on l.player_id = s.player_id "
                "and l.currency = 'coin' and l.source = 'match_reward' and l.note = $3 "
                "where m.match_uid = $1 and m.mode = 'casual' and s.player_id = $2 "
                "order by l.id limit 1",
                match_uid, me.player_id, f"casual match {match_uid}",
            )
        if casual is not None:
            return RankedRewardResponse(status="settled", result=str(casual["result"]),
                                        coin=int(casual["coin"]),
                                        coin_balance_after=int(casual["coin_balance_after"]))
        return RankedRewardResponse(status="pending")
    before = int(row["score_before"])
    after = int(row["score_after"])
    after_tier = ranked.tier_of(after)
    return RankedRewardResponse(status="settled", result=str(row["result"]),
                                coin=int(row["coin"]), score_before=before,
                                score_after=after,
                                coin_balance_after=int(row["coin_balance_after"]),
                                tier_before=ranked.tier_of(before), tier_after=after_tier,
                                tier_progress=ranked.tier_progress(after),
                                tier_span=ranked.progress_span(after))
