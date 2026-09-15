"""PostgreSQL 连接池。

为什么直连而不是走 Supabase 的 PostgREST：账号层以后要做钱包与充值，那些是
「要么全做、要么不做」的多语句事务（同 scripts/multiplayer/EconomyLedger.gd 的
设计原则 3），PostgREST 给不了。直连还让迁移只需要换一条连接串 ——
符合 docs/账号系统RFC.md 第二节「尽量使用标准 PostgreSQL」。

Supabase Auth 仍然走它自己的 REST 接口。那是 RFC 的分工：
**Auth 是可替换的身份提供方，数据库是标准 PostgreSQL。**
"""

from __future__ import annotations

import logging
from urllib.parse import urlparse

import asyncpg

log = logging.getLogger("glory.db")

_pool: asyncpg.Pool | None = None


class NotConfigured(RuntimeError):
    """没配连接串就用数据库。调用方应转成 503，而不是 500。"""


def _pool_kwargs(dsn: str) -> dict:
    """针对连接串挑参数。

    Supabase 的 Transaction pooler（端口 6543）是 pgbouncer transaction 模式，
    与 asyncpg 的预编译语句缓存冲突 —— 症状是随机的
    `prepared statement "__asyncpg_stmt_x__" does not exist`，很难查。
    这里检测到就把缓存关掉。
    """
    kwargs: dict = {"min_size": 1, "max_size": 5, "command_timeout": 10}
    try:
        parsed = urlparse(dsn)
        if parsed.port == 6543:
            log.warning(
                "连接串用的是 Transaction pooler(6543)，已关闭预编译语句缓存。"
                "建议换成 Session pooler 或 Direct connection。"
            )
            kwargs["statement_cache_size"] = 0
    except Exception:  # noqa: BLE001 - 解析失败不该挡住连接，交给 asyncpg 报错
        pass
    return kwargs


async def connect(dsn: str) -> None:
    """建立连接池。连接串为空时**不建池**，也不抛异常。

    骨架要能在还没配数据库时起来（同 /health 的设计），需要数据库的接口各自
    fail closed —— 而不是让整个进程起不来。
    """
    global _pool
    if not dsn.strip():
        log.warning("GLORY_DATABASE_URL 未配置，需要数据库的接口会返回 503")
        return
    _pool = await asyncpg.create_pool(dsn, **_pool_kwargs(dsn))
    log.info("数据库连接池已建立")


async def disconnect() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def pool() -> asyncpg.Pool:
    """取连接池。没配就抛 NotConfigured。"""
    if _pool is None:
        raise NotConfigured("GLORY_DATABASE_URL 未配置或连接池未建立")
    return _pool


def is_connected() -> bool:
    return _pool is not None


# 账号层当前应当存在的表。新增迁移文件时同步更新这里 ——
# 它是 /v1/debug/schema 的判据，漏了就等于那张表没人检查。
EXPECTED_TABLES: tuple[str, ...] = (
    "players",
    "player_bio",
    "player_identities",
    # 005（交友系统）
    "player_friendships",
    "player_blocks",
    "friend_request_log",
    "player_presence",
    # 006（最近一起玩过）
    "player_room_visits",
    # 007（私聊）
    "chat_conversations",
    "chat_messages",
    "chat_read_state",
    # 008（公告）
    "announcements",
)


def affected_rows(status: str) -> int:
    """asyncpg 的 execute() 返回的是命令标签（形如 "DELETE 12"），取出行数。

    取不出来就当 0：这个数只用于日志与测试，不该因为标签格式变了让调用方崩掉。
    """
    try:
        return int(str(status).rsplit(" ", 1)[-1])
    except ValueError:
        return 0


async def inspect_schema() -> list[dict]:
    """查 EXPECTED_TABLES 的存在性、RLS 状态与 policy 数量。

    查的是 pg_class 而不是 information_schema，因为 RLS 开关（relrowsecurity）
    和 policy 数量只有系统目录里有 —— 而那两项正是 RFC 第三节的硬规则：
    **每张表都开 RLS，且默认零 policy。**
    """
    query = """
        select
            c.relname                                                    as table_name,
            c.relrowsecurity                                             as rls_enabled,
            (select count(*) from pg_policy p where p.polrelid = c.oid)  as policy_count
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relkind = 'r'
          and c.relname = any($1::text[])
        order by c.relname
    """
    async with pool().acquire() as conn:
        rows = await conn.fetch(query, list(EXPECTED_TABLES))

    found = {r["table_name"]: r for r in rows}
    result = []
    for name in EXPECTED_TABLES:
        row = found.get(name)
        result.append(
            {
                "table": name,
                "exists": row is not None,
                "rls_enabled": bool(row["rls_enabled"]) if row else False,
                "policy_count": int(row["policy_count"]) if row else 0,
            }
        )
    return result
