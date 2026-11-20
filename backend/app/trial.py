"""体验卡：种族 / 宠物 / 棋盘皮肤的限时体验（database/047_trial_cards.sql）。

## 规则（2026-11-20 用户拍板，改数字只改这里）

- 来源：
  · 宠物祈愿、樱花祈愿**没抽中**时三选一：只给游戏币 / 只给一张卡 / 两样都给（MISS_OUTCOMES）。
    卡的天数随机（DAY_WEIGHTS）。宠物卡从玩家还没拥有的奖池宠物里随机挑一只；皮肤卡就是祈愿的那张皮肤。
  · 商城「棋子」页用游戏币买种族卡：每个账号、每个种族、每周（北京时间周一 0 点重置）1/3/7 天各一次。
- 卡放进背包，玩家点「使用」才开始计时。同一目标再用一张，时长往后叠。
- 已经永久拥有的目标，卡不能用（只能卖）。
- 背包里没用的卡永不过期。任何卡都能卖：1/3/7 天 = 100/200/300 游戏币（买价也是这个）。
- 体验到期后，玩家下一次开始游戏前弹一次提醒（expired_notices / ack_notices）。

## 🔴 体验不是拥有

永久拥有只看 player_entitlements（shop._owns / read_entitlements），集齐解锁种族、抽奖的「已拥有」、
邮件领取都只认它。体验单独放在 player_trials。「能不能用」= 两边合起来（read_usable），
只给出战那几处用：存种族、换皮肤、设出战宠物、出战名片（loadout.py、shop.set_active_pet）。

加锁顺序同 shop：先锁钱包行，再动卡和体验 —— 和抽奖、购买同一个顺序，不会互相死锁。
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import secrets
import uuid
from zoneinfo import ZoneInfo

import asyncpg

from app import db, shop

DAYS = (1, 3, 7)
# 买价 = 卖价（用户定）。
PRICE = {1: 100, 3: 200, 7: 300}
SELL_PRICE = {1: 100, 3: 200, 7: 300}
# 体验卡能指向的内容种类（shop.json 的 kind）。
KINDS = ("race", "pet", "prep_skin")
# 没抽中时的三选一（权重，合计 100）。
MISS_OUTCOMES = (("coin", 60), ("card", 30), ("both", 10))
# 卡的天数（权重，合计 100）。
DAY_WEIGHTS = ((1, 60), (3, 30), (7, 10))
# 每周从北京时间周一 0 点算起。
WEEK_TZ = ZoneInfo("Asia/Shanghai")
# 一次最多卖多少张（同一种卡）。只是挡住离谱的请求体。
MAX_SELL = 999


# --- 纯函数 -------------------------------------------------------------------


def _weighted(table: tuple[tuple, ...]):
    total = sum(weight for _, weight in table)
    pick = secrets.randbelow(total)
    for value, weight in table:
        if pick < weight:
            return value
        pick -= weight
    return table[-1][0]


def roll_miss() -> tuple[bool, int]:
    """没抽中时这一抽给什么：(给不给游戏币, 卡的天数；0 = 不给卡)。"""
    outcome = _weighted(MISS_OUTCOMES)
    give_coin = outcome in ("coin", "both")
    days = _weighted(DAY_WEIGHTS) if outcome in ("card", "both") else 0
    return give_coin, days


def kind_of(target: str) -> str:
    """体验卡目标的种类（race / pet / prep_skin）；不能做体验卡的返回空串。"""
    item = shop.content_item(target)
    if item is None or item.kind not in KINDS:
        return ""
    return item.kind


def week_start(now: dt.datetime | None = None) -> dt.date:
    local = (now or dt.datetime.now(dt.timezone.utc)).astimezone(WEEK_TZ)
    return local.date() - dt.timedelta(days=local.weekday())


def week_resets_at(now: dt.datetime | None = None) -> dt.datetime:
    """下一次重置（下周一 0 点，北京时间）。"""
    start = week_start(now) + dt.timedelta(days=7)
    return dt.datetime.combine(start, dt.time(0, 0), WEEK_TZ).astimezone(dt.timezone.utc)


def _check_days(days: int) -> None:
    if days not in DAYS:
        raise shop.ShopRejected("bad_days", "体验天数只能是 1、3、7 天")


def _check_target(target: str) -> str:
    kind = kind_of(target)
    if not kind:
        raise shop.ShopRejected("unknown_target", "没有这种体验卡")
    return kind


# --- 数据 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Card:
    target: str
    kind: str
    days: int
    count: int
    sell_price: int
    # 目标已经永久拥有 ⇒ 不能用，只能卖。
    owned: bool


@dataclasses.dataclass(frozen=True)
class Trial:
    target: str
    kind: str
    expires_at: dt.datetime


@dataclasses.dataclass(frozen=True)
class Bag:
    cards: list[Card]
    trials: list[Trial]
    server_now: dt.datetime


@dataclasses.dataclass(frozen=True)
class OpResult:
    target: str
    days: int
    count: int              # 这种卡还剩几张
    expires_at: dt.datetime | None   # use 之后的到期时间
    coin_delta: int
    wallet: shop.Wallet
    replayed: bool


@dataclasses.dataclass(frozen=True)
class RaceOffer:
    race: str
    prices: dict[int, int]
    bought: list[int]
    owned: bool
    resets_at: dt.datetime
    trial_expires_at: dt.datetime | None


# --- 读 -----------------------------------------------------------------------

_ACTIVE = ("select target, expires_at from player_trials"
           " where player_id = $1 and expires_at > now() order by target")


async def active_trials_in(conn: asyncpg.Connection, player_id: uuid.UUID) -> dict[str, dt.datetime]:
    """正在体验的目标 -> 到期时间。"""
    rows = await conn.fetch(_ACTIVE, player_id)
    return {str(r["target"]): r["expires_at"] for r in rows}


async def active_trials(player_id: uuid.UUID) -> dict[str, dt.datetime]:
    async with db.pool().acquire() as conn:
        return await active_trials_in(conn, player_id)


async def read_usable(player_id: uuid.UUID) -> set[str]:
    """能用的内容 id = 永久拥有 ∪ 正在体验。**只给出战校验用**（见模块开头）。"""
    owned = set(await shop.read_entitlements(player_id))
    return owned | set(await active_trials(player_id))


async def is_usable_in(conn: asyncpg.Connection, player_id: uuid.UUID, content_id: str) -> bool:
    if await shop._owns(conn, player_id, content_id):
        return True
    return bool(await conn.fetchval(
        "select 1 from player_trials where player_id = $1 and target = $2 and expires_at > now()",
        player_id, content_id))


async def bag(player_id: uuid.UUID) -> Bag:
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select target, days, count from player_trial_cards where player_id = $1"
            " order by target, days", player_id)
        trials = await active_trials_in(conn, player_id)
        owned = set(r["item_id"] for r in await conn.fetch(
            "select item_id from player_entitlements where player_id = $1 and revoked_at is null",
            player_id))
        now = await conn.fetchval("select now()")
    cards = []
    for r in rows:
        target = str(r["target"])
        kind = kind_of(target)
        if not kind:
            # 目录里删掉了这个内容：卡还在库里（客服能查），背包里不显示。
            continue
        days = int(r["days"])
        cards.append(Card(target, kind, days, int(r["count"]), SELL_PRICE[days], target in owned))
    active = [Trial(t, kind_of(t), exp) for t, exp in trials.items()
              if kind_of(t) and t not in owned]
    return Bag(cards, active, now)


async def race_offer(player_id: uuid.UUID, race: str) -> RaceOffer:
    if kind_of(race) != "race":
        raise shop.ShopRejected("unknown_target", "没有这个种族")
    start = week_start()
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select days from trial_race_purchases where player_id = $1 and race = $2"
            " and week_start = $3 order by days", player_id, race, start)
        owned = await shop._owns(conn, player_id, race)
        expires = await conn.fetchval(
            "select expires_at from player_trials where player_id = $1 and target = $2"
            " and expires_at > now()", player_id, race)
    return RaceOffer(race, dict(PRICE), [int(r["days"]) for r in rows], owned,
                     week_resets_at(), expires)


# --- 写（都在调用方的事务里，钱包行已经锁着）----------------------------------


async def add_cards(
    conn: asyncpg.Connection,
    player_id: uuid.UUID,
    target: str,
    days: int,
    count: int,
    kind: str,
    *,
    client_op_id: uuid.UUID | None = None,
    draw_id: uuid.UUID | None = None,
    coin_delta: int = 0,
) -> int:
    """往背包里放卡并记流水。返回这种卡现在有几张。**必须在事务里。**"""
    _check_days(days)
    after = await conn.fetchval(
        "insert into player_trial_cards (player_id, target, days, count) values ($1, $2, $3, $4)"
        " on conflict (player_id, target, days) do update"
        " set count = player_trial_cards.count + excluded.count, updated_at = now()"
        " returning count", player_id, target, days, count)
    await conn.execute(
        "insert into trial_card_ops (op_id, player_id, client_op_id, kind, target, days,"
        " count_delta, coin_delta, draw_id) values ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        uuid.uuid4(), player_id, client_op_id, kind, target, days, count, coin_delta, draw_id)
    return int(after)


async def _take_cards(conn, player_id: uuid.UUID, target: str, days: int, count: int) -> int:
    """从背包里拿走 count 张。不够就拒。返回剩几张。"""
    have = await conn.fetchval(
        "select count from player_trial_cards where player_id = $1 and target = $2 and days = $3"
        " for update", player_id, target, days)
    if have is None or int(have) < count:
        raise shop.ShopRejected("no_card", "背包里没有这么多张这种体验卡")
    left = int(have) - count
    if left == 0:
        await conn.execute(
            "delete from player_trial_cards where player_id = $1 and target = $2 and days = $3",
            player_id, target, days)
    else:
        await conn.execute(
            "update player_trial_cards set count = $4, updated_at = now()"
            " where player_id = $1 and target = $2 and days = $3",
            player_id, target, days, left)
    return left


async def _count(conn, player_id: uuid.UUID, target: str, days: int) -> int:
    return int(await conn.fetchval(
        "select count from player_trial_cards where player_id = $1 and target = $2 and days = $3",
        player_id, target, days) or 0)


async def _replay(conn, player_id, client_op_id, kind, target, days, wallet) -> OpResult | None:
    """同一个 client_op_id 已经处理过：原样回上次的结果（数量、余额给当前的）。"""
    row = await conn.fetchrow(
        "select kind, target, days, coin_delta, expires_after from trial_card_ops"
        " where player_id = $1 and client_op_id = $2", player_id, client_op_id)
    if row is None:
        return None
    if str(row["kind"]) != kind or str(row["target"]) != target or int(row["days"]) != days:
        raise shop.ShopRejected("op_conflict", "这个操作号已经用在另一件事上了")
    expires = row["expires_after"]
    if kind == "use":
        expires = await conn.fetchval(
            "select expires_at from player_trials where player_id = $1 and target = $2",
            player_id, target)
    return OpResult(target, days, await _count(conn, player_id, target, days), expires,
                    int(row["coin_delta"]), wallet, True)


async def use(player_id: uuid.UUID, client_op_id: uuid.UUID, target: str, days: int) -> OpResult:
    """用一张卡：开始计时；正在体验就往后叠。"""
    _check_days(days)
    kind = _check_target(target)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            wallet = await shop._lock_wallet(conn, player_id)
            replayed = await _replay(conn, player_id, client_op_id, "use", target, days, wallet)
            if replayed is not None:
                return replayed
            if await shop._owns(conn, player_id, target):
                raise shop.ShopRejected("already_owned", "你已经永久拥有它了，这张卡可以出售")
            left = await _take_cards(conn, player_id, target, days, 1)
            expires = await conn.fetchval(
                "insert into player_trials (player_id, target, expires_at)"
                " values ($1, $2, now() + make_interval(days => $3))"
                " on conflict (player_id, target) do update"
                " set expires_at = greatest(player_trials.expires_at, now())"
                "                  + make_interval(days => $3),"
                "     notified_at = null, updated_at = now()"
                " returning expires_at", player_id, target, days)
            await conn.execute(
                "insert into trial_card_ops (op_id, player_id, client_op_id, kind, target, days,"
                " count_delta, expires_after) values ($1, $2, $3, 'use', $4, $5, -1, $6)",
                uuid.uuid4(), player_id, client_op_id, target, days, expires)
            if kind == "race":
                # 同集齐解锁（shop._complete_set）：不满 4 个就自动带上，满了由玩家自己去换。
                await conn.execute(
                    "update players set selected_races = array_append("
                    "coalesce(selected_races, array['human']::text[]), $2)"
                    " where player_id = $1 and not ($2 = any("
                    "coalesce(selected_races, array['human']::text[])))"
                    " and cardinality(coalesce(selected_races, array['human']::text[])) < 4",
                    player_id, target)
    return OpResult(target, days, left, expires, 0, wallet, False)


async def sell(player_id: uuid.UUID, client_op_id: uuid.UUID, target: str, days: int,
               count: int) -> OpResult:
    _check_days(days)
    if not 1 <= count <= MAX_SELL:
        raise shop.ShopRejected("bad_count", "出售数量不对")
    # 目录里删掉了的目标也能卖（卡还在背包里就该能处理掉），所以这里不查 kind。
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            wallet = await shop._lock_wallet(conn, player_id)
            replayed = await _replay(conn, player_id, client_op_id, "sell", target, days, wallet)
            if replayed is not None:
                return replayed
            left = await _take_cards(conn, player_id, target, days, count)
            gained = SELL_PRICE[days] * count
            op_id = uuid.uuid4()
            after = await shop._apply(conn, player_id, wallet, {"coin": gained}, "trial_sell", op_id)
            await conn.execute(
                "insert into trial_card_ops (op_id, player_id, client_op_id, kind, target, days,"
                " count_delta, coin_delta) values ($1, $2, $3, 'sell', $4, $5, $6, $7)",
                op_id, player_id, client_op_id, target, days, -count, gained)
    return OpResult(target, days, left, None, gained, after, False)


async def buy_race(player_id: uuid.UUID, client_op_id: uuid.UUID, race: str, days: int) -> OpResult:
    """游戏币买一张种族体验卡（放进背包，不自动使用）。每周每种天数一次。"""
    _check_days(days)
    if kind_of(race) != "race":
        raise shop.ShopRejected("unknown_target", "没有这个种族")
    start = week_start()
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            wallet = await shop._lock_wallet(conn, player_id)
            replayed = await _replay(conn, player_id, client_op_id, "buy", race, days, wallet)
            if replayed is not None:
                return replayed
            if await shop._owns(conn, player_id, race):
                raise shop.ShopRejected("already_owned", "你已经解锁这个种族了")
            if await conn.fetchval(
                    "select 1 from trial_race_purchases where player_id = $1 and race = $2"
                    " and days = $3 and week_start = $4", player_id, race, days, start):
                raise shop.ShopRejected("weekly_limit", "这种体验卡本周已经买过了，下周一再来")
            price = PRICE[days]
            if wallet.coin < price:
                raise shop.ShopRejected("insufficient_funds", "游戏币不足")
            op_id = uuid.uuid4()
            after = await shop._apply(conn, player_id, wallet, {"coin": -price}, "trial_buy", op_id)
            await conn.execute(
                "insert into trial_race_purchases (player_id, race, days, week_start, op_id)"
                " values ($1, $2, $3, $4, $5)", player_id, race, days, start, op_id)
            count = await add_cards(conn, player_id, race, days, 1, "buy",
                                    client_op_id=client_op_id, coin_delta=-price)
    return OpResult(race, days, count, None, -price, after, False)


# --- 到期提醒 -----------------------------------------------------------------


async def expired_notices(player_id: uuid.UUID) -> list[Trial]:
    """到期了、还没提醒过、也没有永久拥有的体验。"""
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select t.target, t.expires_at from player_trials t"
            " where t.player_id = $1 and t.expires_at <= now() and t.notified_at is null"
            " and not exists (select 1 from player_entitlements e where e.player_id = t.player_id"
            "   and e.item_id = t.target and e.revoked_at is null)"
            " order by t.expires_at", player_id)
    return [Trial(str(r["target"]), kind_of(str(r["target"])), r["expires_at"])
            for r in rows if kind_of(str(r["target"]))]


async def ack_notices(player_id: uuid.UUID, targets: list[str]) -> int:
    """记下这些到期提醒已经弹过。只认已经到期的（没到期的不会被误标）。"""
    clean = sorted({str(t) for t in targets if 1 <= len(str(t)) <= 64})[:32]
    if not clean:
        return 0
    async with db.pool().acquire() as conn:
        result = await conn.execute(
            "update player_trials set notified_at = now(), updated_at = now()"
            " where player_id = $1 and target = any($2::text[]) and expires_at <= now()"
            " and notified_at is null", player_id, clean)
    return int(result.split()[-1])
