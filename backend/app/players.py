"""players / player_identities 的读写。

这里是「一次登录解析成一个 player_id」的全部逻辑，也是本后端第一处真正需要
**事务**的地方 —— 建玩家和建身份映射必须要么都成、要么都不成。

半执行的后果很具体：
  - 只建了 players，没建 player_identities → 玩家下次登录解析不到自己，
    等于账号丢了，而数据库里那行还占着
  - 只建了 player_identities，没建 players → 外键直接挡住，不会发生

第一种不会被外键挡住，只能靠事务。这也是选直连 PostgreSQL 而不是 PostgREST
的原因（见 db.py 顶部）。
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

import asyncpg

from app import db

# 与 database/003_player_identities.sql 的 provider 白名单一致。
# 匿名登录也走 supabase —— Supabase 的匿名用户就是一个普通 auth 用户。
PROVIDER_SUPABASE = "supabase"


@dataclass(frozen=True)
class Player:
    player_id: uuid.UUID
    player_name: str
    created: bool  # 这次调用是否新建了玩家（供日志与客户端区分首登）


class PlayerIdConflict(RuntimeError):
    """客户端报上来的 player_id 已经被别人占了。

    UUIDv4 撞号的概率约等于零，所以真出现基本只有两种可能：客户端在伪造，
    或者同一份存档被复制到了两台设备上。两种都应该让客户端重新签一个，
    而不是让它接管别人的账号。
    """


async def resolve_or_create(
    auth_uid: str,
    proposed_player_id: uuid.UUID | None = None,
) -> Player:
    """把一个 Auth 用户解析成 player_id；没有就新建。

    幂等：同一个 auth_uid 反复调用永远返回同一个 player_id。这条很重要 ——
    没有它，客户端每次重试都会多出一个玩家。

    proposed_player_id 来自客户端（设备首次读档时签发，见 SaveSchema）。
    传了就用它，好处是本地存档和服务器账号从第一天起就是同一个 id，
    不存在「两个 player_id」的歧义。没传就服务端签一个。

    **客户端提议的 id 不被信任为身份**：能不能登录完全由 auth_uid 决定，
    这个 id 只是新建时的主键取值。占用了别人的就直接拒绝。
    """
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            existing = await conn.fetchrow(
                """
                select p.player_id, p.player_name
                from player_identities i
                join players p on p.player_id = i.player_id
                where i.provider = $1 and i.provider_user_id = $2
                """,
                PROVIDER_SUPABASE,
                auth_uid,
            )
            if existing is not None:
                # 顺手记一次活跃。放在同一个事务里，省一次往返。
                await conn.execute(
                    "update players set last_seen_at = now() where player_id = $1",
                    existing["player_id"],
                )
                return Player(existing["player_id"], existing["player_name"], created=False)

            player_id = proposed_player_id or uuid.uuid4()
            try:
                row = await conn.fetchrow(
                    "insert into players (player_id) values ($1) returning player_id, player_name",
                    player_id,
                )
            except asyncpg.UniqueViolationError as exc:
                raise PlayerIdConflict(str(player_id)) from exc

            await conn.execute(
                """
                insert into player_identities (provider, provider_user_id, player_id)
                values ($1, $2, $3)
                """,
                PROVIDER_SUPABASE,
                auth_uid,
                player_id,
            )
            return Player(row["player_id"], row["player_name"], created=True)


async def get_by_auth_uid(auth_uid: str) -> Player | None:
    """只读查询，不新建。给 /v1/me 用。"""
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            """
            select p.player_id, p.player_name
            from player_identities i
            join players p on p.player_id = i.player_id
            where i.provider = $1 and i.provider_user_id = $2
            """,
            PROVIDER_SUPABASE,
            auth_uid,
        )
    if row is None:
        return None
    return Player(row["player_id"], row["player_name"], created=False)
