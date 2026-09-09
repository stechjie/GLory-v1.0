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
    friend_code: str = ""  # 见 database/004_profile_display.sql，由数据库默认值签发


class PlayerIdConflict(RuntimeError):
    """客户端报上来的 player_id 已经被别人占了。

    UUIDv4 撞号的概率约等于零，所以真出现基本只有两种可能：客户端在伪造，
    或者同一份存档被复制到了两台设备上。两种都应该让客户端重新签一个，
    而不是让它接管别人的账号。
    """


# 好友码由数据库默认值 glory_new_friend_code() 签发（database/004）。
# 8 位、31 个字符的字母表 ≈ 8.5x10^11 种，撞一次要到百万量级玩家才可能发生一回，
# 但**会**发生 —— 所以要重试。3 次足够：连撞 3 次的概率不可想象，
# 真发生了一定是生成函数坏了，那时候报错比无限重试有用。
_FRIEND_CODE_RETRIES = 3


async def _insert_player(conn, player_id: uuid.UUID):
    """建玩家行。区分两种唯一性冲突 —— **这两种绝不能混为一谈**。

    players_pkey 冲突 = 客户端报上来的 player_id 被占了 → 让它重签一个。
    friend_code 冲突 = 我们自己生成的码撞了     → 我们自己重试。

    混在一起的后果很具体：一次好友码碰撞会被报成 player_id 冲突，
    客户端照 AccountManager 的逻辑重新签发 player_id 再来一次 ——
    本机存档的身份就这么被一次纯运气事件改掉了，
    而那正是 docs/账号系统RFC.md 第七节那条不变量要防的静默身份漂移。
    """
    for attempt in range(_FRIEND_CODE_RETRIES):
        try:
            # ⚠️ **每次尝试必须包在嵌套事务（savepoint）里。**
            # PostgreSQL 里一条语句失败之后整个事务就进入 aborted 状态，
            # 后续任何语句都只会回 "current transaction is aborted" ——
            # 不开 savepoint 的话这个重试循环 100% 是摆设，而且第二次的
            # 报错还和真实原因完全无关，查起来会往错误方向走很远。
            # asyncpg 的嵌套 conn.transaction() 就是 savepoint。
            async with conn.transaction():
                return await conn.fetchrow(
                    "insert into players (player_id) values ($1) "
                    "returning player_id, player_name, friend_code",
                    player_id,
                )
        except asyncpg.UniqueViolationError as exc:
            # asyncpg 把违反的约束名带在 constraint_name 上。缺了它就没法区分，
            # 那种情况按 player_id 冲突处理 —— 保守的一侧是让客户端重签，
            # 而不是让我们在这里无脑重试同一个必然失败的插入。
            if getattr(exc, "constraint_name", "") != "friend_code_unique":
                raise PlayerIdConflict(str(player_id)) from exc
            if attempt == _FRIEND_CODE_RETRIES - 1:
                raise
    raise AssertionError("unreachable")


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
                select p.player_id, p.player_name, p.friend_code
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
                return Player(
                    existing["player_id"],
                    existing["player_name"],
                    created=False,
                    friend_code=existing["friend_code"],
                )

            player_id = proposed_player_id or uuid.uuid4()
            row = await _insert_player(conn, player_id)

            await conn.execute(
                """
                insert into player_identities (provider, provider_user_id, player_id)
                values ($1, $2, $3)
                """,
                PROVIDER_SUPABASE,
                auth_uid,
                player_id,
            )
            return Player(
                row["player_id"],
                row["player_name"],
                created=True,
                friend_code=row["friend_code"],
            )


async def get_by_auth_uid(auth_uid: str) -> Player | None:
    """只读查询，不新建。给 /v1/me 用。"""
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            """
            select p.player_id, p.player_name, p.friend_code
            from player_identities i
            join players p on p.player_id = i.player_id
            where i.provider = $1 and i.provider_user_id = $2
            """,
            PROVIDER_SUPABASE,
            auth_uid,
        )
    if row is None:
        return None
    return Player(
        row["player_id"],
        row["player_name"],
        created=False,
        friend_code=row["friend_code"],
    )
