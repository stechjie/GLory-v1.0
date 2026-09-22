"""赛季结算的后台任务（`docs/排位系统设计.md` 第九节）。第 6 步。

配套 `database/015_ranked_seasons.sql`。**这里几乎不做事** —— 结算的全部逻辑
（认领 / 归档 / 发奖 / 清零）在那个文件的 `settle_season()` 函数里。

## 为什么逻辑在数据库里，不在这里

赛季结算是几千行的集合操作（`insert ... select`）。拉进 Python 再一行行写回去，
既慢又要自己处理「写到一半挂了」。放在函数里，事务边界就是天然的原子性。

这边只负责**什么时候调它**。

## 🔴 幂等不靠这里

后台任务会重复跑：进程重启、手动再点一次、以后真的起了两个实例。
而重复结算一次 = 所有人**收到两份奖励**、分数被清两次。

防线在 `settle_season()` 的第一句（认领 `settled_at`），**不在这里**。
所以这边可以放心地「每 N 分钟看一眼」，不用自己记「我跑过没有」。

## 赛季长度是表里的一行，不是这里的常量

第十节 10.1 还没拍板。管理员往 `ranked_seasons` 插一行、自己填 `ends_at`；
这个任务只管「到点了就结算」。写死成「4 周」的话，改一次要发一次后端。
"""

from __future__ import annotations

import asyncio
import logging

from app import db

log = logging.getLogger("glory.seasons")

# 多久看一眼。赛季是以周计的东西，5 分钟的精度绰绰有余 ——
# 而且每次都是一条走索引的 count，代价可忽略。
POLL_SEC = 300.0

# 结算时写进邮件 actor 列的名字。管理员手动跑时填自己的名字，这里是自动的那条路。
AUTO_ACTOR = "auto"


async def due_seasons(conn) -> list[int]:
    """到点了、还没结算的赛季。正常最多一个；多个说明任务停了一阵。"""
    rows = await conn.fetch(
        "select season from ranked_seasons"
        " where ends_at <= now() and settled_at is null order by season")
    return [int(r["season"]) for r in rows]


async def settle_due() -> int:
    """结算所有到点的赛季。返回结算了几个。

    单独一个函数是为了能在测试里直接调，不必等 5 分钟的循环。
    """
    if not db.is_connected():
        return 0
    settled = 0
    async with db.pool().acquire() as conn:
        for season in await due_seasons(conn):
            # 函数自己是一个事务，这里不用再包一层。
            mails = await conn.fetchval("select settle_season($1, $2)", season, AUTO_ACTOR)
            if int(mails) < 0:
                # -1 = 别人（管理员手动，或者另一个实例）刚刚结算过。不是错误。
                log.info("赛季 %d 已经被结算过了，跳过", season)
                continue
            settled += 1
            log.info("赛季 %d 结算完成，发出 %d 封奖励邮件", season, int(mails))
    return settled


async def loop() -> None:
    """后台循环。由 app/main.py 的 lifespan 起停，同 mail.loop / announcements.loop。"""
    while True:
        try:
            await asyncio.sleep(POLL_SEC)
            await settle_due()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - 一轮出错不该让循环停掉
            log.exception("赛季结算出错，下一轮再试")
