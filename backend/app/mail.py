"""系统邮件（docs/邮件系统设计.md，database/012_mail.sql）。

玩家：列表 / 标记已读 / 领附件（单封、一键）/ 删（单封、已读全删）。
管理员：在 Supabase 里调 send_mail / send_mail_all / withdraw_mail —— **不经过这里**。
后台（Postman）：每 REFRESH_SEC 看一次有没有新邮件，推给在线的收件人；
附件有问题的写回 problem 列给管理员看。

## 🔴 领取只算一次

领取的事务**先锁 mail_states 那一行，再动钱和东西**，最后在同一个事务里记 claimed_at。
两台手机同时点、弱网重试，第二次都会在锁上等到第一次提交，然后看见「已经领过」——
回报当前余额、什么都不再发。顺序反过来（先发再记）的话，两次请求都会在记之前把东西发出去。

## 附件只能是商品目录里卖的东西

不在 data/shop.json 里的内容本来就人人免费（shop.requires_entitlement），发了等于没发；
拼错的 id 更是发了也用不了。所以有这种附件的邮件**整封不给玩家看**，原因写进 problem 列，
管理员改好附件后下一轮自动放出来（并推送）。宁可晚到，不能让玩家点了「领取」却什么都没有。

## 钻石进的是赠送那一列

邮件发的钱不是玩家付的（同 009 的 grant_diamonds）。流水 source 记 mail、mail_id 记是哪封。
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import logging
import uuid
from collections.abc import Awaitable, Callable, Sequence

import asyncpg

from app import db, realtime, shop

log = logging.getLogger("glory.mail")

# 列表最多回多少封。玩家邮箱里同时没过期的邮件不该有这么多；真到了，老的先看不到。
MAX_LIST = 100

# 与 database/012_mail.sql 的 mail_items_shape 一致。
MAX_ITEMS = 10

# 后台看新邮件的周期。与公告同一个节奏：管理员发完，半分钟内在线玩家亮红点。
REFRESH_SEC = 30.0

# 推送类型。与 scripts/autoload/MailService.gd 的 PUSH_TYPE 一致（tools/mail_check 钉着）。
# 推送只是「去拉一次列表」的提醒，不带内容 —— 内容要按人现算（群发的资格、已读已领）。
PUSH_TYPE = "mail"

# 第一轮与之后每轮最多看多少行。活着的邮件（没撤回、没过期）远少于这个数。
SCAN_LIMIT = 1000


class MailRejected(RuntimeError):
    """业务拒绝。code 会被路由层映射成 HTTP 状态码，message 可以直接给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


NOT_FOUND = ("mail_not_found", "邮件不存在或已经过期")


# --- 邮件 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Mail:
    mail_id: int
    title_zh: str
    body_zh: str
    title_en: str
    body_en: str
    diamond: int
    coin: int
    items: tuple[str, ...]
    created_at: dt.datetime
    expires_at: dt.datetime
    read: bool
    claimed: bool

    @property
    def has_attachments(self) -> bool:
        return self.diamond > 0 or self.coin > 0 or bool(self.items)

    @property
    def claimable(self) -> bool:
        return self.has_attachments and not self.claimed


def item_problem(items: Sequence[str]) -> str:
    """附件里有没有不能发的东西。空串 = 没问题。

    这句会原样写进 mails.problem 给管理员看，所以要说清楚怎么改。
    """
    if len(items) > MAX_ITEMS:
        return "附件最多 %d 件，现在是 %d 件" % (MAX_ITEMS, len(items))
    dup = sorted({i for i in items if items.count(i) > 1})
    if dup:
        return "附件重复：%s（同一样东西只能拥有一份，第二份会被当成「已拥有」跳过）" % ", ".join(dup)
    bad = [i for i in items if shop.content_item(i) is None]
    if bad:
        return ("附件里有不能发的东西：%s。只有 data/shop.json 里卖的内容能发 —— "
                "不在里面的要么拼错了，要么本来就人人免费、不用发" % ", ".join(bad))
    return ""


# 玩家看得到的邮件：发给他的 + 他有资格收的群发，没撤回、没过期、他没删。
#
# 群发的资格：include_new_players 打开 = 谁都能收（过期那条已经挡住了过期后注册的）；
# 没打开 = 只给发送那一刻已经存在的玩家（p.created_at <= m.created_at）。
#
# left join 状态行：没有行 = 没读、没领、没删，所以 `s.deleted_at is null` 对没有行的邮件成立。
_SELECT = """
select m.mail_id,
       m.title_zh, m.body_zh, coalesce(m.title_en, '') as title_en, coalesce(m.body_en, '') as body_en,
       m.diamond, m.coin, m.items, m.created_at, m.expires_at,
       s.read_at is not null as is_read, s.claimed_at is not null as is_claimed
from mails m
join players p on p.player_id = $1
left join mail_states s on s.mail_id = m.mail_id and s.player_id = $1
where (m.player_id = $1
       or (m.player_id is null and (m.include_new_players or p.created_at <= m.created_at)))
  and m.withdrawn_at is null
  and m.expires_at > now()
  and s.deleted_at is null
"""

_LIST = _SELECT + " order by m.mail_id desc limit $2"
_ONE = _SELECT + " and m.mail_id = $2"


def _mail(row: asyncpg.Record | dict) -> Mail:
    return Mail(
        mail_id=int(row["mail_id"]),
        title_zh=str(row["title_zh"]),
        body_zh=str(row["body_zh"]),
        title_en=str(row["title_en"]),
        body_en=str(row["body_en"]),
        diamond=int(row["diamond"]),
        coin=int(row["coin"]),
        items=tuple(str(i) for i in (row["items"] or ())),
        created_at=row["created_at"],
        expires_at=row["expires_at"],
        read=bool(row["is_read"]),
        claimed=bool(row["is_claimed"]),
    )


async def list_mail(player_id: uuid.UUID) -> list[Mail]:
    """这个玩家邮箱里的邮件，新的在前。附件有问题的不给看（见模块开头）。"""
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(_LIST, player_id, MAX_LIST)
    return [m for m in map(_mail, rows) if not item_problem(m.items)]


async def _visible(conn: asyncpg.Connection, player_id: uuid.UUID, mail_id: int) -> Mail:
    row = await conn.fetchrow(_ONE, player_id, mail_id)
    if row is None:
        raise MailRejected(*NOT_FOUND)
    mail = _mail(row)
    if item_problem(mail.items):
        raise MailRejected(*NOT_FOUND)
    return mail


async def mark_read(player_id: uuid.UUID, mail_id: int) -> None:
    """标记已读。已经读过就什么都不改（保留第一次读的时间）。"""
    async with db.pool().acquire() as conn:
        await _visible(conn, player_id, mail_id)
        await conn.execute(
            "insert into mail_states (player_id, mail_id, read_at) values ($1, $2, now())"
            " on conflict (player_id, mail_id) do update"
            " set read_at = coalesce(mail_states.read_at, excluded.read_at)",
            player_id, mail_id,
        )


# --- 领取 ---------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class ClaimResult:
    mail_ids: tuple[int, ...]    # 这次真的领到的
    diamond: int
    coin: int
    granted: tuple[str, ...]
    skipped: tuple[str, ...]     # 已经拥有、跳过的
    wallet: shop.Wallet          # 领完之后的余额
    replayed: bool               # 单封：之前已经领过，这次什么都没发


async def _claim_locked(
    conn: asyncpg.Connection, player_id: uuid.UUID, mail: Mail,
) -> tuple[list[str], list[str], shop.Wallet | None] | None:
    """在事务里领一封。已经领过返回 None；这期间被撤回 / 过期了抛 MailRejected。

    🔴 顺序：锁状态行 → 确认邮件还在 → 发钱 → 发东西 → 记 claimed_at。见模块开头。
    """
    # 先保证有行，for update 才锁得到东西（同 shop._lock_wallet 的理由）。
    await conn.execute(
        "insert into mail_states (player_id, mail_id) values ($1, $2) on conflict do nothing",
        player_id, mail.mail_id,
    )
    state = await conn.fetchrow(
        "select claimed_at from mail_states where player_id = $1 and mail_id = $2 for update",
        player_id, mail.mail_id,
    )
    if state["claimed_at"] is not None:
        return None
    # 🔴 在事务里再确认一次这封还在。调用方的可见性检查（_visible / list_mail）在事务外，
    # 两步之间管理员撤回、或者刚好过期，不再查就会照样发出去。
    #
    # for share 与 withdraw_mail 的 update 互斥：撤回先提交，这里读到的是撤回后的行；
    # 这里先锁住，撤回等这笔领完再生效 —— 已经领走的本来就收不回，两种结果都对得上账。
    live = await conn.fetchval(
        "select withdrawn_at is null and expires_at > now() from mails where mail_id = $1 for share",
        mail.mail_id,
    )
    if not live:
        raise MailRejected(*NOT_FOUND)

    wallet: shop.Wallet | None = None
    changes: dict[str, int] = {}
    if mail.diamond:
        # 赠送列，不是付费列。见模块开头。
        changes["diamond_free"] = mail.diamond
    if mail.coin:
        changes["coin"] = mail.coin
    if changes:
        locked = await shop._lock_wallet(conn, player_id)
        wallet = await shop._apply(
            conn, player_id, locked, changes, "mail", None, mail_id=mail.mail_id)

    granted: list[str] = []
    skipped: list[str] = []
    for item in mail.items:
        # 已经拥有就跳过，不折算（docs/邮件系统设计.md 拍板）。其余附件照常到账。
        if await shop._owns(conn, player_id, item):
            skipped.append(item)
            continue
        await shop._grant(conn, player_id, item, "mail", None)
        granted.append(item)

    await conn.execute(
        "update mail_states set claimed_at = now(), read_at = coalesce(read_at, now())"
        " where player_id = $1 and mail_id = $2",
        player_id, mail.mail_id,
    )
    return granted, skipped, wallet


async def claim(player_id: uuid.UUID, mail_id: int) -> ClaimResult:
    async with db.pool().acquire() as conn:
        mail = await _visible(conn, player_id, mail_id)
        if not mail.has_attachments:
            raise MailRejected("nothing_to_claim", "这封邮件没有附件")
        async with conn.transaction():
            done = await _claim_locked(conn, player_id, mail)
        if done is None:
            return ClaimResult((), 0, 0, (), (), await shop.read_wallet_in(conn, player_id), True)
        granted, skipped, wallet = done
        if wallet is None:
            wallet = await shop.read_wallet_in(conn, player_id)
    log.info("领取邮件 player=%s mail=%d 钻石=%d 黄金=%d 物品=%s 跳过=%s",
             player_id, mail.mail_id, mail.diamond, mail.coin, granted, skipped)
    return ClaimResult((mail.mail_id,), mail.diamond, mail.coin,
                       tuple(granted), tuple(skipped), wallet, False)


async def claim_all(player_id: uuid.UUID) -> ClaimResult:
    """一键领取。**每封一个事务** —— 一封出错不连累其他几封，已经领到的不回滚。

    老的先领：两封里有同一样东西时，先发的那封给、后发的那封算「已拥有」，
    和玩家一封封点的结果一样。
    """
    pending = sorted((m for m in await list_mail(player_id) if m.claimable),
                     key=lambda m: m.mail_id)
    ids: list[int] = []
    diamond = coin = 0
    granted: list[str] = []
    skipped: list[str] = []
    async with db.pool().acquire() as conn:
        for mail in pending:
            try:
                async with conn.transaction():
                    done = await _claim_locked(conn, player_id, mail)
            except MailRejected:
                continue   # 列表拉出来之后被撤回 / 过期了，这一封的事务已回滚
            if done is None:
                continue   # 另一台设备刚领走
            ids.append(mail.mail_id)
            diamond += mail.diamond
            coin += mail.coin
            granted.extend(done[0])
            skipped.extend(done[1])
        wallet = await shop.read_wallet_in(conn, player_id)
    if ids:
        log.info("一键领取 player=%s mails=%s 钻石=%d 黄金=%d 物品=%s 跳过=%s",
                 player_id, ids, diamond, coin, granted, skipped)
    return ClaimResult(tuple(ids), diamond, coin, tuple(granted), tuple(skipped), wallet, False)


# --- 删除 ---------------------------------------------------------------------


async def delete(player_id: uuid.UUID, mail_id: int) -> None:
    """只是玩家自己看不到了。邮件与领取记录都还在。

    能删的条件：**已读，并且没有没领的附件**（带着没领的附件不让删，免得误删丢东西）。
    同一条规则还在 delete_read 的 SQL 里、客户端 MailService.is_deletable 里各有一份。
    """
    async with db.pool().acquire() as conn:
        mail = await _visible(conn, player_id, mail_id)
        if not mail.read:
            raise MailRejected("not_read", "先打开看过才能删")
        if mail.claimable:
            raise MailRejected("unclaimed_attachments", "附件还没领，不能删")
        await conn.execute(
            "update mail_states set deleted_at = now()"
            " where player_id = $1 and mail_id = $2 and deleted_at is null",
            player_id, mail_id,
        )


async def delete_read(player_id: uuid.UUID) -> int:
    """删掉所有「已读、并且没有没领的附件」的邮件。返回删了几封。"""
    async with db.pool().acquire() as conn:
        status = await conn.execute(
            "update mail_states s set deleted_at = now()"
            " from mails m"
            " where s.player_id = $1 and m.mail_id = s.mail_id"
            "   and s.deleted_at is null and s.read_at is not null"
            "   and (s.claimed_at is not null"
            "        or (m.diamond = 0 and m.coin = 0 and cardinality(m.items) = 0))",
            player_id,
        )
    # asyncpg 回的是命令标签，形如 "UPDATE 3"。
    try:
        return int(str(status).rsplit(" ", 1)[-1])
    except ValueError:
        return 0


# --- 后台：推送新邮件、写回问题 ---------------------------------------------------


@dataclasses.dataclass(frozen=True)
class ScanRow:
    mail_id: int
    player_id: uuid.UUID | None
    items: tuple[str, ...]
    problem: str


LoadScan = Callable[[int], Awaitable[list[ScanRow]]]
WriteProblems = Callable[[list[tuple[int, str | None]]], Awaitable[None]]
SendToPlayer = Callable[[uuid.UUID, dict], Awaitable[int]]
Broadcast = Callable[[dict], Awaitable[int]]


class Postman:
    """看新邮件、推「去拉一次」、给管理员写回附件问题。由 lifespan 建一个、起 loop()。

    读表、写回、推送全部注入：测试不连数据库、不起 WebSocket。同 announcements.Board。
    """

    def __init__(
        self,
        *,
        load_scan: LoadScan,
        write_problems: WriteProblems,
        send_to_player: SendToPlayer,
        broadcast: Broadcast,
    ) -> None:
        self._load_scan = load_scan
        self._write_problems = write_problems
        self._send_to_player = send_to_player
        self._broadcast = broadcast
        # 看过的最大邮件编号。None = 还没跑过第一轮。
        self._last_id: int | None = None

    @classmethod
    def for_production(cls) -> Postman:
        return cls(load_scan=load_scan, write_problems=write_problems,
                   send_to_player=hub_send_to_player, broadcast=hub_broadcast)

    async def refresh(self) -> None:
        first = self._last_id is None
        since = self._last_id or 0
        rows = await self._load_scan(since)

        changes: list[tuple[int, str | None]] = []
        deliver: list[ScanRow] = []
        for row in rows:
            problem = item_problem(row.items)
            if problem != row.problem:
                changes.append((row.mail_id, problem or None))
            if problem:
                continue
            # 新来的，或者管理员刚把附件改好（问题从有变没有）—— 都是玩家「新看到」的邮件。
            if row.mail_id > since or row.problem:
                deliver.append(row)
        if rows:
            self._last_id = max(since, max(r.mail_id for r in rows))
        elif first:
            self._last_id = 0

        if changes:
            try:
                await self._write_problems(changes)
            except (asyncpg.PostgresError, OSError):
                # 写不回去只影响管理员看不到原因，玩家那边照常。下一轮会再试。
                log.warning("邮件问题写回失败，下一轮再试", exc_info=True)

        # 🔴 第一轮不推：刚重启时表里那些都是旧邮件，玩家登录时本来就会拉列表。
        if first or not deliver:
            return
        await self._deliver(deliver)

    async def _deliver(self, rows: list[ScanRow]) -> None:
        message = {"t": PUSH_TYPE}
        if any(r.player_id is None for r in rows):
            # 有群发就广播一次。资格（只给老玩家还是人人都有）由列表接口按人算，
            # 这里多提醒几个人拉一次列表，没有任何坏处。
            sent = await self._broadcast(message)
            log.info("新全服邮件已提醒 mails=%s 送达连接=%d",
                     [r.mail_id for r in rows if r.player_id is None], sent)
        for player_id in {r.player_id for r in rows if r.player_id is not None}:
            await self._send_to_player(player_id, message)


# 活着的邮件里：新来的，或者还挂着问题的（等管理员改好）。
_SELECT_SCAN = """
select mail_id, player_id, items, coalesce(problem, '') as problem
from mails
where withdrawn_at is null and expires_at > now()
  and (mail_id > $1 or problem is not null)
order by mail_id
limit $2
"""

# `is distinct from`：值没变就不写。管理员正开着表格时，每 30 秒改一次同一个格子会很烦。
_UPDATE_PROBLEM = """
update mails set problem = $2
where mail_id = $1 and problem is distinct from $2
"""


async def load_scan(since: int) -> list[ScanRow]:
    async with db.pool().acquire() as conn:
        records = await conn.fetch(_SELECT_SCAN, since, SCAN_LIMIT)
    return [
        ScanRow(
            mail_id=int(r["mail_id"]),
            player_id=r["player_id"],
            items=tuple(str(i) for i in (r["items"] or ())),
            problem=str(r["problem"]),
        )
        for r in records
    ]


async def write_problems(changes: list[tuple[int, str | None]]) -> None:
    async with db.pool().acquire() as conn:
        await conn.executemany(_UPDATE_PROBLEM, changes)


async def hub_send_to_player(player_id: uuid.UUID, payload: dict) -> int:
    """**每次现取 hub()** —— 测试会换掉它。同 announcements.hub_broadcast。"""
    return await realtime.hub().send_to_player(player_id, payload)


async def hub_broadcast(payload: dict) -> int:
    return await realtime.hub().broadcast(payload)


async def loop(target: Postman) -> None:
    """由 lifespan 起、由它取消。

    **先干再睡**（同 announcements.loop）：第一轮只记下「看到哪儿了」，
    之后才推新的 —— 越早记下，重启后越少漏推。
    """
    while True:
        if db.is_connected():
            try:
                await target.refresh()
            except Exception:
                # 刷新自己出错不能把循环带走 —— 那样新邮件永远不推，而且没有任何症状。
                log.exception("检查新邮件出错，下一轮再试")
        await asyncio.sleep(REFRESH_SEC)
