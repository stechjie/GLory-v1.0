"""人工处罚：禁语音、禁排位（OPS-02）。

表在 `database/019_world_chat.sql` 的 `player_mutes`，范围由 `database/036_sanction_scopes.sql`
放宽到 world / voice / ranked。为什么复用那张表而不另建，见 036 的文件头。

## 三种范围彼此独立

| scope | 限制什么 | 不限制什么 |
| --- | --- | --- |
| `world` | 世界频道发言（`app/world_chat.py` 自己查，不走本模块） | 私聊、语音、排位 |
| `voice` | 组队与局内**说话** | **收听照常**（2026-10-12 用户拍板：禁说不禁听） |
| `ranked` | 人工禁止排位准入 | 休闲、自建房 |

🔴 **撤销一个不解除另外两个**（任务书 §四.3）。这条靠 036 的 `unmute_player` 带 scope 实现，
不是靠这里。本模块只读。

## 🔴 和信誉分自动禁赛是两件事

`player_credit.banned_until`（014）是**系统**按跑路行为自动算的，有自己的到期时间。
这里的 `ranked` 是**人工**下的。任务书 §一 明确要求两者共同生效、
解除人工处罚不能顺带清掉自动禁赛 —— 所以 `ranked.queue_gate` 里两道闸分开判、
原因码也分开（`credit_banned` vs `ranked_sanction`）。

## 为什么「同范围多条只要有一条生效就继续限制」

任务书 §四.3 的原话。这里的 `exists` 查询天然满足：多条里撤销一条，
另一条还在，`exists` 仍为真。别改成「取最后一条」—— 那样撤销最新的一条
就会把更早的一条也放过去。
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from dataclasses import dataclass

log = logging.getLogger("glory.sanctions")

SCOPE_WORLD = "world"
SCOPE_VOICE = "voice"
SCOPE_RANKED = "ranked"

# 后台能下的范围。world 也在里面：统一处罚页要能在同一个地方下世界频道禁言。
SCOPES = (SCOPE_WORLD, SCOPE_VOICE, SCOPE_RANKED)


@dataclass(frozen=True)
class Sanction:
    """一条生效中的处罚。`ends_at` 为 None = 永久。"""

    scope: str
    reason: str
    ends_at: dt.datetime | None

    def to_client(self) -> dict:
        """发给玩家的形状。**不含** note / actor —— 那是内部信息（任务书 §二.3）。"""
        return {"scope": self.scope, "reason": self.reason,
                "ends_at": self.ends_at.isoformat() if self.ends_at else None}


# 模块常量而不是内联：app/schema_check.py 会把它原样拿去 prepare，
# 这样「代码要的列」和「自检要的列」不可能漂移。
#
# order by ends_at desc nulls first：永久的排最前，其次是结束得最晚的那条 ——
# 玩家该看到的是「最严的那一条什么时候结束」，不是随便一条。
_LIVE_SANCTION = """
select reason, ends_at from player_mutes
 where player_id = $1 and scope = $2 and revoked_at is null
   and (ends_at is null or ends_at > now())
 order by ends_at desc nulls first
 limit 1
"""

_ANY_LIVE = """
select exists(
  select 1 from player_mutes
   where player_id = $1 and scope = $2 and revoked_at is null
     and (ends_at is null or ends_at > now()))
"""


async def live(conn, player_id: uuid.UUID, scope: str) -> Sanction | None:
    """这个玩家在这个范围里**现在**有没有被罚。没有返回 None。

    到期判断写在 SQL 里（`ends_at > now()`），不靠定时任务把过期的行标成撤销 ——
    任务书 §四.3：「到期判断在请求路径上有效，不能只等定时任务跑完」。
    """
    row = await conn.fetchrow(_LIVE_SANCTION, player_id, scope)
    if row is None:
        return None
    return Sanction(scope, str(row["reason"]), row["ends_at"])


async def is_sanctioned(conn, player_id: uuid.UUID, scope: str) -> bool:
    """只问「有没有」，不取内容。比 `live` 省一点，用在闸上。"""
    return bool(await conn.fetchval(_ANY_LIVE, player_id, scope))


def clean_scope(value: object) -> str:
    """把外来的 scope 收敛成合法值；不认识的抛 ValueError。

    数据库那边也挡（036 的 check 约束 + 函数里的 raise），这里挡是为了给出
    一句人话 —— 让约束去报错的话，后台看到的是 Postgres 的原文。
    """
    text = str(value or "").strip().lower()
    if text not in SCOPES:
        raise ValueError("不认识的处罚范围：%s（只能是 %s）" % (value, " / ".join(SCOPES)))
    return text
