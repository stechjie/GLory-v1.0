"""在线状态的读写（player_presence）。

配套：database/005_friends.sql、docs/交友系统设计.md 第二节。

**读**在 friends.py 里（好友列表一次 join 把 presence 带出来），
这里只有写：心跳与两个可见性开关。分成两个模块是因为读永远是「好友列表的一部分」，
单独提供一个「查某人在不在线」的接口反而会变成探测器。

## 这一层的全部安全边界：room_id 是客户端自报的

谎报的后果只是让好友进错房间，而房间号本来就是任何人知道号就能进
（NetworkService.team_request_join_room）—— 没有新增攻击面。

⚠️ **这条边界只对「说谎没有收益」的数据成立。**
战绩、排行、奖励一律不能建在这张表上。要做那些，只能等 ②↔③ 通道
（docs/账号系统RFC.md 9.2，未拍板）。
"""

from __future__ import annotations

import uuid

from app import db

VISIBILITIES = frozenset({"friends", "nobody"})

# 房间号由 shard * SHARD_ID_STRIDE + 六位随机组成
# （scripts/multiplayer/NetworkConfig.gd），恒为正。
# 上界给得很松：它只是挡住明显的垃圾值，不是业务校验 ——
# 真正的门是「房间号本来就公开可进」。
MAX_ROOM_ID = 1_000_000_000


class PresenceRejected(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


async def heartbeat(player_id: uuid.UUID, room_id: int | None) -> None:
    """一次心跳。room_id 为 None = 在线但不在房间（主菜单等）。

    **upsert 而不是「先查再插」**：心跳是这套系统里唯一的高频写，
    多一次往返就是多一倍成本，而且两段式在并发下还会撞主键。

    可见性开关**不在这里写** —— on conflict 只更新 last_seen_at 和 room_id。
    心跳顺手覆盖开关的话，玩家设的「隐身」会被下一次心跳冲掉，
    而这个 bug 不报错，只表现为「设置没保存」。
    """
    if room_id is not None and not (0 < room_id <= MAX_ROOM_ID):
        raise PresenceRejected("bad_room_id", "房间号不合法")
    async with db.pool().acquire() as conn:
        await conn.execute(
            """
            insert into player_presence (player_id, last_seen_at, room_id)
            values ($1, now(), $2)
            on conflict (player_id) do update
              set last_seen_at = now(), room_id = excluded.room_id
            """,
            player_id,
            room_id,
        )


async def set_visibility(
    player_id: uuid.UUID, presence_visibility: str, room_visibility: str
) -> dict:
    """两个开关一起写。整份覆盖，不是打补丁。

    分成两个开关的理由：「在不在线」和「在哪个房间」泄漏的东西不是一回事 ——
    后者是行为轨迹。已确认在线状态**只对好友可见**，所以没有 'public' 档。
    """
    for value in (presence_visibility, room_visibility):
        if value not in VISIBILITIES:
            raise PresenceRejected(
                "bad_visibility", "可见性只能是 %s" % " / ".join(sorted(VISIBILITIES))
            )
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            """
            insert into player_presence (player_id, presence_visibility, room_visibility)
            values ($1, $2, $3)
            on conflict (player_id) do update
              set presence_visibility = excluded.presence_visibility,
                  room_visibility     = excluded.room_visibility
            returning presence_visibility, room_visibility
            """,
            player_id,
            presence_visibility,
            room_visibility,
        )
    return {
        "presence_visibility": row["presence_visibility"],
        "room_visibility": row["room_visibility"],
    }


async def get_visibility(player_id: uuid.UUID) -> dict:
    """没有行时返回默认值，而不是 404 —— 没上报过心跳是完全正常的状态
    （新玩家第一次打开设置页就是这样），不该让界面处理一个特例。
    """
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select presence_visibility, room_visibility from player_presence where player_id = $1",
            player_id,
        )
    if row is None:
        return {"presence_visibility": "friends", "room_visibility": "friends"}
    return {
        "presence_visibility": row["presence_visibility"],
        "room_visibility": row["room_visibility"],
    }
