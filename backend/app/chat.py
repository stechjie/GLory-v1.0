"""好友私聊的读写（docs/聊天系统设计.md 批次 C）。

配套：database/007_chat.sql。分层同 friends.py：**这里只管数据库**，
文本校验、限流、推送都在 routes/chat.py 做完了才进来。

有两条规则**必须留在这一层**，因为它们只有在同一个事务里才成立：

  1. 发一条消息是四步：写消息、推进会话的 last_message_id、推进发送者自己的
     已读游标、裁剪到 200 条。拆成几次往返的话，中途失败会留下「消息写了但会话
     没更新」这类不报错的坏状态 —— 表现是对方的红点不亮。
  2. 已读游标只进不退（greatest），且不能越过会话里真实存在的最后一条（least）。

所有 (low_id, high_id) 一律经 friends._pair() 排序 —— 那是 005 与 007 两张
canonical 表的共同前提，这里不许有第二个拼法。
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass

import asyncpg

from app import db, friends

# 每对好友保留的消息数，也是客户端一次能看到的上限 —— **存的就是能显示的**。
# 2026-09-11 拍板：玩家只能看到、也只能举报自己看得到的消息，不显示的不存。
# 与客户端 ChatService.HISTORY_LIMIT 一致（tools/chat_check.gd 钉着）。
KEEP_PER_CONVERSATION = 200

# 不再是好友之后，记录从最后一条消息算起再留多少天。
# 只防一件事：骂完立刻删好友的人，记录不能跟着好友关系一起没了（见 007 文件头）。
ENDED_RETENTION_DAYS = 30


class ChatRejected(RuntimeError):
    """业务规则拒绝。code 是稳定标识，message 给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Message:
    message_id: int
    sender_id: uuid.UUID
    body: str
    created_at: dt.datetime


@dataclass(frozen=True)
class SendResult:
    message: Message
    # 要推给谁。None = 不推：被拉黑后的静默丢弃，或者是一次重发（第一次已经推过了）。
    deliver_to: uuid.UUID | None


@dataclass(frozen=True)
class ChatSummary:
    """会话列表的一项。**列的是全部好友**，没聊过的 last_message 为 None。"""

    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    online: bool
    last_message: Message | None
    unread: bool


def is_unread(last_message_id: int | None, last_read_id: int) -> bool:
    """未读 = 最后一条 > 我的游标。**唯一判据**，没有计数器（见 007 的 chat_read_state）。

    自己发的那条不会让自己亮红点：send() 在同一个事务里把发送者的游标推到了那条。
    """
    return last_message_id is not None and int(last_message_id) > int(last_read_id)


# --- SQL ----------------------------------------------------------------------

# 🔴 两道闸，缺一不可：
#   greatest()  游标只进不退。同一账号两台设备都在线时，滞后的那台会把游标从 100
#               退回 50，表现为「看过的消息又变成未读」。
#   least()     游标不能越过会话里真实的最后一条。否则客户端报一个特别大的数
#               （bug 或者故意），以后所有新消息都会被当成已读 —— 红点再也不亮，不报错。
# 会话不存在时 select 一行都没有，insert 什么都不做 —— 不会凭空建出已读记录。
_ADVANCE_READ = """
insert into chat_read_state (player_id, low_id, high_id, last_read_id)
select $1, c.low_id, c.high_id, least($4::bigint, coalesce(c.last_message_id, 0))
from chat_conversations c
where c.low_id = $2 and c.high_id = $3
on conflict (player_id, low_id, high_id)
do update set last_read_id = greatest(chat_read_state.last_read_id, excluded.last_read_id)
"""

# 裁剪到最近 KEEP_PER_CONVERSATION 条：子查询取第 200 新的那条，比它老的全删。
# 不满 200 条时子查询为 null，`message_id < null` 恒不成立，一条都不删。
_TRIM = """
delete from chat_messages
where low_id = $1 and high_id = $2
  and message_id < (
    select message_id from chat_messages
    where low_id = $1 and high_id = $2
    order by message_id desc
    offset $3 limit 1
  )
"""

# 会话列表 = **全部好友**（上限 MAX_FRIENDS，所以响应体有界），聊过的按最后一条
# 消息时间排在前面，没聊过的按名字排在后面。
#
# 以好友关系为主表、会话 left join：不再是好友的会话**不出现** —— 那些记录还在库里
# 留 30 天，只给以后的举报用，对双方都不可见。
# presence 同样 left join，理由同 friends._LIST_FRIENDS：从没上报过心跳的玩家没有
# presence 行，inner join 会把他们整个弄丢。
_LIST_CHATS = """
select p.friend_code, p.player_name, p.avatar, p.avatar_frame,
       pr.last_seen_at, pr.presence_visibility,
       c.last_message_id, c.updated_at,
       coalesce(rs.last_read_id, 0) as last_read_id,
       m.sender_id as last_sender_id, m.body as last_body, m.created_at as last_created_at
from player_friendships f
join players p
  on p.player_id = case when f.low_id = $1 then f.high_id else f.low_id end
left join player_presence pr on pr.player_id = p.player_id
left join chat_conversations c on c.low_id = f.low_id and c.high_id = f.high_id
left join chat_read_state rs
  on rs.player_id = $1 and rs.low_id = f.low_id and rs.high_id = f.high_id
left join chat_messages m on m.message_id = c.last_message_id
where f.status = 'accepted' and (f.low_id = $1 or f.high_id = $1)
order by c.updated_at desc nulls last, p.player_name, p.friend_code
"""

# 不再是好友、且最后一条消息已满 N 天的会话整段删掉（消息与已读游标随外键级联）。
# 仍是好友的会话**不按时间删** —— 它们只受「每对 200 条」约束。
_PURGE_ENDED = """
delete from chat_conversations c
where c.updated_at < now() - ($1 * interval '1 day')
  and not exists (
    select 1 from player_friendships f
    where f.low_id = c.low_id and f.high_id = c.high_id and f.status = 'accepted'
  )
"""


# --- 小工具 -------------------------------------------------------------------


async def _resolve(conn: asyncpg.Connection, code: str) -> uuid.UUID:
    """好友码 -> player_id。复用 friends 的查法，只把异常换成本模块的。"""
    try:
        return await friends._resolve_code(conn, code)
    except friends.FriendsRejected:
        raise ChatRejected("player_not_found", "没有这个好友码") from None


async def _are_friends(conn: asyncpg.Connection, low: uuid.UUID, high: uuid.UUID) -> bool:
    return bool(await conn.fetchval(
        """
        select exists (
          select 1 from player_friendships
          where low_id = $1 and high_id = $2 and status = 'accepted'
        )
        """,
        low,
        high,
    ))


async def _silently_drop(conn: asyncpg.Connection, sender_id: uuid.UUID, body: str) -> SendResult:
    """被对方拉黑后发的消息：**不落库、不推送**，但返回值与真发出去的一模一样。

    已定（设计文档第八节第 7 条）：对发送方显示「已发送」—— 告诉他「你被拉黑了」
    等于制造对抗，而他也做不了什么。

    message_id 从同一个序列里取。不取的话要么返回 0、要么返回 null，
    两者都能被人从响应里一眼认出「这条没进库」，静默丢弃就白做了。

    2026-09-11 起**不落库**（原文档写的是「仍然落库」）：拉黑会删掉好友关系，
    会话对双方都不可见，这些消息谁都看不到、也没人能举报，存了只会被人拿来灌库。
    """
    row = await conn.fetchrow(
        """
        select nextval(pg_get_serial_sequence('chat_messages', 'message_id')) as message_id,
               now() as created_at
        """
    )
    return SendResult(
        message=Message(int(row["message_id"]), sender_id, body, row["created_at"]),
        deliver_to=None,
    )


# --- 写 -----------------------------------------------------------------------


async def send(
    sender_id: uuid.UUID,
    target_code: str,
    body: str,
    client_msg_id: uuid.UUID,
) -> SendResult:
    """发一条私聊。body 必须已经过 text_guard.clean_chat_message。

    判定顺序是有意的：
      1. 拉黑先于好友关系判。拉黑会删掉好友关系，反过来判的话被拉黑的人
         只会拿到「你们不是好友」，静默丢弃那条已定的规则就永远走不到。
      2. 「我拉黑了对方」明说（这是他自己做的，不说他会以为坏了）；
         「对方拉黑了我」静默丢弃 —— 同 friends._blocked_between 的分寸。
    """
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            target = await _resolve(conn, target_code)
            if target == sender_id:
                raise ChatRejected("cannot_message_self", "不能给自己发消息")

            blocked = await friends._blocked_between(conn, sender_id, target)
            if blocked == "i_blocked":
                raise ChatRejected("you_blocked_them", "你已拉黑对方，发不了消息")
            if blocked == "they_blocked":
                return await _silently_drop(conn, sender_id, body)

            low, high = friends._pair(sender_id, target)
            if not await _are_friends(conn, low, high):
                raise ChatRejected("not_friends", "你们不是好友，发不了消息")

            await conn.execute(
                """
                insert into chat_conversations (low_id, high_id) values ($1, $2)
                on conflict do nothing
                """,
                low,
                high,
            )
            row = await conn.fetchrow(
                """
                insert into chat_messages (low_id, high_id, sender_id, body, client_msg_id)
                values ($1, $2, $3, $4, $5)
                on conflict (sender_id, client_msg_id) do nothing
                returning message_id, created_at
                """,
                low,
                high,
                sender_id,
                body,
                client_msg_id,
            )
            if row is None:
                # 同一条消息的重发：第一次已经落库（多半也已经推过了）。
                # 原样还回去，**不再推一次** —— 否则对方会看到两条一样的。
                existing = await conn.fetchrow(
                    """
                    select message_id, body, created_at from chat_messages
                    where sender_id = $1 and client_msg_id = $2
                    """,
                    sender_id,
                    client_msg_id,
                )
                if existing is None:  # pragma: no cover - 冲突之后又被裁剪掉，只可能是极端并发
                    raise ChatRejected("send_conflict", "发送冲突，请重试")
                return SendResult(
                    message=Message(
                        int(existing["message_id"]), sender_id,
                        existing["body"], existing["created_at"],
                    ),
                    deliver_to=None,
                )

            message_id = int(row["message_id"])
            # greatest：两条并发发送可能乱序提交，指针不能往回走。
            await conn.execute(
                """
                update chat_conversations
                set last_message_id = greatest(coalesce(last_message_id, 0), $3),
                    updated_at = greatest(updated_at, $4)
                where low_id = $1 and high_id = $2
                """,
                low,
                high,
                message_id,
                row["created_at"],
            )
            # 发出去的就算自己读过了。不推的话，自己刚发的那条会让自己的红点亮起来。
            await conn.execute(_ADVANCE_READ, sender_id, low, high, message_id)
            await conn.execute(_TRIM, low, high, KEEP_PER_CONVERSATION - 1)

    return SendResult(
        message=Message(message_id, sender_id, body, row["created_at"]),
        deliver_to=target,
    )


async def mark_read(player_id: uuid.UUID, other_code: str, last_read_id: int) -> None:
    """推进已读游标。会话不存在时什么都不做（见 _ADVANCE_READ）。"""
    async with db.pool().acquire() as conn:
        other = await _resolve(conn, other_code)
        low, high = friends._pair(player_id, other)
        await conn.execute(_ADVANCE_READ, player_id, low, high, last_read_id)


async def purge_ended_conversations(conn: asyncpg.Connection) -> int:
    """删掉过期的已结束会话。给 maintenance.py 调，返回删了几段。"""
    return db.affected_rows(await conn.execute(_PURGE_ENDED, ENDED_RETENTION_DAYS))


# --- 读 -----------------------------------------------------------------------


async def history(viewer_id: uuid.UUID, other_code: str, after_id: int) -> list[Message]:
    """某个好友的最近消息，按 message_id 升序。

    after_id > 0 时是增量拉取：只要比它新的。断线重连、推送漏掉之后靠它补齐 ——
    推送只是「快」，**正确性全押在这个游标上**。

    不再是好友的会话对双方都不可见：记录还在库里（最多 30 天），只给以后的举报用。
    """
    async with db.pool().acquire() as conn:
        other = await _resolve(conn, other_code)
        if other == viewer_id:
            raise ChatRejected("cannot_message_self", "不能给自己发消息")
        low, high = friends._pair(viewer_id, other)
        if not await _are_friends(conn, low, high):
            raise ChatRejected("not_friends", "你们不是好友")
        rows = await conn.fetch(
            """
            select message_id, sender_id, body, created_at from chat_messages
            where low_id = $1 and high_id = $2 and message_id > $3
            order by message_id desc
            limit $4
            """,
            low,
            high,
            after_id,
            KEEP_PER_CONVERSATION,
        )
    return [
        Message(int(r["message_id"]), r["sender_id"], r["body"], r["created_at"])
        for r in reversed(rows)
    ]


async def list_chats(player_id: uuid.UUID) -> list[ChatSummary]:
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(_LIST_CHATS, player_id)
    out: list[ChatSummary] = []
    for r in rows:
        last: Message | None = None
        if r["last_message_id"] is not None and r["last_body"] is not None:
            last = Message(
                int(r["last_message_id"]), r["last_sender_id"],
                r["last_body"], r["last_created_at"],
            )
        out.append(
            ChatSummary(
                friend_code=r["friend_code"],
                player_name=r["player_name"],
                avatar=r["avatar"],
                avatar_frame=r["avatar_frame"],
                # 列表上显示的「在线」照样尊重隐身开关 —— 那是展示。
                # 投递**不看**它（隐身的人照样收私聊），见 routes/chat.py。
                online=friends._online(r["last_seen_at"], r["presence_visibility"]),
                last_message=last,
                unread=is_unread(r["last_message_id"], int(r["last_read_id"])),
            )
        )
    return out
