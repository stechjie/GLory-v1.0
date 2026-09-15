"""公告（app/announcements.py、routes/announcements.py，docs/公告系统设计.md）的行为用例。

同 test_chat / test_ws 的分工：**不连数据库、不连 Supabase**。读表、取图、写回、推送全部注入假的，
判据全在「谁看得到什么」「图过不过得了关」「推不推、推几次」上。

最要紧的几条，失败时都不报错：
  1. 🔴 普通玩家看不到草稿、没到时间的、已结束的 —— 看到了就是提前泄漏活动
  2. 🔴 不合格的图不发给玩家，原因写回 problem 列；没变化时不重复写
  3. 🔴 紧急公告只推一次；进程刚启动那一轮不推（在线的人都是重连回来的）
  4. 图片文件名只能是哈希 —— /media 路由同时靠它挡路径穿越
  5. 部署文件：systemd 给的写目录与 Caddy 读的目录是同一个

跑（从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q tests/test_announcements.py
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import hashlib
import os
import pathlib
import re
import time
import uuid

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketState

from app import announcements, db, players, realtime
from app.announcements import ImageRejected
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.realtime import Connection
from app.routes import me as me_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_008 = (REPO / "database" / "008_announcements.sql").read_text(encoding="utf-8")

NOW = dt.datetime(2026, 9, 20, 12, 0, tzinfo=dt.UTC)
HOUR = dt.timedelta(hours=1)

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
PLAYER_B = uuid.UUID("22222222-2222-2222-2222-222222222222")
CODE_A = "AAAA2222"
CODE_B = "BBBB3333"


def _sql_code(sql: str) -> str:
    """去掉 SQL 注释。注释里写着规则本身，直接全文搜会被注释满足（同 test_chat）。"""
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


# --- 图片字节 -------------------------------------------------------------------


def _png(width: int = 1200, height: int = 600, pad: int = 64) -> bytes:
    return (b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + b"IHDR"
            + width.to_bytes(4, "big") + height.to_bytes(4, "big")
            + b"\x08\x06\x00\x00\x00" + b"\x00" * pad)


def _jpeg(width: int, height: int, fill: bool = False) -> bytes:
    app0 = b"\xff\xe0" + (16).to_bytes(2, "big") + b"JFIF\x00" + b"\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = (b"\xff\xc0" + (17).to_bytes(2, "big") + b"\x08"
            + height.to_bytes(2, "big") + width.to_bytes(2, "big")
            + b"\x03" + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01")
    return b"\xff\xd8" + (b"\xff" if fill else b"") + app0 + sof0 + b"\xff\xda\x00\x08" + b"\x00" * 32


def _riff(chunk: bytes, payload: bytes) -> bytes:
    body = b"WEBP" + chunk + len(payload).to_bytes(4, "little") + payload
    return b"RIFF" + len(body).to_bytes(4, "little") + body


def _webp_vp8(width: int, height: int) -> bytes:
    return _riff(b"VP8 ", b"\x00\x00\x00\x9d\x01\x2a"
                 + width.to_bytes(2, "little") + height.to_bytes(2, "little") + b"\x00" * 16)


def _webp_vp8l(width: int, height: int) -> bytes:
    bits = (width - 1) | ((height - 1) << 14)
    return _riff(b"VP8L", b"\x2f" + bits.to_bytes(4, "little") + b"\x00" * 16)


def _webp_vp8x(width: int, height: int, animated: bool = False) -> bytes:
    return _riff(b"VP8X", bytes([0x02 if animated else 0x00]) + b"\x00\x00\x00"
                 + (width - 1).to_bytes(3, "little") + (height - 1).to_bytes(3, "little") + b"\x00" * 16)


# --- 行与测试台 -----------------------------------------------------------------


def _row(rid: int = 1, **fields) -> announcements.Row:
    base = dict(
        announcement_id=rid, kind="news", status="published",
        title_zh=f"公告{rid}", body_zh="正文", title_en="", body_en="",
        image="", popup=False, sort_order=0,
        starts_at=NOW - HOUR, ends_at=None, revision=1, preview_codes="", problem="",
    )
    base.update(fields)
    return announcements.Row(**base)


class _Rig:
    """假的表、假的 Storage、假的写回与推送。写回会改掉 rows 里那一格，模拟数据库。"""

    def __init__(self, media_dir: str, rows=(), images=None, storage_configured: bool = True) -> None:
        self.rows: list[announcements.Row] = list(rows)
        self.images: dict[str, bytes] = dict(images or {})
        self.fetches: list[str] = []
        self.writes: list[list[tuple[int, str]]] = []
        self.pushed: list[dict] = []
        self.now = NOW
        self.clock = 1000.0
        self.board = announcements.Board(
            load_rows=self._load, fetch_image=self._fetch,
            write_problems=self._write, broadcast=self._broadcast,
            media_dir=media_dir, storage_configured=storage_configured,
            now=lambda: self.now, clock=lambda: self.clock,
        )

    async def _load(self) -> list[announcements.Row]:
        return list(self.rows)

    async def _fetch(self, path: str) -> bytes:
        self.fetches.append(path)
        data = self.images.get(path)
        if data is None:
            raise ImageRejected(f"Storage 里找不到 {path}")
        return data

    async def _write(self, changes: list[tuple[int, str]]) -> None:
        self.writes.append(list(changes))
        fixed = dict(changes)
        self.rows = [dataclasses.replace(r, problem=fixed[r.announcement_id])
                     if r.announcement_id in fixed else r for r in self.rows]

    async def _broadcast(self, payload: dict) -> int:
        self.pushed.append(payload)
        return 3

    def refresh(self) -> None:
        asyncio.run(self.board.refresh())

    def visible(self, code: str | None = None) -> list[tuple[int, bool]]:
        return [(e.row.announcement_id, preview) for e, preview in self.board.view_for(code)]


# --- 图片检查 -------------------------------------------------------------------


@pytest.mark.parametrize(("data", "expected"), [
    (_png(1200, 600), ("png", 1200, 600)),
    (_jpeg(1200, 600), ("jpg", 1200, 600)),
    (_jpeg(640, 320, fill=True), ("jpg", 640, 320)),
    (_webp_vp8(1200, 600), ("webp", 1200, 600)),
    (_webp_vp8l(1200, 600), ("webp", 1200, 600)),
    (_webp_vp8x(2048, 1024), ("webp", 2048, 1024)),
])
def test_probe_reads_size_from_header(data: bytes, expected: tuple[str, int, int]) -> None:
    assert announcements.probe_image(data) == expected


@pytest.mark.parametrize(("data", "fragment"), [
    (b"GIF89a" + b"\x00" * 40, "GIF"),
    (_webp_vp8x(800, 400, animated=True), "动态 WebP"),
    (b"\xff\xd8\xff\xe0\x00\x10JFIF", "JPG"),  # 截断：没有帧头
    (b"<html>not an image</html>", "不是 JPG、PNG 或 WebP"),
])
def test_probe_rejects_what_phones_cannot_show(data: bytes, fragment: str) -> None:
    with pytest.raises(ImageRejected, match=fragment):
        announcements.probe_image(data)


def test_size_is_checked_before_the_header() -> None:
    """超了大小的连文件头都不看 —— 报出来的原因必须是「太大」，不是「格式不对」。"""
    too_big = b"\x00" * (announcements.IMAGE_MAX_BYTES + 1)
    with pytest.raises(ImageRejected, match="太大"):
        announcements.validate_image(too_big)


def test_dimensions_are_bounded() -> None:
    with pytest.raises(ImageRejected, match="长边不能超过"):
        announcements.validate_image(_png(4000, 3000))
    with pytest.raises(ImageRejected, match="太小"):
        announcements.validate_image(_png(8, 8))
    edge = announcements.validate_image(_png(announcements.IMAGE_MAX_SIDE, 16))
    assert edge.width == announcements.IMAGE_MAX_SIDE


def test_filename_is_content_hash() -> None:
    data = _png(1200, 600)
    info = announcements.validate_image(data)
    assert info.filename == hashlib.sha256(data).hexdigest() + ".png"
    assert announcements.MEDIA_NAME_RE.fullmatch(info.filename)
    assert info.size == len(data)


@pytest.mark.parametrize(("path", "ok"), [
    ("summer.jpg", True),
    ("2026-09/summer_v2.webp", True),
    ("../secret.png", False),
    ("a/../b.png", False),
    ("./a.png", False),
    ("/abs.png", False),
    ("a//b.png", False),
    ("夏日活动.jpg", False),
    ("with space.jpg", False),
    ("", False),
    ("a" * 201, False),
])
def test_image_path_rules(path: str, ok: bool) -> None:
    assert announcements.is_valid_image_path(path) is ok


def test_sql_image_path_constraint_matches_python_rule() -> None:
    code = _sql_code(SQL_008)
    assert "image ~ '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$'" in code
    assert announcements._IMAGE_PATH_RE.pattern == "[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*"
    assert "char_length(image) <= 200" in code and announcements.IMAGE_PATH_MAX == 200


def test_storage_url_quotes_path_and_needs_no_key() -> None:
    fetcher = announcements.StorageFetcher("https://example.supabase.co/", "announcements")
    assert fetcher.url_for("2026-09/a b.png") == (
        "https://example.supabase.co/storage/v1/object/public/announcements/2026-09/a%20b.png")
    assert not announcements.StorageFetcher("", "announcements").configured


# --- 表结构 ---------------------------------------------------------------------


def test_sql_constraints_and_rls() -> None:
    code = _sql_code(SQL_008)
    for name in ("announcement_kind", "announcement_status", "announcement_title_zh",
                 "announcement_image_path", "announcement_window", "announcement_revision"):
        assert f"constraint {name}" in code, f"008 少了约束 {name}"
    assert "alter table announcements enable row level security" in code
    assert "create policy" not in code.lower(), "所有表零 policy（database/README 那条硬规则）"


def test_kinds_match_sql() -> None:
    matched = re.search(r"kind in \(([^)]*)\)", _sql_code(SQL_008))
    assert matched is not None
    sql_kinds = tuple(k.strip().strip("'") for k in matched.group(1).split(","))
    assert sql_kinds == announcements.KINDS


def test_select_skips_withdrawn_and_ended_rows() -> None:
    sql = announcements._SELECT_ROWS
    assert "status <> 'withdrawn'" in sql and "ends_at > now()" in sql
    # Row(**record) 要求列名与字段一一对应，少一个多一个都会在第一次刷新时炸。
    selected = re.search(r"select(.*?)from", sql, re.S).group(1)
    columns = [c.strip() for c in selected.split(",")]
    assert columns == [f.name for f in dataclasses.fields(announcements.Row)]


# --- 预览好友码与可见性 ---------------------------------------------------------


def test_preview_codes_accept_common_separators() -> None:
    good, bad = announcements.parse_preview_codes(" aaaa2222，BBBB3333 、 nope ; CCCC444O")
    assert good == frozenset({CODE_A, CODE_B})
    # O 不在好友码字母表里（database/004 排掉了易混字符）。
    assert bad == ["nope", "CCCC444O"]


def test_normal_player_sees_only_live_rows(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[
        _row(1),
        _row(2, status="draft"),
        _row(3, starts_at=NOW + HOUR),
        _row(4, starts_at=NOW - 3 * HOUR, ends_at=NOW - HOUR),
        _row(5, status="withdrawn"),
        _row(6, starts_at=NOW - 2 * HOUR, ends_at=NOW + HOUR),
    ])
    rig.refresh()
    assert sorted(rid for rid, _ in rig.visible()) == [1, 6]
    assert sorted(rid for rid, _ in rig.visible(CODE_A)) == [1, 6], "不在预览名单里的人不能多看"


def test_preview_code_sees_drafts_and_scheduled_but_not_ended(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[
        _row(1),
        _row(2, status="draft", preview_codes=CODE_A),
        _row(3, starts_at=NOW + HOUR, preview_codes=f"{CODE_B},{CODE_A}"),
        _row(4, starts_at=NOW - 3 * HOUR, ends_at=NOW - HOUR, preview_codes=CODE_A),
        _row(5, status="withdrawn", preview_codes=CODE_A),
    ])
    rig.refresh()
    assert dict(rig.visible(CODE_A)) == {1: False, 2: True, 3: True}
    assert dict(rig.visible(CODE_B)) == {1: False, 3: True}
    assert rig.board.needs_identity()


def test_sort_order_then_newest_first(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[
        _row(1, starts_at=NOW - 3 * HOUR),
        _row(2, starts_at=NOW - HOUR),
        _row(3, starts_at=NOW - 5 * HOUR, sort_order=10),
    ])
    rig.refresh()
    assert [rid for rid, _ in rig.visible()] == [3, 2, 1]
    assert not rig.board.needs_identity(), "没人设预览码时接口不该去查数据库"


def test_visibility_follows_server_clock_between_refreshes(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, starts_at=NOW + HOUR)])
    rig.refresh()
    assert rig.visible() == []
    rig.now = NOW + 2 * HOUR
    assert rig.visible() == [(1, False)], "到点就该出现，不必等下一轮刷新"


# --- 图片取回与写回 -------------------------------------------------------------


def test_image_is_fetched_once_and_stored_by_hash(tmp_path: pathlib.Path) -> None:
    data = _png(1200, 600)
    rig = _Rig(str(tmp_path), rows=[_row(1, image="summer.png"), _row(2, image="summer.png")],
               images={"summer.png": data})
    rig.refresh()
    rig.refresh()
    assert rig.fetches == ["summer.png"], "同一个路径只取一次"
    name = hashlib.sha256(data).hexdigest() + ".png"
    assert (tmp_path / name).read_bytes() == data
    assert not list(tmp_path.glob(".*.tmp")), "临时文件要改名转正，不能留下"
    entry, _ = rig.board.view_for(None)[0]
    assert entry.image is not None and entry.image.filename == name
    assert rig.writes == []


def test_bad_image_is_withheld_and_reason_written_once(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, image="huge.png")], images={"huge.png": _png(4000, 3000)})
    rig.refresh()
    entry, _ = rig.board.view_for(None)[0]
    assert entry.image is None, "不合格的图不能发给玩家"
    assert len(rig.writes) == 1 and "长边不能超过" in rig.writes[0][0][1]
    assert not list(tmp_path.iterdir()), "不合格的图不落盘"
    rig.refresh()
    assert len(rig.writes) == 1, "原因没变就不重复写（管理员正开着表格）"


def test_failed_fetch_waits_before_retrying(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, image="typo.png")])
    rig.refresh()
    rig.refresh()
    assert rig.fetches == ["typo.png"], "冷却期内不该每轮都去打 Storage"
    rig.images["typo.png"] = _png()
    rig.clock += announcements.IMAGE_RETRY_SEC
    rig.refresh()
    assert rig.fetches == ["typo.png", "typo.png"]
    entry, _ = rig.board.view_for(None)[0]
    assert entry.image is not None
    assert rig.rows[0].problem == "", "修好之后 problem 要清空"


def test_renamed_image_is_tried_immediately(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, image="typo.png")], images={"fixed.png": _png()})
    rig.refresh()
    rig.rows = [dataclasses.replace(rig.rows[0], image="fixed.png")]
    rig.refresh()
    assert rig.fetches == ["typo.png", "fixed.png"]


def test_missing_media_dir_is_reported_without_fetching(tmp_path: pathlib.Path) -> None:
    rig = _Rig("", rows=[_row(1, image="summer.png")], images={"summer.png": _png()})
    rig.refresh()
    assert rig.fetches == []
    assert "GLORY_MEDIA_DIR" in rig.rows[0].problem
    assert [rid for rid, _ in rig.visible()] == [1], "没配图片目录时公告照常显示，只是没图"


def test_unconfigured_storage_is_reported(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, image="summer.png")], storage_configured=False)
    rig.refresh()
    assert rig.fetches == [] and "GLORY_SUPABASE_URL" in rig.rows[0].problem


def test_bad_preview_codes_are_reported(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, status="draft", preview_codes="AAAA2222, 12345")])
    rig.refresh()
    assert "预览好友码格式不对：12345" in rig.rows[0].problem


# --- 紧急公告推送 ---------------------------------------------------------------


def test_urgent_is_not_pushed_on_first_refresh(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, kind="urgent")])
    rig.refresh()
    assert rig.pushed == [], "刚启动那一轮在线的都是重连回来的人，他们会自己拉列表"


def test_urgent_pushed_once_when_it_becomes_visible(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1)])
    rig.refresh()
    rig.rows.append(_row(2, kind="urgent", title_zh="10 分钟后停服", title_en="Maintenance in 10 min"))
    rig.rows.append(_row(3, kind="event"))
    rig.rows.append(_row(4, kind="urgent", status="draft", preview_codes=CODE_A))
    rig.refresh()
    rig.refresh()
    assert rig.pushed == [{"t": "announcement", "id": 2, "revision": 1,
                           "title_zh": "10 分钟后停服", "title_en": "Maintenance in 10 min"}]


def test_urgent_scheduled_is_pushed_when_time_arrives(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, kind="urgent", starts_at=NOW + HOUR)])
    rig.refresh()
    rig.refresh()
    assert rig.pushed == []
    rig.now = NOW + 2 * HOUR
    rig.refresh()
    assert [p["id"] for p in rig.pushed] == [1]


def test_urgent_revision_bump_pushes_again(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1)])
    rig.refresh()
    rig.rows = [_row(1, kind="urgent")]
    rig.refresh()
    rig.rows = [_row(1, kind="urgent", revision=2)]
    rig.refresh()
    assert [(p["id"], p["revision"]) for p in rig.pushed] == [(1, 1), (1, 2)]


def test_push_type_matches_client() -> None:
    gd = (REPO / "scripts" / "autoload" / "AnnouncementService.gd").read_text(encoding="utf-8")
    assert f'const PUSH_TYPE := "{announcements.PUSH_TYPE}"' in gd


# --- 图片清理 -------------------------------------------------------------------


def test_sweep_keeps_referenced_and_recent_files(tmp_path: pathlib.Path) -> None:
    data = _png()
    rig = _Rig(str(tmp_path), rows=[_row(1, image="live.png")], images={"live.png": data})
    rig.refresh()
    live = tmp_path / (hashlib.sha256(data).hexdigest() + ".png")
    old = time.time() - announcements.MEDIA_KEEP_UNUSED_SEC - 60
    os.utime(live, (old, old))

    stale = tmp_path / ("a" * 64 + ".jpg")
    fresh = tmp_path / ("b" * 64 + ".webp")
    leftover = tmp_path / (".%s.png.tmp" % ("c" * 64))
    foreign = tmp_path / "README.txt"
    for path in (stale, fresh, leftover, foreign):
        path.write_bytes(b"x")
    for path in (stale, leftover, foreign):
        os.utime(path, (old, old))

    assert rig.board.sweep_media() == 2
    assert live.exists() and live.stat().st_mtime > old, "仍在用的图要刷新修改时间，不能删"
    assert fresh.exists()
    assert not stale.exists() and not leftover.exists()
    assert foreign.exists(), "不是我们形状的文件不碰"


# --- 广播 -----------------------------------------------------------------------


class _Socket:
    def __init__(self, hang: bool = False) -> None:
        self.client_state = WebSocketState.CONNECTED
        self.hang = hang
        self.sent: list[dict] = []

    async def send_json(self, payload: dict) -> None:
        if self.hang:
            await asyncio.sleep(3600)
        self.sent.append(payload)

    async def close(self, code: int = 1000) -> None:
        self.client_state = WebSocketState.DISCONNECTED


def test_broadcast_does_not_wait_on_a_stuck_connection(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(realtime, "BROADCAST_SEND_TIMEOUT_SEC", 0.05)
    hub = realtime.Hub()
    ok, stuck = _Socket(), _Socket(hang=True)

    async def run() -> int:
        await hub.register(Connection(PLAYER_A, "device-aaaaaaaa", ok))  # type: ignore[arg-type]
        await hub.register(Connection(PLAYER_B, "device-bbbbbbbb", stuck))  # type: ignore[arg-type]
        return await hub.broadcast({"t": "announcement", "id": 1})

    assert asyncio.run(run()) == 1
    assert ok.sent == [{"t": "announcement", "id": 1}]
    assert asyncio.run(realtime.Hub().broadcast({"t": "x"})) == 0


# --- 接口 -----------------------------------------------------------------------


@dataclasses.dataclass
class _FakePlayer:
    player_id: uuid.UUID
    player_name: str
    friend_code: str


_KNOWN = {
    "auth-a": _FakePlayer(PLAYER_A, "阿甲", CODE_A),
    "auth-b": _FakePlayer(PLAYER_B, "阿乙", CODE_B),
}


class _FakeVerifier:
    accept = {"token-a": "auth-a", "token-b": "auth-b"}

    async def verify(self, token: str) -> Claims:
        uid = self.accept.get(token)
        if uid is None:
            raise TokenError("令牌校验失败：测试用的假 verifier 不认识它")
        return Claims(auth_uid=uid, is_anonymous=True, expires_at=0)


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path):
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    # 🔴 同 test_ws：不清的话 lifespan 会拿 backend/.env 里的串去连真库。
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    monkeypatch.setenv("GLORY_MEDIA_DIR", str(tmp_path))
    get_settings.cache_clear()
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)
    lookups: list[str] = []

    async def _lookup(auth_uid: str):
        lookups.append(auth_uid)
        return _KNOWN.get(auth_uid)

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    announcements.reset()
    yield tmp_path, lookups
    announcements.reset()
    get_settings.cache_clear()


def _auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_list_requires_token(wired) -> None:
    assert TestClient(app).get("/v1/announcements").status_code == 401


def test_list_for_normal_player(wired) -> None:
    media_dir, lookups = wired
    data = _png(1200, 600)
    rig = _Rig(str(media_dir), rows=[
        _row(1, kind="event", title_en="Summer", image="summer.png", popup=True,
             ends_at=NOW + 24 * HOUR, sort_order=5),
        _row(2, status="draft"),
    ], images={"summer.png": data})
    rig.refresh()
    announcements.install(rig.board)

    r = TestClient(app).get("/v1/announcements", headers=_auth("token-b"))
    assert r.status_code == 200
    body = r.json()
    assert isinstance(body, dict) and body["server_time"] == int(NOW.timestamp())
    assert [a["id"] for a in body["announcements"]] == [1]
    item = body["announcements"][0]
    sha = hashlib.sha256(data).hexdigest()
    assert item["image"] == {"url": f"/media/{sha}.png", "sha256": sha,
                             "width": 1200, "height": 600, "size": len(data)}
    assert item["starts_at"] == int((NOW - HOUR).timestamp())
    assert item["ends_at"] == int((NOW + 24 * HOUR).timestamp())
    assert item["popup"] is True and item["preview"] is False and item["problem"] == ""
    assert lookups == [], "没人设预览码时不查「你是谁」"


def test_preview_player_sees_draft_and_problem(wired) -> None:
    media_dir, lookups = wired
    rig = _Rig(str(media_dir), rows=[
        _row(1, image="missing.png", preview_codes=CODE_A),
        _row(2, status="draft", preview_codes=CODE_A),
    ])
    rig.refresh()
    announcements.install(rig.board)
    client = TestClient(app)

    tester = client.get("/v1/announcements", headers=_auth("token-a")).json()["announcements"]
    assert {a["id"]: a["preview"] for a in tester} == {1: False, 2: True}
    assert "missing.png" in next(a for a in tester if a["id"] == 1)["problem"]

    player = client.get("/v1/announcements", headers=_auth("token-b")).json()["announcements"]
    assert [a["id"] for a in player] == [1]
    assert player[0]["problem"] == "", "problem 只给预览账号看"
    assert player[0]["image"] is None
    assert lookups == ["auth-a", "auth-b"]


def test_media_route_serves_hash_named_files_only(wired) -> None:
    media_dir, _ = wired
    data = _png()
    name = hashlib.sha256(data).hexdigest() + ".png"
    (media_dir / name).write_bytes(data)
    (media_dir / "notes.txt").write_text("secret", encoding="utf-8")
    client = TestClient(app)

    r = client.get(f"/media/{name}")
    assert r.status_code == 200 and r.content == data
    assert r.headers["content-type"] == "image/png"
    assert "immutable" in r.headers["cache-control"]
    for bad in ("notes.txt", name.upper(), "0" * 64 + ".png", name.replace(".png", ".gif")):
        assert client.get(f"/media/{bad}").status_code == 404, bad


def test_media_route_404_without_media_dir(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GLORY_MEDIA_DIR", "")
    get_settings.cache_clear()
    assert TestClient(app).get("/media/" + "0" * 64 + ".png").status_code == 404


# --- 接线与部署文件 -------------------------------------------------------------


def test_routes_and_background_loop_are_wired() -> None:
    # 路由本身有没有挂上，上面几条走 TestClient 的用例已经证明了；
    # 这里钉的是 lifespan —— TestClient 不当上下文管理器用时不跑它，那几条测不到。
    main_py = (REPO / "backend" / "app" / "main.py").read_text(encoding="utf-8")
    assert "app.include_router(announcement_routes.router)" in main_py
    assert "announcements.loop(" in main_py, "lifespan 没起公告刷新任务 —— 公告永远是空的"
    assert "await fetcher.aclose()" in main_py, "取图用的 HTTP 客户端退出时没关"


def test_media_dir_is_written_by_backend_and_read_by_caddy() -> None:
    service = (REPO / "deploy" / "glory-backend.service").read_text(encoding="utf-8")
    caddy = (REPO / "deploy" / "Caddyfile").read_text(encoding="utf-8")
    assert "StateDirectory=glory-media" in service
    assert "Environment=GLORY_MEDIA_DIR=/var/lib/glory-media" in service
    media_block = re.search(r"handle_path /media/\* \{(.*?)\n\t\}", caddy, re.S)
    assert media_block is not None and "root * /var/lib/glory-media" in media_block.group(1)
    status_block = re.search(r"handle /status\.json \{(.*?)\n\t\}", caddy, re.S)
    assert status_block is not None and "root * /opt/glory/public" in status_block.group(1)
    assert "reverse_proxy 127.0.0.1:8099" in caddy


def test_deploy_scripts_create_status_dir() -> None:
    for script in ("update.sh", "bootstrap.sh"):
        text = (REPO / "deploy" / script).read_text(encoding="utf-8")
        assert 'mkdir -p "$BASE/public"' in text, script
    env_example = (REPO / "backend" / ".env.example").read_text(encoding="utf-8")
    assert "GLORY_MEDIA_DIR=" in env_example and "GLORY_ANNOUNCEMENT_BUCKET=" in env_example
