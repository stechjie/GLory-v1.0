"""好友关系、拉黑、请求配额的读写。

配套：database/005_friends.sql、docs/交友系统设计.md。

分层同 profile.py：**这里只管数据库**，好友码大小写归一、文本校验之类
在 routes/friends.py 做完了才进来。

但有几条规则**必须留在这一层**，因为它们只有在事务里才成立：

  1. 好友数上限   要先 count 再 insert，中间不能有别人插进来
  2. 每日请求配额  同上
  3. 交叉请求      A 加 B 的同时 B 加 A，靠主键冲突裁决，且重试要在 savepoint 里

把它们提到路由层就变成「先查一次、再写一次」的两段式，
两个并发请求能同时通过检查 —— 上限就被突破了。
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass

import asyncpg

from app import db

# 好友数上限。已确认 100。
#
# 它首先是**响应体上界**：没有它 GET /v1/me/friends 的大小由玩家决定。
MAX_FRIENDS = 100

# 每人每天能发起的好友请求数。
#
# ⚠️ **判在数据库上（friend_request_log），不能用 app/rate_limit.py。**
# 那是进程内滑动窗口，重启即清零、多 worker 各算各的（它自己的注释写着）。
# 它仍然要挂着，但它防的是刷接口，不是业务配额。
# 同 004 把改名冷却判在 players.name_changed_at 上。
DAILY_REQUEST_QUOTA = 20

# 心跳间隔与在线判定 TTL。TTL 必须**大于**心跳间隔，否则丢一个包就显示离线。
# 留一次重试的余量：60 秒发一次，150 秒内没消息才算离线。
#
# 代价是「刚下线」最多显示成在线 2.5 分钟。没有更好的办法 ——
# 客户端崩溃时不会发「我下线了」，任何「下线时发个包」的方案都挡不住进程被杀。
HEARTBEAT_INTERVAL_SEC = 60
PRESENCE_TTL = dt.timedelta(seconds=150)


class FriendsRejected(RuntimeError):
    """业务规则拒绝。code 是稳定标识，message 给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class FriendSummary:
    """好友列表的一项。**昵称永远和好友码一起显示** —— 见下面 to_public 的说明。"""

    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    online: bool
    room_id: int | None


@dataclass(frozen=True)
class PendingRequest:
    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    created_at: dt.datetime


@dataclass(frozen=True)
class BlockedPlayer:
    friend_code: str
    player_name: str
    avatar: str
    created_at: dt.datetime


# --- 小工具 -------------------------------------------------------------------


def _pair(a: uuid.UUID, b: uuid.UUID) -> tuple[uuid.UUID, uuid.UUID]:
    """把两个 player_id 排成 (low, high)。

    **这是 005 那张表的全部前提。** 任何直接拼 (low_id, high_id) 而不过这个
    函数的地方，都可能写出一行 low > high —— 那行会被 check 约束挡下来，
    但错误信息完全看不出是排序问题。
    """
    return (a, b) if a < b else (b, a)


def _online(last_seen: dt.datetime | None, visibility: str | None) -> bool:
    if last_seen is None or visibility != "friends":
        return False
    return dt.datetime.now(dt.timezone.utc) - last_seen < PRESENCE_TTL


async def _resolve_code(conn: asyncpg.Connection, code: str) -> uuid.UUID:
    """好友码 -> player_id。查无此人抛 FriendsRejected。

    好友码在库里一律大写（004），调用方负责 .upper()。
    """
    row = await conn.fetchrow("select player_id from players where friend_code = $1", code)
    if row is None:
        raise FriendsRejected("player_not_found", "没有这个好友码")
    return row["player_id"]


async def _blocked_between(
    conn: asyncpg.Connection, me: uuid.UUID, other: uuid.UUID
) -> str:
    """返回 'none' / 'i_blocked' / 'they_blocked'。

    两个方向要分开报：**我拉黑了对方**必须明说（不然玩家不知道为什么发不出去，
    而这是他自己做的），**对方拉黑了我**只给通用失败 —— 把它说破等于给
    骚扰者一个「对方是不是拉黑我了」的探测器。

    这条不是完美的（被拉黑的人仍能从别处推断出来），但不该由我们主动告知。
    """
    rows = await conn.fetch(
        """
        select blocker_id from player_blocks
        where (blocker_id = $1 and blocked_id = $2)
           or (blocker_id = $2 and blocked_id = $1)
        """,
        me,
        other,
    )
    blockers = {r["blocker_id"] for r in rows}
    if me in blockers:
        return "i_blocked"
    if other in blockers:
        return "they_blocked"
    return "none"


async def _friend_count(conn: asyncpg.Connection, player_id: uuid.UUID) -> int:
    row = await conn.fetchrow(
        """
        select count(*) as n from player_friendships
        where status = 'accepted' and (low_id = $1 or high_id = $1)
        """,
        player_id,
    )
    return int(row["n"])


# --- 读 -----------------------------------------------------------------------

# 好友列表。presence 用 left join —— 从没上报过心跳的玩家没有 presence 行，
# inner join 会把他们整个从好友列表里弄丢，而那是**沉默的**数据缺失。
_LIST_FRIENDS = """
select p.friend_code, p.player_name, p.avatar, p.avatar_frame,
       pr.last_seen_at, pr.room_id, pr.presence_visibility, pr.room_visibility
from player_friendships f
join players p
  on p.player_id = case when f.low_id = $1 then f.high_id else f.low_id end
left join player_presence pr on pr.player_id = p.player_id
where f.status = 'accepted' and (f.low_id = $1 or f.high_id = $1)
order by p.player_name, p.friend_code
"""


async def list_friends(player_id: uuid.UUID) -> list[FriendSummary]:
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(_LIST_FRIENDS, player_id)
    out: list[FriendSummary] = []
    for r in rows:
        online = _online(r["last_seen_at"], r["presence_visibility"])
        # 房间号有独立开关：「在不在线」和「在哪个房间」泄漏的东西不是一回事。
        # 不在线时一律不给房间号 —— 否则会泄漏「他刚才在哪」。
        room = r["room_id"] if (online and r["room_visibility"] == "friends") else None
        out.append(
            FriendSummary(
                friend_code=r["friend_code"],
                player_name=r["player_name"],
                avatar=r["avatar"],
                avatar_frame=r["avatar_frame"],
                online=online,
                room_id=int(room) if room is not None else None,
            )
        )
    return out


_LIST_REQUESTS = """
select p.friend_code, p.player_name, p.avatar, p.avatar_frame, f.created_at,
       (f.requested_by = $1) as outgoing
from player_friendships f
join players p
  on p.player_id = case when f.low_id = $1 then f.high_id else f.low_id end
where f.status = 'pending' and (f.low_id = $1 or f.high_id = $1)
order by f.created_at desc
"""


async def list_requests(player_id: uuid.UUID) -> dict[str, list[PendingRequest]]:
    """收到的 + 发出的，一次查询拿全。

    刻意不拆成两个接口：资料页那次的教训 —— 拆开只会让界面发两个并发请求，
    多一处会出「收到的到了、发出的没到」的中间态（见 docs/玩家资料系统设计.md 第六节）。
    """
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(_LIST_REQUESTS, player_id)
    incoming: list[PendingRequest] = []
    outgoing: list[PendingRequest] = []
    for r in rows:
        item = PendingRequest(
            friend_code=r["friend_code"],
            player_name=r["player_name"],
            avatar=r["avatar"],
            avatar_frame=r["avatar_frame"],
            created_at=r["created_at"],
        )
        (outgoing if r["outgoing"] else incoming).append(item)
    return {"incoming": incoming, "outgoing": outgoing}


async def list_blocks(player_id: uuid.UUID) -> list[BlockedPlayer]:
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            """
            select p.friend_code, p.player_name, p.avatar, b.created_at
            from player_blocks b
            join players p on p.player_id = b.blocked_id
            where b.blocker_id = $1
            order by b.created_at desc
            """,
            player_id,
        )
    return [
        BlockedPlayer(
            friend_code=r["friend_code"],
            player_name=r["player_name"],
            avatar=r["avatar"],
            created_at=r["created_at"],
        )
        for r in rows
    ]


async def relation_to(player_id: uuid.UUID, other_code: str) -> str:
    """我和这个好友码是什么关系。

    给 GET /v1/players/by-code/{code} 用 —— 资料页要显示「加好友 / 已是好友 /
    待通过」。返回 none / pending_out / pending_in / friends / blocked。
    """
    async with db.pool().acquire() as conn:
        other = await _resolve_code(conn, other_code)
        if other == player_id:
            return "self"
        if await _blocked_between(conn, player_id, other) != "none":
            return "blocked"
        low, high = _pair(player_id, other)
        row = await conn.fetchrow(
            "select status, requested_by from player_friendships where low_id = $1 and high_id = $2",
            low,
            high,
        )
    if row is None:
        return "none"
    if row["status"] == "accepted":
        return "friends"
    return "pending_out" if row["requested_by"] == player_id else "pending_in"


# --- 写 -----------------------------------------------------------------------


async def send_request(player_id: uuid.UUID, target_code: str) -> str:
    """发起好友请求。返回 'pending' 或 'accepted'（对方已经先加过我）。

    整个流程在**一个事务**里，因为好友数上限和每日配额都是「先查后写」，
    分成两次往返就能被并发绕过。
    """
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            target = await _resolve_code(conn, target_code)
            if target == player_id:
                raise FriendsRejected("cannot_add_self", "不能加自己为好友")

            blocked = await _blocked_between(conn, player_id, target)
            if blocked == "i_blocked":
                raise FriendsRejected(
                    "you_blocked_them", "你已拉黑对方。先解除拉黑才能加好友"
                )
            if blocked == "they_blocked":
                # 刻意含糊：把「对方拉黑了你」说破，等于给骚扰者一个探测器。
                raise FriendsRejected("request_refused", "无法向该玩家发送好友请求")

            if await _friend_count(conn, player_id) >= MAX_FRIENDS:
                raise FriendsRejected(
                    "friend_limit_reached", "你的好友已满 %d 人" % MAX_FRIENDS
                )
            # 对方是否已满**不在这里查**：那会泄漏别人的好友数。
            # 满员由 accept 时再判 —— 那时对方是自愿操作，告知他自己满了没有问题。

            used = await conn.fetchval(
                """
                select count(*) from friend_request_log
                where requester_id = $1 and created_at > now() - interval '1 day'
                """,
                player_id,
            )
            if int(used) >= DAILY_REQUEST_QUOTA:
                raise FriendsRejected(
                    "daily_quota_exceeded",
                    "今天发出的好友请求已达上限（%d 个），明天再试" % DAILY_REQUEST_QUOTA,
                )

            low, high = _pair(player_id, target)
            try:
                # 嵌套 transaction = savepoint。**必须有** ——
                # PostgreSQL 里一条语句失败后整个事务进入 aborted 状态，
                # 不开 savepoint 的话下面的 fetchrow 只会报一个与真实原因
                # 完全无关的错（同 backend/app/players.py 的好友码重试）。
                async with conn.transaction():
                    await conn.execute(
                        """
                        insert into player_friendships (low_id, high_id, requested_by, status)
                        values ($1, $2, $3, 'pending')
                        """,
                        low,
                        high,
                        player_id,
                    )
                    outcome = "pending"
            except asyncpg.UniqueViolationError:
                # 已经有这一行了。三种情况：
                #   已是好友        -> 报错
                #   我发过了        -> 报错（幂等地告诉他"已经发过"）
                #   **对方先加了我** -> 直接成为好友（交叉请求）
                row = await conn.fetchrow(
                    """
                    select status, requested_by from player_friendships
                    where low_id = $1 and high_id = $2
                    """,
                    low,
                    high,
                )
                if row is None:  # pragma: no cover - 冲突后又消失，只可能是并发删除
                    raise FriendsRejected("request_conflict", "请求冲突，请重试") from None
                if row["status"] == "accepted":
                    raise FriendsRejected("already_friends", "你们已经是好友了") from None
                if row["requested_by"] == player_id:
                    raise FriendsRejected("already_requested", "已经发过请求，等对方通过") from None
                await _accept_locked(conn, low, high, player_id, target)
                outcome = "accepted"

            # 配额日志**无论成为 pending 还是 accepted 都要记**：
            # 它计的是"发起动作"，不是"产生了一个待处理请求"。
            # 只在 pending 时记的话，靠交叉请求就能绕过配额。
            await conn.execute(
                "insert into friend_request_log (requester_id, target_id) values ($1, $2)",
                player_id,
                target,
            )
            return outcome


async def _accept_locked(
    conn: asyncpg.Connection,
    low: uuid.UUID,
    high: uuid.UUID,
    me: uuid.UUID,
    other: uuid.UUID,
) -> None:
    """把一行 pending 置为 accepted。调用方必须已经在事务里。

    **两边都要查上限。** 只查自己的话，对方满员时这段关系照样建立，
    他的好友列表就会超过 MAX_FRIENDS —— 而那正是响应体上界要防的。
    """
    for who, label in ((me, "你"), (other, "对方")):
        if await _friend_count(conn, who) >= MAX_FRIENDS:
            raise FriendsRejected(
                "friend_limit_reached", "%s的好友已满 %d 人" % (label, MAX_FRIENDS)
            )
    await conn.execute(
        """
        update player_friendships
        set status = 'accepted', accepted_at = now()
        where low_id = $1 and high_id = $2 and status = 'pending'
        """,
        low,
        high,
    )


async def accept_request(player_id: uuid.UUID, other_code: str) -> None:
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            other = await _resolve_code(conn, other_code)
            low, high = _pair(player_id, other)
            row = await conn.fetchrow(
                """
                select status, requested_by from player_friendships
                where low_id = $1 and high_id = $2
                for update
                """,
                low,
                high,
            )
            if row is None or row["status"] != "pending":
                raise FriendsRejected("no_pending_request", "没有待处理的好友请求")
            if row["requested_by"] == player_id:
                # 自己发的请求不能自己通过。没有这条判断，任何人都能单方面
                # 把自己加进别人的好友列表 —— 而"互相同意"是这套模型的全部意义。
                raise FriendsRejected("cannot_accept_own", "这是你自己发出的请求")
            await _accept_locked(conn, low, high, player_id, other)


async def remove_request(player_id: uuid.UUID, other_code: str) -> None:
    """拒绝收到的请求 / 取消自己发出的请求。**两者都是删掉这一行。**

    已确认的产品决定：拒绝 = 删记录，不留 'rejected' 状态。
    留 rejected 的话误拒的人永远加不回来；删掉则靠每日配额与拉黑防重发。
    """
    async with db.pool().acquire() as conn:
        other = await _resolve_code(conn, other_code)
        low, high = _pair(player_id, other)
        result = await conn.execute(
            """
            delete from player_friendships
            where low_id = $1 and high_id = $2 and status = 'pending'
            """,
            low,
            high,
        )
    if result == "DELETE 0":
        raise FriendsRejected("no_pending_request", "没有待处理的好友请求")


async def remove_friend(player_id: uuid.UUID, other_code: str) -> None:
    """删好友。**双向消失** —— 一行没了就是没了。

    这不是选择题：选了「互相同意」模型，删除就必须对称，
    否则会造出 005 要堵死的那个「他有我、我没他」的状态。
    Steam / 王者 / 微信都是双向消失；单向只存在于「关注」模型。

    **不通知对方**（通知等于制造对抗，对方也做不了什么），
    但界面要提示操作者「对方也会从他的列表里消失」。
    """
    async with db.pool().acquire() as conn:
        other = await _resolve_code(conn, other_code)
        low, high = _pair(player_id, other)
        result = await conn.execute(
            """
            delete from player_friendships
            where low_id = $1 and high_id = $2 and status = 'accepted'
            """,
            low,
            high,
        )
    if result == "DELETE 0":
        raise FriendsRejected("not_friends", "你们不是好友")


async def block(player_id: uuid.UUID, other_code: str) -> None:
    """拉黑。**同一个事务里删掉已有关系**（含待处理请求）。

    只插 block 不删关系，会得到「已经拉黑了但还在好友列表里」——
    而玩家点拉黑的意思显然是两者都要。
    """
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            other = await _resolve_code(conn, other_code)
            if other == player_id:
                raise FriendsRejected("cannot_block_self", "不能拉黑自己")
            low, high = _pair(player_id, other)
            await conn.execute(
                "delete from player_friendships where low_id = $1 and high_id = $2",
                low,
                high,
            )
            await conn.execute(
                """
                insert into player_blocks (blocker_id, blocked_id) values ($1, $2)
                on conflict do nothing
                """,
                player_id,
                other,
            )


async def unblock(player_id: uuid.UUID, other_code: str) -> None:
    """解除拉黑。**不恢复好友关系** —— 那已经在 block() 里删掉了，
    要重新加好友得重新走请求流程。这是想要的：拉黑是一次明确的断交。
    """
    async with db.pool().acquire() as conn:
        other = await _resolve_code(conn, other_code)
        result = await conn.execute(
            "delete from player_blocks where blocker_id = $1 and blocked_id = $2",
            player_id,
            other,
        )
    if result == "DELETE 0":
        raise FriendsRejected("not_blocked", "你没有拉黑这个玩家")
