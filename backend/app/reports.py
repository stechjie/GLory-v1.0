"""玩家举报（database/019_world_chat.sql 的 player_reports，docs/聊天系统设计.md）。

以前资料页的「举报该玩家」只在客户端弹一句「已记录」，后端什么都没收到（2026-09-27 补上）。
Google Play 的 UGC 规定：玩家能发内容，就必须能举报；世界频道上线之前这条必须是真的。

## 🔴 证据由服务器在举报那一刻复制

不收客户端上传的聊天记录 —— 那可以伪造。服务器手上有的，当场复制进 evidence：

  · 所有场合：他当时的昵称、头像、签名
  · 世界频道：被举报的那一条 + 他最近 EVIDENCE_WORLD_RECENT 条发言（含已被删的）
  · 私聊：举报人与他最近 EVIDENCE_DM_RECENT 条私聊
  · 房间 / 局内：服务器不存那两条频道的消息（设计文档第八节第 5 条），只有资料快照

世界频道 7 天就清，证据复制在这里不跟着清。

## 同一个人对同一个人、同一种场合，处理前只算一条

数据库唯一索引（019 的 player_reports_open_once）。重复举报回原来那条的编号，**对举报人显示得和第一次一样**
（「已收到」）—— 告诉他「你举报过了」没有意义，也不该让刷举报的人从响应里看出任何差别。
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import uuid

import asyncpg

from app import db, friends
from app.players import Player

log = logging.getLogger("glory.reports")

# 与 database/019 的 report_context / report_reason 约束一致；客户端 AccountManager.REPORT_* 一致
# （tools/chat_check.gd 钉着）。
CONTEXTS = ("world", "profile", "dm", "match")
REASONS = ("abuse", "ads", "cheat", "name", "other")

EVIDENCE_WORLD_RECENT = 20
EVIDENCE_DM_RECENT = 50


class ReportRejected(RuntimeError):
    def __init__(self, code: str, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


class ReportsUnavailable(RuntimeError):
    """019 没跑（表不存在）或者数据库没配。路由层映射成 503。"""


def _iso(value: dt.datetime | None) -> str | None:
    return None if value is None else value.astimezone(dt.UTC).isoformat()


async def _evidence(conn: asyncpg.Connection, reporter_id: uuid.UUID, target: asyncpg.Record,
                    context: str, message_id: int | None) -> dict:
    target_id = target["player_id"]
    signature = await conn.fetchval("select signature from player_bio where player_id = $1", target_id)
    evidence: dict = {
        "captured_at": _iso(dt.datetime.now(dt.UTC)),
        "profile": {
            "friend_code": target["friend_code"], "player_name": target["player_name"],
            "avatar": target["avatar"], "avatar_frame": target["avatar_frame"], "signature": signature,
        },
    }
    if context == "world":
        rows = await conn.fetch(
            "select message_id, body, sender_name, created_at, hidden_at from world_messages"
            " where sender_id = $1 order by message_id desc limit $2", target_id, EVIDENCE_WORLD_RECENT)
        evidence["world_recent"] = [
            {"message_id": r["message_id"], "body": r["body"], "name": r["sender_name"],
             "created_at": _iso(r["created_at"]), "hidden": r["hidden_at"] is not None}
            for r in reversed(rows)]
        if message_id is not None:
            # 只认他自己的那条：别人的消息挂在他的举报下面，只会让处理的人看错人。
            row = await conn.fetchrow(
                "select message_id, body, sender_name, created_at, hidden_at from world_messages"
                " where message_id = $1 and sender_id = $2", message_id, target_id)
            evidence["world_message"] = None if row is None else {
                "message_id": row["message_id"], "body": row["body"], "name": row["sender_name"],
                "created_at": _iso(row["created_at"]), "hidden": row["hidden_at"] is not None}
    elif context == "dm":
        low, high = friends._pair(reporter_id, target_id)
        rows = await conn.fetch(
            "select sender_id, body, created_at from chat_messages where low_id = $1 and high_id = $2"
            " order by message_id desc limit $3", low, high, EVIDENCE_DM_RECENT)
        evidence["dm_recent"] = [
            {"from": "target" if r["sender_id"] == target_id else "reporter", "body": r["body"],
             "created_at": _iso(r["created_at"])}
            for r in reversed(rows)]
    return evidence


async def create(reporter: Player, target_code: str, context: str, reason: str,
                 message_id: int | None, detail: str | None) -> tuple[int, bool]:
    """建一条举报。返回 (编号, 是否是重复举报)。"""
    if context not in CONTEXTS:
        raise ReportRejected("bad_context", "不认识的举报场合")
    if reason not in REASONS:
        raise ReportRejected("bad_reason", "请选择举报原因")
    if not db.is_connected():
        raise ReportsUnavailable("数据库未配置")
    try:
        async with db.pool().acquire() as conn:
            target = await conn.fetchrow(
                "select player_id, friend_code, player_name, avatar, avatar_frame from players"
                " where friend_code = $1 and deleted_at is null", target_code)
            if target is None:
                raise ReportRejected("player_not_found", "没有这个玩家", 404)
            if target["player_id"] == reporter.player_id:
                raise ReportRejected("cannot_report_self", "不能举报自己")
            evidence = await _evidence(conn, reporter.player_id, target, context, message_id)
            report_id = await conn.fetchval(
                "insert into player_reports (reporter_id, target_id, context, reason, detail, message_id, evidence)"
                " values ($1, $2, $3, $4, $5, $6, $7::jsonb)"
                " on conflict (reporter_id, target_id, context) where status = 'open' do nothing"
                " returning report_id",
                reporter.player_id, target["player_id"], context, reason, detail, message_id,
                json.dumps(evidence, ensure_ascii=False))
            if report_id is not None:
                log.info("收到举报 #%d 场合=%s 原因=%s", report_id, context, reason)
                return int(report_id), False
            existing = await conn.fetchval(
                "select report_id from player_reports where reporter_id = $1 and target_id = $2"
                " and context = $3 and status = 'open'", reporter.player_id, target["player_id"], context)
            return int(existing), True
    except asyncpg.UndefinedTableError:
        log.error("player_reports / world_messages 表不存在：先在 Supabase 跑 database/019_world_chat.sql")
        raise ReportsUnavailable("019 没跑") from None
