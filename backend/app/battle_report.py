"""战报 —— 账号服务器一侧：验章、去重、入库（docs/排位系统设计.md 第七节）。

签发在战斗服务器（`scripts/multiplayer/BattleReport.gd`），这边只做四件事：

    1. 验章（RSA-2048 / PKCS#1 v1.5 / SHA-256，公钥在本机文件里）
    2. 校验形状（签过章不等于内容对 —— 战斗服务器也可能有 bug）
    3. 按 match_uid 去重
    4. 写 match_records + match_seats（database/013_match_history.sql）

## 它是出战名片反过来那一半

名片：**这边**用私钥签 → 客户端转交 → 战斗服务器用公钥验（`app/loadout.py`）
战报：战斗服务器用私钥签 → 客户端转交 → **这边**用公钥验

两边都是「签名 + 客户端转交」，所以两台服务器之间一条网络通道都不用开。

## 🔴 先验签、再解析，绝不重新序列化

签的是那串字节，验的也是那串字节。先解析再验签等于让没签过名的数据先进 JSON 解析器；
验完之后重新序列化再比对，则会因为两边 JSON 实现的细微差别而永远对不上。

## 一份战报结算全场六个座位

六个人里只要有一个交上来就够。`match_uid` 是主键 = 天然幂等，
第二个人交上来是 `on conflict do nothing`，**不报错**（客户端据此显示「已记录」）。

## 签过章 ≠ 内容一定对

战报是我们自己的战斗服务器签的，不是敌意输入。但它可能有 bug ——
`rounds=0` 这种值直接写下去会撞数据库的 check 约束，变成 500 而不是一条能看懂的日志。
所以这边逐项校验，不合规的整份拒掉并**打 error 级日志**：
签过章的战报被拒，说明我们自己这边坏了，不是玩家的问题。
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import logging
import os
import pathlib
import re
import uuid

from app import db

log = logging.getLogger("glory.battle_report")

# 与 scripts/multiplayer/BattleReport.gd 的 VERSION 一致（test_battle_report 钉着）。
REPORT_VERSION = 1

# 线格式的长度上限，**在 base64 解码之前**就挡。
#
# 实测满配一局（六座位 × 16 棋子 + 8 佣兵 + 5 宝藏）是 13913 字节
# （tools/battle_report_check.gd 每次都量一遍并打印）。这里给到 64 KB：
# 够以后加字段，又不至于让一次解码 + RSA 验签的开销由对方决定。
MAX_WIRE_CHARS = 65536

# RSA-2048 的签名固定 256 字节。
SIGNATURE_BYTES = 256

SEAT_COUNT = 6
# slot < 3 是 A 队。与 GameConstants.team_of_slot 和 013 的 match_seat_team_matches_slot 一致。
TEAM_SIDE_SIZE = 3

MODES = frozenset({"custom", "casual", "ranked"})
OUTCOMES = frozenset({"team_a", "team_b", "draw"})

_MATCH_UID_RE = re.compile(r"^[0-9a-f]{32}$")

# 两台机器的钟差容忍。同名片的 CLOCK_LEEWAY_SEC。
CLOCK_LEEWAY_SEC = 300
# 多久以前的战报就不收了。防的不是伪造（签名管那个），是无限期回填 ——
# 一份躺了半年的战报突然冒出来，对历史列表只是噪音。
MAX_REPORT_AGE_SEC = 7 * 24 * 3600

# 数据库那几列都是 int（4 字节）。战斗服务器那边已经 clamp 过，这里是第二道 ——
# 溢出的话 asyncpg 会抛，变成 500。
_INT_MAX = 2**31 - 1


class ReportRejected(Exception):
    """战报不收。code 会原样回给客户端，所以不许带任何内部细节。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class ReportKeyMissing(RuntimeError):
    """没配公钥。调用方应转成 503，不是 500。"""


# --- 公钥 ---------------------------------------------------------------------

_key_cache: tuple[str, float, object] | None = None


def _key_path() -> str:
    from app.config import get_settings

    return get_settings().battle_report_public_key_file.strip()


def _public_key():
    """读公钥，按 (路径, mtime) 缓存。轮换时换文件即可，不用重启。"""
    global _key_cache
    path = _key_path()
    if not path:
        raise ReportKeyMissing("没有配置 GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE")
    try:
        mtime = os.stat(path).st_mtime
    except OSError as exc:
        raise ReportKeyMissing("读不到战报公钥 %s" % path) from exc
    if _key_cache is not None and _key_cache[0] == path and _key_cache[1] == mtime:
        return _key_cache[2]

    from cryptography.hazmat.primitives import serialization

    key = serialization.load_pem_public_key(pathlib.Path(path).read_bytes())
    _key_cache = (path, mtime, key)
    return key


# --- 验章 ---------------------------------------------------------------------


def verify(wire: str, now: float | None = None) -> dict:
    """验章并解析。返回战报字典；不收就抛 ReportRejected。

    `now` 由调用方传（测试要能造「太旧」的场景）。
    """
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding

    # 🔴 先取公钥，再看内容。
    #
    # 没配公钥时**任何**战报都收不了，那是服务器配置问题（503），不是这一份的问题（400）。
    # 反过来排的话，配置坏掉的服务器会对每一份战报回「格式不对」——
    # 客户端照着提示去查自己那边，而真正的原因在运维那头。
    # 代价可以忽略：公钥按 (路径, mtime) 缓存，命中时只有一次 os.stat。
    key = _public_key()

    if not wire:
        raise ReportRejected("report_required", "没有战报")
    if len(wire) > MAX_WIRE_CHARS:
        raise ReportRejected("report_malformed", "战报太长")
    parts = wire.split(".")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise ReportRejected("report_malformed", "战报格式不对")
    try:
        body = base64.b64decode(parts[0], validate=True)
        signature = base64.b64decode(parts[1], validate=True)
    except (ValueError, TypeError) as exc:
        raise ReportRejected("report_malformed", "战报不是合法的 base64") from exc
    if not body or len(signature) != SIGNATURE_BYTES:
        raise ReportRejected("report_malformed", "战报格式不对")

    try:
        key.verify(signature, body, padding.PKCS1v15(), hashes.SHA256())
    except InvalidSignature as exc:
        raise ReportRejected("report_bad_signature", "战报签名验不过") from exc

    # 签名对了才解析。顺序反过来等于让没签过名的数据先进 JSON 解析器。
    try:
        raw = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ReportRejected("report_malformed", "战报不是合法的 JSON") from exc
    if not isinstance(raw, dict):
        raise ReportRejected("report_malformed", "战报不是一个对象")
    return _validate(raw, dt.datetime.now(dt.UTC).timestamp() if now is None else now)


def _validate(raw: dict, now: float) -> dict:
    """逐项校验。签过章的战报走到这里被拒 = **我们自己这边有 bug**，调用方要打 error。"""
    if int(raw.get("v", 0)) != REPORT_VERSION:
        raise ReportRejected("report_version", "战报版本对不上")

    match_uid = str(raw.get("mid", ""))
    if not _MATCH_UID_RE.match(match_uid):
        raise ReportRejected("report_malformed", "match_uid 格式不对")

    mode = str(raw.get("mode", ""))
    if mode not in MODES:
        raise ReportRejected("report_malformed", "未知的对局模式")

    outcome = str(raw.get("out", ""))
    if outcome not in OUTCOMES:
        raise ReportRejected("report_malformed", "未知的胜负结果")

    rounds = _int(raw.get("rounds"))
    if not 1 <= rounds <= 100:
        raise ReportRejected("report_malformed", "回合数超出范围")

    started = _int(raw.get("start"))
    ended = _int(raw.get("end"))
    if started <= 0 or ended <= 0 or ended < started:
        raise ReportRejected("report_malformed", "时间对不上")
    if ended > now + CLOCK_LEEWAY_SEC:
        raise ReportRejected("report_malformed", "战报来自未来")
    if ended < now - MAX_REPORT_AGE_SEC:
        raise ReportRejected("report_too_old", "这份战报太旧了")

    hp = raw.get("hp", [])
    if not isinstance(hp, list) or len(hp) != 2:
        raise ReportRejected("report_malformed", "法阵 HP 字段不对")

    raw_seats = raw.get("seats", [])
    if not isinstance(raw_seats, list) or len(raw_seats) != SEAT_COUNT:
        raise ReportRejected("report_malformed", "座位数不是 6")
    seats = [_validate_seat(item, index) for index, item in enumerate(raw_seats)]

    return {
        "match_uid": match_uid,
        "mode": mode,
        "protocol": _int(raw.get("proto")),
        "server_epoch": _int(raw.get("epoch")),
        "room_id": _int(raw.get("room")),
        "started_at": dt.datetime.fromtimestamp(started, dt.UTC),
        "ended_at": dt.datetime.fromtimestamp(ended, dt.UTC),
        "rounds": rounds,
        "outcome": outcome,
        "team_a_hp": _int(hp[0]),
        "team_b_hp": _int(hp[1]),
        "gold_authoritative": bool(raw.get("gold_auth", False)),
        "carrot_authoritative": bool(raw.get("carrot_auth", False)),
        "seats": seats,
    }


def _validate_seat(item: object, index: int) -> dict:
    if not isinstance(item, dict):
        raise ReportRejected("report_malformed", "座位格式不对")
    slot = _int(item.get("slot"))
    # 座位必须**按顺序**占满 0..5。战斗服务器那边就是按 slot 循环生成的，
    # 对不上说明它坏了 —— 而不是「这一局只有 4 个人」。
    if slot != index:
        raise ReportRejected("report_malformed", "座位号对不上")
    team = _int(item.get("team"))
    if team != (0 if slot < TEAM_SIDE_SIZE else 1):
        raise ReportRejected("report_malformed", "队伍与座位号对不上")

    # 空 = 这个座位不是真人（房主加的 AI，或者入座时没带名片）。
    raw_pid = str(item.get("pid", "")).strip()
    player_id: uuid.UUID | None = None
    if raw_pid:
        try:
            player_id = uuid.UUID(raw_pid)
        except ValueError as exc:
            raise ReportRejected("report_malformed", "座位上的 player_id 格式不对") from exc

    return {
        "slot": slot,
        "team": team,
        "player_id": player_id,
        "was_ai": bool(item.get("ai", False)),
        "online_at_end": bool(item.get("online", False)),
        "ai_rounds": _int(item.get("ai_rounds")),
        "gold": _int(item.get("gold")),
        "carrots": _int(item.get("carrots")),
        "carrots_spent": _int(item.get("spent")),
        "board": _json_list(item.get("board")),
        "treasures": _json_list(item.get("treasures")),
    }


def _int(value: object) -> int:
    """取整并夹到 int4 范围。溢出的话 asyncpg 会抛，那是 500 不是 400。"""
    try:
        out = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError) as exc:
        raise ReportRejected("report_malformed", "数字字段格式不对") from exc
    return max(-_INT_MAX, min(_INT_MAX, out))


def _json_list(value: object) -> str:
    """jsonb 列的参数。项目里还没设 asyncpg 的 json 编解码器，所以自己序列化后 ::jsonb。"""
    if not isinstance(value, list):
        return "[]"
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


# --- 入库 ---------------------------------------------------------------------


async def record(report: dict) -> bool:
    """写一局。返回 True = 这是第一次记；False = 已经记过了（不是错误）。

    **不记「谁交的」** —— 那一列是死路，理由写在 013 里。交的人写进日志。
    """
    async with db.pool().acquire() as conn, conn.transaction():
        inserted = await conn.fetchval(
            """
            insert into match_records (
              match_uid, mode, protocol, server_epoch, room_id,
              started_at, ended_at, rounds, outcome, team_a_hp, team_b_hp,
              gold_authoritative, carrot_authoritative
            ) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
            on conflict (match_uid) do nothing
            returning match_uid
            """,
            report["match_uid"], report["mode"], report["protocol"],
            report["server_epoch"], report["room_id"],
            report["started_at"], report["ended_at"], report["rounds"],
            report["outcome"], report["team_a_hp"], report["team_b_hp"],
            report["gold_authoritative"], report["carrot_authoritative"],
        )
        if inserted is None:
            # 已经有人交过了。幂等，不是错误 —— 六个人各交一份是设计如此。
            return False

        # 🔴 认不出的 player_id 写 null，不是让整局插不进去。
        #
        # 外键指着 players。**对局结束到战报交上来之间**有一段窗口（玩家看完结算、
        # 退回主菜单），一个人在这段里注销账号的话，直接插会违反外键、整个事务回滚 ——
        # 那就是一个人注销毁掉同局其他五个人的历史。所以先查哪些还在，
        # 不在的那一格退化成「看起来像 AI」的座位。
        #
        # 注意这跟**之后**再注销不是一回事：那时走的是 013 里的 on delete cascade，
        # 他那一行会被删掉（而不是置空），同局其他人的历史少一格。那是设计如此。
        known = await _known_players(conn, [s["player_id"] for s in report["seats"]])
        rows = [
            (
                report["match_uid"], s["slot"], s["team"],
                s["player_id"] if s["player_id"] in known else None,
                s["was_ai"], s["online_at_end"], s["ai_rounds"],
                s["gold"], s["carrots"], s["carrots_spent"],
                s["board"], s["treasures"],
            )
            for s in report["seats"]
        ]
        await conn.executemany(
            """
            insert into match_seats (
              match_uid, slot, team, player_id, was_ai, online_at_end, ai_rounds,
              gold, carrots, carrots_spent, board, treasures
            ) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12::jsonb)
            """,
            rows,
        )
    return True


async def _known_players(conn, ids: list[uuid.UUID | None]) -> set[uuid.UUID]:
    wanted = [i for i in ids if i is not None]
    if not wanted:
        return set()
    rows = await conn.fetch(
        "select player_id from players where player_id = any($1::uuid[])", wanted
    )
    return {r["player_id"] for r in rows}


# --- 读 -----------------------------------------------------------------------


async def list_for_player(player_id: uuid.UUID, limit: int) -> list[dict]:
    """这个人打过的局，新的在前。每局带全部六个座位。"""
    async with db.pool().acquire() as conn:
        rows = await conn.fetch(
            """
            select r.match_uid, r.mode, r.rounds, r.outcome,
                   r.team_a_hp, r.team_b_hp, r.ended_at,
                   r.gold_authoritative, r.carrot_authoritative,
                   s.slot as my_slot
              from match_seats s
              join match_records r on r.match_uid = s.match_uid
             where s.player_id = $1
             order by r.ended_at desc
             limit $2
            """,
            player_id, limit,
        )
        if not rows:
            return []
        seats = await conn.fetch(
            """
            select match_uid, slot, team, player_id, was_ai, online_at_end,
                   ai_rounds, gold, carrots, carrots_spent, board, treasures
              from match_seats
             where match_uid = any($1::text[])
             order by match_uid, slot
            """,
            [r["match_uid"] for r in rows],
        )
    by_match: dict[str, list[dict]] = {}
    for s in seats:
        by_match.setdefault(s["match_uid"], []).append(
            {
                "slot": s["slot"],
                "team": s["team"],
                # 好友码 / 昵称不在这里拼 —— 名字会改，历史里存一份死的就会过期。
                # 客户端拿 player_id 走已有的公开资料接口。
                "player_id": str(s["player_id"]) if s["player_id"] else None,
                "was_ai": s["was_ai"],
                "online_at_end": s["online_at_end"],
                "ai_rounds": s["ai_rounds"],
                "gold": s["gold"],
                "carrots": s["carrots"],
                "carrots_spent": s["carrots_spent"],
                "board": json.loads(s["board"]) if isinstance(s["board"], str) else s["board"],
                "treasures": json.loads(s["treasures"]) if isinstance(s["treasures"], str) else s["treasures"],
            }
        )
    now = dt.datetime.now(dt.UTC)
    return [
        {
            "match_uid": r["match_uid"],
            "mode": r["mode"],
            "rounds": r["rounds"],
            "outcome": r["outcome"],
            "team_a_hp": r["team_a_hp"],
            "team_b_hp": r["team_b_hp"],
            # 同邮件那条：只发相对值，不发绝对时间 —— 手机的钟可能是错的。
            "age_sec": max(0, int((now - r["ended_at"]).total_seconds())),
            "my_slot": r["my_slot"],
            "gold_authoritative": r["gold_authoritative"],
            "carrot_authoritative": r["carrot_authoritative"],
            "seats": by_match.get(r["match_uid"], []),
        }
        for r in rows
    ]
