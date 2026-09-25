"""玩家资料的读写（players 的展示字段 + player_bio）。

配套：database/004_profile_display.sql、docs/玩家资料系统设计.md。

这里只管数据库，**不做任何校验** —— 昵称过 text_guard、头像过 avatar_catalog，
都在 routes/profile.py 里做完了才进来。分开的理由是这一层要能被单独读懂：
看到 update_identity 就知道它写哪几列，不用先读三百行校验。

唯一的例外是两条**只有数据库能判**的规则，它们必须在事务里做：

  1. 改名冷却   要读 name_changed_at，读完到写之间不能有别人插进来
  2. 生日只设一次  要读 birth_month，同上

把它们放到路由层就变成「先查一次、再写一次」的两段式，
两个并发请求能同时通过检查 —— 生日就被改了两次。
"""

from __future__ import annotations

import datetime as dt
import uuid
from dataclasses import dataclass

from app import db

# 首次改名免费（默认名是 'Player'，谁都要改一次），之后 7 天一次。
RENAME_COOLDOWN = dt.timedelta(days=7)


class ProfileRejected(RuntimeError):
    """业务规则拒绝。code 是稳定标识，message 给玩家看。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class SelfProfile:
    """自己看自己：**含隐藏字段与可见性开关**。"""

    player_id: uuid.UUID
    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    showcase_pet: str | None
    created_at: dt.datetime
    name_changed_at: dt.datetime | None
    gender: str | None
    birth_month: int | None
    birth_day: int | None
    region: str | None
    signature: str | None
    gender_visibility: str
    birth_visibility: str
    region_visibility: str

    @property
    def days_since_created(self) -> int:
        """「第 128 天」。比精确日期友好，也少泄漏一点。"""
        delta = dt.datetime.now(dt.timezone.utc) - self.created_at
        return max(1, delta.days + 1)

    def rename_available_at(self) -> dt.datetime | None:
        if self.name_changed_at is None:
            return None
        return self.name_changed_at + RENAME_COOLDOWN


_SELF_QUERY = """
select p.player_id, p.friend_code, p.player_name, p.avatar, p.avatar_frame,
       p.showcase_pet, p.created_at, p.name_changed_at,
       b.gender, b.birth_month, b.birth_day, b.region, b.signature,
       coalesce(b.gender_visibility, 'public') as gender_visibility,
       coalesce(b.birth_visibility,  'public') as birth_visibility,
       coalesce(b.region_visibility, 'public') as region_visibility
from players p
left join player_bio b on b.player_id = p.player_id
where %s
"""


def _row_to_self(row) -> SelfProfile:
    return SelfProfile(**dict(row))


async def get_self(player_id: uuid.UUID) -> SelfProfile | None:
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(_SELF_QUERY % "p.player_id = $1", player_id)
    return None if row is None else _row_to_self(row)


async def get_by_friend_code(code: str) -> SelfProfile | None:
    """按好友码取整行。**裁剪由调用方做** —— 见 routes/profile.py 的 to_public。

    这里刻意不裁剪：一个函数只做一件事，裁剪规则要放在能被门禁直接断言的地方。
    """
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(_SELF_QUERY % "p.friend_code = $1", code)
    return None if row is None else _row_to_self(row)


async def update_identity(
    player_id: uuid.UUID,
    *,
    player_name: str | None = None,
    avatar: str | None = None,
    avatar_frame: str | None = None,
    showcase_pet: str | None = None,
    clear_showcase_pet: bool = False,
) -> SelfProfile:
    """写 players 上的展示字段。只写传进来的那几个。

    showcase_pet 有两种「不传」：没提到（保持原样）和明确要清空。
    None 表示前者，clear_showcase_pet=True 表示后者 —— 用一个 None 表达两件事
    是这类接口最常见的 bug 来源。
    """
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            current = await conn.fetchrow(
                "select player_name, name_changed_at from players "
                "where player_id = $1 for update",
                player_id,
            )
            if current is None:
                raise ProfileRejected("no_player", "该身份没有对应的玩家")

            sets: list[str] = []
            args: list[object] = []

            if player_name is not None and player_name != current["player_name"]:
                last = current["name_changed_at"]
                if last is not None:
                    ready = last + RENAME_COOLDOWN
                    now = dt.datetime.now(dt.timezone.utc)
                    if now < ready:
                        remaining = ready - now
                        raise ProfileRejected(
                            "rename_cooldown",
                            "改名冷却中，还需 %d 天" % max(1, remaining.days + 1),
                        )
                args.append(player_name)
                sets.append("player_name = $%d" % (len(args) + 1))
                sets.append("name_changed_at = now()")

            if avatar is not None:
                args.append(avatar)
                sets.append("avatar = $%d" % (len(args) + 1))
            if avatar_frame is not None:
                args.append(avatar_frame)
                sets.append("avatar_frame = $%d" % (len(args) + 1))
            if clear_showcase_pet:
                sets.append("showcase_pet = null")
            elif showcase_pet is not None:
                args.append(showcase_pet)
                sets.append("showcase_pet = $%d" % (len(args) + 1))

            if sets:
                await conn.execute(
                    "update players set %s where player_id = $1" % ", ".join(sets),
                    player_id,
                    *args,
                )
            row = await conn.fetchrow(_SELF_QUERY % "p.player_id = $1", player_id)
    return _row_to_self(row)


async def update_bio(
    player_id: uuid.UUID,
    *,
    gender: str | None,
    birth_month: int | None,
    birth_day: int | None,
    region: str | None,
    signature: str | None,
    gender_visibility: str,
    birth_visibility: str,
    region_visibility: str,
) -> SelfProfile:
    """整份写 player_bio。行不存在就建。

    ⚠️ **生日只能设置一次。** 已经有值就保留原值，新传的直接丢弃 ——
    不是报错，因为 UI 上那两个输入框在设置过之后就是只读的，
    能走到这里的「新生日」要么是老客户端，要么是有人在打接口。
    静默保留原值比 400 更稳，且不给对方任何反馈。

    判断依据是 birth_month is not null，**不需要额外加一列**。
    这也是为什么「不显示生日」必须做成可见性开关而不是字段值：
    做成值的话，选一次「不显示」就用掉了唯一一次设置机会。
    """
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            existing = await conn.fetchrow(
                "select birth_month, birth_day from player_bio "
                "where player_id = $1 for update",
                player_id,
            )
            if existing is not None and existing["birth_month"] is not None:
                birth_month = existing["birth_month"]
                birth_day = existing["birth_day"]

            await conn.execute(
                """
                insert into player_bio (
                    player_id, gender, birth_month, birth_day, region, signature,
                    gender_visibility, birth_visibility, region_visibility, updated_at
                ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
                on conflict (player_id) do update set
                    gender = excluded.gender,
                    birth_month = excluded.birth_month,
                    birth_day = excluded.birth_day,
                    region = excluded.region,
                    signature = excluded.signature,
                    gender_visibility = excluded.gender_visibility,
                    birth_visibility = excluded.birth_visibility,
                    region_visibility = excluded.region_visibility,
                    updated_at = now()
                """,
                player_id,
                gender,
                birth_month,
                birth_day,
                region,
                signature,
                gender_visibility,
                birth_visibility,
                region_visibility,
            )
            row = await conn.fetchrow(_SELF_QUERY % "p.player_id = $1", player_id)
    return _row_to_self(row)


async def delete_player(player_id: uuid.UUID) -> bool:
    """注销：删资料、留账目。返回是否真的删到了（并发重复注销时第二次是 False）。

    全部逻辑在 database/017 的 erase_player() 里，一个事务。**players 这一行不删** ——
    钱包流水、订单、邮件领取、对局、封号记录都挂在它上面，要留着对账、处理退款与违规
    （2026-09-24 拍板，Google / Apple 都允许为这些目的保留）。删的是能认出这个人的东西：
    资料、登录方式、好友与私聊、昵称头像；好友码换成一个没人知道的新码。

    登录方式删掉之后，这个 Auth 用户再来登录会被当成新玩家，回不到这个号。

    ⚠️ **Supabase Auth 那边的用户刻意不删。**
    今天全是匿名用户，那条记录里没有邮箱、没有任何可识别的个人数据。
    删 auth 用户要用 secret key 调 admin API，会把 secret key 引进
    supabase_auth.py —— 那个类的注释里明写着「不要在这里用 secret key」。
    **接了 Google / Apple 登录之后这一条必须重新做**：那时 auth 用户里有邮箱。
    """
    async with db.pool().acquire() as conn:
        return bool(await conn.fetchval("select erase_player($1)", player_id))
