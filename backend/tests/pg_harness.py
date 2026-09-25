"""真 PostgreSQL 上的集成测试底座。

其余测试都**不连数据库**（假连接钉语句顺序）。那能证明「代码按什么顺序发了哪些语句」，
证明不了「这些 SQL 在真库上跑得通」「两个事务真撞在一起时结果对不对」——
而 database/ 里的函数（grant_diamonds、settle_season …）过去只能等管理员在
Supabase 里第一次跑时才知道有没有写错。这组测试补的就是这一块。

## 怎么跑

没设 `GLORY_TEST_PG` 时整组跳过，其余测试不受影响。设了就是一个**能建库删库**的连接串：

    GLORY_TEST_PG=postgresql://postgres@localhost:54329/postgres

每个测试拿一个全新的库：第一次用时按编号把 database/*.sql 全跑一遍做成模板库，
之后每个测试从模板复制（毫秒级）。SQL 文件一改，模板名跟着变，自动重建。

## 🔴 只许连本机

它会 create / drop database。连接串指向的主机不是本机就直接拒绝 ——
一个手滑贴成线上连接串的环境变量，不能变成一次删库。
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import pathlib
import uuid
from collections.abc import Awaitable, Callable
from urllib.parse import urlparse, urlunparse

import asyncpg
import pytest

from app import db

REPO = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = sorted((REPO / "database").glob("[0-9][0-9][0-9]_*.sql"))

ADMIN_DSN = os.environ.get("GLORY_TEST_PG", "").strip()
_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}

requires_pg = pytest.mark.skipif(
    not ADMIN_DSN, reason="没设 GLORY_TEST_PG（本机测试库的连接串），跳过真数据库测试")


def _check_local(dsn: str) -> None:
    host = urlparse(dsn).hostname or ""
    if host not in _LOCAL_HOSTS:
        raise RuntimeError("GLORY_TEST_PG 只许指向本机（现在是 %r）：这组测试会建库删库" % host)


def _with_database(dsn: str, name: str) -> str:
    return urlunparse(urlparse(dsn)._replace(path="/" + name))


def _template_name() -> str:
    digest = hashlib.sha256()
    for path in MIGRATIONS:
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return "glory_tpl_" + digest.hexdigest()[:12]


async def _ensure_template(admin: asyncpg.Connection) -> str:
    name = _template_name()
    if await admin.fetchval("select 1 from pg_database where datname = $1", name):
        return name
    await admin.execute('create database "%s"' % name)
    conn = await asyncpg.connect(_with_database(ADMIN_DSN, name))
    try:
        for path in MIGRATIONS:
            # 无参数的 execute 走简单查询协议，整份文件（多条语句、$$ 函数体）一次发。
            try:
                await conn.execute(path.read_text(encoding="utf-8"))
            except Exception as exc:
                raise RuntimeError("%s 在真库上跑失败：%s" % (path.name, exc)) from exc
    except BaseException:
        await conn.close()
        await admin.execute('drop database if exists "%s"' % name)
        raise
    await conn.close()
    return name


async def fresh_database() -> tuple[str, str]:
    """建一个跑完全部迁移的新库。返回 (库名, 连接串)。"""
    _check_local(ADMIN_DSN)
    admin = await asyncpg.connect(ADMIN_DSN)
    try:
        template = await _ensure_template(admin)
        name = "glory_t_" + uuid.uuid4().hex[:12]
        await admin.execute('create database "%s" template "%s"' % (name, template))
    finally:
        await admin.close()
    return name, _with_database(ADMIN_DSN, name)


async def drop_database(name: str) -> None:
    admin = await asyncpg.connect(ADMIN_DSN)
    try:
        await admin.execute('drop database if exists "%s" with (force)' % name)
    finally:
        await admin.close()


def run_with_db(body: Callable[[], Awaitable[None]]) -> None:
    """在一个新库上跑 body：app 的连接池（app.db）已经指向它，跑完删库。"""

    async def main() -> None:
        name, url = await fresh_database()
        await db.connect(url)
        try:
            await body()
        finally:
            await db.disconnect()
            await drop_database(name)

    asyncio.run(main())


async def new_player(conn: asyncpg.Connection, *, created_days_ago: int = 0) -> uuid.UUID:
    """建一个玩家（带登录身份），返回 player_id。"""
    player_id = uuid.uuid4()
    await conn.execute(
        "insert into players (player_id, created_at) values ($1, now() - make_interval(days => $2))",
        player_id, created_days_ago)
    await conn.execute(
        "insert into player_identities (provider, provider_user_id, player_id) values ('supabase', $1, $2)",
        "auth-" + player_id.hex, player_id)
    return player_id


def auth_uid_of(player_id: uuid.UUID) -> str:
    """new_player 建的身份映射里的 auth_uid。"""
    return "auth-" + player_id.hex
