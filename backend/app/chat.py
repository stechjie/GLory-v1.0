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
import json
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

# 房间邀请（bug提交和修复.docx 第 2 条，2026-09-27）。见 database/020_room_invite.sql。
#
# 与客户端 scripts/multiplayer/RoomInvite.gd 的 KIND 一致（tools/room_invite_check.gd 钉着）——
# 对不上的症状是「发出去的邀请对方收不到」或「邀请渲染成普通文本」，都不报错。
ROOM_INVITE_KIND = "room_invite"
# 同一邀请人**两次邀请之间**至少隔这么多秒（2026-10-11 第 6 条 c：**5 秒**）。
# 客户端 RoomInvite.RATE_LIMIT_SEC 必须同值同口径，但**这里才是权威**：
# 本地那份改个内存就绕过去了。
#
# ⚠️ 口径改过一次：上一版是「同一邀请人**换房间**的邀请间隔 10 秒」
# （2026-09-28 反馈第 5 条）。现行口径「该类消息，同一房间只能发送一次，
# 发送 CD 5 秒」把它换成一条**与房间无关**的发送频率限制 ——
# 「同一房间只能发送一次」由下面的 (a) 去重负责，不再靠冷却表达。
ROOM_INVITE_RATE_SEC = 5

# 组队邀请（10.07 bug 文档第 10 条，2026-10-07）。
#
# 排位/休闲房间的「邀请好友入队」。与 room_invite 同样做成**一条带 kind 的私聊**，
# 理由见 scripts/multiplayer/RoomInvite.gd 文件头：「有消息 + 有音效 + 有红点 + 可已读」
# 这四件事全部白拿，不必再造一条要单独维护红点的推送通路。
#
# ⚠️ 与客户端 ui/components/PartyInviteBubble.gd 的 KIND_TEAM 一致，
# 也与 RoomInvite.PARTY_KIND 一致（tools/party_invite_bubble_check.gd 钉着）。
# 对不上的症状：邀请气泡照弹，但聊天列表里没有那条记录、红点也不灭。
PARTY_INVITE_KIND = "party_invite"


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
    # text / room_invite。默认 text 让既有构造点（_silently_drop 等）一个字都不用改。
    kind: str = "text"
    # 类型相关的机器可读数据。text 为 None；room_invite 为 {"room_id": int}。
    payload: dict | None = None


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
       m.sender_id as last_sender_id, m.body as last_body, m.created_at as last_created_at,
       m.kind as last_kind, m.payload as last_payload
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


# asyncpg 把 jsonb 取回来是**字符串**（除非注册了 codec）—— 这里统一转成 dict。
# 不转的话 routes 那一层把 payload 直接塞进响应模型，会变成一坨 JSON 文本。
def _decode_payload(value) -> dict | None:
    if value is None:
        return None
    if isinstance(value, dict):
        return value
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


async def _silently_drop(
    conn: asyncpg.Connection,
    sender_id: uuid.UUID,
    body: str,
    kind: str = "text",
    payload: dict | None = None,
) -> SendResult:
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
        message=Message(
            int(row["message_id"]), sender_id, body, row["created_at"], kind, payload,
        ),
        deliver_to=None,
    )


# --- 写 -----------------------------------------------------------------------


async def _check_invite_rules(
    conn: asyncpg.Connection,
    sender_id: uuid.UUID,
    low: uuid.UUID,
    high: uuid.UUID,
    room_id: int,
) -> None:
    """房间邀请的两条业务规则（要求 4）。**判在数据库上**。

    理由与 friends 的每日配额、改名冷却相同：`rate_limit.py` 是进程内滑动窗口，
    重启即清零、多 worker 各算各的（它自己的注释写着）。把「同房只发一次」判在那里，
    等于重启一次就能重发一轮，而症状只是「有人能反复邀请」——不报错。

    (a)「同一邀请人同一房间只会发送一次邀请消息」
        —— 键是 (邀请人, 房间号, 收件人)。同一个房间邀请第二个好友要放行，
        否则这个功能就只能邀请一个人。
    (b)「该类消息……发送 CD 5 秒」（2026-10-11 第 6 条 c）——
        **任意两次邀请之间至少隔 ROOM_INVITE_RATE_SEC 秒，与房间号无关**。

        ⚠️ 上一版把冷却绑在「房间号变了」上（2026-09-28 反馈第 5 条：
        防「换房后刷屏式群发」，同房连邀不同好友不限）。10.11 的用户口径
        把「同一房间只能发送一次」交给 (a)，冷却则变成一条纯粹的发送频率限制，
        所以这里不再比较房间号 —— 只看向上一条邀请过了多久。
        客户端 RoomInvite.send_blocked_reason 用同一口径，两边必须一致。
    """
    dup = await conn.fetchval(
        """
        select 1 from chat_messages
        where sender_id = $1 and kind = $2
          and payload ->> 'room_id' = $3
          and ((low_id = $4 and high_id = $5) or (low_id = $5 and high_id = $4))
        limit 1
        """,
        sender_id,
        ROOM_INVITE_KIND,
        str(room_id),
        low,
        high,
    )
    if dup:
        raise ChatRejected("invite_duplicate", "同一个房间已经邀请过对方了")

    # (b) 发送冷却：distance 与房间号无关。
    last = await conn.fetchrow(
        """
        select created_at from chat_messages
        where sender_id = $1 and kind = $2
        order by created_at desc
        limit 1
        """,
        sender_id,
        ROOM_INVITE_KIND,
    )
    if last is not None:
        elapsed = await conn.fetchval("select now() - $1::timestamptz", last["created_at"])
        if elapsed is not None and elapsed.total_seconds() < ROOM_INVITE_RATE_SEC:
            raise ChatRejected("invite_rate_limited", "邀请发得太快了，请稍后再试")


async def _check_party_invite_rules(conn, low: uuid.UUID, high: uuid.UUID,
                                    party_id: str) -> None:
    """组队邀请的业务规则（10.07 第 10 条）。

    比 room_invite 简单：没有「换房 10 秒间隔」那条 —— 组队邀请的限流在
    routes/party.py 的 _invite_limiter（按邀请人滑窗）上已经有一道，
    这里只判**同一个队伍对同一个人不重复发**（要求：被邀请方只收到一次）。

    键是 (队伍, 收件人)，不含邀请人 —— 队伍里任何人点「邀请好友」都算同一支队伍，
    换个队员再邀同一个人不该再落一条。
    """
    dup = await conn.fetchval(
        """
        select 1 from chat_messages
        where kind = $1
          and payload ->> 'party_id' = $2
          and ((low_id = $3 and high_id = $4) or (low_id = $4 and high_id = $3))
        limit 1
        """,
        PARTY_INVITE_KIND,
        party_id,
        low,
        high,
    )
    if dup:
        raise ChatRejected("party_invite_duplicate", "已经邀请过对方了")


async def send(
    sender_id: uuid.UUID,
    target_code: str,
    body: str,
    client_msg_id: uuid.UUID,
    kind: str = "text",
    payload: dict | None = None,
) -> SendResult:
    """发一条私聊。body 必须已经过 text_guard.clean_chat_message。

    判定顺序是有意的：
      1. 拉黑先于好友关系判。拉黑会删掉好友关系，反过来判的话被拉黑的人
         只会拿到「你们不是好友」，静默丢弃那条已定的规则就永远走不到。
      2. 「我拉黑了对方」明说（这是他自己做的，不说他会以为坏了）；
         「对方拉黑了我」静默丢弃 —— 同 friends._blocked_between 的分寸。
      3. 房间邀请的业务规则（去重 / 5 秒发送冷却）压在**好友关系之后** ——
         陌生人根本发不出消息，那两条就没必要先跑一遍查询。

    kind='room_invite' 时 payload 必须是 {"room_id": int}（校验在 routes/chat.py 做，
    这里只负责按它去重）。

    kind='party_invite'（10.07 第 10 条）时 payload 是 {"party_id": str, "mode": str}，
    去重口径：**同一队伍 + 同一收件人**只落一条，重复邀请不再写库、也不再推送
    —— 与 room_invite 的 (房间, 收件人) 一致，理由同样是不想刷屏。
    """
    invite_room_id = int((payload or {}).get("room_id", 0)) if kind == ROOM_INVITE_KIND else 0
    party_invite_id = str((payload or {}).get("party_id", "")) if kind == PARTY_INVITE_KIND else ""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            target = await _resolve(conn, target_code)
            if target == sender_id:
                raise ChatRejected("cannot_message_self", "不能给自己发消息")

            blocked = await friends._blocked_between(conn, sender_id, target)
            if blocked == "i_blocked":
                raise ChatRejected("you_blocked_them", "你已拉黑对方，发不了消息")
            if blocked == "they_blocked":
                return await _silently_drop(conn, sender_id, body, kind, payload)

            low, high = friends._pair(sender_id, target)
            if not await _are_friends(conn, low, high):
                raise ChatRejected("not_friends", "你们不是好友，发不了消息")

            if kind == ROOM_INVITE_KIND:
                await _check_invite_rules(conn, sender_id, low, high, invite_room_id)
            elif kind == PARTY_INVITE_KIND and party_invite_id:
                await _check_party_invite_rules(conn, low, high, party_invite_id)

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
                insert into chat_messages
                    (low_id, high_id, sender_id, body, client_msg_id, kind, payload)
                values ($1, $2, $3, $4, $5, $6, $7::jsonb)
                on conflict (sender_id, client_msg_id) do nothing
                returning message_id, created_at
                """,
                low,
                high,
                sender_id,
                body,
                client_msg_id,
                kind,
                json.dumps(payload) if payload is not None else None,
            )
            if row is None:
                # 同一条消息的重发：第一次已经落库（多半也已经推过了）。
                # 原样还回去，**不再推一次** —— 否则对方会看到两条一样的。
                existing = await conn.fetchrow(
                    """
                    select message_id, body, created_at, kind, payload from chat_messages
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
                        str(existing["kind"]), _decode_payload(existing["payload"]),
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

    # kind / payload 必须回给调用方：routes 用它组装 HTTP 回包与 dm 推送，两条都靠它。
    # 少了这两个参数，发出去的邀请在收件人那头就是一条普通文本（不报错）。
    return SendResult(
        message=Message(message_id, sender_id, body, row["created_at"], kind, payload),
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
            select message_id, sender_id, body, created_at, kind, payload from chat_messages
            where low_id = $1 and high_id = $2 and message_id > $3
            order by message_id desc
            limit $4
            """,
            low,
            high,
            after_id,
            KEEP_PER_CONVERSATION,
        )
    # 🔴 kind / payload 必须一起带出去。漏掉的话，收件人**重进聊天时**（走这条 history，
    # 而不是那条带 kind 的推送）拿到的邀请就是缺字段的 → 渲染成一条普通文本，
    # 「立即参与」按钮永远不出现，而且不报错。2026-09-27 实测踩到的就是这一处。
    return [
        Message(
            int(r["message_id"]), r["sender_id"], r["body"], r["created_at"],
            str(r["kind"] or "text"), _decode_payload(r["payload"]),
        )
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
                str(r["last_kind"] or "text"), _decode_payload(r["last_payload"]),
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
