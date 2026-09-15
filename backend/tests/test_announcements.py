"""公告（app/announcements.py、routes/announcements.py，docs/公告系统设计.md）的行为用例。

同 test_chat / test_ws 的分工：**不连数据库、不连 Supabase**。读表、取图、写回、推送全部注入假的，
判据全在「谁看得到什么」「图转不转得出来」「推不推、推几次」上。

最要紧的几条，失败时都不报错：
  1. 🔴 普通玩家看不到草稿、没到时间的、已结束的 —— 看到了就是提前泄漏活动
  2. 🔴 管理员传的原图一律转成 WebP 再发给玩家；转不了的不发，原因写回 problem 列；没变化时不重复写
  3. 🔴 解码之前先挡：原图超过上限、像素超过上限、不是 PNG / JPG / WebP（包括会去调外部程序的 EPS）
  4. 🔴 紧急公告只推一次；进程刚启动那一轮不推（在线的人都是重连回来的）
  5. 图片文件名只能是哈希 —— /media 路由同时靠它挡路径穿越
  6. 部署文件：systemd 给的写目录与 Caddy 读的目录是同一个；Pillow 写进了 requirements

跑（从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q tests/test_announcements.py
"""

from __future__ import annotations

import asyncio
import dataclasses
import datetime as dt
import hashlib
import inspect
import io
import os
import pathlib
import re
import time
import uuid
import zlib

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image, features
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


def _encode(image: Image.Image, fmt: str, **params) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format=fmt, **params)
    return buffer.getvalue()


def _png(width: int = 1200, height: int = 600, mode: str = "RGB") -> bytes:
    """纯色原图：压缩后很小，但尺寸与颜色模式都是真的。"""
    fill = {"RGB": (210, 140, 60), "RGBA": (210, 140, 60, 128)}[mode]
    return _encode(Image.new(mode, (width, height), fill), "PNG")


def _noise(width: int, height: int) -> Image.Image:
    """细节多到压不小的图，测大小相关的路径用。"""
    return Image.effect_noise((width, height), 64).convert("RGB")


def _gif() -> bytes:
    return _encode(Image.new("L", (64, 32), 128), "GIF")


def _animated(fmt: str) -> bytes:
    frames = [Image.new("RGB", (64, 32), color) for color in ((255, 0, 0), (0, 255, 0))]
    return _encode(frames[0], fmt, save_all=True, append_images=frames[1:], duration=100, loop=0)


def _png_header_only(width: int, height: int) -> bytes:
    """只有文件头、没有像素的 PNG：尺寸写多大都行，测「不解码就拒」用。"""
    ihdr = b"IHDR" + width.to_bytes(4, "big") + height.to_bytes(4, "big") + b"\x08\x02\x00\x00\x00"
    return (b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + ihdr
            + zlib.crc32(ihdr).to_bytes(4, "big") + (0).to_bytes(4, "big") + b"IDAT")


def _decoded(data: bytes) -> Image.Image:
    image = Image.open(io.BytesIO(data))
    image.load()
    return image


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


# --- 图片转换 -------------------------------------------------------------------


def test_pillow_can_write_webp() -> None:
    """装的 Pillow 必须带 WebP 编码器 —— 不带的话每张图都会转换失败。"""
    assert features.check("webp")


def test_png_becomes_webp_named_by_its_own_hash() -> None:
    info, encoded = announcements.prepare_image(_png(1600, 800))
    assert (info.ext, info.width, info.height) == ("webp", 1600, 800)
    assert _decoded(encoded).format == "WEBP"
    assert info.sha256 == hashlib.sha256(encoded).hexdigest() and info.size == len(encoded)
    assert info.filename == info.sha256 + ".webp"
    assert announcements.MEDIA_NAME_RE.fullmatch(info.filename)


@pytest.mark.parametrize(("size", "expected"), [
    ((4000, 2000), (2048, 1024)),
    ((1000, 3000), (683, 2048)),
    ((2048, 1024), (2048, 1024)),
])
def test_oversized_images_are_scaled_down_not_rejected(size, expected) -> None:
    info, encoded = announcements.prepare_image(_png(*size))
    assert abs(info.width - expected[0]) <= 1 and abs(info.height - expected[1]) <= 1
    assert _decoded(encoded).size == (info.width, info.height)


def test_transparency_survives_conversion() -> None:
    _, encoded = announcements.prepare_image(_png(400, 200, mode="RGBA"))
    image = _decoded(encoded)
    assert image.mode == "RGBA" and image.getpixel((10, 10))[3] < 255


def test_photo_orientation_is_applied_and_exif_dropped() -> None:
    """手机照片常把「竖着拍」写在 EXIF 里而不转像素；不处理的话发出去是躺着的。
    EXIF 里还可能有拍摄位置，转出来的图不能带着它。"""
    exif = Image.Exif()
    exif[0x0112] = 6  # 顺时针转 90°
    data = _encode(Image.new("RGB", (1200, 600), (10, 20, 30)), "JPEG", exif=exif)
    info, encoded = announcements.prepare_image(data)
    assert (info.width, info.height) == (600, 1200)
    assert len(_decoded(encoded).getexif()) == 0


@pytest.mark.parametrize(("make", "fragment"), [
    pytest.param(_gif, "GIF", id="gif"),
    pytest.param(lambda: _animated("WEBP"), "动图", id="animated-webp"),
    pytest.param(lambda: _animated("PNG"), "动图", id="apng"),
    pytest.param(lambda: b"<html>not an image</html>", "不是 PNG、JPG 或 WebP", id="html"),
    # EPS 会让 Pillow 去调系统里的 Ghostscript —— formats 限死之后根本不认它。
    pytest.param(lambda: b"%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 100 100\n",
                 "不是 PNG、JPG 或 WebP", id="eps"),
    pytest.param(lambda: _png(8, 8), "太小", id="tiny"),
    pytest.param(lambda: _png(4000, 12), "太小", id="thin"),
    pytest.param(lambda: _png(3000, 20), "太扁", id="flat-after-scaling"),
])
def test_rejects_what_cannot_be_shown(make, fragment) -> None:
    with pytest.raises(ImageRejected, match=fragment):
        announcements.prepare_image(make())


def test_truncated_file_is_reported_as_damaged() -> None:
    data = _encode(_noise(256, 256), "PNG")
    with pytest.raises(ImageRejected, match="损坏"):
        announcements.prepare_image(data[: len(data) * 2 // 3])


@pytest.mark.parametrize("size", [(5000, 4000), (10000, 10000), (20000, 20000)])
def test_pixel_bombs_are_rejected_before_decoding(size) -> None:
    """文件头里的尺寸就够判了：5000×4000 解码要 80 MB，20000×20000 要 1.6 GB。
    后两个大到 Pillow 自己会警告 / 报错，也必须变成同一句给管理员看的话。"""
    with pytest.raises(ImageRejected, match="像素太多"):
        announcements.prepare_image(_png_header_only(*size))


def test_upload_size_is_checked_before_decoding() -> None:
    with pytest.raises(ImageRejected, match="原图太大"):
        announcements.prepare_image(b"\x89PNG\r\n\x1a\n" + b"\x00" * announcements.UPLOAD_MAX_BYTES)


def test_quality_steps_down_before_giving_up(monkeypatch: pytest.MonkeyPatch) -> None:
    source = _noise(512, 256)
    data = _encode(source, "PNG")
    at_85 = len(_encode(source, "WEBP", quality=85, method=4))
    at_60 = len(_encode(source, "WEBP", quality=60, method=4))
    assert at_60 < at_85
    monkeypatch.setattr(announcements, "IMAGE_MAX_BYTES", at_60)
    info, _ = announcements.prepare_image(data)
    assert info.size <= at_60
    monkeypatch.setattr(announcements, "IMAGE_MAX_BYTES", 100)
    with pytest.raises(ImageRejected, match="仍超过"):
        announcements.prepare_image(data)


def test_conversion_runs_in_a_worker_thread() -> None:
    """转一张图要几百毫秒 CPU。在事件循环里直接转，所有人的心跳和接口请求都得排队等它 ——
    不报错，只是整个账号服务器一卡一卡的。"""
    assert "asyncio.to_thread(prepare_image" in inspect.getsource(announcements.Board._image_for)


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


# --- 取原图 ---------------------------------------------------------------------


def _fetch_with(handler, path: str = "a.png") -> bytes:
    fetcher = announcements.StorageFetcher(
        "https://example.supabase.co/", "announcements", transport=httpx.MockTransport(handler))

    async def run() -> bytes:
        try:
            return await fetcher(path)
        finally:
            await fetcher.aclose()

    return asyncio.run(run())


def test_fetcher_reads_the_public_url_without_any_key() -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, content=b"abc")

    assert _fetch_with(handler, "2026-09/a b.png") == b"abc"
    assert str(seen[0].url) == (
        "https://example.supabase.co/storage/v1/object/public/announcements/2026-09/a%20b.png")
    assert "apikey" not in seen[0].headers and "authorization" not in seen[0].headers
    assert not announcements.StorageFetcher("", "announcements").configured


def test_fetcher_stops_reading_past_the_upload_limit() -> None:
    big = b"x" * (announcements.UPLOAD_MAX_BYTES + 1)
    with pytest.raises(ImageRejected, match="原图太大"):
        _fetch_with(lambda request: httpx.Response(200, content=big))


def test_fetcher_explains_missing_files_and_network_errors() -> None:
    with pytest.raises(ImageRejected, match="找不到"):
        _fetch_with(lambda request: httpx.Response(400, json={"error": "not_found"}))

    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    with pytest.raises(ImageRejected, match="连不上 Storage"):
        _fetch_with(refuse)


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


# --- 取图、转换、写回 -----------------------------------------------------------


def test_image_is_fetched_once_converted_and_stored_by_hash(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, image="summer.png"), _row(2, image="summer.png")],
               images={"summer.png": _png(1200, 600)})
    rig.refresh()
    rig.refresh()
    assert rig.fetches == ["summer.png"], "同一个路径只取一次"
    entry, _ = rig.board.view_for(None)[0]
    assert entry.image is not None and entry.image.ext == "webp"
    stored = (tmp_path / entry.image.filename).read_bytes()
    assert hashlib.sha256(stored).hexdigest() == entry.image.sha256
    assert _decoded(stored).format == "WEBP", "发给玩家的必须是转过的那份，不是原图"
    assert not list(tmp_path.glob(".*.tmp")), "临时文件要改名转正，不能留下"
    assert rig.writes == []


def test_unconvertible_image_is_withheld_and_reason_written_once(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, image="anim.gif")], images={"anim.gif": _gif()})
    rig.refresh()
    entry, _ = rig.board.view_for(None)[0]
    assert entry.image is None, "转不了的图不能发给玩家"
    assert len(rig.writes) == 1 and "GIF" in rig.writes[0][0][1]
    assert not list(tmp_path.iterdir()), "转不了的图不落盘"
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


def test_push_type_and_image_limits_match_client() -> None:
    service = (REPO / "scripts" / "autoload" / "AnnouncementService.gd").read_text(encoding="utf-8")
    assert f'const PUSH_TYPE := "{announcements.PUSH_TYPE}"' in service
    images = (REPO / "scripts" / "account" / "AnnouncementImages.gd").read_text(encoding="utf-8")
    assert f"const MAX_SIDE := {announcements.IMAGE_MAX_SIDE}" in images
    matched = re.search(r"const MAX_BYTES := (\d+) \* 1024 \* 1024", images)
    assert matched is not None
    assert int(matched.group(1)) * 1024 * 1024 >= announcements.IMAGE_MAX_BYTES, (
        "手机的字节上限比服务器转出来的图还小 —— 手机会拒收，玩家看不到图")


# --- 图片清理 -------------------------------------------------------------------


def test_sweep_keeps_referenced_and_recent_files(tmp_path: pathlib.Path) -> None:
    rig = _Rig(str(tmp_path), rows=[_row(1, image="live.png")], images={"live.png": _png()})
    rig.refresh()
    entry, _ = rig.board.view_for(None)[0]
    assert entry.image is not None
    live = tmp_path / entry.image.filename
    old = time.time() - announcements.MEDIA_KEEP_UNUSED_SEC - 60
    os.utime(live, (old, old))

    stale = tmp_path / ("a" * 64 + ".jpg")
    fresh = tmp_path / ("b" * 64 + ".webp")
    leftover = tmp_path / (".%s.webp.tmp" % ("c" * 64))
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
    rig = _Rig(str(media_dir), rows=[
        _row(1, kind="event", title_en="Summer", image="summer.png", popup=True,
             ends_at=NOW + 24 * HOUR, sort_order=5),
        _row(2, status="draft"),
    ], images={"summer.png": _png(1200, 600)})
    rig.refresh()
    announcements.install(rig.board)
    entry, _ = rig.board.view_for(None)[0]
    info = entry.image
    assert info is not None

    r = TestClient(app).get("/v1/announcements", headers=_auth("token-b"))
    assert r.status_code == 200
    body = r.json()
    assert isinstance(body, dict) and body["server_time"] == int(NOW.timestamp())
    assert [a["id"] for a in body["announcements"]] == [1]
    item = body["announcements"][0]
    assert item["image"] == {"url": f"/media/{info.filename}", "sha256": info.sha256,
                             "width": 1200, "height": 600, "size": info.size}
    assert item["image"]["url"].endswith(".webp")
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
    _, data = announcements.prepare_image(_png())
    name = hashlib.sha256(data).hexdigest() + ".webp"
    (media_dir / name).write_bytes(data)
    (media_dir / "notes.txt").write_text("secret", encoding="utf-8")
    client = TestClient(app)

    r = client.get(f"/media/{name}")
    assert r.status_code == 200 and r.content == data
    assert r.headers["content-type"] == "image/webp"
    assert "immutable" in r.headers["cache-control"]
    for bad in ("notes.txt", name.upper(), "0" * 64 + ".webp", name.replace(".webp", ".gif")):
        assert client.get(f"/media/{bad}").status_code == 404, bad


def test_media_route_404_without_media_dir(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GLORY_MEDIA_DIR", "")
    get_settings.cache_clear()
    assert TestClient(app).get("/media/" + "0" * 64 + ".webp").status_code == 404


# --- 接线与部署文件 -------------------------------------------------------------


def test_routes_and_background_loop_are_wired() -> None:
    # 路由本身有没有挂上，上面几条走 TestClient 的用例已经证明了；
    # 这里钉的是 lifespan —— TestClient 不当上下文管理器用时不跑它，那几条测不到。
    main_py = (REPO / "backend" / "app" / "main.py").read_text(encoding="utf-8")
    assert "app.include_router(announcement_routes.router)" in main_py
    assert "announcements.loop(" in main_py, "lifespan 没起公告刷新任务 —— 公告永远是空的"
    assert "await fetcher.aclose()" in main_py, "取图用的 HTTP 客户端退出时没关"


def test_pillow_is_pinned_for_the_server() -> None:
    """update.sh 按 requirements.txt 装依赖：漏了这一行，服务器一 import 就起不来。"""
    requirements = (REPO / "backend" / "requirements.txt").read_text(encoding="utf-8")
    assert re.search(r"^pillow==\d+\.\d+\.\d+$", requirements, re.M | re.I)


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
