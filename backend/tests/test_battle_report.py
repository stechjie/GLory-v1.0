"""战报（`docs/排位系统设计.md` 第七节）的账号服务器一侧。

同 test_loadout 的分工：**不连数据库**，用假连接。签名用真 RSA ——
验的就是「战斗服务器用私钥签出来的东西这边能不能验过」，替身在这里没有意义。

战斗服务器那一侧的门禁是 `tools/battle_report_check.tscn`（Godot）。
两边的接缝由本文件「跨语言约定」那一组钉住：**字段名和常量对不上时，
症状不是报错，而是所有战报被静默丢掉。**

最重要的几组，失败时都**不报错**：

  1. 先验签、再解析。反过来等于让没签过名的数据先进 JSON 解析器。
  2. 签过章 ≠ 内容对。战斗服务器也可能有 bug，`rounds=0` 直接写下去会撞
     数据库的 check 约束变成 500，而不是一条能看懂的日志。
  3. 幂等。六个人各交一份是设计如此，第二份起必须是 200 + recorded=false，
     不是 409 —— 客户端分不出「重复」和「失败」就会一直重试。
  4. 认不出的 player_id 写 null，不是让整局插不进去。对局结束到战报交上来
     之间有一段窗口，有人在这段里注销的话，整个事务会因为外键回滚 ——
     那就是一个人注销毁掉同局其他五个人的历史。

跑：
    backend\\.venv\\Scripts\\python.exe -m pytest backend/tests/test_battle_report.py -q -p no:cacheprovider
"""

from __future__ import annotations

import base64
import datetime as dt
import json
import pathlib
import re
import uuid
from dataclasses import dataclass

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from fastapi.testclient import TestClient

from app import battle_report, db, players
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import battle_report as report_routes
from app.routes import me as me_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
REPORT_GD = (REPO / "scripts" / "multiplayer" / "BattleReport.gd").read_text(encoding="utf-8")
SQL_013 = (REPO / "database" / "013_match_history.sql").read_text(encoding="utf-8")

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
PLAYER_B = uuid.UUID("22222222-2222-2222-2222-222222222222")
GONE = uuid.UUID("99999999-9999-9999-9999-999999999999")   # 已删号


# --- 密钥 ---------------------------------------------------------------------


@pytest.fixture
def report_key(tmp_path, monkeypatch: pytest.MonkeyPatch):
    """真 RSA 密钥对。返回**私钥**（这边扮演战斗服务器去签），公钥配给账号服务器。"""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    path = tmp_path / "report_pub.pem"
    path.write_bytes(
        key.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
        )
    )
    monkeypatch.setenv("GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE", str(path))
    get_settings.cache_clear()
    battle_report._key_cache = None
    yield key
    battle_report._key_cache = None
    get_settings.cache_clear()


def _sign(private_key, payload: dict) -> str:
    """照 BattleReport.gd 的 sign() 做：签 body 的字节，线格式是 base64.base64。"""
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sig = private_key.sign(body, padding.PKCS1v15(), hashes.SHA256())
    return "%s.%s" % (
        base64.b64encode(body).decode("ascii"),
        base64.b64encode(sig).decode("ascii"),
    )


def _payload(**over) -> dict:
    now = int(dt.datetime.now(dt.UTC).timestamp())
    seats = []
    for slot in range(6):
        seats.append({
            "slot": slot,
            "team": 0 if slot < 3 else 1,
            "pid": "" if slot == 5 else str(PLAYER_A if slot == 0 else PLAYER_B),
            "ai": slot == 5,
            "online": slot != 5,
            "ai_rounds": 3 if slot == 5 else 0,
            "gold": 137, "carrots": 12, "spent": 40,
            "board": [{"slot": 0, "id": "unit_dark_dragon", "star": 3, "merc": False}],
            "treasures": ["treasure_blood_pact"],
        })
    base = {
        "v": battle_report.REPORT_VERSION,
        "mid": "a" * 32,
        "mode": "custom",
        "proto": 31, "epoch": 2, "room": 123456,
        "start": now - 1500, "end": now - 10,
        "rounds": 21, "out": "team_a", "hp": [17, 0],
        "gold_auth": False, "carrot_auth": True,
        "seats": seats,
    }
    base.update(over)
    return base


# --- 验章 ---------------------------------------------------------------------


def test_signed_report_verifies(report_key) -> None:
    got = battle_report.verify(_sign(report_key, _payload()))
    assert got["match_uid"] == "a" * 32
    assert got["outcome"] == "team_a"
    assert len(got["seats"]) == 6


def test_tampered_body_is_rejected(report_key) -> None:
    """🔴 验的是那串字节本身。改一个字节就该整份拒掉。"""
    wire = _sign(report_key, _payload())
    body_b64, sig_b64 = wire.split(".")
    body = bytearray(base64.b64decode(body_b64))
    body[0] ^= 0x01
    tampered = "%s.%s" % (base64.b64encode(bytes(body)).decode("ascii"), sig_b64)
    with pytest.raises(battle_report.ReportRejected) as exc:
        battle_report.verify(tampered)
    assert exc.value.code in ("report_bad_signature", "report_malformed")


def test_another_key_cannot_sign_reports(report_key) -> None:
    """换一把私钥签的必须验不过 —— 否则谁都能给自己造历史。"""
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with pytest.raises(battle_report.ReportRejected) as exc:
        battle_report.verify(_sign(other, _payload()))
    assert exc.value.code == "report_bad_signature"


def test_uses_pkcs1v15_not_pss() -> None:
    """Godot 底下的 mbedtls 对 RSA 走 PKCS#1 v1.5（2026-09-22 用一次性探针实测）。
    这边换成 PSS 的话，战斗服务器签出来的每一份都会被拒，而且不报错。"""
    src = (REPO / "backend" / "app" / "battle_report.py").read_text(encoding="utf-8")
    assert "padding.PKCS1v15()" in src
    assert "PSS" not in src.split('"""', 2)[2]


def test_oversize_is_rejected_before_decoding(report_key) -> None:
    """长度要在 base64 解码**之前**挡。不然一次解码 + 验签的开销由对方决定。"""
    with pytest.raises(battle_report.ReportRejected) as exc:
        battle_report.verify("x" * (battle_report.MAX_WIRE_CHARS + 1))
    assert exc.value.code == "report_malformed"


def test_missing_key_raises_key_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE", "")
    get_settings.cache_clear()
    battle_report._key_cache = None
    with pytest.raises(battle_report.ReportKeyMissing):
        battle_report.verify("a.b")
    monkeypatch.setenv("GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE", "C:/definitely/not/here.pem")
    get_settings.cache_clear()
    with pytest.raises(battle_report.ReportKeyMissing):
        battle_report.verify("a.b")
    get_settings.cache_clear()


def test_wire_format_has_no_dot_inside_base64() -> None:
    """按「一个点」切开。base64 字母表里没有点，所以不会切错。"""
    body = json.dumps(_payload(), ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    assert "." not in base64.b64encode(body).decode("ascii")


# --- 签过章 ≠ 内容对 -----------------------------------------------------------


@pytest.mark.parametrize(
    "over, code",
    [
        ({"v": 999}, "report_version"),
        ({"mid": "ZZZ"}, "report_malformed"),
        ({"mid": "A" * 32}, "report_malformed"),          # 大写十六进制不收
        ({"mode": "ranked_v2"}, "report_malformed"),
        ({"out": "team_c"}, "report_malformed"),
        ({"rounds": 0}, "report_malformed"),
        ({"rounds": 999}, "report_malformed"),
        ({"hp": [1]}, "report_malformed"),
        ({"seats": []}, "report_malformed"),
    ],
)
def test_bad_payload_is_rejected(report_key, over, code) -> None:
    """战报是我们自己的服务器签的，但它可能有 bug。
    这些值直接写下去会撞 013 的 check 约束变成 500，而不是一条能看懂的日志。"""
    with pytest.raises(battle_report.ReportRejected) as exc:
        battle_report.verify(_sign(report_key, _payload(**over)))
    assert exc.value.code == code


def test_seats_must_be_in_order(report_key) -> None:
    seats = _payload()["seats"]
    seats[2], seats[3] = seats[3], seats[2]
    with pytest.raises(battle_report.ReportRejected):
        battle_report.verify(_sign(report_key, _payload(seats=seats)))


def test_team_must_match_slot(report_key) -> None:
    """013 有 match_seat_team_matches_slot 约束。这边先拦，不然是 500。"""
    seats = _payload()["seats"]
    seats[0]["team"] = 1
    with pytest.raises(battle_report.ReportRejected):
        battle_report.verify(_sign(report_key, _payload(seats=seats)))


def test_report_from_the_future_is_rejected(report_key) -> None:
    now = int(dt.datetime.now(dt.UTC).timestamp())
    with pytest.raises(battle_report.ReportRejected):
        battle_report.verify(_sign(report_key, _payload(start=now, end=now + 99999)))


def test_stale_report_is_rejected(report_key) -> None:
    """防的不是伪造（签名管那个），是无限期回填。"""
    old = int(dt.datetime.now(dt.UTC).timestamp()) - battle_report.MAX_REPORT_AGE_SEC - 60
    with pytest.raises(battle_report.ReportRejected) as exc:
        battle_report.verify(_sign(report_key, _payload(start=old - 100, end=old)))
    assert exc.value.code == "report_too_old"


def test_empty_pid_means_no_player(report_key) -> None:
    """空 pid = 房主加的 AI，或者入座时没带名片。要写 null，不是报错。"""
    got = battle_report.verify(_sign(report_key, _payload()))
    assert got["seats"][5]["player_id"] is None
    assert got["seats"][0]["player_id"] == PLAYER_A


def test_bad_pid_is_rejected(report_key) -> None:
    seats = _payload()["seats"]
    seats[0]["pid"] = "not-a-uuid"
    with pytest.raises(battle_report.ReportRejected):
        battle_report.verify(_sign(report_key, _payload(seats=seats)))


# --- 跨语言约定（钉住 GDScript 那一侧）------------------------------------------


def test_version_matches_gdscript() -> None:
    gd = int(re.search(r"const VERSION\s*:=\s*(\d+)", REPORT_GD).group(1))
    assert gd == battle_report.REPORT_VERSION


def test_modes_match_gdscript_and_sql() -> None:
    """三处要一致：GDScript 的 MODES、Python 的 MODES、013 的 check 约束。
    对不上时战报会被静默丢掉（或者撞数据库约束变 500）。"""
    gd = set(re.findall(r'"(\w+)"', re.search(r"const MODES\s*:=\s*\[([^\]]+)\]", REPORT_GD).group(1)))
    sql = set(re.findall(r"'(\w+)'", re.search(r"match_mode_known check \(mode in \(([^)]+)\)", SQL_013).group(1)))
    assert gd == battle_report.MODES == sql


def test_match_uid_regex_matches_sql_constraint() -> None:
    sql = re.search(r"match_uid_format check \(match_uid ~ '([^']+)'\)", SQL_013).group(1)
    assert sql == battle_report._MATCH_UID_RE.pattern


def test_seat_count_matches_gdscript() -> None:
    gd = int(re.search(r"const SEAT_COUNT\s*:=\s*(\d+)", REPORT_GD).group(1))
    assert gd == battle_report.SEAT_COUNT == 6


def test_wire_limit_is_above_the_measured_worst_case() -> None:
    """🔴 这边的上限不能比战斗服务器签得出来的最大战报还小。

    小了的表现是**满配的对局全部记不下来**，而空房间的测试一路绿 ——
    和名片那条 MAX_CARD_CHARS 是同一类坑。

    13913 是 tools/battle_report_check.gd 实测的最坏情况（六座位 × 16 棋子 +
    8 佣兵 + 5 宝藏，每次运行都会重新打印）。留 4 倍余量给以后加字段。
    """
    measured_worst_case = 13913
    assert battle_report.MAX_WIRE_CHARS >= measured_worst_case * 4


def test_gdscript_does_not_put_uid_in_the_report() -> None:
    """uid / race_relations 出了一局就没有意义，混进去只会让战报慢慢变大。"""
    cleaned = REPORT_GD.split("_clean_units", 1)[1]
    assert '"uid"' not in cleaned
    assert '"race_relations"' not in cleaned


# --- 入库（假数据库）------------------------------------------------------------


class _FakeConn:
    def __init__(self, existing: set[str], known: set[uuid.UUID]) -> None:
        self.existing = existing
        self.known = known
        self.seat_rows: list[tuple] = []

    async def fetchval(self, sql, *args):
        uid = args[0]
        if uid in self.existing:
            return None            # on conflict do nothing -> 没有 returning
        self.existing.add(uid)
        return uid

    async def fetch(self, sql, *args):
        return [{"player_id": p} for p in args[0] if p in self.known]

    async def executemany(self, sql, rows):
        self.seat_rows.extend(rows)

    def transaction(self):
        class _T:
            async def __aenter__(self_inner):
                return None

            async def __aexit__(self_inner, *e):
                return False

        return _T()


class _Pool:
    def __init__(self, conn):
        self.conn = conn

    def acquire(self):
        conn = self.conn

        class _A:
            async def __aenter__(self):
                return conn

            async def __aexit__(self, *e):
                return False

        return _A()


@pytest.mark.anyio
async def test_record_is_idempotent(report_key, monkeypatch: pytest.MonkeyPatch) -> None:
    """六个人各交一份是设计如此。第二份起是 False，不是异常。"""
    conn = _FakeConn(set(), {PLAYER_A, PLAYER_B})
    monkeypatch.setattr(db, "pool", lambda: _Pool(conn))
    report = battle_report.verify(_sign(report_key, _payload()))
    assert await battle_report.record(report) is True
    assert await battle_report.record(report) is False
    assert len(conn.seat_rows) == 6, "第二次不该再插一遍座位"


@pytest.mark.anyio
async def test_deleted_player_becomes_null_not_a_failure(
    report_key, monkeypatch: pytest.MonkeyPatch
) -> None:
    """🔴 注销账号的**时间窗口**不能毁掉同局其他五个人的历史。

    对局结束到战报交上来之间，玩家要看完结算、退回主菜单。有人在这段里注销的话，
    直接插一个已经不存在的 player_id 会违反外键、让**整局**回滚。

    （之后再注销走的是 013 的 on delete cascade，他那一行被删掉 —— 那是设计如此，
    见 test_profile.test_every_table_referencing_players_cascades。）
    """
    seats = _payload()["seats"]
    seats[1]["pid"] = str(GONE)
    conn = _FakeConn(set(), {PLAYER_A, PLAYER_B})     # GONE 不在里面
    monkeypatch.setattr(db, "pool", lambda: _Pool(conn))
    report = battle_report.verify(_sign(report_key, _payload(seats=seats)))
    assert await battle_report.record(report) is True
    assert len(conn.seat_rows) == 6
    # 第 4 个参数是 player_id
    assert conn.seat_rows[1][3] is None
    assert conn.seat_rows[0][3] == PLAYER_A


@pytest.fixture
def anyio_backend():
    return "asyncio"


# --- 接口 ---------------------------------------------------------------------


@dataclass
class _FakePlayer:
    player_id: uuid.UUID
    player_name: str
    friend_code: str


class _FakeVerifier:
    async def verify(self, token: str) -> Claims:
        if token != "token-a":
            raise TokenError("令牌校验失败")
        return Claims(auth_uid="auth-a", is_anonymous=True, expires_at=0)


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)

    async def _lookup(auth_uid: str):
        return _FakePlayer(PLAYER_A, "阿甲", "AAAA2222") if auth_uid == "auth-a" else None

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    report_routes._report_limiter.reset()
    report_routes._matches_limiter.reset()
    yield
    report_routes._report_limiter.reset()
    report_routes._matches_limiter.reset()
    get_settings.cache_clear()


def test_submit_requires_login(wired) -> None:
    assert TestClient(app).post("/v1/battle/report", json={"report": "x.y"}).status_code == 401


def test_submit_without_key_is_503_not_500(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """没配公钥是服务器配置问题。回 500 的话客户端分不出「服务器坏了」和「稍后再试」。"""
    monkeypatch.setenv("GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE", "")
    get_settings.cache_clear()
    battle_report._key_cache = None
    with TestClient(app) as client:
        r = client.post("/v1/battle/report", json={"report": "a.b"},
                        headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 503
    assert "not/here" not in r.text and ".pem" not in r.text, "路径不许出现在响应里"


def test_rejected_report_is_400_with_reason(wired, report_key) -> None:
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with TestClient(app) as client:
        r = client.post("/v1/battle/report", json={"report": _sign(other, _payload())},
                        headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 400
    assert r.headers.get("X-Glory-Reason") == "report_bad_signature"


def test_duplicate_submit_is_200_not_409(wired, report_key, monkeypatch: pytest.MonkeyPatch) -> None:
    """🔴 六个人各交一份。第二份回 409 的话客户端会当成失败，然后一直重试。"""
    conn = _FakeConn(set(), {PLAYER_A, PLAYER_B})
    monkeypatch.setattr(db, "pool", lambda: _Pool(conn))
    wire = _sign(report_key, _payload())
    with TestClient(app) as client:
        headers = {"Authorization": "Bearer token-a"}
        first = client.post("/v1/battle/report", json={"report": wire}, headers=headers)
        second = client.post("/v1/battle/report", json={"report": wire}, headers=headers)
    assert first.status_code == 200 and first.json()["recorded"] is True
    assert second.status_code == 200 and second.json()["recorded"] is False
    assert second.json()["match_uid"] == "a" * 32


def test_oversize_body_is_rejected_by_the_schema(wired, report_key) -> None:
    """Pydantic 的 max_length 先挡，不用等进到验章那一步。"""
    with TestClient(app) as client:
        r = client.post("/v1/battle/report",
                        json={"report": "x" * (battle_report.MAX_WIRE_CHARS + 1)},
                        headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 422


def test_matches_requires_login(wired) -> None:
    assert TestClient(app).get("/v1/me/matches").status_code == 401


def test_matches_limit_is_bounded(wired) -> None:
    with TestClient(app) as client:
        r = client.get("/v1/me/matches?limit=9999", headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 422, "不限上限的话一次请求能把整张表拉出来"


# --- 部署 ---------------------------------------------------------------------


def test_service_file_points_at_the_public_key() -> None:
    """systemd 单元里没有这一行 = 线上永远 503，而本地测试一路绿。

    同 test_loadout 里 GLORY_BATTLE_CARD_KEY_FILE 那条。
    """
    service = (REPO / "deploy" / "glory-backend.service").read_text(encoding="utf-8")
    assert (
        "Environment=GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE=/opt/glory/battle_report_public.pem"
        in service
    )


def test_service_holds_the_public_key_not_the_private_one() -> None:
    """🔴 方向搞反了不会报错，只会让**所有**战报验不过。

    账号服务器只该持公钥（战报由战斗服务器签）。哪天有人把私钥装到这台上，
    谁拿到这台机器谁就能给自己造一整页赢来的历史。
    """
    service = (REPO / "deploy" / "glory-backend.service").read_text(encoding="utf-8")
    assert "GLORY_BATTLE_REPORT_KEY_FILE" not in service, "这个名字意味着放的是私钥"
    src = (REPO / "backend" / "app" / "battle_report.py").read_text(encoding="utf-8")
    assert "load_pem_public_key" in src
    assert "load_pem_private_key" not in src, "账号服务器不该读任何战报私钥"


def test_generator_script_warns_about_the_tools_directory() -> None:
    """make_server_zip.ps1 会把整个 tools/ 打进战斗服务器包。
    私钥放进去 = 发给每一个拿到包的人。这条提醒必须留在生成工具里。"""
    src = (REPO / "deploy" / "make_battle_report_key.py").read_text(encoding="utf-8")
    assert "tools/" in src and "make_server_zip" in src
