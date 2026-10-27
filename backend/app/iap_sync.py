"""充值的定时对账（docs/充值系统设计.md 第五、六、七节，第 2 步）。

客户端交凭证、平台推通知之外的第三道兜底。由 app/main.py 的 lifespan 起停，同 bans.loop。

每分钟：
  · Steam 待付款的单问一遍 Steam：玩家点了确认但游戏崩了、回调没送到 → 替他扣款入账；
    一小时还停在 Init 的取消；下单就没成功（没拿到 transid）的十分钟后取消。
每 10 分钟（启动后第一分钟也跑一次）：
  · Steam GetReport：退款、拒付 → 扣回；
  · Google 补消耗：入了账没消耗的（🔴 3 天内不消耗 Google 自动退款）；
  · Google 作废购买：实时通知丢了的退款靠它补。

替玩家入了账、扣回了退款的，都发一封不带附件的说明邮件（iap.mail_notice）。

## 游标只放内存

「从哪个时间往后问」不落库：重启后都从 30 天前重查一遍（Google 最多也只给 30 天）。
退款是幂等的（已退款的单原样回），重查只是多几次请求，换来的是不用为一个游标再开一张表、再跑一次迁移。

## 没配好的平台直接跳过

没填 Steam 发行商密钥 / Google 服务账号的那一路整段不跑，也不每分钟往日志里喊一次。
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import logging

from app import db, iap, iap_google, iap_steam, steam
from app.config import get_settings

log = logging.getLogger("glory.iap.sync")

TICK_SEC = 60
SLOW_EVERY = 10                       # 每 10 圈跑一次慢的那几样
STEAM_PENDING_WINDOW_SEC = 86400      # 只看一天内建的待付款 Steam 单
STEAM_GIVE_UP_SEC = 3600              # 一小时还停在 Init 就取消
STEAM_NO_TXN_SEC = 600                # 没拿到 transid 的单十分钟后取消（下单那一步还在路上的不能误杀）
GOOGLE_CONSUME_WINDOW_SEC = 3 * 86400
LOOKBACK_SEC = 30 * 86400
STEAM_REPORT_PAGE = 1000              # 和 iap_steam.report 的 maxresults 一致


@dataclasses.dataclass
class Cursors:
    steam_since: str        # RFC 3339 UTC
    google_since_ms: int


def fresh_cursors(now: dt.datetime | None = None) -> Cursors:
    now = now or dt.datetime.now(dt.timezone.utc)
    start = now - dt.timedelta(seconds=LOOKBACK_SEC)
    return Cursors(steam_since=start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                   google_since_ms=_google_floor_ms(now))


def _google_floor_ms(now: dt.datetime) -> int:
    """Google 作废购买接口最早只给 30 天。留一分钟余量，免得请求到达时刚好超出。"""
    return int((now - dt.timedelta(seconds=LOOKBACK_SEC - 60)).timestamp() * 1000)


def _steam_ready() -> bool:
    return bool(get_settings().steam_web_api_key.strip())


def _google_ready() -> bool:
    return bool(get_settings().google_play_service_account_file.strip())


async def sweep_steam(now: dt.datetime | None = None) -> int:
    """推一遍待付款的 Steam 单。返回这一轮替玩家入账的张数。"""
    if not _steam_ready():
        return 0
    now = now or dt.datetime.now(dt.timezone.utc)
    credited = 0
    for order in await iap.pending_orders("steam", STEAM_PENDING_WINDOW_SEC):
        age = (now - order.created_at).total_seconds()
        try:
            if order.external_id is None:
                if age > STEAM_NO_TXN_SEC:
                    await iap.cancel(order.order_id, "steam_init_lost")
                continue
            outcome = await iap_steam.settle(order)
            if outcome.order.status == "credited" and not outcome.replayed:
                credited += 1
                await iap.mail_notice(outcome)
            elif outcome.order.status == "pending" and age > STEAM_GIVE_UP_SEC:
                await iap.cancel(order.order_id, "steam_timeout")
        except (steam.SteamUnavailable, iap_steam.SteamTxnFailed, iap.IapRejected) as exc:
            # 一张出错不耽误后面的；下一分钟再来。
            log.warning("Steam 扫单这一张没处理成 order=%s：%s", order.order_id, exc)
    return credited


async def steam_refunds(cursors: Cursors) -> int:
    """Steam 退款 / 拒付扣回。返回这一轮新扣回的张数。"""
    if not _steam_ready():
        return 0
    clawed = 0
    for _ in range(20):  # 翻页上限，防坏游标卡死
        rows = await iap_steam.report(cursors.steam_since)
        for row in rows:
            if row.status in iap_steam.REVERSED and row.transid:
                outcome = await iap.refund("steam", row.transid, "steam_" + row.status.lower())
                if outcome is not None and not outcome.replayed:
                    clawed += 1
                    await iap.mail_notice(outcome)
            elif row.status == "PartialRefund":
                # 我们一单只有一件，理论上不会出现（docs/充值系统设计.md 第十七节）。出现了交人看。
                log.warning("Steam 部分退款，需要人工处理 orderid=%d transid=%s", row.order_no, row.transid)
        latest = max((r.time for r in rows if r.time), default="")
        if latest > cursors.steam_since:
            cursors.steam_since = latest
        if len(rows) < STEAM_REPORT_PAGE or not latest:
            break
    return clawed


async def google_consume() -> int:
    """补消耗。返回这一轮补上的张数。"""
    if not _google_ready():
        return 0
    done = 0
    for order in await iap.unconsumed_google_orders(GOOGLE_CONSUME_WINDOW_SEC):
        if order.purchase_token and await iap_google.consume(order.product_id, order.purchase_token):
            await iap.mark_consumed(order.order_id)
            done += 1
    return done


async def google_voided(cursors: Cursors, now: dt.datetime | None = None) -> int:
    """Google 作废购买扣回。返回这一轮新扣回的张数。"""
    if not _google_ready():
        return 0
    start = max(cursors.google_since_ms, _google_floor_ms(now or dt.datetime.now(dt.timezone.utc)))
    rows = await iap_google.voided_since(start)
    clawed = 0
    for row in rows:
        outcome = await iap.refund("google", iap_google.token_key(row.token), "google_voided")
        if outcome is not None and not outcome.replayed:
            clawed += 1
            await iap.mail_notice(outcome)
    cursors.google_since_ms = max([start] + [r.voided_ms for r in rows])
    return clawed


async def tick(cursors: Cursors, n: int) -> None:
    jobs = [("Steam 扫单", sweep_steam)]
    if n % SLOW_EVERY == 1:
        jobs += [("Steam 退款报表", lambda: steam_refunds(cursors)),
                 ("Google 补消耗", google_consume),
                 ("Google 作废购买", lambda: google_voided(cursors))]
    for name, job in jobs:
        try:
            await job()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - 一样出错不该让别的停掉，也不该让循环停掉
            log.exception("充值对账「%s」出错，下一轮再试", name)


async def loop() -> None:
    """后台对账。由 app/main.py 的 lifespan 起停，同 bans.loop。"""
    cursors = fresh_cursors()
    n = 0
    while True:
        await asyncio.sleep(TICK_SEC)
        if not db.is_connected():
            continue
        n += 1
        await tick(cursors, n)
