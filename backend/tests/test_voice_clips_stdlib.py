"""语音留言（app/voice_clips.py，database/033_voice_clips.sql）里不连数据库也能验的那几条。

## 为什么挑这几条

语音这条链上**失败不报错**的地方有三处，三处都在这里钉住：

1. **客户端写的 WAV 头和服务端的解析器对不上。** 症状是「录完发不出去」，
   而客户端只会说一句「语音发送失败」—— 头里哪个字段不对，日志里也看不出。
   这里把客户端那 44 字节头在 Python 里原样重建一遍喂给 `parse_wav`，
   并把同一份字节存进 `tools/fixtures/voice_clip_wav.json`：
   Godot 那边的 `tools/voice_clip_check.gd` 拿 `VoiceClipService.build_wav()` 跟它对账。
   两边读同一个文件，谁先漂谁红。

2. **秒数以服务端为准。** 它决定配额、保留期、界面上语音条的长度。
   客户端报的时长一律不采用（`parse_wav` 从 data 块大小算），所以这里验的是
   「同一段字节算出来的秒数」而不是「客户端说了多少」。

3. **三种语言里的那几个常量**：Python、GDScript、SQL 各写了一份
   MAX_SECONDS / MIN_SECONDS / 文件名形状。对不上的后果是客户端让你录 30 秒、
   服务端拒收 —— 玩家看到的还是那句「语音发送失败」。

## 证明不了什么

不碰数据库，所以配额、保留期清理、`require_own_clip` 的归属校验都不在这里
（那些要 `pg_harness.py` + `GLORY_TEST_PG`）。ffmpeg 转码也不在：它要真的装了 ffmpeg。
"""

from __future__ import annotations

import json
import math
import pathlib
import re
import struct

import pytest

from app import announcements, voice_clips

REPO = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = REPO / "tools" / "fixtures" / "voice_clip_wav.json"
GD_SERVICE = REPO / "scripts" / "autoload" / "VoiceClipService.gd"
GD_NETWORK = REPO / "scripts" / "autoload" / "NetworkService.gd"
MIGRATION = REPO / "database" / "033_voice_clips.sql"


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def _roundi(value: float) -> int:
    """Godot 的 roundi：半数远离零。Python 的 round() 是半数取偶，两者在 .5 上分叉。"""
    return int(math.floor(value + 0.5)) if value >= 0.0 else int(math.ceil(value - 0.5))


def build_wav(samples: list[float], rate: int) -> bytes:
    """和 VoiceClipService.build_wav 逐字段等价的那 44 字节头 + 16 位小端采样。

    刻意不用 `wave` 模块：那样验的是「标准库写的头标准库读得懂」，
    而要验的是**客户端写的那个头**服务端读得懂。
    """
    data = b"".join(
        struct.pack("<h", max(-32768, min(32767, _roundi(s * 32767.0)))) for s in samples)
    return b"".join([
        b"RIFF", struct.pack("<I", 36 + len(data)), b"WAVE",
        b"fmt ", struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16),
        b"data", struct.pack("<I", len(data)), data,
    ])


def test_fixture_header_matches_builder() -> None:
    """夹具里那 44 字节就是上面那个构造器出来的（Godot 那边照同一份字节对账）。"""
    fixture = _fixture()
    rebuilt = build_wav([0.0] * fixture["sample_count"], fixture["rate"])
    assert rebuilt[:44].hex() == fixture["silence_header_hex"], (
        "夹具和 build_wav 的头不一致。改了 WAV 头要同时重算夹具，"
        "否则 tools/voice_clip_check.gd 会按旧夹具判客户端")
    assert len(rebuilt) == 44 + fixture["sample_count"] * 2


def test_fixture_probes_match_builder() -> None:
    """采样编码的边界：超幅必须**夹住**而不是绕回（绕回的听感是一声爆响）。"""
    fixture = _fixture()
    assert build_wav(fixture["probe_inputs"], fixture["rate"])[44:].hex() == fixture["probe_hex"]


def test_server_accepts_client_wav() -> None:
    """客户端那个头，服务端解得开，而且秒数是服务端自己算的。"""
    fixture = _fixture()
    wav = build_wav([0.0] * fixture["sample_count"], fixture["rate"])
    rate, seconds = voice_clips.parse_wav(wav)
    assert rate == fixture["rate"]
    # data 块大小 / (采样率 × 2)，与客户端报的时长无关。
    assert seconds == pytest.approx(fixture["seconds"], abs=0.05)


@pytest.mark.parametrize(("name", "mangle"), [
    ("不是 RIFF", lambda b: b"RIFX" + b[4:]),
    ("不是 WAVE", lambda b: b[:8] + b"WAVF" + b[12:]),
    ("立体声", lambda b: b[:22] + struct.pack("<H", 2) + b[24:]),
    ("8 位", lambda b: b[:34] + struct.pack("<H", 8) + b[36:]),
    ("不认的采样率", lambda b: b[:24] + struct.pack("<I", 12345) + b[28:]),
    ("不是 PCM", lambda b: b[:20] + struct.pack("<H", 3) + b[22:]),
    ("data 块比文件长", lambda b: b[:40] + struct.pack("<I", len(b) * 4) + b[44:]),
    ("头都不全", lambda b: b[:20]),
])
def test_parse_wav_rejects(name: str, mangle) -> None:
    """每一种都必须是 ClipRejected，**不能是别的异常** ——
    别的异常冒到接口层就是 HTTP 500（组队邀请踩过，见 test_chat_kind_migration_stdlib）。"""
    fixture = _fixture()
    good = build_wav([0.0] * fixture["sample_count"], fixture["rate"])
    with pytest.raises(voice_clips.ClipRejected):
        voice_clips.parse_wav(mangle(good))


def test_parse_wav_rejects_too_long() -> None:
    """客户端会在 30 秒自己停，这里是最后一道门（改包的客户端不会停）。"""
    rate = 16000
    over = int((voice_clips.MAX_SECONDS + 2.0) * rate)
    wav = build_wav([0.0] * over, rate)
    with pytest.raises(voice_clips.ClipRejected) as caught:
        voice_clips.parse_wav(wav)
    assert caught.value.code == "too_long"


def test_parse_wav_rejects_too_short() -> None:
    wav = build_wav([0.0] * int(voice_clips.MIN_SECONDS * 16000 / 2), 16000)
    with pytest.raises(voice_clips.ClipRejected) as caught:
        voice_clips.parse_wav(wav)
    assert caught.value.code == "too_short"


def test_parse_wav_skips_unknown_chunks() -> None:
    """头里插一个 LIST 块照样解得开（注释里承诺过「不假设 fmt 和 data 紧挨着」）。"""
    rate = 16000
    samples = [0.1] * (rate * 3 // 4)        # 0.75 秒：过得了 MIN_SECONDS
    data = b"".join(struct.pack("<h", round(s * 32767.0)) for s in samples)
    extra = b"LIST" + struct.pack("<I", 4) + b"INFO"
    body = (b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
            + extra + b"data" + struct.pack("<I", len(data)) + data)
    wav = b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body
    assert voice_clips.parse_wav(wav)[0] == rate


def test_body_text_fits_world_constraint() -> None:
    """世界频道的 body 有长度约束（033 里 1–32 字），服务端写的占位必须塞得进去。

    塞不进去的后果是 insert 撞 check → asyncpg 异常 → HTTP 500，
    玩家看到「服务器出错了」。这正是 033 改约束前那一版的真实状态。
    """
    bound = re.search(r"kind = 'voice' and char_length\(body\) between (\d+) and (\d+)",
                      MIGRATION.read_text(encoding="utf-8"))
    assert bound is not None, "033 里世界频道那条 body 约束的写法变了，这条判据要跟着改"
    low, high = int(bound.group(1)), int(bound.group(2))
    for seconds in (voice_clips.MIN_SECONDS, 1.0, 9.9, voice_clips.MAX_SECONDS):
        text = voice_clips.body_text(seconds)
        assert low <= len(text) <= high, f"{seconds} 秒的占位「{text}」不满足 {low}–{high}"


def test_media_name_shape_matches_everywhere() -> None:
    """文件名形状在四处各写了一份：公告的正则、GDScript 两份、SQL 一份。

    对不上的后果是**客户端拒绝播自己能收到的文件**（或者反过来，
    让一个形状没卡死的名字被拼进 /media/<name> 这个 URL）。
    """
    name = "a" * 64 + ".ogg"
    assert announcements.MEDIA_NAME_RE.fullmatch(name), "公告那套不认 .ogg 了"

    for path in (GD_SERVICE, GD_NETWORK):
        src = path.read_text(encoding="utf-8")
        found = re.search(r'(?:MEDIA_PATTERN|VOICE_MEDIA_PATTERN) := "([^"]+)"', src)
        assert found is not None, f"{path.name} 里找不到文件名形状常量"
        pattern = found.group(1)
        assert re.fullmatch(pattern, name), f"{path.name} 的形状不认 {name}"
        assert not re.fullmatch(pattern, "../../etc/passwd"), (
            f"{path.name} 的形状放得过路径穿越 —— 它会被拼进 /media/<name>")

    sql = MIGRATION.read_text(encoding="utf-8")
    assert "[0-9a-f]{64}" in sql, "033 里 media_name 的 check 形状变了"


def test_client_constants_match_server() -> None:
    """GDScript 和 Python 的那几个数必须一样。

    不一样的方向都很难看：客户端上限大 → 录完被服务端拒（「语音发送失败」）；
    客户端上限小 → 玩家录不到承诺的 30 秒。采样率对不上 → 直接 bad_rate。
    """
    src = GD_SERVICE.read_text(encoding="utf-8")

    def gd_number(name: str) -> float:
        found = re.search(rf"^const {name} :?= ([0-9.]+)", src, re.M)
        assert found is not None, f"VoiceClipService.gd 里没有 {name}"
        return float(found.group(1))

    assert gd_number("MAX_SECONDS") == voice_clips.MAX_SECONDS
    assert gd_number("MIN_SECONDS") == voice_clips.MIN_SECONDS
    assert int(gd_number("SAMPLE_RATE")) in voice_clips.ALLOWED_RATES


def test_scopes_match_migration() -> None:
    """三个渠道名在 SQL 的 check、Python 的保留期表、GDScript 的常量里各一份。

    漏一个的后果：上传时 scope 对不上 → 403「这段语音不能发到这里」。
    """
    sql = MIGRATION.read_text(encoding="utf-8")
    allowed = set(re.findall(r"'(private|world|match)'", sql))
    assert allowed == {"private", "world", "match"}
    assert set(voice_clips.RETENTION_DAYS) == allowed

    src = GD_SERVICE.read_text(encoding="utf-8")
    gd_scopes = set(re.findall(r'^const SCOPE_\w+ :?= "(\w+)"', src, re.M))
    assert gd_scopes == allowed, f"GDScript 的渠道常量是 {gd_scopes}"
