"""系统邮件接口（docs/邮件系统设计.md）。

    GET  /v1/me/mail                    邮箱（新的在前，最多 100 封）
    POST /v1/me/mail/{mail_id}/read     标记已读
    POST /v1/me/mail/{mail_id}/claim    领这一封的附件
    POST /v1/me/mail/claim-all          一键领取
    POST /v1/me/mail/{mail_id}/delete   删这一封（要已读、附件已领完）
    POST /v1/me/mail/delete-read        删掉所有已读且附件已领完的

发邮件**不在这里** —— 管理员在 Supabase 里调 send_mail / send_mail_all（database/012_mail.sql）。
这边没有任何「发」的接口，被拿到令牌也发不了钱。

## 时间只发相对值

`age_sec`（发出多久了）、`expires_in_sec`（还有多久过期），不发绝对时间 ——
手机的钟可能是错的，拿绝对时间在手机上算「还剩几天」会算歪。
"""

from __future__ import annotations

import datetime as dt
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path
from pydantic import BaseModel

from app import db, mail, players, shop
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

router = APIRouter(prefix="/v1/me/mail", tags=["mail"])

# 每人每分钟的操作上限（读 / 领 / 删合计）。玩家一封封点开看，一分钟也点不到这么多；
# 只防脚本刷。按 player_id 计，不按 IP（同 routes/shop.py 的理由）。
ACTION_PER_MINUTE = 60
_action_limiter = SlidingWindowLimiter(ACTION_PER_MINUTE, 60.0)

# 邮件编号是 bigint。不设上限的话，一个超大的数会在数据库那层报错、变成 500。
MailId = Annotated[int, Path(ge=1, le=2**63 - 1)]

_STATUS_BY_CODE = {
    "mail_not_found": 404,
    "nothing_to_claim": 409,
    "not_read": 409,
    "unclaimed_attachments": 409,
}


class ItemModel(BaseModel):
    id: str
    kind: str        # avatar / avatar_frame / pet（同 data/shop.json）
    name: str
    name_en: str


class MailModel(BaseModel):
    id: int
    title_zh: str
    body_zh: str
    title_en: str    # 空串 = 没写英文，客户端显示中文（同公告）
    body_en: str
    diamond: int
    coin: int
    items: list[ItemModel]
    age_sec: int
    expires_in_sec: int
    read: bool
    claimed: bool


class MailListResponse(BaseModel):
    """列表包一层对象，不返回顶层数组 —— 客户端 _request 只接受 Dictionary。"""

    mails: list[MailModel]


class WalletModel(BaseModel):
    diamond: int
    coin: int


class ClaimResponse(BaseModel):
    mail_ids: list[int]          # 这次真的领到的
    diamond: int
    coin: int
    granted: list[ItemModel]
    skipped: list[ItemModel]     # 已经拥有、跳过的
    wallet: WalletModel          # 领完之后的余额，客户端直接拿它刷新
    replayed: bool               # 单封：之前已经领过，这次什么都没发


class OkResponse(BaseModel):
    ok: bool


class DeletedResponse(BaseModel):
    deleted: int


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


def _check_rate(player_id: uuid.UUID) -> None:
    try:
        _action_limiter.check(str(player_id))
    except RateLimited as exc:
        raise HTTPException(
            status_code=429,
            detail="操作太快了，%d 秒后再试" % exc.retry_after,
            headers={"Retry-After": str(exc.retry_after)},
        ) from None


def _reject(exc: mail.MailRejected) -> HTTPException:
    return HTTPException(
        status_code=_STATUS_BY_CODE.get(exc.code, 400),
        detail=exc.message,
        headers={"X-Glory-Reason": exc.code},
    )


def _item(content_id: str) -> ItemModel:
    found = shop.content_item(content_id)
    if found is None:
        # 列表已经把这种邮件滤掉了（mail.item_problem）；能走到这里只可能是目录刚好在两次读之间改了。
        return ItemModel(id=content_id, kind="", name=content_id, name_en=content_id)
    return ItemModel(id=content_id, kind=found.kind, name=found.name, name_en=found.name_en)


def _seconds(delta: dt.timedelta) -> int:
    return max(0, int(delta.total_seconds()))


def _mail_model(m: mail.Mail, now: dt.datetime) -> MailModel:
    return MailModel(
        id=m.mail_id,
        title_zh=m.title_zh,
        body_zh=m.body_zh,
        title_en=m.title_en,
        body_en=m.body_en,
        diamond=m.diamond,
        coin=m.coin,
        items=[_item(i) for i in m.items],
        age_sec=_seconds(now - m.created_at),
        expires_in_sec=_seconds(m.expires_at - now),
        read=m.read,
        claimed=m.claimed,
    )


def _claim_response(r: mail.ClaimResult) -> ClaimResponse:
    return ClaimResponse(
        mail_ids=list(r.mail_ids),
        diamond=r.diamond,
        coin=r.coin,
        granted=[_item(i) for i in r.granted],
        skipped=[_item(i) for i in r.skipped],
        wallet=WalletModel(diamond=r.wallet.diamond, coin=r.wallet.coin),
        replayed=r.replayed,
    )


# --- 接口 ---------------------------------------------------------------------


@router.get("", response_model=MailListResponse)
async def my_mail(claims: Annotated[Claims, Depends(current_claims)]) -> MailListResponse:
    me = await _me(claims)
    mails = await mail.list_mail(me.player_id)
    now = dt.datetime.now(dt.timezone.utc)
    return MailListResponse(mails=[_mail_model(m, now) for m in mails])


@router.post("/claim-all", response_model=ClaimResponse)
async def claim_all(claims: Annotated[Claims, Depends(current_claims)]) -> ClaimResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    return _claim_response(await mail.claim_all(me.player_id))


@router.post("/delete-read", response_model=DeletedResponse)
async def delete_read(claims: Annotated[Claims, Depends(current_claims)]) -> DeletedResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    return DeletedResponse(deleted=await mail.delete_read(me.player_id))


@router.post("/{mail_id}/read", response_model=OkResponse)
async def read(mail_id: MailId, claims: Annotated[Claims, Depends(current_claims)]) -> OkResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        await mail.mark_read(me.player_id, mail_id)
    except mail.MailRejected as exc:
        raise _reject(exc) from None
    return OkResponse(ok=True)


@router.post("/{mail_id}/claim", response_model=ClaimResponse)
async def claim(mail_id: MailId, claims: Annotated[Claims, Depends(current_claims)]) -> ClaimResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        result = await mail.claim(me.player_id, mail_id)
    except mail.MailRejected as exc:
        raise _reject(exc) from None
    return _claim_response(result)


@router.post("/{mail_id}/delete", response_model=OkResponse)
async def delete(mail_id: MailId, claims: Annotated[Claims, Depends(current_claims)]) -> OkResponse:
    me = await _me(claims)
    _check_rate(me.player_id)
    try:
        await mail.delete(me.player_id, mail_id)
    except mail.MailRejected as exc:
        raise _reject(exc) from None
    return OkResponse(ok=True)
