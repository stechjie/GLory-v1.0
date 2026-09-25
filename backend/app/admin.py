"""网页后台的业务（docs/运营后台设计.md，database/018_admin.sql）。

## 只套一层，不另写规则

发钻石 → 009 grant_diamonds；发黄金 → 018 grant_coin；发邮件 / 撤回 → 012 send_mail / send_mail_all /
withdraw_mail；封号 / 解封 → 016 ban_player / unban_player；公告 → 008 那张表。
**钱包、邮件、封号的规则都在那些函数里**，这里只加：谁能做、要不要第二个人批、记一笔操作记录。

## 发钱要第二个人批（2026-09-24 拍板）

发钻石 / 黄金、带附件的邮件：先落成一条 admin_requests（pending），另一个管理员点「批准」时
**在同一个事务里**改状态 + 执行 + 记操作记录。封号、公告、没附件的邮件不用批（随时能撤）。

## 找人只认好友码和完整编号

昵称不唯一（一大半人叫 Player），按昵称只给候选列表，**动手之前页面必须先点开那个人**
（接口都按 player_id 收，不收昵称）。
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import hashlib
import json
import logging
import re
import uuid
from typing import Any

import asyncpg
import httpx

from app import announcements, bans, db, mail, ranked, realtime, shop
from app.admin_auth import Admin
from app.config import get_settings

log = logging.getLogger("glory.admin")


class AdminRejected(RuntimeError):
    """业务上不行。message 直接显示在后台页面上。status 给路由层用。"""

    def __init__(self, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.message = message
        self.status = status


FRIEND_CODE_RE = re.compile(r"[2-9A-HJKMNP-Z]{8}")

# 单笔上限：防手滑（500 多打两个 0）。与 012 邮件附件的上限一致。
GRANT_LIMITS = {"grant_diamonds": 100_000, "grant_coin": 1_000_000}
GRANT_NAMES = {"grant_diamonds": "钻石", "grant_coin": "黄金"}


def _jsonable(value: Any) -> Any:
    if isinstance(value, dt.datetime):
        return value.astimezone(dt.UTC).isoformat()
    if isinstance(value, uuid.UUID):
        return str(value)
    return value


def _row(record: asyncpg.Record) -> dict:
    out = {k: _jsonable(v) for k, v in dict(record).items()}
    for key in ("payload", "detail", "result"):
        if isinstance(out.get(key), str):
            out[key] = json.loads(out[key])
    return out


async def _audit(conn: asyncpg.Connection, admin: Admin, action: str, player_id: uuid.UUID | None,
                 detail: dict, ok: bool = True) -> None:
    await conn.execute(
        "insert into admin_audit (admin_name, action, player_id, detail, ok) values ($1, $2, $3, $4::jsonb, $5)",
        admin.name, action, player_id, json.dumps(detail, ensure_ascii=False, default=str), ok)


async def _live_friend_code(conn: asyncpg.Connection, player_id: uuid.UUID) -> str:
    code = await conn.fetchval(
        "select friend_code from players where player_id = $1 and deleted_at is null", player_id)
    if code is None:
        raise AdminRejected("没有这个玩家，或者他已经注销了", 404)
    return str(code)


def _require_text(value: str, what: str, limit: int) -> str:
    text = (value or "").strip()
    if not text:
        raise AdminRejected("%s不能空" % what)
    if len(text) > limit:
        raise AdminRejected("%s最多 %d 个字，现在是 %d 个" % (what, limit, len(text)))
    return text


# --- 找人 -----------------------------------------------------------------------


_PLAYER_COLUMNS = ("select player_id, friend_code, player_name, created_at, last_seen_at, deleted_at"
                   " from players")


async def search_players(query: str) -> list[dict]:
    q = (query or "").strip()
    if not q:
        return []
    async with db.pool().acquire() as conn:
        if FRIEND_CODE_RE.fullmatch(q.upper()):
            rows = await conn.fetch(_PLAYER_COLUMNS + " where friend_code = $1", q.upper())
        else:
            try:
                pid = uuid.UUID(q)
            except ValueError:
                pid = None
            if pid is not None:
                rows = await conn.fetch(_PLAYER_COLUMNS + " where player_id = $1", pid)
            else:
                # 昵称只给候选。% 和 _ 转义掉，免得「100%」匹配出一大片。
                pattern = "%" + re.sub(r"([\\%_])", r"\\\1", q[:24]) + "%"
                rows = await conn.fetch(
                    _PLAYER_COLUMNS + " where player_name ilike $1 escape '\\'"
                    " order by last_seen_at desc limit 20", pattern)
    return [_row(r) for r in rows]


async def player_detail(player_id: uuid.UUID) -> dict:
    async with db.pool().acquire() as conn:
        base = await conn.fetchrow(_PLAYER_COLUMNS + " where player_id = $1", player_id)
        if base is None:
            raise AdminRejected("没有这个玩家", 404)
        wallet = await shop.read_wallet_in(conn, player_id)
        live = await bans.live_ban(conn, player_id)
        ban_rows = await conn.fetch(
            "select ban_id, created_at, ends_at, reason, note, actor, revoked_at, revoked_by, revoke_note"
            " from player_bans where player_id = $1 order by ban_id desc", player_id)
        ledger = await conn.fetch(
            "select id, created_at, currency, delta, balance_after, source, actor, note, order_id, mail_id"
            " from wallet_ledger where player_id = $1 order by id desc limit 50", player_id)
        orders = await conn.fetch(
            "select order_id, created_at, item_id, currency, price_snapshot, status, source"
            " from shop_orders where player_id = $1 order by created_at desc limit 50", player_id)
        owned = await conn.fetch(
            "select item_id, source, granted_at, revoked_at from player_entitlements"
            " where player_id = $1 order by granted_at", player_id)
        mails = await conn.fetch(
            "select m.mail_id, m.created_at, m.expires_at, m.title_zh, m.diamond, m.coin, m.items, m.actor,"
            "       m.withdrawn_at, m.problem, s.read_at, s.claimed_at, s.deleted_at"
            " from mails m left join mail_states s on s.mail_id = m.mail_id and s.player_id = $1"
            " where m.player_id = $1 order by m.mail_id desc limit 50", player_id)
        ranked_row = await conn.fetchrow(
            "select season, score, games, wins from player_ranked where player_id = $1", player_id)
        credit = await conn.fetchrow(
            "select score, banned_until from player_credit where player_id = $1", player_id)
        matches = await conn.fetch(
            "select r.match_uid, r.mode, r.ended_at, r.outcome, r.rounds, s.team, s.was_ai, s.online_at_end"
            " from match_seats s join match_records r on r.match_uid = s.match_uid"
            " where s.player_id = $1 order by r.ended_at desc limit 20", player_id)
        audit = await conn.fetch(
            "select audit_id, at, admin_name, action, detail, ok from admin_audit"
            " where player_id = $1 order by audit_id desc limit 50", player_id)
    ranked_out = None
    if ranked_row is not None:
        ranked_out = {**_row(ranked_row), "tier": ranked.tier_of(int(ranked_row["score"]))}
    return {
        "player": _row(base),
        # 「在线」是这一刻连着账号服务器的实时连接，不是 last_seen_at。
        "online": realtime.hub().is_online(player_id),
        "ban": None if live is None else {**live.to_client(), "ban_id": live.ban_id},
        "bans": [_row(r) for r in ban_rows],
        "wallet": {"diamond_paid": wallet.diamond_paid, "diamond_free": wallet.diamond_free, "coin": wallet.coin},
        "ledger": [_row(r) for r in ledger],
        "orders": [_row(r) for r in orders],
        "entitlements": [_row(r) for r in owned],
        "mails": [_row(r) for r in mails],
        "ranked": ranked_out,
        "credit": None if credit is None else _row(credit),
        "matches": [_row(r) for r in matches],
        "audit": [_row(r) for r in audit],
    }


# --- 封号（不用批）-----------------------------------------------------------------


async def ban(admin: Admin, player_id: uuid.UUID, days: int | None, reason: str, note: str) -> dict:
    reason = _require_text(reason, "给玩家看的原因", 200)
    note = (note or "").strip()[:500] or None
    if days is not None and not 1 <= days <= 3650:
        raise AdminRejected("封号天数要在 1 到 3650 之间；永久封号不填天数")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            code = await _live_friend_code(conn, player_id)
            ban_id = await conn.fetchval(
                "select ban_player($1, $2::interval, $3, $4, $5)",
                code, None if days is None else dt.timedelta(days=days), reason, admin.name, note)
            await _audit(conn, admin, "ban", player_id,
                         {"ban_id": ban_id, "days": days, "reason": reason, "note": note})
    # 在线的当场踢，不等巡检那 10 秒。
    kicked = await bans.kick_now(player_id)
    return {"ban_id": ban_id, "kicked": kicked}


async def unban(admin: Admin, player_id: uuid.UUID, note: str) -> dict:
    note = (note or "").strip()[:500] or None
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            code = await _live_friend_code(conn, player_id)
            try:
                count = await conn.fetchval("select unban_player($1, $2, $3)", code, admin.name, note)
            except asyncpg.RaiseError:
                raise AdminRejected("这个玩家现在没有被封") from None
            await _audit(conn, admin, "unban", player_id, {"revoked": count, "note": note})
    return {"revoked": count}


# --- 发钱的审批 ---------------------------------------------------------------------


async def _insert_request(conn: asyncpg.Connection, admin: Admin, kind: str, player_id: uuid.UUID | None,
                          payload: dict, summary: str, reason: str, request_key: uuid.UUID) -> dict:
    row = await conn.fetchrow(
        "insert into admin_requests (kind, player_id, payload, summary, reason, request_key, requested_by)"
        " values ($1, $2, $3::jsonb, $4, $5, $6, $7)"
        " on conflict (requested_by, request_key) do nothing returning *",
        kind, player_id, json.dumps(payload, ensure_ascii=False), summary, reason, request_key, admin.name)
    if row is None:
        # 同一次提交（连点、网络重试）：回同一条，不再建一条。
        row = await conn.fetchrow(
            "select * from admin_requests where requested_by = $1 and request_key = $2", admin.name, request_key)
        return {**_row(row), "replayed": True}
    await _audit(conn, admin, "request.create", player_id,
                 {"request_id": row["request_id"], "kind": kind, "summary": summary, "reason": reason})
    return {**_row(row), "replayed": False}


async def request_grant(admin: Admin, kind: str, player_id: uuid.UUID, amount: int,
                        reason: str, request_key: uuid.UUID) -> dict:
    if kind not in GRANT_LIMITS:
        raise AdminRejected("不认识的发放类型：%s" % kind)
    if not 1 <= amount <= GRANT_LIMITS[kind]:
        raise AdminRejected("%s数量要在 1 到 %d 之间（再多就分几次，每次都有人再看一眼）"
                            % (GRANT_NAMES[kind], GRANT_LIMITS[kind]))
    reason = _require_text(reason, "原因", 200)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            code = await _live_friend_code(conn, player_id)
            summary = "给 %s 发 %d %s" % (code, amount, GRANT_NAMES[kind])
            return await _insert_request(conn, admin, kind, player_id, {"amount": amount},
                                         summary, reason, request_key)


async def list_requests(pending_only: bool) -> list[dict]:
    async with db.pool().acquire() as conn:
        if pending_only:
            rows = await conn.fetch("select * from admin_requests where status = 'pending' order by request_id")
        else:
            rows = await conn.fetch("select * from admin_requests order by request_id desc limit 100")
    return [_row(r) for r in rows]


async def _execute(conn: asyncpg.Connection, row: asyncpg.Record, actor: str) -> dict:
    payload = json.loads(row["payload"]) if isinstance(row["payload"], str) else dict(row["payload"])
    note = ("后台#%d %s" % (row["request_id"], row["reason"]))[:200]
    kind = row["kind"]
    if kind in ("grant_diamonds", "grant_coin"):
        balance = await conn.fetchval("select %s($1, $2, $3, $4)" % kind,
                                      row["player_id"], int(payload["amount"]), note, actor)
        return {"balance_after": int(balance)}
    if kind == "mail":
        return {"mail_id": await _send_mail_now(conn, row["player_id"], payload, actor, note)}
    raise AdminRejected("不认识的申请类型：%s" % kind)


async def decide(admin: Admin, request_id: int, approve: bool, note: str) -> dict:
    """批准（当场执行）或拒绝。**自己不能批自己**，数据库约束也挡着。"""
    note = (note or "").strip()[:200] or None
    status = "done" if approve else "rejected"
    async with db.pool().acquire() as conn:
        try:
            async with conn.transaction():
                row = await conn.fetchrow(
                    "update admin_requests set status = $3, decided_by = $2, decided_at = now(), decision_note = $4"
                    " where request_id = $1 and status = 'pending' and requested_by <> $2 returning *",
                    request_id, admin.name, status, note)
                if row is None:
                    await _explain_undecidable(conn, admin, request_id)
                result: dict = {}
                if approve:
                    try:
                        result = await _execute(conn, row, "%s/%s" % (row["requested_by"], admin.name))
                    except (asyncpg.RaiseError, asyncpg.CheckViolationError) as exc:
                        raise _ExecutionFailed(str(exc).split("\n")[0]) from None
                    except AdminRejected as exc:
                        raise _ExecutionFailed(exc.message) from None
                    await conn.execute("update admin_requests set result = $2::jsonb where request_id = $1",
                                       request_id, json.dumps(result))
                await _audit(conn, admin, "request.approve" if approve else "request.reject", row["player_id"],
                             {"request_id": request_id, "summary": row["summary"], "result": result, "note": note})
        except _ExecutionFailed as exc:
            # 执行失败（例如玩家刚注销、附件不合格）：上面的事务已回滚，单独记成 failed，别让它一直挂着。
            message = str(exc)
            await conn.execute(
                "update admin_requests set status = 'failed', decided_by = $2, decided_at = now(),"
                " result = $3::jsonb where request_id = $1 and status = 'pending' and requested_by <> $2",
                request_id, admin.name, json.dumps({"error": message}, ensure_ascii=False))
            await _audit(conn, admin, "request.approve", None,
                         {"request_id": request_id, "error": message}, ok=False)
            raise AdminRejected("执行失败：%s" % message) from None
    log.info("审批 #%d %s by %s", request_id, status, admin.name)
    return {"request_id": request_id, "status": status, "result": result}


class _ExecutionFailed(RuntimeError):
    """批准了、执行时失败。和「这条批不了」（_explain_undecidable）分开：只有这种要记成 failed。"""


async def _explain_undecidable(conn: asyncpg.Connection, admin: Admin, request_id: int) -> None:
    current = await conn.fetchrow(
        "select status, requested_by, decided_by from admin_requests where request_id = $1", request_id)
    if current is None:
        raise AdminRejected("没有这条申请", 404)
    if current["status"] != "pending":
        raise AdminRejected("这条申请已经被 %s 处理过了（%s）" % (current["decided_by"] or "?", current["status"]), 409)
    if current["requested_by"] == admin.name:
        raise AdminRejected("自己不能批自己的申请，要另一个管理员来批", 403)
    raise AdminRejected("这条申请现在处理不了", 409)


async def cancel(admin: Admin, request_id: int) -> dict:
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                "update admin_requests set status = 'cancelled', decided_by = $2, decided_at = now()"
                " where request_id = $1 and status = 'pending' and requested_by = $2 returning *",
                request_id, admin.name)
            if row is None:
                raise AdminRejected("只能撤回自己提交、还没被处理的申请", 409)
            await _audit(conn, admin, "request.cancel", row["player_id"],
                         {"request_id": request_id, "summary": row["summary"]})
    return {"request_id": request_id, "status": "cancelled"}


# --- 邮件 ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class MailDraft:
    to: str                  # "all" 或 player_id
    title_zh: str
    body_zh: str
    title_en: str
    body_en: str
    diamond: int
    coin: int
    items: tuple[str, ...]
    days: int
    include_new_players: bool
    note: str

    @property
    def has_attachments(self) -> bool:
        return self.diamond > 0 or self.coin > 0 or bool(self.items)


def _check_mail(draft: MailDraft) -> None:
    # 与 012 的约束同一套数（那边是最后一道；这里先挡，报错说人话）。
    _require_text(draft.title_zh, "中文标题", 60)
    if len(draft.body_zh) > 2000 or len(draft.body_en) > 2000:
        raise AdminRejected("正文最多 2000 字")
    if len(draft.title_en) > 60:
        raise AdminRejected("英文标题最多 60 字")
    if not 0 <= draft.diamond <= 100_000 or not 0 <= draft.coin <= 1_000_000:
        raise AdminRejected("单封最多 100000 钻石、1000000 黄金（再多就分几封）")
    if not 1 <= draft.days <= 365:
        raise AdminRejected("有效天数要在 1 到 365 之间")
    problem = mail.item_problem(list(draft.items))
    if problem:
        raise AdminRejected(problem)
    if draft.to != "all" and draft.include_new_players:
        raise AdminRejected("「之后注册的新玩家也能收到」只对全服邮件有意义")
    # 带奖励的全服邮件给「以后注册的人」= 总量没有上限（设计文档第五节）。先不开放。
    if draft.to == "all" and draft.include_new_players and draft.has_attachments:
        raise AdminRejected("带奖励的全服邮件暂时不能发给以后注册的新玩家（总量没有上限）")


async def _send_mail_now(conn: asyncpg.Connection, player_id: uuid.UUID | None, payload: dict,
                         actor: str, note: str | None) -> int:
    args = (payload["title_zh"], payload["body_zh"], actor, int(payload["diamond"]), int(payload["coin"]),
            list(payload["items"]), int(payload["days"]), note, payload["title_en"] or None,
            payload["body_en"] or None)
    if player_id is None:
        return int(await conn.fetchval(
            "select send_mail_all(p_title_zh => $1, p_body_zh => $2, p_actor => $3, p_diamond => $4,"
            " p_coin => $5, p_items => $6, p_days => $7, p_note => $8, p_title_en => $9, p_body_en => $10,"
            " p_include_new_players => $11)", *args, bool(payload["include_new_players"])))
    code = await _live_friend_code(conn, player_id)
    return int(await conn.fetchval(
        "select send_mail(p_friend_code => $11, p_title_zh => $1, p_body_zh => $2, p_actor => $3,"
        " p_diamond => $4, p_coin => $5, p_items => $6, p_days => $7, p_note => $8, p_title_en => $9,"
        " p_body_en => $10)", *args, code))


async def submit_mail(admin: Admin, draft: MailDraft, request_key: uuid.UUID) -> dict:
    """没附件：当场发。有附件：落一条申请，等另一个人批。"""
    _check_mail(draft)
    player_id = None if draft.to == "all" else uuid.UUID(draft.to)
    payload = {
        "title_zh": draft.title_zh.strip(), "body_zh": draft.body_zh, "title_en": draft.title_en.strip(),
        "body_en": draft.body_en, "diamond": draft.diamond, "coin": draft.coin, "items": list(draft.items),
        "days": draft.days, "include_new_players": draft.include_new_players,
    }
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            target = "全服" if player_id is None else await _live_friend_code(conn, player_id)
            if draft.has_attachments:
                parts = [("%d 钻石" % draft.diamond) if draft.diamond else "",
                         ("%d 黄金" % draft.coin) if draft.coin else "",
                         "、".join(draft.items)]
                summary = "给%s发邮件《%s》，附件：%s" % (
                    target if player_id is None else " " + target, payload["title_zh"],
                    "，".join(p for p in parts if p))
                reason = _require_text(draft.note, "原因（内部备注）", 200)
                return {"queued": True, **await _insert_request(
                    conn, admin, "mail", player_id, payload, summary[:300], reason, request_key)}
            mail_id = await _send_mail_now(conn, player_id, payload, admin.name, draft.note.strip()[:200] or None)
            await _audit(conn, admin, "mail.send", player_id,
                         {"mail_id": mail_id, "to": target, "title_zh": payload["title_zh"]})
    return {"queued": False, "mail_id": mail_id}


async def recent_mails() -> list[dict]:
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select m.mail_id, m.player_id, p.friend_code, m.include_new_players, m.title_zh, m.diamond, m.coin,"
            "       m.items, m.actor, m.note, m.created_at, m.expires_at, m.withdrawn_at, m.problem,"
            "       (select count(*) from mail_states s where s.mail_id = m.mail_id and s.claimed_at is not null)"
            "         as claimed"
            " from mails m left join players p on p.player_id = m.player_id"
            " order by m.mail_id desc limit 100")
    return [_row(r) for r in rows]


async def withdraw_mail(admin: Admin, mail_id: int) -> dict:
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            try:
                await conn.execute("select withdraw_mail($1)", mail_id)
            except asyncpg.RaiseError:
                raise AdminRejected("没有这封邮件，或者它已经撤回过了", 409) from None
            claimed = await conn.fetchval(
                "select count(*) from mail_states where mail_id = $1 and claimed_at is not null", mail_id)
            await _audit(conn, admin, "mail.withdraw", None, {"mail_id": mail_id, "already_claimed": claimed})
    return {"mail_id": mail_id, "already_claimed": int(claimed)}


def attachable_items() -> list[dict]:
    """邮件能发的东西：只有商品目录里卖的（不在目录里的本来就人人免费，见 mail.item_problem）。"""
    return [{"content_id": i.grants, "name": i.name, "name_en": i.name_en} for i in shop.items()]


# --- 公告（不用批）------------------------------------------------------------------

ANNOUNCEMENT_FIELDS = ("kind", "status", "title_zh", "body_zh", "title_en", "body_en", "image", "popup",
                       "sort_order", "starts_at", "ends_at", "preview_codes")


def _parse_time(value: Any, what: str, required: bool) -> dt.datetime | None:
    if value in (None, ""):
        if required:
            raise AdminRejected("%s不能空" % what)
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value))
    except ValueError:
        raise AdminRejected("%s格式不对：%s" % (what, value)) from None
    if parsed.tzinfo is None:
        # 不带时区按哪个钟都是猜 —— 008 文件头那条。页面会带上 +08:00。
        raise AdminRejected("%s没带时区" % what)
    return parsed


def _announcement_values(fields: dict) -> list:
    kind = str(fields.get("kind", "news"))
    status = str(fields.get("status", "draft"))
    if kind not in announcements.KINDS:
        raise AdminRejected("页签只能是 %s" % "、".join(announcements.KINDS))
    if status not in ("draft", "published", "withdrawn"):
        raise AdminRejected("状态只能是 draft / published / withdrawn")
    image = str(fields.get("image", "")).strip()
    if image and not announcements.is_valid_image_path(image):
        raise AdminRejected("图片文件名只能用英文字母、数字、. _ - 和 /")
    starts = _parse_time(fields.get("starts_at"), "开始时间", True)
    ends = _parse_time(fields.get("ends_at"), "结束时间", False)
    if ends is not None and starts is not None and ends <= starts:
        raise AdminRejected("结束时间要晚于开始时间")
    return [kind, status, _require_text(str(fields.get("title_zh", "")), "中文标题", 60),
            str(fields.get("body_zh", "")), str(fields.get("title_en", "")).strip(),
            str(fields.get("body_en", "")), image, bool(fields.get("popup", False)),
            int(fields.get("sort_order", 0) or 0), starts, ends, str(fields.get("preview_codes", "")).strip()]


async def list_announcements() -> list[dict]:
    async with db.pool().acquire() as conn:
        # xmin 当版本号：两个人同时改同一条，后保存的那个会被告知「别人刚改过」，而不是悄悄覆盖。
        rows = await conn.fetch(
            "select *, xmin::text as version from announcements order by announcement_id desc limit 100")
    return [_row(r) for r in rows]


async def save_announcement(admin: Admin, announcement_id: int | None, fields: dict,
                            version: str | None, bump_revision: bool) -> dict:
    values = _announcement_values(fields)
    columns = ", ".join(ANNOUNCEMENT_FIELDS)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            try:
                if announcement_id is None:
                    placeholders = ", ".join("$%d" % (i + 1) for i in range(len(values)))
                    row = await conn.fetchrow(
                        "insert into announcements (%s) values (%s) returning announcement_id, revision"
                        % (columns, placeholders), *values)
                else:
                    sets = ", ".join("%s = $%d" % (name, i + 3) for i, name in enumerate(ANNOUNCEMENT_FIELDS))
                    row = await conn.fetchrow(
                        "update announcements set %s, revision = revision + $%d"
                        " where announcement_id = $1 and xmin::text = $2 returning announcement_id, revision"
                        % (sets, len(values) + 3),
                        announcement_id, version or "", *values, 1 if bump_revision else 0)
                    if row is None:
                        raise AdminRejected("这条公告刚被别人改过（或者不存在），刷新之后再改", 409)
            except asyncpg.CheckViolationError as exc:
                raise AdminRejected("数据库拒绝了：%s" % exc.constraint_name) from None
            await _audit(conn, admin, "announcement.save", None, {
                "announcement_id": row["announcement_id"], "status": values[1], "title_zh": values[2],
                "revision": row["revision"], "created": announcement_id is None})
    return {"announcement_id": row["announcement_id"], "revision": row["revision"]}


def _image_ext(data: bytes) -> str:
    if data.startswith(b"\x89PNG"):
        return "png"
    if data.startswith(b"\xff\xd8"):
        return "jpg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    raise AdminRejected("只接受 PNG、JPG、WebP")


_CONTENT_TYPES = {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp"}


async def upload_announcement_image(admin: Admin, data: bytes,
                                    transport: httpx.AsyncBaseTransport | None = None) -> dict:
    """原图先在这里按玩家那边同一套规则检查一遍（通不过当场报错），再原样存进 Storage 公开桶。

    存的是原图不是转好的 WebP：账号服务器取图时会自己转（announcements.Board），
    这样换机器、清图片目录都不丢图。文件名是内容哈希 —— 同一张图传两次是同一个路径，
    换图一定是新路径（008 那条「换图就传新文件名」自动满足）。
    """
    ext = _image_ext(data)
    try:
        await asyncio.to_thread(announcements.prepare_image, data)
    except announcements.ImageRejected as exc:
        raise AdminRejected(str(exc)) from None
    s = get_settings()
    if not (s.supabase_url and s.supabase_secret_key):
        raise AdminRejected("服务器没配 GLORY_SUPABASE_SECRET_KEY，不能从这里传图。"
                            "请在 Supabase 后台传到 %s 桶，再把文件名填进来" % s.announcement_bucket, 503)
    path = "admin/%s/%s.%s" % (dt.datetime.now(dt.UTC).strftime("%Y-%m"),
                               hashlib.sha256(data).hexdigest()[:24], ext)
    url = "%s/storage/v1/object/%s/%s" % (s.supabase_url.rstrip("/"), s.announcement_bucket, path)
    key = s.supabase_secret_key.strip()
    headers = {"apikey": key, "Content-Type": _CONTENT_TYPES[ext], "x-upsert": "false"}
    if not key.startswith("sb_"):
        # 旧式的 service_role 密钥本身就是 JWT，要同时放进 Authorization。
        # 新式的 sb_secret_… 不是 JWT，只放 apikey（放进 Authorization 会被当成坏令牌）。
        headers["Authorization"] = "Bearer %s" % key
    try:
        async with httpx.AsyncClient(timeout=30.0, transport=transport) as client:
            resp = await client.post(url, headers=headers, content=data)
    except httpx.HTTPError as exc:
        raise AdminRejected("连不上 Storage（%s），稍后再试" % type(exc).__name__, 502) from None
    duplicate = resp.status_code in (400, 409) and "exist" in resp.text.lower()
    if resp.status_code >= 400 and not duplicate:
        # 不回显响应体全文：里面可能有桶的内部信息。
        raise AdminRejected("传到 Storage 失败（HTTP %d）" % resp.status_code, 502)
    async with db.pool().acquire() as conn:
        await _audit(conn, admin, "announcement.image", None, {"path": path, "bytes": len(data)})
    return {"path": path}


# --- 操作记录 -------------------------------------------------------------------------


async def recent_audit() -> list[dict]:
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            "select a.audit_id, a.at, a.admin_name, a.action, a.player_id, p.friend_code, a.detail, a.ok"
            " from admin_audit a left join players p on p.player_id = a.player_id"
            " order by a.audit_id desc limit 200")
    return [_row(r) for r in rows]
