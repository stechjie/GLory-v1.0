"""举报接口（app/reports.py）。

    POST /v1/reports      举报一个玩家（资料页、世界频道、私聊、房间 / 对局里）

处理在网页后台（docs/运营后台设计.md「举报」页）。玩家这边只拿到「已收到」，不回处理结果 ——
第一版没有回执（和封号、禁言的通知是两回事：被处理的人自己会在登录 / 发言时看到原因）。
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app import reports, text_guard
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.chat import _me
from app.routes.friends import _norm
from app.routes.me import current_claims

router = APIRouter(prefix="/v1", tags=["reports"])

# 每人每小时最多举报几次。按 player_id 计（同私聊的理由）。只防有人写循环刷举报队列 ——
# 同一个人对同一个人重复举报本来就只算一条（数据库唯一索引），这一道管的是「换着人刷」。
REPORTS_PER_HOUR = 10
_limiter = SlidingWindowLimiter(REPORTS_PER_HOUR, 3600.0)


class ReportBody(BaseModel):
    target_code: str = Field(min_length=8, max_length=8)
    context: str = Field(max_length=16)
    reason: str = Field(max_length=16)
    # 世界频道里举报某一条时带上它（服务器会核对是不是这个人发的）。
    message_id: int | None = Field(default=None, ge=1)
    detail: str | None = Field(default=None, max_length=1000)


class ReportResponse(BaseModel):
    report_id: int


@router.post("/reports", response_model=ReportResponse)
async def report_player(
    body: ReportBody,
    claims: Annotated[Claims, Depends(current_claims)],
) -> ReportResponse:
    me = await _me(claims)
    try:
        _limiter.check(str(me.player_id))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="举报太频繁了，请稍后再试",
                            headers={"Retry-After": str(exc.retry_after)}) from None
    try:
        detail = text_guard.clean_report_detail(body.detail)
    except text_guard.TextRejected as exc:
        raise HTTPException(status_code=400, detail=exc.message,
                            headers={"X-Glory-Reason": exc.code}) from None
    try:
        report_id, _duplicate = await reports.create(
            me, _norm(body.target_code), body.context, body.reason, body.message_id, detail)
    except reports.ReportRejected as exc:
        raise HTTPException(status_code=exc.status, detail=exc.message,
                            headers={"X-Glory-Reason": exc.code}) from None
    except reports.ReportsUnavailable:
        raise HTTPException(status_code=503, detail="举报暂时提交不了，请稍后再试",
                            headers={"X-Glory-Reason": "reports_unavailable"}) from None
    # 重复举报回原来那条的编号，响应长得和第一次一样（app/reports.py 顶部）。
    return ReportResponse(report_id=report_id)
