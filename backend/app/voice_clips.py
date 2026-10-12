"""语音消息的音频文件（database/033_voice_clips.sql）。

    手机/电脑 ──上传 16 kHz 单声道 WAV──> 这里 ──转成 Ogg Vorbis──> GLORY_MEDIA_DIR
    手机/电脑 <──GET /media/<sha256>.ogg── Caddy 直接给文件（deploy/Caddyfile）

三个聊天渠道（私聊、世界频道、房间与对局内）走三条不同的投递路，但**音频文件都先过这里**，
之后传来传去的只是 clip_id 加秒数。战斗服务器一个字节的音频都不碰。

## 为什么客户端传的是没压缩的 WAV，而不是直接传压缩格式

Godot 能**放** Ogg Vorbis（`AudioStreamOggVorbis.load_from_buffer`，2026-10-11 在 4.7.1 上验过），
但**压不了**它 —— 引擎没有编码器。所以只有两个选择：传大文件让服务端压，或者上线一个
自己写的编码器。后者要动三个平台的原生桥接（安卓 AAR / Windows dll / iOS），
而这个项目 09-29 刚因为「改了桥接没重编」坏过一次。

传 WAV 的代价是上行流量：30 秒 ≈ 960 KB。收的那一方只下 Ogg（≈ 90 KB），
所以**代价只落在说话的人身上，而且只有一次**。

## 🔴 服务端必须重新编码，不能原样存

与公告图片一律转 WebP 是同一条理由（app/announcements.py）：

  1. 存进来的字节是玩家给的。原样存 = 别人能拿这台服务器当免费网盘，
     或者塞一个能让播放器出问题的文件给队友
  2. 重新编码之后，落盘的东西只可能是我们自己编码器的输出

所以 ffmpeg 不在就**拒收**（fail closed），不会退化成「那就原样存吧」。

## 保留期与举报

保留期按渠道分（私聊 30 天、世界频道与对局 7 天），**被举报的不清理** ——
`hold_until` 往后推，清理任务跳过。没有这一条的话，处理举报的人点开会发现文件已经被定时任务删了。

文件按内容哈希命名，所以**同一段音频被两个人发就是同一个文件**，而登记行各自一份。
直接后果：删行不能顺手删文件，要等到没有任何行引用它（见 `sweep`）。
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import shutil
import struct
import uuid
from dataclasses import dataclass
from pathlib import Path

from app import db

log = logging.getLogger("glory.voice_clips")

# 与客户端 VoiceClipService.MAX_SECONDS、database/033 的 check 约束一致
# （tools/voice_clip_check 钉着）。用户 2026-10-11 定的 30 秒，三个渠道一样。
MAX_SECONDS = 30.0
# 低于这个就是误触（点一下就松手），直接拒，省得聊天里刷一排 0 秒语音。
MIN_SECONDS = 0.6

# 客户端录 16 kHz 单声道 16 位：30 秒 = 960044 字节。留余量，但不留到能塞别的东西。
MAX_UPLOAD_BYTES = 1_400_000
# 允许的采样率。客户端固定发 16 kHz，这里放宽几档只是为了不让一次采样率调整
# 变成「服务端也要改」——但不接受任意值：越界的直接拒。
ALLOWED_RATES = (8000, 12000, 16000, 22050, 24000, 44100, 48000)

# 转码后的目标。单声道 24 kbps 的 Vorbis 对语音够用，30 秒约 90 KB。
TARGET_BITRATE = "24k"
FFMPEG_TIMEOUT_SEC = 20.0

# 配额。两层：一天的总量防刷屏，一分钟的突发防「按住不放连发」。
# 按 player_id 计，不按 IP —— 手机运营商 NAT 下同一个出口 IP 是成片的正常玩家
# （同 app/rate_limit.py 顶部那条）。
PER_DAY = 80
PER_MINUTE = 6

RETENTION_DAYS = {"private": 30, "world": 7, "match": 7}
SCOPES = tuple(RETENTION_DAYS)
# 被举报之后至少留这么久，够人工听完并处理。
REPORT_HOLD_DAYS = 60

# 清理任务多久跑一次。过期判定本来就是按天的，不用扫得勤。
SWEEP_INTERVAL_SEC = 3600.0


def body_text(seconds: float) -> str:
    """语音消息落库时的 body。**服务端写，不采用客户端传的**（见 chat.VOICE_KIND）。

    旧版本的包不认识 voice 这个类型，但会把 body 显示出来 —— 于是它们看到
    「[语音 12″]」而不是一条空白消息。新客户端拿 payload 画语音条，不读这段。
    """
    return "[语音 %d″]" % max(1, round(seconds))


# payload 里为什么连文件名一起带：收消息的人要拿它去 /media 下载。
# 只给 clip_id 的话，每条语音都要多一次「用编号换文件名」的往返 —— 一个聊天界面
# 滚动一屏就是十几次。文件名是内容哈希，猜不到，发给看得到这条消息的人没有多余暴露。
PAYLOAD_KEYS = ("clip_id", "media", "seconds")


class ClipRejected(Exception):
    """拒收。code 给日志与客户端分支，message 给玩家看（同 text_guard.TextRejected）。"""

    def __init__(self, code: str, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


@dataclass(frozen=True)
class Clip:
    clip_id: uuid.UUID
    media_name: str
    seconds: float
    bytes: int


# --- WAV 解析 -----------------------------------------------------------------


def parse_wav(data: bytes) -> tuple[int, float]:
    """校验是不是我们认的那种 WAV，返回（采样率，秒数）。

    **自己先解一遍再交给 ffmpeg**，不是多此一举：ffmpeg 什么都吃，
    包括一堆我们根本不想支持的容器与编码。先把输入收敛到「16 位 PCM、单声道」，
    ffmpeg 那边的攻击面就只剩这一种形状。

    秒数也在这里算 —— **不信客户端报的时长**。它决定配额、保留期与界面上显示的长度。
    """
    if len(data) < 44:
        raise ClipRejected("too_short", "录音太短了")
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ClipRejected("not_wav", "音频格式不对")

    fmt_found = False
    channels = 0
    rate = 0
    bits = 0
    data_size = 0
    offset = 12
    # 逐块走，不假设 fmt 和 data 紧挨着：有些录音器会插 LIST / fact。
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset + 4]
        (chunk_size,) = struct.unpack_from("<I", data, offset + 4)
        body = offset + 8
        if chunk_size > len(data) - body:
            raise ClipRejected("bad_wav", "音频文件不完整")
        if chunk_id == b"fmt ":
            if chunk_size < 16:
                raise ClipRejected("bad_wav", "音频格式不对")
            audio_format, channels, rate, _byte_rate, _align, bits = struct.unpack_from(
                "<HHIIHH", data, body)
            if audio_format != 1:
                raise ClipRejected("not_pcm", "音频格式不对（只收未压缩的录音）")
            fmt_found = True
        elif chunk_id == b"data":
            data_size = chunk_size
        offset = body + chunk_size + (chunk_size & 1)  # 块按偶数字节对齐

    if not fmt_found or data_size <= 0:
        raise ClipRejected("bad_wav", "音频文件不完整")
    if channels != 1:
        raise ClipRejected("not_mono", "音频格式不对（只收单声道）")
    if bits != 16:
        raise ClipRejected("not_16bit", "音频格式不对")
    if rate not in ALLOWED_RATES:
        raise ClipRejected("bad_rate", "音频格式不对")

    seconds = data_size / float(rate * 2)
    if seconds < MIN_SECONDS:
        raise ClipRejected("too_short", "说得太短了，按住多说一会儿")
    if seconds > MAX_SECONDS + 0.5:
        # 客户端自己会在 30 秒停，这里是最后一道：+0.5 容掉一帧的误差。
        raise ClipRejected("too_long", "语音最长 %d 秒" % int(MAX_SECONDS))
    return rate, round(min(seconds, MAX_SECONDS), 1)


# --- 转码 ---------------------------------------------------------------------


def ffmpeg_path() -> str:
    return shutil.which("ffmpeg") or ""


async def encode_ogg(wav: bytes) -> bytes:
    """WAV -> Ogg Vorbis（单声道）。ffmpeg 不在或失败一律抛，**不回退成原样存**。"""
    binary = ffmpeg_path()
    if not binary:
        # 部署漏装时要一眼看懂，而不是让玩家收到一句「发送失败」。
        log.error("服务器没装 ffmpeg，语音消息收不了（apt-get install ffmpeg）")
        raise ClipRejected("transcode_unavailable", "服务器暂时处理不了语音，请稍后再试", status=503)
    process = await asyncio.create_subprocess_exec(
        binary, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "wav", "-i", "pipe:0",
        "-vn", "-ac", "1", "-c:a", "libvorbis", "-b:a", TARGET_BITRATE,
        "-f", "ogg", "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(process.communicate(wav), FFMPEG_TIMEOUT_SEC)
    except TimeoutError:
        process.kill()
        await process.wait()
        log.error("ffmpeg 转码超时（%.0f 秒）", FFMPEG_TIMEOUT_SEC)
        raise ClipRejected("transcode_timeout", "语音处理超时，请重试", status=503) from None
    if process.returncode != 0 or not out:
        log.error("ffmpeg 失败 rc=%s err=%s", process.returncode, err[-400:].decode("utf-8", "replace"))
        raise ClipRejected("transcode_failed", "这段录音处理不了，请重录")
    return out


# --- 上传 ---------------------------------------------------------------------


async def _quota_used(player_id: uuid.UUID) -> tuple[int, int]:
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            """
            select
              count(*) filter (where created_at > now() - interval '1 day')   as day_count,
              count(*) filter (where created_at > now() - interval '1 minute') as minute_count
            from voice_clips
            where uploader_id = $1 and created_at > now() - interval '1 day'
            """,
            player_id,
        )
    return int(row["day_count"]), int(row["minute_count"])


def _write_media(media_dir: Path, media_name: str, payload: bytes) -> None:
    """落盘。文件名是内容哈希，所以已经在就不用再写。

    先写临时文件再 rename：半个文件被 Caddy 发出去，表现是「别人点开听到一半没了」，
    而且那个文件会一直留着（名字对、内容不全），下次同样内容的上传还会命中它。
    """
    target = media_dir / media_name
    if target.exists():
        return
    media_dir.mkdir(parents=True, exist_ok=True)
    tmp = media_dir / f".{media_name}.{os.getpid()}.tmp"
    tmp.write_bytes(payload)
    os.replace(tmp, target)


async def upload(player_id: uuid.UUID, scope: str, wav: bytes, media_dir: str) -> Clip:
    """收一段录音，返回登记好的 clip。调用方只拿 clip_id 往消息里塞。"""
    if scope not in SCOPES:
        raise ClipRejected("bad_scope", "语音来源不对")
    if not media_dir.strip():
        log.error("没配 GLORY_MEDIA_DIR，语音消息收不了")
        raise ClipRejected("media_unavailable", "服务器暂时处理不了语音，请稍后再试", status=503)
    if len(wav) > MAX_UPLOAD_BYTES:
        raise ClipRejected("too_large", "录音太大了，请重录")

    day_count, minute_count = await _quota_used(player_id)
    if minute_count >= PER_MINUTE:
        raise ClipRejected("too_fast", "语音发得太快了，歇一下", status=429)
    if day_count >= PER_DAY:
        raise ClipRejected("daily_limit", "今天的语音条数用完了，明天再来", status=429)

    _rate, seconds = parse_wav(wav)
    ogg = await encode_ogg(wav)
    media_name = hashlib.sha256(ogg).hexdigest() + ".ogg"
    _write_media(Path(media_dir), media_name, ogg)

    clip_id = uuid.uuid4()
    async with db.pool().acquire() as conn:
        await conn.execute(
            """
            insert into voice_clips (clip_id, media_name, uploader_id, seconds, bytes, scope, expires_at)
            values ($1, $2, $3, $4, $5, $6, now() + ($7 || ' days')::interval)
            """,
            clip_id, media_name, player_id, seconds, len(ogg), scope, str(RETENTION_DAYS[scope]),
        )
    log.info("语音入库 clip=%s scope=%s %.1f秒 %d字节", clip_id, scope, seconds, len(ogg))
    return Clip(clip_id=clip_id, media_name=media_name, seconds=seconds, bytes=len(ogg))


# --- 查、举报、清理 -------------------------------------------------------------


@dataclass(frozen=True)
class ClipRow:
    clip_id: uuid.UUID
    media_name: str
    uploader_id: uuid.UUID
    seconds: float
    scope: str


async def get(clip_id: uuid.UUID) -> ClipRow | None:
    async with db.pool().acquire() as conn:
        row = await conn.fetchrow(
            "select clip_id, media_name, uploader_id, seconds, scope from voice_clips where clip_id = $1",
            clip_id,
        )
    if row is None:
        return None
    return ClipRow(
        clip_id=row["clip_id"],
        media_name=row["media_name"],
        uploader_id=row["uploader_id"],
        seconds=float(row["seconds"]),
        scope=str(row["scope"]),
    )


async def require_own_clip(player_id: uuid.UUID, clip_id: uuid.UUID, scope: str) -> ClipRow:
    """发消息时核对：这个 clip 是不是他自己刚传的、渠道对不对。

    不核对的话，任何人都能拿别人的 clip_id 发一条「自己的」语音 —— 编号是 uuid，
    猜不到，但它会出现在对方的聊天记录里，转手就能被引用。
    """
    row = await get(clip_id)
    if row is None:
        raise ClipRejected("clip_missing", "这段语音已经过期了，请重录")
    if row.uploader_id != player_id:
        raise ClipRejected("clip_not_mine", "这段语音不是你的", status=403)
    if row.scope != scope:
        raise ClipRejected("clip_wrong_scope", "这段语音不能发到这里")
    return row


async def hold_for_report(clip_id: uuid.UUID) -> None:
    """被举报：推迟清理。已经推得更久的不往回缩（greatest）。"""
    async with db.pool().acquire() as conn:
        await conn.execute(
            """
            update voice_clips
               set hold_until = greatest(coalesce(hold_until, now()), now() + ($2 || ' days')::interval)
             where clip_id = $1
            """,
            clip_id, str(REPORT_HOLD_DAYS),
        )


async def sweep(media_dir: str) -> tuple[int, int]:
    """清过期的登记行，再删没人引用的文件。返回（删了几行，删了几个文件）。

    顺序不能反：先删行再看引用。反过来的话，两次清理之间新插进来的行会指向
    一个刚被删掉的文件 —— 玩家点开是「这段语音已经没有了」，而数据库里看着一切正常。
    """
    async with db.pool().acquire() as conn:
        removed = await conn.fetch(
            """
            delete from voice_clips
             where expires_at < now()
               and (hold_until is null or hold_until < now())
            returning media_name
            """
        )
        if not removed:
            return 0, 0
        names = {str(row["media_name"]) for row in removed}
        still_used = await conn.fetch(
            "select distinct media_name from voice_clips where media_name = any($1::text[])",
            list(names),
        )
    orphans = names - {str(row["media_name"]) for row in still_used}
    deleted_files = 0
    base = Path(media_dir) if media_dir.strip() else None
    if base is not None:
        for name in orphans:
            try:
                (base / name).unlink(missing_ok=True)
                deleted_files += 1
            except OSError:
                # 删不掉一个文件不该让整轮清理停下 —— 下一轮还会再试。
                log.warning("删语音文件失败 %s", name, exc_info=True)
    log.info("语音清理：行 %d、文件 %d", len(removed), deleted_files)
    return len(removed), deleted_files


async def sweep_loop(media_dir: str) -> None:
    """后台清理任务。由 lifespan 起、由它取消（同 realtime.sweep_loop）。"""
    try:
        while True:
            await asyncio.sleep(SWEEP_INTERVAL_SEC)
            try:
                await sweep(media_dir)
            except Exception:
                # 自己出错不能把循环带走：那样文件只增不减，而且没有任何症状。
                log.exception("语音清理出错，继续下一轮")
    except asyncio.CancelledError:
        raise
