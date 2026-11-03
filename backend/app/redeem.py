"""兑换码（database/044_redeem_codes.sql，2026-11-03 用户逐条拍板）。

玩家填码 → 账号服务器核对 → 发一封带奖励的系统邮件（钻石进赠送列，领取走 mail.claim）。
建码在网页后台（app/admin.py，要第二个管理员批准），撤回一个人就能做。

## 🔴 这是全系统唯一一个「猜对了就给钱」的接口

防爆破按**账号**（这个接口要登录），不按 IP —— 正好躲开按 IP 限流的固有缺陷：
马来西亚运营商 NAT 后面几万人共一个出口，按 IP 会误伤一片。
只数「码不存在」：填了过期、撤回、领完的码是手慢的真玩家，不是在猜码。
计数在进程内存里（同 rate_limit.py 的局限：单 worker 才准，重启清零）。

## 一次兑换的顺序

  1. 同一个号的并发兑换排队（advisory lock，理由同 friends._lock_players）
  2. 锁住码那一行（for update）：撤回、领完的判断都在锁里做，不会判完就变
  3. 查「这个码我领过吗」「这个活动我领过吗」
  4. used_count + 1（条件 update，044 的约束是最后一道）
  5. 建邮件、写领取记录

全部在一个事务里。第 5 步撞唯一索引（理论上不会：第 1 步已经排队了）就整笔回滚，
次数不会白扣。
"""

from __future__ import annotations

import dataclasses
import logging
import re
import unicodedata
import uuid

from app import db, mail
from app.config import get_settings
from app.rate_limit import SlidingWindowLimiter

log = logging.getLogger("glory.redeem")

# 与 044 redeem_code_format 一致。
CODE_RE = re.compile(r"[A-Z0-9]{4,24}")

_LOCK_PREFIX = "redeem:"

TITLE = ("兑换码奖励", "Redeem code reward")


class RedeemRejected(RuntimeError):
    """业务拒绝。code 进 X-Glory-Reason，message 可以直接给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class RedeemLocked(RuntimeError):
    """试错太多次，先等一会儿。路由层回 429 + Retry-After。"""

    def __init__(self, retry_after: int) -> None:
        minutes = max(1, (retry_after + 59) // 60)
        super().__init__("试错太多次了，请 %d 分钟后再试" % minutes)
        self.retry_after = retry_after


def normalize(code: str) -> str:
    """全角转半角、去空格和连字符、转大写。

    🔴 对 ASCII 输入必须和 044 的 glory_normalize_redeem_code 一致（tests/test_redeem_pg.py 钉着）：
    后台建码时存的是 SQL 那边规范化的结果，玩家填码时比的是这边规范化的结果。
    这边多做的 NFKC 只会让更多输入能对上，不会让本来对得上的对不上。
    """
    text = unicodedata.normalize("NFKC", code or "")
    return re.sub(r"[\s-]", "", text).upper()


_limiter_cache: tuple[tuple[int, int], SlidingWindowLimiter] | None = None


def _limiter() -> SlidingWindowLimiter:
    """按当前配置取限流器。配置变了（测试里换 .env）就换一个新的。"""
    global _limiter_cache
    s = get_settings()
    key = (s.redeem_failure_limit, s.redeem_failure_window_seconds)
    if _limiter_cache is None or _limiter_cache[0] != key:
        _limiter_cache = (key, SlidingWindowLimiter(key[0], float(key[1])))
    return _limiter_cache[1]


@dataclasses.dataclass(frozen=True)
class Claimed:
    mail_id: int
    diamond: int
    coin: int
    items: tuple[str, ...]


_FIND = (
    "select code_id, campaign, max_uses, used_count, diamond, coin, items,"
    "       withdrawn_at is not null as withdrawn,"
    "       now() < starts_at as not_started,"
    "       now() >= expires_at as expired"
    "  from redeem_codes where code = $1 for update"
)

# 第 4 步。条件和上面的判断重复 —— 锁住之后不会变，这里是第二道。
_TAKE = (
    "update redeem_codes set used_count = used_count + 1"
    " where code_id = $1 and used_count < max_uses and withdrawn_at is null"
    "   and now() >= starts_at and now() < expires_at"
    " returning used_count"
)

_SEND = (
    "insert into mails (player_id, title_zh, body_zh, title_en, body_en, diamond, coin, items, actor, note)"
    " values ($1, $2, $3, $4, $5, $6, $7, $8, 'redeem', $9) returning mail_id"
)


async def claim(player_id: uuid.UUID, raw_code: str) -> Claimed:
    code = normalize(raw_code)
    if not CODE_RE.fullmatch(code):
        # 格式都不对的不数：没查库，也就没泄漏任何东西。
        raise RedeemRejected("redeem_invalid", "兑换码无效，检查一下有没有抄错")
    limiter = _limiter()
    key = str(player_id)
    retry_after = limiter.blocked(key)
    if retry_after is not None:
        raise RedeemLocked(retry_after)

    async with db.pool().acquire() as conn, conn.transaction():
        await conn.execute("select pg_advisory_xact_lock(hashtextextended($1, 0))", _LOCK_PREFIX + key)
        row = await conn.fetchrow(_FIND, code)
        if row is None:
            limiter.record(key)
            raise RedeemRejected("redeem_invalid", "兑换码无效，检查一下有没有抄错")
        if row["withdrawn"] or row["expired"]:
            raise RedeemRejected("redeem_expired", "这个兑换码已经失效了")
        if row["not_started"]:
            raise RedeemRejected("redeem_not_started", "这个兑换码还没到可以使用的时间")
        if await conn.fetchval(
                "select 1 from redeem_claims where code_id = $1 and player_id = $2",
                row["code_id"], player_id):
            raise RedeemRejected("redeem_already_claimed", "你已经领过这个兑换码了")
        if row["campaign"] is not None and await conn.fetchval(
                "select 1 from redeem_claims where campaign = $1 and player_id = $2",
                row["campaign"], player_id):
            raise RedeemRejected("redeem_campaign_claimed", "这个活动的兑换码你已经领过一个了")
        if int(row["used_count"]) >= int(row["max_uses"]):
            raise RedeemRejected("redeem_used_up", "这个兑换码已经被领完了")
        items = list(row["items"])
        # 后台建码时核过一次；商品目录之后可能改了。发出去的邮件附件不对会被整封藏起来
        # （mail.py 文件头）—— 玩家看到「已发到邮箱」却什么都没有，比现在说清楚更糟。
        problem = mail.item_problem(items)
        if problem:
            log.error("兑换码附件发不出去 code=%s problem=%s", code, problem)
            raise RedeemRejected("redeem_unavailable", "这个兑换码的奖励暂时发不出来，请联系客服")
        if await conn.fetchval(_TAKE, row["code_id"]) is None:
            raise RedeemRejected("redeem_used_up", "这个兑换码已经被领完了")
        mail_id = await conn.fetchval(
            _SEND, player_id, TITLE[0], "你用兑换码 %s 兑换的奖励，请查收。" % code,
            TITLE[1], "Here is your reward for redeem code %s." % code,
            int(row["diamond"]), int(row["coin"]), items, "redeem %s" % code)
        await conn.execute(
            "insert into redeem_claims (code_id, player_id, mail_id) values ($1, $2, $3)",
            row["code_id"], player_id, mail_id)
    log.info("兑换 player=%s code=%s mail=%s", player_id, code, mail_id)
    return Claimed(mail_id=int(mail_id), diamond=int(row["diamond"]), coin=int(row["coin"]),
                   items=tuple(items))
