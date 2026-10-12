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

from app import db, friends, voice_clips
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


def _payload(raw) -> dict | None:
    """payload 列是 jsonb：asyncpg 不带 codec 时给字符串、带了给 dict，两种都认
    （同 world_chat._decode_payload / chat._decode_payload）。"""
    if raw is None or isinstance(raw, dict):
        return raw
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return None


def _voice(payload: object) -> dict | None:
    """从消息的 payload 里抽出语音的那几个字段（不是语音就 None）。

    处理举报的人要的是**能点开听**：光有一句「[语音 12″]」的占位文字没法判断。
    media 就是文件名，拼到 /media/<media> 就能播。
    """
    if not isinstance(payload, dict):
        return None
    media = str(payload.get("media") or "")
    if not media:
        return None
    return {"clip_id": str(payload.get("clip_id") or ""), "media": media,
            "seconds": payload.get("seconds")}


async def _voice_clip_evidence(conn: asyncpg.Connection, target_id: uuid.UUID,
                               clip_id: uuid.UUID) -> dict | None:
    """按编号取一段语音当证据，并推迟它的清理。

    🔴 **只认被举报的那个人传的**（同世界频道那条消息的规矩）：把别人的语音挂在他的
    举报下面，只会让处理的人听错人。

    这条路是**房间 / 对局内语音唯一的证据来源** —— 那条消息根本不落库
    （战斗服务器只转发），所以不像世界频道 / 私聊那样能从消息表里翻出来。
    这也正是 voice_clips 这张表存在的理由，见 database/033 顶部那段。
    """
    row = await conn.fetchrow(
        "select clip_id, media_name, uploader_id, seconds, scope, created_at"
        " from voice_clips where clip_id = $1", clip_id)
    if row is None or row["uploader_id"] != target_id:
        return None
    # 默认保留期是 7~30 天，处理举报可能拖得更久：押后到 REPORT_HOLD_DAYS。
    # 不押的话，后台点开证据会是「这段语音已经没有了」。
    await voice_clips.hold_for_report(clip_id)
    return {"clip_id": str(row["clip_id"]), "media": row["media_name"],
            "seconds": float(row["seconds"]), "scope": str(row["scope"]),
            "created_at": _iso(row["created_at"])}


async def _evidence(conn: asyncpg.Connection, reporter_id: uuid.UUID, target: asyncpg.Record,
                    context: str, message_id: int | None, clip_id: uuid.UUID | None) -> dict:
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
            "select message_id, body, sender_name, created_at, hidden_at, payload from world_messages"
            " where sender_id = $1 order by message_id desc limit $2", target_id, EVIDENCE_WORLD_RECENT)
        evidence["world_recent"] = [
            {"message_id": r["message_id"], "body": r["body"], "name": r["sender_name"],
             "created_at": _iso(r["created_at"]), "hidden": r["hidden_at"] is not None,
             "voice": _voice(_payload(r["payload"]))}
            for r in reversed(rows)]
        if message_id is not None:
            # 只认他自己的那条：别人的消息挂在他的举报下面，只会让处理的人看错人。
            row = await conn.fetchrow(
                "select message_id, body, sender_name, created_at, hidden_at, payload"
                " from world_messages where message_id = $1 and sender_id = $2",
                message_id, target_id)
            evidence["world_message"] = None if row is None else {
                "message_id": row["message_id"], "body": row["body"], "name": row["sender_name"],
                "created_at": _iso(row["created_at"]), "hidden": row["hidden_at"] is not None,
                "voice": _voice(_payload(row["payload"]))}
    elif context == "dm":
        low, high = friends._pair(reporter_id, target_id)
        rows = await conn.fetch(
            "select sender_id, body, created_at, payload from chat_messages"
            " where low_id = $1 and high_id = $2"
            " order by message_id desc limit $3", low, high, EVIDENCE_DM_RECENT)
        evidence["dm_recent"] = [
            {"from": "target" if r["sender_id"] == target_id else "reporter", "body": r["body"],
             "created_at": _iso(r["created_at"]), "voice": _voice(_payload(r["payload"]))}
            for r in reversed(rows)]
    if clip_id is not None:
        # 举报某一段语音（房间 / 对局内只有这条路；世界频道 / 私聊里点某条语音也走它）。
        evidence["voice_clip"] = await _voice_clip_evidence(conn, target_id, clip_id)
    return evidence


async def create(reporter: Player, target_code: str, context: str, reason: str,
                 message_id: int | None, detail: str | None,
                 clip_id: uuid.UUID | None = None) -> tuple[int, bool]:
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
            evidence = await _evidence(conn, reporter.player_id, target, context, message_id,
                                       clip_id)
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
