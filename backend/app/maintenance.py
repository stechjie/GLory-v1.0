"""定时清理（② 进程内的后台任务）。

为什么在进程里跑、不用 cron：② 已经被钉死成单进程单实例（app/single_instance.py），
所以进程内的定时任务天然只有一份在跑，不会两个实例同时删同一批行。
cron 则要多一处部署配置 —— 又一处会被忘掉的东西。

清两样东西，都是「只增的表，必须有人定期清」：

  1. 不再是好友、且最后一条消息已满 30 天的私聊会话（database/007 文件头）。
  2. friend_request_log 里 30 天前的行。005 的注释写着「必须有人定期清理」，
     但直到 2026-09-11 都没有任何地方在清 —— 这张表一直只增不减。
"""

from __future__ import annotations

import asyncio
import logging

from app import chat, db

log = logging.getLogger("glory.maintenance")

# 一小时一轮。清理的对象都是「满 30 天」这种天级判断，跑得再勤也没有意义。
INTERVAL_SEC = 3600.0

# 与 database/005_friends.sql 注释里的保留期一致。
# 每日配额只看最近 24 小时，30 天绰绰有余。
REQUEST_LOG_RETENTION_DAYS = 30

_PURGE_REQUEST_LOG = """
delete from friend_request_log
where created_at < now() - ($1 * interval '1 day')
"""


async def run_once() -> dict[str, int]:
    """跑一轮。返回各删了多少，给日志与测试用。"""
    async with db.pool().acquire() as conn:
        conversations = await chat.purge_ended_conversations(conn)
        request_logs = db.affected_rows(
            await conn.execute(_PURGE_REQUEST_LOG, REQUEST_LOG_RETENTION_DAYS)
        )
    if conversations or request_logs:
        log.info("定时清理：过期私聊会话 %d 段，好友请求日志 %d 行", conversations, request_logs)
    return {"chat_conversations": conversations, "friend_request_log": request_logs}


async def loop() -> None:
    """由 lifespan 起、由它取消。

    **先睡再干**：启动那一刻不去跟冷启动抢数据库，也让「改一行代码重启一下」
    这种开发节奏不会每次都触发一轮删除。
    """
    try:
        while True:
            await asyncio.sleep(INTERVAL_SEC)
            if not db.is_connected():
                continue
            try:
                await run_once()
            except Exception:
                # 同 realtime.sweep_loop：清理自己出错不能把循环带走 ——
                # 那样这两张表会重新变成只增不减，而且没有任何症状。
                log.exception("定时清理出错，下一轮再试")
    except asyncio.CancelledError:
        raise
