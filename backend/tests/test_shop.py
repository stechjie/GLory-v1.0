"""商城（`docs/商城系统设计.md`）的行为用例。

同 test_chat / test_friends 的分工：**不连数据库**。判据是纯函数、目录校验、
SQL 文本的静态一致性、路由接线，以及用一个假连接钉住**语句的执行顺序**。
需要真库的部分（真并发下的行锁、check 约束真的挡住负余额）归线上验证。

最重要的几组，它们的失败模式都**不会报错**：

  1. handler 顺序：查订单必须在查归属**之前**。反过来的话，「执行成功但回执丢了」
     的重试会被「你已经拥有了」拒掉 —— 玩家钱扣了、东西看不见，而且再也拿不回
     那张回执。这是整个幂等设计里最容易写反的一处。
  2. 重放不扣钱：命中已有订单时一行钱都不能动、一件货都不能再发。
  3. 不在目录里的内容免费：写反了会让现有玩家正在用的头像一夜变成「你没有」。
  4. 扣款先扣赠送后扣付费：写反了不报错，要到第一次退款时才发现口径算不出来。
  5. 三选一的「已经领过」要按宠物 id 过滤去问，不能只看归属表第一行。
  6. 流水一行都不许裁剪 —— 这个仓库别处**是有**裁剪先例的，照抄过来当天毫无症状。

跑（从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q tests/test_shop.py
"""

from __future__ import annotations

import asyncio
import datetime as dt
import inspect
import json
import pathlib
import re
import uuid
from dataclasses import dataclass

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app import db, players, shop
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import me as me_routes
from app.routes import profile as profile_routes
from app.routes import shop as shop_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_009 = (REPO / "database" / "009_wallet.sql").read_text(encoding="utf-8")
SQL_010 = (REPO / "database" / "010_shop.sql").read_text(encoding="utf-8")
UPDATE_SH = (REPO / "deploy" / "update.sh").read_text(encoding="utf-8")

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
WHEN = dt.datetime(2026, 9, 15, 12, 0, tzinfo=dt.timezone.utc)


def _sql_code(sql: str) -> str:
    """去掉 SQL 注释，只留代码。

    009/010 的注释里**写着**「绝不 join 目录」「没有 rejected」这些话，
    直接在全文里搜会被注释自己满足。同 test_chat._sql_code。
    """
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


SQL_009_CODE = _sql_code(SQL_009)
SQL_010_CODE = _sql_code(SQL_010)


# --- 假数据库 -----------------------------------------------------------------


class _NullCtx:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


class FakeConn:
    """按 SQL 片段返回预置结果，并**按顺序**记下每一条语句。

    顺序正是这里要钉的东西之一，所以不能用「调用了几次」这种无序判据。
    """

    def __init__(self, responses: list[tuple[str, object]]) -> None:
        self.queries: list[str] = []
        self.args: list[tuple] = []
        self._responses = responses

    def _match(self, sql: str):
        for frag, value in self._responses:
            if frag in sql:
                return value
        return None

    def _record(self, sql: str, args: tuple):
        self.queries.append(" ".join(sql.split()))
        self.args.append(args)

    async def execute(self, sql: str, *args):
        self._record(sql, args)
        return "OK 1"

    async def fetchrow(self, sql: str, *args):
        self._record(sql, args)
        return self._match(sql)

    async def fetchval(self, sql: str, *args):
        self._record(sql, args)
        return self._match(sql)

    async def fetch(self, sql: str, *args):
        self._record(sql, args)
        return self._match(sql) or []

    def transaction(self):
        return _NullCtx()

    # --- 给断言用的小工具 ---

    def index_of(self, frag: str) -> int:
        for i, q in enumerate(self.queries):
            if frag in q:
                return i
        return -1

    def count(self, frag: str) -> int:
        return sum(1 for q in self.queries if frag in q)

    def wrote_money(self) -> bool:
        return self.count("update player_wallets") > 0 or self.count("into wallet_ledger") > 0

    def granted(self) -> bool:
        return self.count("into player_entitlements") > 0


class FakePool:
    def __init__(self, conn: FakeConn) -> None:
        self._conn = conn

    def acquire(self):
        conn = self._conn

        class _Acquire:
            async def __aenter__(self):
                return conn

            async def __aexit__(self, *exc):
                return False

        return _Acquire()


def wire_db(monkeypatch: pytest.MonkeyPatch, responses: list[tuple[str, object]]) -> FakeConn:
    conn = FakeConn(responses)
    monkeypatch.setattr(db, "pool", lambda: FakePool(conn))
    monkeypatch.setattr(db, "is_connected", lambda: True)
    return conn


WALLET_ROW = {"diamond_paid": 0, "diamond_free": 0, "coin": 0}


def wallet_row(paid: int = 0, free: int = 0, coin: int = 0) -> dict:
    return {"diamond_paid": paid, "diamond_free": free, "coin": coin}


# --- 目录 ---------------------------------------------------------------------


def test_catalog_loads_and_ids_are_unique() -> None:
    items = shop.items()
    assert items, "data/shop.json 是空的"
    ids = [i.id for i in items]
    assert len(ids) == len(set(ids))
    for item in items:
        assert item.currency in shop.CURRENCIES
        assert item.price >= 0
        # 商品 id 与内容 id 必须是两个不同的值。写成一样的话，
        # 「同一只宠物在不同活动里不同包装」这条路就没了，而那正是分开的理由。
        assert item.id != item.grants


def test_item_by_id_rejects_unknown() -> None:
    with pytest.raises(shop.ShopRejected) as exc:
        shop.item_by_id("shop_does_not_exist")
    assert exc.value.code == "unknown_item"


def test_content_not_in_catalog_is_free() -> None:
    """🔴 不在目录里 = 免费。

    现有那 20 张头像与 frame_default 上线时就是免费的，做商城不能把它们变成付费 ——
    那是对已经在用它的玩家的回收。写反成「不在归属表里就是没有」的话，
    每个玩家的头像会一夜之间全部失效，而且不报错。
    """
    catalog = json.loads((REPO / "data" / "shop.json").read_text(encoding="utf-8"))
    sold = {str(i["grants"]) for i in catalog["items"]}

    avatars = json.loads((REPO / "data" / "avatars.json").read_text(encoding="utf-8"))
    for entry in avatars["avatars"]:
        content_id = "preset:%s" % entry["id"]
        assert content_id not in sold, "现有头像 %s 被挪进商城卖了" % entry["id"]
        assert shop.requires_entitlement(content_id) is False
    for entry in avatars["frames"]:
        assert shop.requires_entitlement("preset:%s" % entry["id"]) is False


def test_sold_content_requires_entitlement() -> None:
    for item in shop.items():
        assert shop.requires_entitlement(item.grants) is True


def test_starter_ids_come_from_the_same_pets_table_as_the_client() -> None:
    """服务端与客户端读同一份 data/pets/pets.json。

    两处定义的话会出现「客户端让选、服务端说不是新手宠物」，
    而那只会在新玩家身上发生 —— 自己测的时候多半碰不到。
    """
    table = json.loads((REPO / "data" / "pets" / "pets.json").read_text(encoding="utf-8"))
    assert shop.starter_ids() == [str(x) for x in table["starter_ids"]]
    for pet in table["pets"]:
        assert shop.is_pet(str(pet["id"]))


# --- 扣款拆分（纯函数）---------------------------------------------------------


def test_diamond_spends_free_before_paid() -> None:
    """🔴 先扣赠送、后扣付费。

    反过来扣的话，玩家充值后会先花掉付费那部分、剩一堆赠送余额，
    退款时「他还剩多少是花钱买的」就算不出来了。这段写反不报错。
    """
    w = shop.Wallet(diamond_paid=100, diamond_free=30, coin=0)
    assert shop.split_charge(w, "diamond", 20) == {"diamond_free": 20}
    assert shop.split_charge(w, "diamond", 30) == {"diamond_free": 30}
    # 跨两列：赠送的 30 花光，剩下 20 从付费出。
    assert shop.split_charge(w, "diamond", 50) == {"diamond_free": 30, "diamond_paid": 20}


def test_diamond_spend_with_no_free_balance_touches_paid_only() -> None:
    w = shop.Wallet(diamond_paid=100, diamond_free=0, coin=0)
    assert shop.split_charge(w, "diamond", 40) == {"diamond_paid": 40}


def test_coin_never_touches_diamond_columns() -> None:
    w = shop.Wallet(diamond_paid=100, diamond_free=100, coin=50)
    assert shop.split_charge(w, "coin", 50) == {"coin": 50}


def test_zero_price_charges_nothing() -> None:
    """0 价不能产出 delta = 0 的流水 —— 009 的 check 会挡下来，
    表现是买免费商品直接 500。"""
    assert shop.split_charge(shop.Wallet(0, 0, 0), "diamond", 0) == {}


def test_wallet_merges_diamonds_for_the_client() -> None:
    """游戏里只显示一个总数，分账纯粹是后台账目。"""
    assert shop.Wallet(diamond_paid=7, diamond_free=3, coin=1).diamond == 10


def test_ledger_currency_values_are_the_wallet_columns_not_the_currencies() -> None:
    """🔴 流水记的是**列名**（diamond_paid / diamond_free），不是货币名（diamond）。

    一笔钻石消费可能跨两列，就要写两条流水、各自带那一列的 balance_after。
    记成货币名的话，对账时没法定位到具体哪一列。
    """
    assert set(shop.COLUMNS) == {"diamond_paid", "diamond_free", "coin"}
    assert set(shop.CURRENCIES) == {"diamond", "coin"}
    for column in shop.COLUMNS:
        assert "'%s'" % column in SQL_009_CODE
    # 货币名 diamond 不是合法的流水 currency —— 它不对应任何一列。
    assert "check (currency in ('diamond_paid', 'diamond_free', 'coin'))" in SQL_009_CODE


def test_apply_validates_the_ledger_source() -> None:
    """source 拼错不会报错，坏的是以后对账 —— 所以要在写之前挡住。"""
    assert "grant" in shop.SOURCES and "iap" in shop.SOURCES
    assert "SOURCES" in inspect.getsource(shop._apply)


def test_wallet_ledger_is_never_pruned_by_maintenance() -> None:
    """🔴 这张流水表一行都不许删。

    分账能从它重放算出来，所以它一旦被裁剪，算出来的是个**看起来很正常的错数**。
    而这个仓库是有裁剪先例的：app/maintenance.py 会清过期私聊会话与好友请求日志，
    chat_messages 更是「每对好友只留最近 200 条」。谁照着那个模式给钱包流水
    也加一条清理，当天什么都不会发生。

    这条断言就是把 009 里那段注释变成能红的东西。
    """
    maintenance = (REPO / "backend" / "app" / "maintenance.py").read_text(encoding="utf-8")
    assert "wallet_ledger" not in maintenance, (
        "maintenance.py 碰了 wallet_ledger —— 钱包流水永不裁剪，要控体积请归档不要删")


# --- 🔴 handler 顺序与幂等 -----------------------------------------------------


def test_order_lookup_happens_before_ownership_check(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """★ 查订单必须在查归属之前。

    反过来的话：玩家买成功了但回执在路上丢了，客户端用同一个 client_order_id 重试，
    这一次会先撞上「你已经拥有了」而被拒 —— 他再也拿不回那张回执，
    钱扣了、东西在库里、界面上什么都没有。
    """
    item = shop.items()[0]
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", None),
        ("from player_wallets", wallet_row(paid=1000)),
        ("into shop_orders", WHEN),
    ])
    asyncio.run(shop.purchase(PLAYER_A, uuid.uuid4(), item.id))

    order_lookup = conn.index_of("select order_id, item_id, currency")
    ownership = conn.index_of("select 1 from player_entitlements")
    assert order_lookup >= 0 and ownership >= 0
    assert order_lookup < ownership, "查归属跑到了查订单前面，重试会被误拒"


def test_replay_returns_original_receipt_and_moves_no_money(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """重放：回执原样还回去，**一分钱不动、一件货不发**。"""
    item = shop.items()[0]
    original = uuid.uuid4()
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", {
            "order_id": original, "item_id": item.id, "currency": item.currency,
            "price_snapshot": item.price, "created_at": WHEN,
        }),
        ("from player_wallets", wallet_row(paid=5)),
    ])
    receipt = asyncio.run(shop.purchase(PLAYER_A, uuid.uuid4(), item.id))

    assert receipt.replayed is True
    assert receipt.order_id == original
    assert receipt.price == item.price
    assert not conn.wrote_money(), "重放时动了钱"
    assert not conn.granted(), "重放时又发了一次货"
    assert conn.count("into shop_orders") == 0, "重放时插了第二张订单"


def test_replay_reports_current_balance_not_historical(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """重放回的余额是**当前**余额。

    给历史余额的话，客户端界面会倒退回那笔订单刚成交时的数字 ——
    期间买过的东西全部「回血」，玩家会以为扣错了钱。
    """
    item = shop.items()[0]
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", {
            "order_id": uuid.uuid4(), "item_id": item.id, "currency": item.currency,
            "price_snapshot": item.price, "created_at": WHEN,
        }),
        ("from player_wallets", wallet_row(paid=42, free=8, coin=3)),
    ])
    receipt = asyncio.run(shop.purchase(PLAYER_A, uuid.uuid4(), item.id))
    assert receipt.wallet.diamond == 50
    assert receipt.wallet.coin == 3
    assert conn.index_of("for update") >= 0


def test_same_order_id_different_item_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """同一个幂等键买两样东西 —— 不是弱网重试，是客户端有 bug 或者有人在试探。"""
    items = shop.items()
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", {
            "order_id": uuid.uuid4(), "item_id": items[1].id, "currency": "diamond",
            "price_snapshot": 1, "created_at": WHEN,
        }),
        ("from player_wallets", WALLET_ROW),
    ])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(shop.purchase(PLAYER_A, uuid.uuid4(), items[0].id))
    assert exc.value.code == "order_conflict"
    assert not conn.wrote_money()
    assert not conn.granted()


def test_already_owned_rejects_without_charging(monkeypatch: pytest.MonkeyPatch) -> None:
    item = shop.items()[0]
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", 1),
        ("from player_wallets", wallet_row(paid=99999)),
    ])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(shop.purchase(PLAYER_A, uuid.uuid4(), item.id))
    assert exc.value.code == "already_owned"
    assert not conn.wrote_money(), "已拥有却把钱扣了"


def test_insufficient_funds_rejects_without_granting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """余额不足不能发货。反过来（先发后扣）就是白送。"""
    item = shop.items()[0]
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", None),
        ("from player_wallets", wallet_row(paid=item.price - 1)),
    ])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(shop.purchase(PLAYER_A, uuid.uuid4(), item.id))
    assert exc.value.code == "insufficient_funds"
    assert not conn.granted()
    assert not conn.wrote_money()


def test_successful_purchase_writes_ledger_and_grants_and_orders(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """成功那次：扣钱、写流水、发货、落订单，一样都不能少。

    尤其是流水 —— 余额是结果、流水是过程，只改余额不写流水的账查不动，
    而漏了它一点症状都没有。
    """
    item = shop.items()[0]
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", None),
        ("from player_wallets", wallet_row(free=item.price)),
        ("into shop_orders", WHEN),
    ])
    receipt = asyncio.run(shop.purchase(PLAYER_A, uuid.uuid4(), item.id))

    assert receipt.replayed is False
    assert receipt.granted == item.grants
    assert conn.count("update player_wallets") == 1
    assert conn.count("into wallet_ledger") == 1
    assert conn.count("into player_entitlements") == 1
    assert conn.count("into shop_orders") == 1
    # 全款从赠送列出，付费列一分没动。
    assert receipt.wallet.diamond_free == 0
    assert receipt.wallet.diamond_paid == 0


def test_purchase_never_trusts_a_client_supplied_price(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """价格只能来自服务端目录。

    `purchase()` 的签名里根本没有价格参数 —— 这条断言是防止以后有人"顺手"
    加一个，那等于把定价权交给客户端。
    """
    params = set(inspect.signature(shop.purchase).parameters)
    assert params == {"player_id", "client_order_id", "item_id"}
    assert "price" not in params and "amount" not in params


# --- 三选一 -------------------------------------------------------------------


def test_starter_pick_rejects_non_starter(monkeypatch: pytest.MonkeyPatch) -> None:
    conn = wire_db(monkeypatch, [])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(shop.pick_starter(PLAYER_A, uuid.uuid4(), "pet_not_real"))
    assert exc.value.code == "not_a_starter"
    assert not conn.granted()


def test_starter_pick_asks_for_pets_specifically_not_the_first_row(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """🔴「已经领过没有」必须按宠物 id 过滤去问。

    只取归属表第一行来判的话，一个同时拥有头像和宠物的玩家会在第一行拿到头像、
    `is_pet` 判 false，于是又被发一只新手宠物。白送，而且不报错。
    """
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", None),
        ("from player_wallets", WALLET_ROW),
        ("into shop_orders", WHEN),
    ])
    asyncio.run(shop.pick_starter(PLAYER_A, uuid.uuid4(), shop.starter_ids()[0]))

    idx = conn.index_of("select 1 from player_entitlements")
    assert idx >= 0, "没有按宠物 id 过滤去问，多半是退回了只看第一行的写法"
    # 传进去的第二个参数必须是完整宠物 id 列表。
    assert sorted(conn.args[idx][1]) == sorted(shop.starter_ids()) or set(
        shop.starter_ids()).issubset(set(conn.args[idx][1]))


def test_starter_pick_rejects_when_a_pet_is_already_owned(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", 1),
        ("from player_wallets", WALLET_ROW),
    ])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(shop.pick_starter(PLAYER_A, uuid.uuid4(), shop.starter_ids()[0]))
    assert exc.value.code == "starter_already_picked"
    assert not conn.granted()


def test_starter_pick_uses_the_same_order_table_as_buying(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """三选一走和购买同一条发货路径。

    这不是洁癖：发货与幂等因此在第一天就被每个新玩家压满，
    不用等到充值上线才第一次被真实流量压。
    """
    conn = wire_db(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", None),
        ("from player_wallets", WALLET_ROW),
        ("into shop_orders", WHEN),
    ])
    receipt = asyncio.run(shop.pick_starter(PLAYER_A, uuid.uuid4(), shop.starter_ids()[0]))

    assert receipt.price == 0
    assert conn.count("into shop_orders") == 1
    assert conn.count("into player_entitlements") == 1
    assert "'starter_pick'" in conn.queries[conn.index_of("into shop_orders")]
    # 0 价不能产出流水：009 的 delta <> 0 会挡下来，表现是新玩家领宠物直接 500。
    assert conn.count("into wallet_ledger") == 0


def test_set_active_pet_requires_ownership(monkeypatch: pytest.MonkeyPatch) -> None:
    """players.showcase_pet 原本没有归属校验 —— 和 avatar_catalog 注释里
    预告的是同一个洞。不补的话改个请求体就能用没买的宠物。"""
    conn = wire_db(monkeypatch, [
        ("from player_entitlements", None),
    ])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(shop.set_active_pet(PLAYER_A, shop.starter_ids()[0]))
    assert exc.value.code == "not_owned"
    assert conn.count("update players") == 0


# --- 装备时的归属校验 ----------------------------------------------------------
#
# avatar_catalog 只回答「这个 id 存不存在」。它自己的文件注释预告过：
# 「等头像变成活动奖励或付费内容，同一个洞就是白嫖限定头像」。商城上线那天到了。


def test_equipping_free_content_needs_no_entitlement(monkeypatch: pytest.MonkeyPatch) -> None:
    """🔴 现有那 20 张头像不在目录里 = 免费，装备时**不能**去查归属表。

    查了就会把每个玩家正在用的头像判成「你没有」—— 一夜之间全部失效。
    """
    called: list = []

    async def _never(_player_id):
        called.append(1)
        return []

    monkeypatch.setattr(shop, "read_entitlements", _never)
    avatars = json.loads((REPO / "data" / "avatars.json").read_text(encoding="utf-8"))
    value = "preset:%s" % avatars["avatars"][0]["id"]
    asyncio.run(profile_routes._require_entitlement(PLAYER_A, value))
    assert not called, "免费内容也去查了归属表"


def test_equipping_sold_content_without_owning_it_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """卖过的东西必须查。不查就是「改个请求体就能用没买的宠物」。"""
    async def _owns_nothing(_player_id):
        return []

    monkeypatch.setattr(shop, "read_entitlements", _owns_nothing)
    sold = shop.items()[0].grants
    with pytest.raises(HTTPException) as exc:
        asyncio.run(profile_routes._require_entitlement(PLAYER_A, sold))
    assert exc.value.status_code == 403
    assert exc.value.headers.get("X-Glory-Reason") == "not_owned"


def test_equipping_sold_content_you_own_is_allowed(monkeypatch: pytest.MonkeyPatch) -> None:
    sold = shop.items()[0].grants

    async def _owns_it(_player_id):
        return [sold]

    monkeypatch.setattr(shop, "read_entitlements", _owns_it)
    asyncio.run(profile_routes._require_entitlement(PLAYER_A, sold))


def test_profile_patch_checks_avatar_frame_and_pet(monkeypatch: pytest.MonkeyPatch) -> None:
    """三样都要查 —— 漏掉任何一样，那一样就是白嫖入口。"""
    source = inspect.getsource(profile_routes.patch_me_profile)
    assert source.count("_require_entitlement") >= 3
    for field in ("avatar", "frame", "pet"):
        assert "_require_entitlement(row.player_id, %s)" % field in source


# --- SQL 的静态一致性 ----------------------------------------------------------


def test_expected_tables_lists_the_four_new_ones() -> None:
    """漏登记等于 /v1/debug/schema 不检查这张表，RLS 开没开没人知道。"""
    for table in ("player_wallets", "wallet_ledger", "player_entitlements", "shop_orders"):
        assert table in db.EXPECTED_TABLES


def test_every_new_table_enables_rls_with_zero_policies() -> None:
    """RFC 第三节的硬规则：开 RLS + 零 policy。"""
    both = SQL_009_CODE + SQL_010_CODE
    for table in ("player_wallets", "wallet_ledger", "player_entitlements", "shop_orders"):
        assert "alter table %s enable row level security" % table in both
    assert "create policy" not in both.lower()


def test_wallet_balances_cannot_go_negative() -> None:
    assert "diamond_paid >= 0" in SQL_009_CODE
    assert "diamond_free >= 0" in SQL_009_CODE
    assert "coin >= 0" in SQL_009_CODE


def test_ledger_currency_matches_wallet_columns() -> None:
    """流水的 currency 只能是钱包那三列。写错列名不报错，只会永远对不上账。"""
    for column in shop.COLUMNS:
        assert "'%s'" % column in SQL_009_CODE


def test_ledger_source_has_no_database_check() -> None:
    """source 刻意不在数据库加 check —— 加了以后运营手工发一种新名目的补偿
    就要先跑迁移，而那通常发生在出事故的当天。合法值在 shop.SOURCES。"""
    assert "check (currency in" in SQL_009_CODE
    assert "source in (" not in SQL_009_CODE


def test_manual_grant_is_a_single_atomic_function() -> None:
    """手工发放只给一个入口。

    拍板是「管理员直接改 Supabase 后台」，但手改两条语句迟早会漏掉流水那条 ——
    改完余额、忘了 insert，于是「这个号的钻石哪来的」永远查不出来，
    而且当时毫无症状。函数化之后忘不掉。
    """
    assert "create function grant_diamonds(" in SQL_009_CODE
    assert "insert into wallet_ledger" in SQL_009_CODE


def test_manual_grant_never_touches_the_paid_column() -> None:
    """🔴 手工发的钱不是玩家付的。

    混进 diamond_paid 就把退款口径弄脏了，而那一列的全部意义
    就是「他到底花过多少钱」。流水的 source 同理必须是 grant。
    """
    body = SQL_009_CODE.split("create function grant_diamonds(", 1)[1]
    assert "diamond_free = diamond_free + p_amount" in body
    assert "diamond_paid" not in body
    assert "'grant'" in body and "'iap'" not in body


def test_manual_grant_requires_an_actor_and_rejects_negatives() -> None:
    """不填操作人就发不出去；回收要走退款流程，不能偷偷发负数
    —— 后者玩家会当成扣错钱来投诉，客服无从解释。"""
    body = SQL_009_CODE.split("create function grant_diamonds(", 1)[1]
    assert "p_amount <= 0" in body
    assert "btrim(p_actor) = ''" in body


def test_order_status_has_no_rejected() -> None:
    """拒绝不落库。落了就会被重放 ——「余额不足 → 去充值 → 同一个 client_order_id
    重试」会被重放成失败，而玩家看到的是「我明明有钱了」。"""
    assert "check (status in ('ok', 'refunded'))" in SQL_010_CODE
    assert "rejected" not in SQL_010_CODE


def test_order_idempotency_key_is_unique_per_player() -> None:
    assert "unique (player_id, client_order_id)" in SQL_010_CODE


def test_external_id_is_unique_for_rtdn_dedup() -> None:
    """Google 的 RTDN 会重复推同一笔。第一版这个索引是空的，
    它在这里是为了接充值时不用动一张已经有真实数据的表。"""
    assert "create unique index shop_orders_external" in SQL_010_CODE
    assert "external_id is not null" in SQL_010_CODE


def test_entitlement_primary_key_allows_regrant_after_refund() -> None:
    """退款收回之后重新买：主键已经被那一行占着，
    `do nothing` 会让钱扣了东西不到。"""
    assert "primary key (player_id, item_id)" in SQL_010_CODE
    shop_py = (REPO / "backend" / "app" / "shop.py").read_text(encoding="utf-8")
    assert "on conflict (player_id, item_id) do update" in shop_py
    assert "revoked_at = null" in shop_py


def test_deploy_copies_both_new_data_files() -> None:
    """🔴 update.sh 的文件名列表是写死的。

    漏了 shop.json 不是「商城空了」—— `requires_entitlement` 会对所有内容返回
    False，**所有付费内容变免费**。这一段的注释里记着上一次漏掉
    avatars.json 的后果（玩家一换头像就 500）。
    """
    assert "shop.json" in UPDATE_SH
    assert "pets/pets.json" in UPDATE_SH
    # 带子目录的条目要能建出父目录，否则 rsync 直接失败。
    assert 'mkdir -p "$(dirname "$REPO/data/$f")"' in UPDATE_SH


# --- 路由接线 -----------------------------------------------------------------


@dataclass
class _FakePlayer:
    player_id: uuid.UUID
    player_name: str
    friend_code: str


class _FakeVerifier:
    async def verify(self, token: str) -> Claims:
        if token != "token-a":
            raise TokenError("令牌校验失败：测试用的假 verifier 不认识它")
        return Claims(auth_uid="auth-a", is_anonymous=True, expires_at=0)


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    # 🔴 数据库串必须清空，否则 lifespan 会拿 backend/.env 里那串去连真库。
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()

    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)

    async def _lookup(auth_uid: str):
        return _FakePlayer(PLAYER_A, "阿甲", "AAAA2222") if auth_uid == "auth-a" else None

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    shop_routes._order_limiter.reset()
    yield
    shop_routes._order_limiter.reset()
    get_settings.cache_clear()


def _auth() -> dict[str, str]:
    return {"Authorization": "Bearer token-a"}


def test_catalog_needs_no_login(wired) -> None:
    """目录对所有人一样、不含玩家数据，所以不挂鉴权 ——
    挂了的话登录页都还没过就看不到商城。"""
    with TestClient(app) as client:
        r = client.get("/v1/shop")
    assert r.status_code == 200, r.text
    assert isinstance(r.json()["items"], list)


def test_wallet_requires_login(wired) -> None:
    with TestClient(app) as client:
        assert client.get("/v1/me/wallet").status_code == 401


def test_order_body_has_no_price_field(wired) -> None:
    """请求体里塞价格会被 pydantic 忽略，但接口也不该声明它。
    客户端只发意图，价格从服务端目录取。"""
    assert set(shop_routes.OrderBody.model_fields) == {"client_order_id", "item_id"}


def test_reject_codes_map_to_distinct_meaningful_statuses(wired) -> None:
    """余额不足要弹充值入口，「你没资格」要弹错误提示 —— 客户端得能一眼分开。"""
    table = shop_routes._STATUS_BY_CODE
    assert table["insufficient_funds"] == 402
    assert table["already_owned"] == 409
    assert table["order_conflict"] == 409
    assert table["not_owned"] == 403
    assert table["unknown_item"] == 404


def test_every_shop_rejection_code_has_a_status(wired) -> None:
    """shop.py 里抛出的每个 code 都要在映射表里，漏了会静默变成 400 ——
    余额不足弹成「参数错误」，玩家永远找不到充值入口。"""
    source = (REPO / "backend" / "app" / "shop.py").read_text(encoding="utf-8")
    codes = set(re.findall(r'ShopRejected\(\s*"([a-z_]+)"', source))
    assert codes, "没扫到任何 ShopRejected，正则该更新了"
    missing = codes - set(shop_routes._STATUS_BY_CODE)
    assert not missing, "这些拒绝码没有对应状态码：%s" % sorted(missing)


def test_list_responses_are_objects_not_bare_arrays(wired) -> None:
    """客户端 _request 的 body 只接受 Dictionary，顶层数组会**静默变成空**。"""
    for model in (shop_routes.ShopResponse, shop_routes.EntitlementsResponse):
        assert "items" in model.model_fields


def test_wallet_response_does_not_leak_the_paid_free_split(wired) -> None:
    """分账是退款与对账的口径，客户端没有用到它的场景，下发只是多一个泄露面。"""
    fields = set(shop_routes.WalletResponse.model_fields)
    assert fields == {"diamond", "coin"}

