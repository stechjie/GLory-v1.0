"""棋盘皮肤（docs/棋盘皮肤.md）的账号服务器一侧：存哪张、能不能选、旧包看不看得到。

同 test_loadout 的分工：**不连数据库**，用假连接。

失败时都**不报错**的几组：

  1. 卖的皮肤没买也存进去了 —— 玩家白嫖，而且客户端照样显示。
  2. 退款之后读出来的还是那张 —— 同名片「每一样都要再过一遍资格」那条。
  3. 旧包（versionCode 16 及更早）看到了皮肤商品 —— 它会当成头像显示、能买却用不了。
  4. shop.json 卖了一张客户端目录（data/prep_skins.json）里没有的皮肤 ——
     新包会把它藏起来（没有图），等于卖不出去也没人发现。

跑：
    backend\\.venv\\Scripts\\python.exe -m pytest backend/tests/test_prep_skin.py -q -p no:cacheprovider
"""

from __future__ import annotations

import asyncio
import json
import pathlib
import re
import uuid
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from app import client_version, db, loadout, players, shop
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import me as me_routes
from app.routes import shop as shop_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_021 = (REPO / "database" / "021_prep_skin.sql").read_text(encoding="utf-8")
SKIN_CATALOG = json.loads((REPO / "data" / "prep_skins.json").read_text(encoding="utf-8"))

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
SOLD_SKIN = "prep_skin_ice"


# --- 假数据库 -----------------------------------------------------------------


class _FakeConn:
    def __init__(self, stored: str | None) -> None:
        self.stored = stored
        self.executed: list[tuple] = []

    async def fetchval(self, sql, *args):
        return self.stored

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


def _wire(monkeypatch, stored: str | None, owned: list[str]) -> _FakeConn:
    conn = _FakeConn(stored)
    monkeypatch.setattr(db, "pool", lambda: _Pool(conn))

    async def _owned(_pid):
        return list(owned)

    monkeypatch.setattr(shop, "read_entitlements", _owned)
    return conn


# --- 格式 ---------------------------------------------------------------------


@pytest.mark.parametrize("value", [None, "", loadout.PREP_SKIN_DEFAULT])
def test_default_is_stored_as_null(value) -> None:
    """同一个意思只有一种写法：选回默认一律存 null。"""
    assert loadout.clean_prep_skin(value) is None


@pytest.mark.parametrize("bad", [
    "ice", "Prep_skin_ice", "prep_skin_", "prep_skin_ICE", "prep_skin_ice-2",
    "prep_skin_" + "x" * 55, 3, ["prep_skin_ice"],
])
def test_malformed_skin_ids_are_rejected(bad) -> None:
    with pytest.raises(loadout.LoadoutRejected) as exc:
        loadout.clean_prep_skin(bad)
    assert exc.value.code == "bad_prep_skin"


def test_sql_constraint_matches_the_code() -> None:
    """两边的格式要一致：代码放过、库约束不放过的话，玩家看到的是 500。"""
    code = "\n".join(line.split("--", 1)[0] for line in SQL_021.splitlines())
    assert "add column prep_skin text" in code
    assert "'^prep_skin_[a-z0-9_]{1,54}$'" in code
    assert loadout._PREP_SKIN_ID.pattern == r"^prep_skin_[a-z0-9_]{1,54}$"


# --- 存与读 -------------------------------------------------------------------


def test_sold_skin_needs_to_be_owned(monkeypatch: pytest.MonkeyPatch) -> None:
    assert shop.requires_entitlement(SOLD_SKIN), "冰雪棋盘应该在商城目录里卖"
    conn = _wire(monkeypatch, None, owned=[])
    with pytest.raises(loadout.LoadoutRejected) as exc:
        asyncio.run(loadout.save_prep_skin(PLAYER_A, SOLD_SKIN))
    assert exc.value.code == "prep_skin_not_owned"
    assert not conn.executed, "没买还是写进库了"


def test_owned_skin_is_stored(monkeypatch: pytest.MonkeyPatch) -> None:
    conn = _wire(monkeypatch, None, owned=[SOLD_SKIN])
    assert asyncio.run(loadout.save_prep_skin(PLAYER_A, SOLD_SKIN)) == SOLD_SKIN
    assert conn.executed and conn.executed[0][1][1] == SOLD_SKIN


def test_back_to_default_writes_null(monkeypatch: pytest.MonkeyPatch) -> None:
    conn = _wire(monkeypatch, SOLD_SKIN, owned=[])
    assert asyncio.run(loadout.save_prep_skin(PLAYER_A, loadout.PREP_SKIN_DEFAULT)) is None
    assert conn.executed and conn.executed[0][1][1] is None


def test_refunded_skin_reads_back_as_default(monkeypatch: pytest.MonkeyPatch) -> None:
    """🔴 退款收回之后 prep_skin 还指着那张。读的时候不再过一遍资格，就等于没收回。"""
    _wire(monkeypatch, SOLD_SKIN, owned=[])
    assert asyncio.run(loadout.read_prep_skin(PLAYER_A)) is None


def test_owned_skin_reads_back(monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, SOLD_SKIN, owned=[SOLD_SKIN])
    assert asyncio.run(loadout.read_prep_skin(PLAYER_A)) == SOLD_SKIN


def test_skin_is_not_on_the_battle_card() -> None:
    """只有自己看得见，战斗服务器用不到。要让别人也看见，是改设计，不是顺手加字段。"""
    assert "prep_skin" not in [f.name for f in loadout.Loadout.__dataclass_fields__.values()]


# --- 旧包看不到 -----------------------------------------------------------------


@pytest.mark.parametrize("header,build", [
    (None, None), ("", None), ("protocol=32", None), ("protocol=32; build=16", 16),
    ("protocol=32; build=0", 0), ("build=17", 17), ("protocol=32;build=170", 170),
    ("protocol=32; build=abc", None), ("protocol=32; rebuild=18", None),
])
def test_build_is_read_from_the_client_header(header, build) -> None:
    assert client_version.build_of(header) == build


def test_min_build_is_above_the_last_package_without_skins() -> None:
    """versionCode 16（2026-09-26 的测试包）还不认识皮肤。发第一个带皮肤的包之前别把这个数调小。"""
    assert shop_routes.PREP_SKIN_MIN_BUILD >= 17


def _skin_ids(client: TestClient, header: str | None) -> list[str]:
    headers = {"X-Glory-Client": header} if header is not None else {}
    r = client.get("/v1/shop", headers=headers)
    assert r.status_code == 200, r.text
    return [i["grants"] for i in r.json()["items"] if i["kind"] == "prep_skin"]


def test_catalog_hides_skins_from_old_builds(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    get_settings.cache_clear()
    with TestClient(app) as client:
        assert _skin_ids(client, None) == [], "不带版本头的老包看到了皮肤"
        assert _skin_ids(client, "protocol=32; build=16") == []
        assert SOLD_SKIN in _skin_ids(client, "protocol=32; build=17")
        assert SOLD_SKIN in _skin_ids(client, "protocol=32; build=0"), "编辑器里看不到皮肤，没法开发"
        # 别的商品照常发给旧包。
        pets = [i for i in client.get("/v1/shop").json()["items"] if i["kind"] == "pet"]
        assert pets
    get_settings.cache_clear()


# --- 目录一致 -----------------------------------------------------------------


def test_every_sold_skin_exists_in_the_client_catalog() -> None:
    """卖了客户端目录里没有的皮肤：新包会把它藏起来（没有图），卖不出去也没人发现。"""
    client_ids = {str(s["id"]) for s in SKIN_CATALOG["skins"]}
    sold = [i.grants for i in shop.items() if i.kind == "prep_skin"]
    assert sold, "商城里一张皮肤都没有"
    for skin in sold:
        assert skin in client_ids, "shop.json 卖的 %s 不在 data/prep_skins.json 里" % skin
        assert re.match(loadout._PREP_SKIN_ID, skin), "%s 不符合皮肤 id 格式，存不进库" % skin


def test_default_skin_is_first_and_never_sold() -> None:
    ids = [str(s["id"]) for s in SKIN_CATALOG["skins"]]
    assert ids[0] == loadout.PREP_SKIN_DEFAULT
    assert not shop.requires_entitlement(loadout.PREP_SKIN_DEFAULT), "默认皮肤被放进了商城 —— 所有人会一夜失去它"


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
    yield
    get_settings.cache_clear()


AUTH = {"Authorization": "Bearer token-a"}


def test_prep_skin_requires_login(wired) -> None:
    with TestClient(app) as client:
        assert client.get("/v1/me/prep-skin").status_code == 401
        assert client.put("/v1/me/prep-skin", json={"skin": SOLD_SKIN}).status_code == 401


def test_get_returns_null_for_default(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, None, owned=[])
    with TestClient(app) as client:
        r = client.get("/v1/me/prep-skin", headers=AUTH)
    assert r.status_code == 200
    assert r.json() == {"skin": None}


def test_put_unowned_is_403_with_reason(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, None, owned=[])
    with TestClient(app) as client:
        r = client.put("/v1/me/prep-skin", headers=AUTH, json={"skin": SOLD_SKIN})
    assert r.status_code == 403
    assert r.headers.get("X-Glory-Reason") == "prep_skin_not_owned"


def test_put_malformed_is_400(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, None, owned=[])
    with TestClient(app) as client:
        r = client.put("/v1/me/prep-skin", headers=AUTH, json={"skin": "DROP TABLE"})
    assert r.status_code == 400


def test_put_owned_round_trips(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, None, owned=[SOLD_SKIN])
    with TestClient(app) as client:
        r = client.put("/v1/me/prep-skin", headers=AUTH, json={"skin": SOLD_SKIN})
    assert r.status_code == 200, r.text
    assert r.json() == {"skin": SOLD_SKIN}
