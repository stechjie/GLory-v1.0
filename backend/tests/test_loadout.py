"""出战名片（`docs/商城系统设计.md` 第五节）的账号服务器一侧。

同 test_shop 的分工：**不连数据库**，用假连接。签名用真 RSA —— 验的就是
「战斗服务器拿公钥能不能验过」这件事，替身在这里没有意义。

最重要的几组，失败时都**不报错**：

  1. 名片里的每一样都要再过一遍资格。写入时校验过，但之后可能退款收回 ——
     名片是战斗服务器唯一认的东西，这里漏了就等于没校验。
  2. 签的字节与发出去的字节必须是同一串。战斗服务器先验签再解析，
     这边要是签一份、发另一份（比如重新序列化了），所有名片都验不过。
  3. 名片不能超过战斗服务器肯收的长度（BattleCard.MAX_CARD_CHARS）。
     超了的表现是「所有人都进不了房间」，报的是 card_malformed。
  4. 没配私钥要回 503，不是 500 —— 客户端据此提示「稍后再试」。

跑：
    backend\\.venv\\Scripts\\python.exe -m pytest backend/tests/test_loadout.py -q -p no:cacheprovider
"""

from __future__ import annotations

import asyncio
import base64
import json
import pathlib
import re
import uuid
from dataclasses import dataclass

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from fastapi.testclient import TestClient

from app import avatar_catalog, db, loadout, players, shop
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import loadout as loadout_routes
from app.routes import me as me_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_011 = (REPO / "database" / "011_loadout.sql").read_text(encoding="utf-8")
CARD_GD = (REPO / "scripts" / "multiplayer" / "BattleCard.gd").read_text(encoding="utf-8")
SERVICE = (REPO / "deploy" / "glory-backend.service").read_text(encoding="utf-8")

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
SOLD_PET = shop.items()[0].grants            # 商品目录里的宠物（必须归属）
FREE_AVATAR = avatar_catalog.default_avatar()  # 不在目录里 = 免费


# --- 密钥 ---------------------------------------------------------------------


@pytest.fixture
def card_key(tmp_path, monkeypatch: pytest.MonkeyPatch):
    """真 RSA 密钥对。返回公钥，私钥写进临时文件并配给 loadout。"""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    path = tmp_path / "card.pem"
    path.write_bytes(pem)
    monkeypatch.setenv("GLORY_BATTLE_CARD_KEY_FILE", str(path))
    get_settings.cache_clear()
    loadout._key_cache = None
    yield key.public_key()
    loadout._key_cache = None
    get_settings.cache_clear()


def _split(card: str) -> tuple[bytes, bytes]:
    body_b64, sig_b64 = card.split(".")
    return base64.b64decode(body_b64), base64.b64decode(sig_b64)


def _loadout(**over) -> loadout.Loadout:
    base = dict(
        player_id=str(PLAYER_A), friend_code="AAAA2222", player_name="阿甲",
        avatar=FREE_AVATAR, avatar_frame=avatar_catalog.default_frame(),
        pet=SOLD_PET, races=["god", "dark", "undead", "human"],
    )
    base.update(over)
    return loadout.Loadout(**base)


# --- 签名 ---------------------------------------------------------------------


def test_signed_card_verifies_with_the_public_key(card_key) -> None:
    card = loadout.sign(loadout.card_payload(_loadout()))
    body, sig = _split(card)
    # 验不过会抛 InvalidSignature。
    card_key.verify(sig, body, padding.PKCS1v15(), hashes.SHA256())


def test_signature_covers_the_exact_bytes_that_are_sent(card_key) -> None:
    """🔴 签的与发的必须是同一串字节。

    战斗服务器验签用的是线上收到的那串，不会重新序列化。这边要是先签一份、
    再把 dict 重新 dumps 一遍发出去（排版稍有不同），所有名片都验不过。
    """
    card = loadout.sign(loadout.card_payload(_loadout()))
    body, sig = _split(card)
    tampered = body.replace(b'"pet":"', b'"pet":"x', 1)
    assert tampered != body
    with pytest.raises(Exception):
        card_key.verify(sig, tampered, padding.PKCS1v15(), hashes.SHA256())


def test_card_uses_pkcs1v15_not_pss() -> None:
    """Godot 底下的 mbedtls 对 RSA 默认走 PKCS#1 v1.5（2026-09-16 实测）。
    换成 PSS 的话 Python 这边照样能自验通过，只有战斗服务器会全部拒掉。"""
    src = (REPO / "backend" / "app" / "loadout.py").read_text(encoding="utf-8")
    assert "padding.PKCS1v15()" in src
    assert "PSS" not in src.split('"""', 2)[2]


def test_wire_format_is_two_base64_parts() -> None:
    """战斗服务器按「一个点」切开。base64 字母表里没有点，所以不会切错。"""
    payload = loadout.card_payload(_loadout())
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    encoded = base64.b64encode(body).decode("ascii")
    assert "." not in encoded


def test_missing_key_raises_card_key_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GLORY_BATTLE_CARD_KEY_FILE", "")
    get_settings.cache_clear()
    loadout._key_cache = None
    with pytest.raises(loadout.CardKeyMissing):
        loadout.sign({"v": 1})
    monkeypatch.setenv("GLORY_BATTLE_CARD_KEY_FILE", "C:/definitely/not/here.pem")
    get_settings.cache_clear()
    with pytest.raises(loadout.CardKeyMissing):
        loadout.sign({"v": 1})
    get_settings.cache_clear()


# --- 名片内容 -----------------------------------------------------------------


def test_payload_has_short_ttl_and_unique_jti() -> None:
    a = loadout.card_payload(_loadout(), now=1_000_000)
    b = loadout.card_payload(_loadout(), now=1_000_000)
    assert a["exp"] - a["iat"] == loadout.CARD_TTL_SEC
    assert loadout.CARD_TTL_SEC <= 120, "名片有效期太长 —— 被截走能冒充的时间就是这么长"
    assert a["jti"] != b["jti"], "一次性编号重复了，战斗服务器的防重放就失效了"


def test_payload_field_names_are_stable() -> None:
    """字段名是与战斗服务器之间的约定。改名就得两边一起改、顶协议号。"""
    assert set(loadout.card_payload(_loadout())) == {
        "v", "pid", "code", "name", "avatar", "frame", "pet", "races", "iat", "exp", "jti"}


def test_max_size_card_fits_what_the_battle_server_accepts(card_key) -> None:
    """🔴 最大的名片也要在战斗服务器肯收的长度以内。

    超了的表现是**所有人都进不了房间**，报的是 card_malformed，而且只在
    名字长 / 种族多的玩家身上出现 —— 自己测的时候多半碰不到。
    用数据库允许的上限来造：名字 24 个中文、种族 16 个 32 字符。
    """
    limit = int(re.search(r"MAX_CARD_CHARS\s*:=\s*(\d+)", CARD_GD).group(1))
    fat = _loadout(
        friend_code="ZZZZ9999",
        player_name="字" * 24,
        avatar="upload:" + "a" * 64,
        avatar_frame="upload:" + "b" * 64,
        pet="p" * 32,
        races=[("r%02d" % i) + "x" * 29 for i in range(loadout.MAX_RACES)],
    )
    card = loadout.sign(loadout.card_payload(fat))
    # 名片是纯 ASCII（base64 + 一个点），字符数 = 字节数。
    assert card.isascii()
    assert len(card) <= limit, (
        "最大名片 %d 字符，战斗服务器只收 %d —— 要么调大 BattleCard.MAX_CARD_CHARS，要么收紧名片字段"
        % (len(card), limit))


def test_card_fields_match_the_battle_server() -> None:
    """字段名是两边的约定。这边改了名、那边还在取旧名，取到的是空串 ——
    表现是宠物、头像全部消失，而且不报错。

    ⚠️ `match` / `team` 是**匹配出来的对局才有**的（协议 32，app/matchmaking.py）。
    自己建房那条路的名片没有它们，所以要拿**带分配的**那一份来比 ——
    只比基础那一份的话，这条断言会把「可选字段」误报成「漏发」。
    """
    text_fields = set(re.findall(r'"(\w+)":\s*\d+', CARD_GD.split("const MAX_TEXT", 1)[1].split("}", 1)[0]))
    payload = set(loadout.card_payload(_loadout(), match_uid="a" * 32, team=0))
    assert text_fields <= payload, "战斗服务器取的字段账号服务器没发：%s" % sorted(text_fields - payload)
    # 反过来也要钉住：没有分配时那两个字段**必须不出现**。
    # 出现了（哪怕是空串）会让战斗服务器把一张普通名片当成匹配对局的名片。
    base = set(loadout.card_payload(_loadout()))
    assert "match" not in base and "team" not in base
    for field in ("races", "exp", "iat", "v"):
        assert field in payload
    assert "races" in CARD_GD and '"exp"' in CARD_GD and '"iat"' in CARD_GD


def test_card_version_matches_the_battle_server() -> None:
    gd_version = int(re.search(r"^const VERSION\s*:=\s*(\d+)", CARD_GD, re.M).group(1))
    assert gd_version == loadout.CARD_VERSION


# --- 资格过滤（假数据库）---------------------------------------------------------


class _FakeConn:
    def __init__(self, row: dict | None, ranked_row: dict | None = None) -> None:
        self.row = row
        # None = 没打过排位。带段位的名片在 test_ranked / test_matchmaking 里验。
        self.ranked_row = ranked_row
        self.executed: list[tuple] = []

    async def fetchrow(self, sql, *args):
        # build_loadout 现在还会查一次段位（第 6 步）。这里返回 None =
        # 「没打过排位」，名片上就不带 tier —— 本文件验的是资格过滤，不是段位。
        if "player_ranked" in sql:
            return self.ranked_row
        return self.row

    async def fetchval(self, sql, *args):
        return self.row.get("selected_races") if self.row else None

    async def execute(self, sql, *args):
        self.executed.append((sql, args))
        return "UPDATE 1"


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


def _wire(monkeypatch, row: dict | None, owned: list[str]) -> _FakeConn:
    conn = _FakeConn(row)
    monkeypatch.setattr(db, "pool", lambda: _Pool(conn))

    async def _owned(_pid):
        return list(owned)

    monkeypatch.setattr(shop, "read_entitlements", _owned)
    return conn


def _row(**over) -> dict:
    base = {
        "friend_code": "AAAA2222", "player_name": "阿甲",
        "avatar": FREE_AVATAR, "avatar_frame": avatar_catalog.default_frame(),
        "showcase_pet": SOLD_PET, "selected_races": ["god", "dark", "undead", "human"],
    }
    base.update(over)
    return base


def test_owned_pet_goes_on_the_card(monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, _row(), owned=[SOLD_PET])
    result = asyncio.run(loadout.build_loadout(PLAYER_A))
    assert result.pet == SOLD_PET


def test_unowned_pet_is_dropped_from_the_card(monkeypatch: pytest.MonkeyPatch) -> None:
    """🔴 退款收回之后 showcase_pet 可能还指着那只。名片是最后一道。"""
    _wire(monkeypatch, _row(), owned=[])
    result = asyncio.run(loadout.build_loadout(PLAYER_A))
    assert result.pet == ""


def test_free_avatar_needs_no_entitlement(monkeypatch: pytest.MonkeyPatch) -> None:
    """现有 20 张头像不在目录里 = 免费。这里要是去查归属表，每个人的头像都会被换成默认。"""
    other_free = "preset:%s" % avatar_catalog.avatar_ids()[3]
    _wire(monkeypatch, _row(avatar=other_free), owned=[])
    result = asyncio.run(loadout.build_loadout(PLAYER_A))
    assert result.avatar == other_free


def test_unowned_sold_avatar_falls_back_to_default(monkeypatch: pytest.MonkeyPatch) -> None:
    """以后头像上架卖了，没买的（或退款的）换回默认头像，**不是报错** —— 玩家该能继续玩。"""
    sold_avatar = "preset:avatar_999_paid"
    monkeypatch.setattr(shop, "requires_entitlement",
                        lambda cid: cid in (sold_avatar, SOLD_PET))
    _wire(monkeypatch, _row(avatar=sold_avatar), owned=[SOLD_PET])
    result = asyncio.run(loadout.build_loadout(PLAYER_A))
    assert result.avatar == avatar_catalog.default_avatar()
    assert result.pet == SOLD_PET


def test_unowned_race_is_dropped(monkeypatch: pytest.MonkeyPatch) -> None:
    """以后某一族要解锁：没解锁的不上名片。凑不够数由战斗服务器按 RacePick 换默认。"""
    monkeypatch.setattr(shop, "requires_entitlement", lambda cid: cid == "dragon")
    _wire(monkeypatch, _row(selected_races=["god", "dragon", "undead", "human"]), owned=[])
    result = asyncio.run(loadout.build_loadout(PLAYER_A))
    assert result.races == ["god", "undead", "human"]


def test_missing_player_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, None, owned=[])
    with pytest.raises(loadout.LoadoutRejected) as exc:
        asyncio.run(loadout.build_loadout(PLAYER_A))
    assert exc.value.code == "player_not_found"


# --- 出战种族 -----------------------------------------------------------------


@pytest.mark.parametrize("bad", [
    None, "god", [], ["God"], ["a b"], ["x" * 33], ["god", "god"],
    ["r%d" % i for i in range(loadout.MAX_RACES + 1)], [1, 2],
])
def test_clean_races_rejects_malformed(bad) -> None:
    with pytest.raises(loadout.LoadoutRejected):
        loadout.clean_races(bad)


def test_clean_races_keeps_order_and_does_not_enforce_count() -> None:
    """**不校验「必须 4 个」** —— 那是战斗服务器的规则（RacePick），它有棋子表。
    两边各写一个 4，迟早会出现这边收下、那边不认的组合。"""
    assert loadout.clean_races(["human", "god"]) == ["human", "god"]
    assert loadout.clean_races(["a", "b", "c", "d", "e"]) == ["a", "b", "c", "d", "e"]


def test_save_races_rejects_locked_race(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(shop, "requires_entitlement", lambda cid: cid == "dragon")
    conn = _wire(monkeypatch, _row(), owned=[])
    with pytest.raises(loadout.LoadoutRejected) as exc:
        asyncio.run(loadout.save_races(PLAYER_A, ["god", "dragon", "undead", "human"]))
    assert exc.value.code == "race_not_owned"
    assert not conn.executed, "没解锁还是写进库了"


def test_save_races_stores_free_races(monkeypatch: pytest.MonkeyPatch) -> None:
    conn = _wire(monkeypatch, _row(), owned=[])
    saved = asyncio.run(loadout.save_races(PLAYER_A, ["human", "god", "dark", "undead"]))
    assert saved == ["human", "god", "dark", "undead"]
    assert conn.executed and conn.executed[0][1][1] == saved


# --- SQL 与部署 ---------------------------------------------------------------


def test_races_column_has_a_shape_constraint() -> None:
    code = "\n".join(line.split("--", 1)[0] for line in SQL_011.splitlines())
    assert "add column selected_races text[]" in code
    assert "cardinality(selected_races) between 1 and 16" in code
    assert str(loadout.MAX_RACES) == "16", "MAX_RACES 与 011 的约束要一致"


def test_service_unit_points_at_the_card_key() -> None:
    assert "Environment=GLORY_BATTLE_CARD_KEY_FILE=/opt/glory/battle_card_key.pem" in SERVICE


# --- 路由 ---------------------------------------------------------------------


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
    loadout_routes._card_limiter.reset()
    yield
    loadout_routes._card_limiter.reset()
    get_settings.cache_clear()


def test_card_requires_login(wired) -> None:
    with TestClient(app) as client:
        assert client.post("/v1/battle/card").status_code == 401


def test_card_without_key_is_503_not_500(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """没配私钥是服务器配置问题。回 500 的话客户端分不出「服务器坏了」和「稍后再试」。"""
    async def _no_key(_pid, **_kw):
        raise loadout.CardKeyMissing("没有配置")

    monkeypatch.setattr(loadout, "issue_card", _no_key)
    with TestClient(app) as client:
        r = client.post("/v1/battle/card", headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 503
    assert "GLORY_BATTLE_CARD_KEY_FILE" not in r.text, "内部配置名泄漏给了客户端"


def test_card_response_shape(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    async def _card(_pid, **_kw):
        return "Ym9keQ==.c2ln"

    monkeypatch.setattr(loadout, "issue_card", _card)
    with TestClient(app) as client:
        r = client.post("/v1/battle/card", headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 200, r.text
    assert r.json() == {"card": "Ym9keQ==.c2ln", "expires_in": loadout.CARD_TTL_SEC}


def test_races_get_returns_null_when_never_chosen(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """null = 没选过。这边**不替客户端填默认** —— 默认值归战斗服务器按棋子表算。"""
    async def _none(_pid):
        return None

    monkeypatch.setattr(loadout, "read_races", _none)
    with TestClient(app) as client:
        r = client.get("/v1/me/races", headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 200
    assert r.json() == {"races": None}


def test_card_is_rate_limited_per_player(wired) -> None:
    assert loadout_routes.CARD_PER_MINUTE >= 5, "额度太紧 —— 正常玩家一分钟里重进几次房间就会被挡"
