"""公告（docs/公告系统设计.md）。

    管理员 ── Supabase 后台 ──> announcements 表 + Storage 公开桶里的原图
    本进程每 REFRESH_SEC 读一次表；图片第一次出现时取回原图、转成 WebP、按内容哈希存进 media_dir
    玩家   ── GET /v1/announcements ──> 内存里的快照（不查库）
    玩家   ── GET /media/<sha256>.webp ──> Caddy 直接给文件（deploy/Caddyfile）

## 为什么图由服务器取回，而不是让手机去 Supabase 下载（2026-09-15 定）

  1. RFC 第三节第一条：Godot 永远不直连 Supabase。
  2. 玩家那边能不能连上 supabase.co 没人验证过；我们自己的域名能登录就能下图。
  3. 取回时就能处理：格式不对、像素离谱的图根本不发给玩家，
     原因写回这一行的 problem 列 —— 管理员在后台刷新表格就看得到，不用翻服务器日志。

## 为什么服务器把图转成 WebP（2026-09-15 改）

原来是「原样转发，超过 512 KB 就拒」。第一次实测管理员传的就是 2.1 MB 的 PNG ——
手绘图存 PNG 本来就是两三 MB。放宽上限让玩家直接下 PNG 的话，下载量是 WebP 的六七倍，
而且登录弹窗那一刻大家同时下，占的是和战斗服务器同一台机器的带宽。
所以改成：**管理员传什么都尽量收，玩家下载的永远是转过的那份**（实测游戏手绘图 1600×800 约 265 KB）。
长边超过 IMAGE_MAX_SIDE 的等比缩小，不再拒收。转出来的文件不带 EXIF（手机照片里的位置信息不会发出去）。

## 文件名 = 转出来那份的 SHA-256

同一个地址永远是同一张图，所以手机和 Caddy 可以永久缓存。
代价：管理员在 Storage 里**覆盖同名文件**时这里发现不了 —— 每个路径只在第一次见到时取一次
（重启后再取一次）。所以规矩是**换图就传新文件名**。

## 紧急公告的推送

kind='urgent' 的公告**变成可见的那一轮**顺着 WebSocket 推给所有在线的人（只推标题）。
进程刚启动的第一轮不推：那时在线的人都是重连回来的，客户端重连后自己会拉列表。

## 状态在进程内存里

与 realtime / admission 同一个前提：单进程单实例（app/single_instance.py）。
重启后第一轮刷新完成之前接口返回空列表（通常一两秒）。
"""

from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import io
import logging
import os
import re
import time
import warnings
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

import asyncpg
import httpx
from PIL import Image, ImageOps, UnidentifiedImageError

from app import db, realtime

log = logging.getLogger("glory.announcements")

# 多久读一次表。管理员改完最多等这么久玩家才看得到 —— 对公告足够，
# 而每 30 秒一条 select 对数据库可以忽略。
REFRESH_SEC = 30.0
# 一次最多读多少行。已撤下、已结束的不读，正常情况下远到不了。
MAX_ROWS = 200

# 与 database/008_announcements.sql 的 announcement_kind 约束、
# 客户端 AnnouncementService.KINDS 一致（tests/test_announcements.py、tools/announcement_check 钉着）。
KINDS = ("event", "news", "update", "urgent")
KIND_URGENT = "urgent"
STATUS_PUBLISHED = "published"
STATUS_WITHDRAWN = "withdrawn"

# 推给在线玩家的消息类型。与客户端 AnnouncementService.PUSH_TYPE 一致（tools/announcement_check 钉着）——
# 对不上的话推送落进 RealtimeService 的「未知类型」分支：不报错，就是收不到。
PUSH_TYPE = "announcement"

# --- 图片规格 -------------------------------------------------------------------

# 管理员能传多大的原图。只防误传视频、超大照片 —— 取回时边收边数，超了就停。
UPLOAD_MAX_BYTES = 10 * 1024 * 1024
# 原图最多多少像素。解码时每像素要 4 字节：1600 万像素 ≈ 64 MB 内存，而这台机器上还跑着战斗服务器。
# 判的是文件头里写的尺寸，**超了就不解码**。
UPLOAD_MAX_PIXELS = 16_000_000
UPLOAD_FORMATS = ("PNG", "JPEG", "WEBP")
# 转出来的图长边超过就等比缩小。与客户端 AnnouncementImages.MAX_SIDE 一致（tools/announcement_check 钉着）：
# 一张 4000×3000 的图解码后要几十 MB 内存，低端安卓机会闪退。
IMAGE_MAX_SIDE = 2048
IMAGE_MIN_SIDE = 16
# 转出来的图最多多大。**客户端 AnnouncementImages.MAX_BYTES 不能比它小**（tools/announcement_check 钉着）——
# 手机会拒收比自己上限大的图。客户端故意留得更宽：以后放宽这里不用发新包。
IMAGE_MAX_BYTES = 1024 * 1024
# WebP 质量。先用 85；压不进 IMAGE_MAX_BYTES 再往下降。
WEBP_QUALITIES = (85, 75, 60)

# 取图失败后多久再试。管理员传错文件名时不该每 30 秒去打一次 Storage。
IMAGE_RETRY_SEC = 300.0
IMAGE_FETCH_TIMEOUT_SEC = 15.0
MEDIA_SWEEP_SEC = 3600.0
# 不再被任何公告引用的图片留多久。撤下又重新发布时不用重新取。
MEDIA_KEEP_UNUSED_SEC = 7 * 86400.0

# 与 008 的 announcement_image_path 约束同一条规则。那边是最后一道，这里防的是约束被人改松。
_IMAGE_PATH_RE = re.compile(r"[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*")
IMAGE_PATH_MAX = 200
# 与 database/004 的 friend_code_format 同一个字母表。
_FRIEND_CODE_RE = re.compile(r"[2-9A-HJKMNP-Z]{8}")
# 管理员在表格里会用各种分隔符，中文逗号尤其常见。
_CODE_SPLIT_RE = re.compile(r"[\s,，、;；]+")

# 图片文件名。**只有这个形状的名字才会被读写或送出去** —— /media 路由也靠它挡路径穿越。
MEDIA_NAME_RE = re.compile(r"[0-9a-f]{64}\.(png|jpg|webp)")
MEDIA_TYPES = {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp"}


# --- 图片处理 -------------------------------------------------------------------


class ImageRejected(ValueError):
    """图片不合格或取不到。message 是给管理员看的中文原因，会写进 problem 列。"""


@dataclass(frozen=True)
class ImageInfo:
    """转出来、发给玩家的那份图。"""

    ext: str
    width: int
    height: int
    sha256: str
    size: int

    @property
    def filename(self) -> str:
        return f"{self.sha256}.{self.ext}"


def _kb(size: int) -> str:
    return f"{size / 1024:.0f} KB"


def _mb(size: int) -> str:
    return f"{size / 1024 / 1024:.1f} MB"


_TOO_MANY_PIXELS = f"最多约 {UPLOAD_MAX_PIXELS // 10_000} 万像素（例如 5600×2800）"


def prepare_image(data: bytes) -> tuple[ImageInfo, bytes]:
    """管理员传的原图 -> 发给玩家的 WebP。返回 (信息, 转好的字节)。

    同步、吃 CPU：调用方放进线程（asyncio.to_thread），别卡住事件循环 ——
    这个进程同时在跑所有在线玩家的 WebSocket。
    """
    if len(data) > UPLOAD_MAX_BYTES:
        raise ImageRejected(f"原图太大：{_mb(len(data))}，上限 {_mb(UPLOAD_MAX_BYTES)}")
    if data.startswith((b"GIF87a", b"GIF89a")):
        raise ImageRejected("GIF 不支持（手机上显示不了动图），请用 PNG、JPG 或 WebP")
    try:
        with warnings.catch_warnings():
            # 像素多到 Pillow 自己都要警告的图（解压炸弹）直接当错误，不给它解码的机会。
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            # 🔴 formats 必须限死。不限的话 Pillow 会挨个试所有格式的解码器，
            # 其中 EPS 会去调系统里的 Ghostscript —— 那是打开不可信文件的经典漏洞入口。
            source = Image.open(io.BytesIO(data), formats=UPLOAD_FORMATS)
    except (Image.DecompressionBombWarning, Image.DecompressionBombError):
        raise ImageRejected(f"图片像素太多，{_TOO_MANY_PIXELS}") from None
    except UnidentifiedImageError:
        raise ImageRejected("不是 PNG、JPG 或 WebP 图片") from None
    except (OSError, SyntaxError, ValueError):
        raise ImageRejected("图片文件损坏，读不出来") from None

    with source:
        width, height = source.size
        if width * height > UPLOAD_MAX_PIXELS:
            raise ImageRejected(f"图片像素太多：{width}×{height}，{_TOO_MANY_PIXELS}")
        if min(width, height) < IMAGE_MIN_SIDE:
            raise ImageRejected(f"图片太小：{width}×{height}")
        # 只看 PNG / WebP 的动图。有些手机拍的 JPG 是「多张图打包」（MPO），
        # Pillow 也会说它有多帧，但那是正常照片，取第一张就对了。
        if source.format in ("PNG", "WEBP") and getattr(source, "is_animated", False):
            raise ImageRejected("动图不支持（手机上只会显示成静态图），请用静态的 PNG、JPG 或 WebP")
        try:
            # 手机拍的照片常把「横竖」写在 EXIF 里而不是真的转像素；不处理的话发出去是躺着的。
            image = ImageOps.exif_transpose(source)
            has_alpha = image.mode in ("RGBA", "LA", "PA") or (
                image.mode == "P" and "transparency" in image.info)
            image = image.convert("RGBA" if has_alpha else "RGB")
        except (OSError, SyntaxError):
            raise ImageRejected("图片文件损坏，读不出来") from None
        except ValueError:
            raise ImageRejected("图片的颜色格式不支持（例如 16 位 PNG），请另存为普通的 PNG 或 JPG") from None

    if max(image.size) > IMAGE_MAX_SIDE:
        image.thumbnail((IMAGE_MAX_SIDE, IMAGE_MAX_SIDE), Image.Resampling.LANCZOS)
    out_width, out_height = image.size
    if min(out_width, out_height) < IMAGE_MIN_SIDE:
        raise ImageRejected(
            f"图片太扁：{width}×{height} 缩到长边 {IMAGE_MAX_SIDE} 后只剩 {out_width}×{out_height}")

    encoded = b""
    for quality in WEBP_QUALITIES:
        buffer = io.BytesIO()
        image.save(buffer, format="WEBP", quality=quality, method=4)
        encoded = buffer.getvalue()
        if len(encoded) <= IMAGE_MAX_BYTES:
            break
    else:
        raise ImageRejected(
            f"转成 WebP 后仍超过 {_kb(IMAGE_MAX_BYTES)}（{_kb(len(encoded))}），"
            "请换一张细节少一点或尺寸小一点的图")
    return ImageInfo("webp", out_width, out_height, hashlib.sha256(encoded).hexdigest(), len(encoded)), encoded


def is_valid_image_path(path: str) -> bool:
    return (
        0 < len(path) <= IMAGE_PATH_MAX
        and _IMAGE_PATH_RE.fullmatch(path) is not None
        and all(segment not in (".", "..") for segment in path.split("/"))
    )


class StorageFetcher:
    """按**公开地址**从 Supabase Storage 取原图，不带任何密钥。

    桶设成公开就不需要密钥；secret key 只该出现在绕过 RLS 的数据库操作里
    （supabase_auth.py 顶部同一条）。玩家拿不到这个地址 —— 手机从来不连 Supabase。
    """

    def __init__(
        self,
        base_url: str,
        bucket: str,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._base = base_url.rstrip("/")
        self._bucket = bucket.strip()
        self._transport = transport
        self._client: httpx.AsyncClient | None = None

    @property
    def configured(self) -> bool:
        return bool(self._base and self._bucket)

    def url_for(self, path: str) -> str:
        return (f"{self._base}/storage/v1/object/public/"
                f"{quote(self._bucket, safe='')}/{quote(path, safe='/')}")

    async def __call__(self, path: str) -> bytes:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=IMAGE_FETCH_TIMEOUT_SEC, transport=self._transport)
        try:
            async with self._client.stream("GET", self.url_for(path)) as resp:
                if resp.status_code in (400, 404):
                    # Storage 对「桶不公开」和「没有这个文件」都回 400 / 404，分不开，一起说。
                    raise ImageRejected(
                        f"Storage 的 {self._bucket} 桶里找不到 {path}"
                        "（桶要设成公开；文件名区分大小写）")
                if resp.status_code != 200:
                    raise ImageRejected(f"取图失败：Storage 返回 HTTP {resp.status_code}")
                chunks: list[bytes] = []
                total = 0
                async for chunk in resp.aiter_bytes():
                    total += len(chunk)
                    # 边收边数。先收完再判的话，一个误传的视频会被完整读进内存。
                    if total > UPLOAD_MAX_BYTES:
                        raise ImageRejected(f"原图太大：超过 {_mb(UPLOAD_MAX_BYTES)}")
                    chunks.append(chunk)
                return b"".join(chunks)
        except httpx.HTTPError as exc:
            raise ImageRejected(f"取图失败：连不上 Storage（{type(exc).__name__}）") from None

    async def aclose(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None


# --- 行与可见性 -----------------------------------------------------------------


@dataclass(frozen=True)
class Row:
    """announcements 表的一行。字段名与列名一一对应（load_rows 直接 Row(**record)）。"""

    announcement_id: int
    kind: str
    status: str
    title_zh: str
    body_zh: str
    title_en: str
    body_en: str
    image: str
    popup: bool
    sort_order: int
    starts_at: dt.datetime
    ends_at: dt.datetime | None
    revision: int
    preview_codes: str
    problem: str


@dataclass(frozen=True)
class Entry:
    row: Row
    image: ImageInfo | None
    # 这一轮算出来的问题。与 row.problem（库里现在的值）不同时写回。
    problem: str
    preview_codes: frozenset[str]


def parse_preview_codes(text: str) -> tuple[frozenset[str], list[str]]:
    """返回 (合法的好友码, 认不出的原文)。认不出的会写进 problem，不静默丢掉。"""
    good: set[str] = set()
    bad: list[str] = []
    for raw in _CODE_SPLIT_RE.split(text or ""):
        code = raw.strip().upper()
        if not code:
            continue
        if _FRIEND_CODE_RE.fullmatch(code):
            good.add(code)
        else:
            bad.append(raw.strip())
    return frozenset(good), bad


def is_live(row: Row, now: dt.datetime) -> bool:
    """普通玩家看得到：已发布、已开始、没结束。"""
    return (row.status == STATUS_PUBLISHED
            and row.starts_at <= now
            and (row.ends_at is None or row.ends_at > now))


def is_previewable(row: Row, now: dt.datetime) -> bool:
    """预览账号额外看得到：草稿、还没开始的。撤下的、已结束的谁都看不到。"""
    return row.status != STATUS_WITHDRAWN and (row.ends_at is None or row.ends_at > now)


def _sort_key(row: Row) -> tuple[int, float, int]:
    return -row.sort_order, -row.starts_at.timestamp(), -row.announcement_id


def push_message(row: Row) -> dict:
    """只推标题。正文、图片等玩家点进公告栏时再拉 —— 推送里带全文会让 1000 条消息都变大。"""
    return {
        "t": PUSH_TYPE,
        "id": row.announcement_id,
        "revision": row.revision,
        "title_zh": row.title_zh,
        "title_en": row.title_en,
    }


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


# --- 快照 -----------------------------------------------------------------------

LoadRows = Callable[[], Awaitable[list[Row]]]
FetchImage = Callable[[str], Awaitable[bytes]]
WriteProblems = Callable[[list[tuple[int, str]]], Awaitable[None]]
Broadcast = Callable[[dict], Awaitable[int]]


class Board:
    """公告快照 + 图片 + 推送。进程内单例，见 `install()` / `current()`。

    读表、取图、写回、推送全部注入：测试不连数据库、不连 Supabase、不起 WebSocket。
    """

    def __init__(
        self,
        *,
        load_rows: LoadRows,
        fetch_image: FetchImage,
        write_problems: WriteProblems,
        broadcast: Broadcast,
        media_dir: str = "",
        storage_configured: bool = True,
        now: Callable[[], dt.datetime] = _utc_now,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._load_rows = load_rows
        self._fetch_image = fetch_image
        self._write_problems = write_problems
        self._broadcast = broadcast
        self._media_dir = Path(media_dir) if media_dir.strip() else None
        self._storage_configured = storage_configured
        self._now = now
        self._clock = clock
        self._entries: list[Entry] = []
        self._loaded = False
        # 路径 -> 已转好的图。**只在第一次见到这个路径时取**，理由见文件头「文件名 = 转出来那份的 SHA-256」。
        self._images: dict[str, ImageInfo] = {}
        # 路径 -> (失败时刻, 原因)。IMAGE_RETRY_SEC 之内不再去打 Storage。
        self._image_failures: dict[str, tuple[float, str]] = {}
        # 上一轮可见的紧急公告 (id, revision)。
        self._pushed: set[tuple[int, int]] = set()
        self._next_sweep = clock() + MEDIA_SWEEP_SEC

    @classmethod
    def for_production(cls, fetcher: StorageFetcher, *, media_dir: str) -> Board:
        return cls(
            load_rows=load_rows,
            fetch_image=fetcher,
            write_problems=write_problems,
            broadcast=hub_broadcast,
            media_dir=media_dir,
            storage_configured=fetcher.configured,
        )

    # --- 刷新 -----------------------------------------------------------------

    async def refresh(self) -> None:
        rows = await self._load_rows()
        now = self._now()
        entries = [await self._entry(row) for row in rows]
        self._entries = entries
        first = not self._loaded
        self._loaded = True

        changes = [(e.row.announcement_id, e.problem) for e in entries if e.problem != e.row.problem]
        if changes:
            try:
                await self._write_problems(changes)
            except (asyncpg.PostgresError, OSError):
                # 写不回去只影响管理员看不到原因，玩家那边照常。下一轮会再试。
                log.warning("公告问题写回失败，下一轮再试", exc_info=True)

        await self._push_new_urgent(now, first)

        if self._clock() >= self._next_sweep:
            self._next_sweep = self._clock() + MEDIA_SWEEP_SEC
            self.sweep_media()

    async def _entry(self, row: Row) -> Entry:
        codes, bad_codes = parse_preview_codes(row.preview_codes)
        problems: list[str] = []
        image: ImageInfo | None = None
        if row.image:
            image, image_problem = await self._image_for(row.image)
            if image_problem:
                problems.append(image_problem)
        if bad_codes:
            problems.append("预览好友码格式不对：" + "、".join(bad_codes))
        return Entry(row, image, "；".join(problems), codes)

    async def _image_for(self, path: str) -> tuple[ImageInfo | None, str]:
        cached = self._images.get(path)
        if cached is not None:
            return cached, ""
        if self._media_dir is None:
            return None, "服务器没配置图片目录（GLORY_MEDIA_DIR），这条的图片不会显示"
        if not self._storage_configured:
            return None, "服务器没配置 GLORY_SUPABASE_URL，取不到图片"
        if not is_valid_image_path(path):
            return None, f"图片文件名 {path} 不合规：只能用英文字母、数字、. _ - 和 /"
        failed = self._image_failures.get(path)
        if failed is not None and self._clock() - failed[0] < IMAGE_RETRY_SEC:
            return None, failed[1]
        try:
            data = await self._fetch_image(path)
            # 解码、缩放、编码都吃 CPU（一张两三百毫秒）：放进线程，
            # 别让所有人的 WebSocket 心跳和接口请求排队等它。
            info, encoded = await asyncio.to_thread(prepare_image, data)
            self._store(info, encoded)
        except ImageRejected as exc:
            return None, self._remember_failure(path, str(exc))
        except OSError as exc:
            return None, self._remember_failure(
                path, f"服务器写不进图片目录（{exc.strerror or type(exc).__name__}）")
        self._image_failures.pop(path, None)
        self._images[path] = info
        log.info("公告图片就绪 %s（原图 %s）-> %s（%d×%d，%s）",
                 path, _kb(len(data)), info.filename, info.width, info.height, _kb(info.size))
        return info, ""

    def _remember_failure(self, path: str, reason: str) -> str:
        message = (f"图片 {path}：{reason}"
                   f"（修好后 {IMAGE_RETRY_SEC / 60:.0f} 分钟内自动重试；换个文件名会立刻重试）")
        self._image_failures[path] = (self._clock(), message)
        log.info("公告图片不可用 %s", message)
        return message

    def _store(self, info: ImageInfo, data: bytes) -> None:
        assert self._media_dir is not None
        target = self._media_dir / info.filename
        if target.is_file():
            return
        self._media_dir.mkdir(parents=True, exist_ok=True)
        # 先写临时文件再改名：Caddy 随时可能来读，不能让它读到半截图。
        tmp = self._media_dir / f".{info.filename}.tmp"
        tmp.write_bytes(data)
        os.replace(tmp, target)

    async def _push_new_urgent(self, now: dt.datetime, first: bool) -> None:
        live = {
            (e.row.announcement_id, e.row.revision): e.row
            for e in self._entries
            if e.row.kind == KIND_URGENT and is_live(e.row, now)
        }
        fresh = [row for key, row in live.items() if key not in self._pushed]
        self._pushed = set(live)
        if first:
            return
        for row in fresh:
            sent = await self._broadcast(push_message(row))
            log.info("紧急公告已推送 id=%d revision=%d 送达连接=%d",
                     row.announcement_id, row.revision, sent)

    def sweep_media(self) -> int:
        """删掉不再被引用、并且 MEDIA_KEEP_UNUSED_SEC 没用过的图。返回删了几个。"""
        if self._media_dir is None or not self._media_dir.is_dir():
            return 0
        referenced = {e.image.filename for e in self._entries if e.image is not None}
        cutoff = time.time() - MEDIA_KEEP_UNUSED_SEC
        removed = 0
        for path in self._media_dir.iterdir():
            name = path.name
            try:
                if name in referenced:
                    # 仍在用：刷新修改时间，下线之后从这一刻起算保留期。
                    os.utime(path)
                    continue
                ours = MEDIA_NAME_RE.fullmatch(name) is not None or (
                    name.startswith(".") and name.endswith(".tmp"))
                if ours and path.stat().st_mtime < cutoff:
                    path.unlink()
                    removed += 1
            except OSError:
                log.warning("清理公告图片 %s 失败", name, exc_info=True)
        # 已经不在任何公告里的路径从内存里忘掉：重新发布时再取一次，不会指向已删掉的文件。
        in_use = {e.row.image for e in self._entries if e.row.image}
        for stale in [p for p in self._images if p not in in_use]:
            del self._images[stale]
        if removed:
            log.info("清理了 %d 张不再使用的公告图片", removed)
        return removed

    # --- 读 -------------------------------------------------------------------

    def now(self) -> dt.datetime:
        return self._now()

    def needs_identity(self) -> bool:
        """有没有公告设了预览好友码。没有的话接口不用查「你是谁」，省一次数据库。"""
        return any(e.preview_codes for e in self._entries)

    def view_for(self, friend_code: str | None) -> list[tuple[Entry, bool]]:
        """这个人看得到的公告，排好序。第二项 = 是不是只因为预览才看得到。"""
        now = self._now()
        out: list[tuple[Entry, bool]] = []
        for entry in self._entries:
            if is_live(entry.row, now):
                out.append((entry, False))
            elif friend_code and friend_code in entry.preview_codes and is_previewable(entry.row, now):
                out.append((entry, True))
        out.sort(key=lambda item: _sort_key(item[0].row))
        return out


# --- 数据库 ---------------------------------------------------------------------

_SELECT_ROWS = """
select announcement_id, kind, status, title_zh, body_zh, title_en, body_en, image, popup,
       sort_order, starts_at, ends_at, revision, preview_codes, problem
from announcements
where status <> 'withdrawn' and (ends_at is null or ends_at > now())
order by sort_order desc, starts_at desc, announcement_id desc
limit $1
"""

# `is distinct from`：值没变就不写。管理员正开着表格时，服务器每 30 秒改一次同一个格子会很烦。
_UPDATE_PROBLEM = """
update announcements set problem = $2
where announcement_id = $1 and problem is distinct from $2
"""


async def load_rows() -> list[Row]:
    async with db.pool().acquire() as conn:
        records = await conn.fetch(_SELECT_ROWS, MAX_ROWS)
    return [Row(**dict(record)) for record in records]


async def write_problems(changes: list[tuple[int, str]]) -> None:
    async with db.pool().acquire() as conn:
        await conn.executemany(_UPDATE_PROBLEM, changes)


async def hub_broadcast(payload: dict) -> int:
    """**每次现取 hub()** —— 测试会换掉它。同 admission.hub_send。"""
    return await realtime.hub().broadcast(payload)


# --- 单例与后台任务 -------------------------------------------------------------

_board: Board | None = None


async def _no_rows() -> list[Row]:
    return []


async def _no_image(_path: str) -> bytes:
    raise ImageRejected("没有接上图片来源")


async def _no_write(_changes: list[tuple[int, str]]) -> None:
    return None


async def _no_broadcast(_payload: dict) -> int:
    return 0


def install(board: Board) -> Board:
    """由 lifespan 调。"""
    global _board
    _board = board
    return board


def current() -> Board:
    global _board
    if _board is None:
        # 没经过 lifespan 时的兜底（不该发生在生产上）：一张空公告板。
        _board = Board(load_rows=_no_rows, fetch_image=_no_image,
                       write_problems=_no_write, broadcast=_no_broadcast)
    return _board


def reset() -> None:
    """只给测试用。"""
    global _board
    _board = None


async def loop(target: Board) -> None:
    """由 lifespan 起、由它取消。

    **先干再睡**（与 maintenance.loop 相反）：刚重启时玩家马上就会来拉列表，
    等 30 秒才有第一份快照的话，这段时间里所有人看到的都是空公告栏。
    """
    try:
        while True:
            if db.is_connected():
                try:
                    await target.refresh()
                except Exception:
                    # 同 realtime.sweep_loop：刷新自己出错不能把循环带走 ——
                    # 那样公告永远停在上一份，而且没有任何症状。
                    log.exception("刷新公告出错，下一轮再试")
            await asyncio.sleep(REFRESH_SEC)
    except asyncio.CancelledError:
        raise
