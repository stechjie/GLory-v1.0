"""充值（docs/充值系统设计.md）的行为用例。

同 test_shop 的分工：**不连数据库**，用一个假连接钉住语句的执行顺序；三家平台全用 httpx.MockTransport
和本地生成的证书。真库上 040 跑不跑得通、约束真的挡不挡，归 test_pg_integration（设了 GLORY_TEST_PG 才跑）。

最要紧的几组，失败模式都**不报错**，只会让钱对不上：

  1. 入账只认平台核实过的凭证；同一张凭证不能入两张单、不能交到别人的单上。
  2. 首充双倍按 iap_first_bonus 插没插进去算；测试单不占资格、全进赠送列、24 小时最多 1 张。
  3. 退款先扣付费、再扣赠送、不够的记欠账；欠账时花不了钻石，任何入账先还欠账。
  4. 开关只挡建单，已经付了钱的单照样能入账。
  5. 向平台核实时不握数据库连接（好友在线推送把服务器拖卡过一次）。

跑（从仓库根）：
    backend/.venv/Scripts/python.exe -m pytest backend/tests/test_iap.py -q -p no:cacheprovider
"""

from __future__ import annotations

import asyncio
import base64
import dataclasses
import datetime as dt
import json
import pathlib
import uuid
from types import SimpleNamespace

import httpx
import jwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID
from fastapi.testclient import TestClient

from app import (db, iap, iap_apple, iap_google, iap_steam, iap_sync, login_sessions, players, schema_check, shop,
                 steam)
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import iap as iap_routes
from app.routes import me as me_routes
from app.supabase_auth import STEAM_PROVIDER, LinkedIdentity

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_040 = (REPO / "database" / "040_iap.sql").read_text(encoding="utf-8")
SQL_040_CODE = "\n".join(line.split("--", 1)[0] for line in SQL_040.splitlines())

PLAYER = uuid.UUID("11111111-1111-1111-1111-111111111111")
OTHER = uuid.UUID("22222222-2222-2222-2222-222222222222")
ORDER = uuid.UUID("33333333-3333-3333-3333-333333333333")
CLIENT = uuid.UUID("44444444-4444-4444-4444-444444444444")
NOW = dt.datetime(2026, 10, 27, 12, 0, tzinfo=dt.timezone.utc)
TOKEN = "gpa-token." + "a" * 60
STEAM_ID = "76561198000000042"
KEY = "SECRETPUBLISHERKEY0123456789ABCD"
PUSH_ACCOUNT = "glory-play-billing@demo.iam.gserviceaccount.com"
PUSH_AUDIENCE = "https://glorytd-api.duckdns.org/iap/google/rtdn"

# data/iap_products.json 的第 3 档：基础 500、平时加送 60。用真目录，目录改了这些用例会提醒。
PACK = "diamond_pack_3"


def _settings(**overrides) -> SimpleNamespace:
    base = dict(
        iap_google_enabled=True, iap_apple_enabled=True, iap_steam_enabled=True,
        google_play_package="com.glory.game.google", google_play_service_account_file="",
        apple_bundle_id="com.superforge.glory", apple_root_cert_file="",
        steam_sandbox_steam_ids="", steam_web_api_key=KEY, steam_app_id=4919850,
        steam_ticket_identity="glory-account",
        google_rtdn_service_account=PUSH_ACCOUNT, google_rtdn_audience=PUSH_AUDIENCE,
        iap_test_orders_per_day=1,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


@pytest.fixture(autouse=True)
def _iap_settings(monkeypatch: pytest.MonkeyPatch):
    holder = {"s": _settings()}
    for module in (iap, iap_google, iap_apple, iap_steam, iap_sync, steam):
        monkeypatch.setattr(module, "get_settings", lambda: holder["s"])
    iap_google.reset()
    iap_apple.reset()
    yield holder
    iap_google.reset()
    iap_apple.reset()


# --- 假数据库 -----------------------------------------------------------------


class _NullCtx:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


class FakeConn:
    """按 SQL 片段返回预置结果（值，或按参数算结果的函数），并按顺序记下每一条语句。

    片段按列表顺序匹配、第一个命中的算数 —— 「… for update」那种更长的片段要排在前面。
    """

    def __init__(self, responses: list[tuple[str, object]]) -> None:
        self.queries: list[str] = []
        self.args: list[tuple] = []
        self._responses = responses

    def _answer(self, sql: str, args: tuple):
        self.queries.append(" ".join(sql.split()))
        self.args.append(args)
        for frag, value in self._responses:
            if frag in self.queries[-1]:
                return value(*args) if callable(value) else value
        return None

    async def execute(self, sql: str, *args):
        self._answer(sql, args)
        return "OK 1"

    async def fetchrow(self, sql: str, *args):
        return self._answer(sql, args)

    async def fetchval(self, sql: str, *args):
        return self._answer(sql, args)

    async def fetch(self, sql: str, *args):
        return self._answer(sql, args) or []

    def transaction(self):
        return _NullCtx()

    def index_of(self, frag: str) -> int:
        return next((i for i, q in enumerate(self.queries) if frag in q), -1)

    def count(self, frag: str) -> int:
        return sum(1 for q in self.queries if frag in q)

    def ledger(self) -> list[tuple[str, int, str]]:
        """写进流水的 (列, 变化, 名目)。"""
        return [(a[1], a[2], a[4]) for q, a in zip(self.queries, self.args) if "into wallet_ledger" in q]

    def wallet_update(self) -> tuple | None:
        found = [a for q, a in zip(self.queries, self.args) if q.startswith("update player_wallets")]
        return found[-1] if found else None


class FakePool:
    """数着此刻借出去几条连接 —— 用来钉「向平台核实时不握连接」。"""

    def __init__(self, conn: FakeConn) -> None:
        self.conn = conn
        self.active = 0

    def acquire(self):
        pool = self

        class _Acquire:
            async def __aenter__(self):
                pool.active += 1
                return pool.conn

            async def __aexit__(self, *exc):
                pool.active -= 1
                return False

        return _Acquire()


def wire(monkeypatch: pytest.MonkeyPatch, responses) -> tuple[FakeConn, FakePool]:
    conn = FakeConn(responses)
    pool = FakePool(conn)
    monkeypatch.setattr(db, "pool", lambda: pool)
    monkeypatch.setattr(db, "is_connected", lambda: True)
    return conn, pool


def order_row(**overrides) -> dict:
    row = dict(
        order_id=ORDER, order_no=42, player_id=PLAYER, client_order_id=CLIENT, platform="google",
        product_id=PACK, status="pending", environment=None, external_id=None, purchase_token=None,
        steam_id=None, diamond_paid=0, diamond_free=0, first_bonus=False, price_amount=None,
        price_currency=None, note=None, created_at=NOW, credited_at=None, consumed_at=None, refunded_at=None,
    )
    row.update(overrides)
    return row


def wallet_row(paid: int = 0, free: int = 0, coin: int = 0, debt: int = 0) -> dict:
    return {"diamond_paid": paid, "diamond_free": free, "coin": coin, "diamond_debt": debt}


def _credited(order_id, env, external, token, paid, free, first, price, currency):
    return order_row(order_id=order_id, status="credited", environment=env, external_id=external,
                     purchase_token=token, diamond_paid=paid, diamond_free=free, first_bonus=first,
                     price_amount=price, price_currency=currency, credited_at=NOW)


def _cancelled_for_limit(order_id, env, external, token):
    return order_row(order_id=order_id, status="cancelled", environment=env, external_id=external,
                     purchase_token=token, note="test_daily_limit")


def credit_db(*, order=None, wallet=None, first_inserted=True, first_used=False, taken=None,
              recent_tests=0) -> list[tuple[str, object]]:
    """credit() 一趟要问的全部语句。"""
    return [
        ("from iap_orders where order_id = $1 for update", order or order_row()),
        ("select order_id from iap_orders where platform = $1 and external_id = $2", taken),
        ("from player_wallets where player_id = $1 for update", wallet or wallet_row()),
        ("insert into iap_first_bonus", 1 if first_inserted else None),
        ("select 1 from iap_first_bonus", 1 if first_used else None),
        ("select count(*) from iap_orders", recent_tests),
        ("update iap_orders set status = 'credited'", _credited),
        ("update iap_orders set status = 'cancelled', environment", _cancelled_for_limit),
        ("from player_wallets where player_id = $1", wallet or wallet_row()),
    ]


def proof(**overrides) -> iap.Proof:
    base = dict(platform="google", order_id=ORDER, product_id=PACK, external_id="ext-1",
                environment=iap.PRODUCTION, purchase_token=TOKEN)
    base.update(overrides)
    return iap.Proof(**base)


# --- 欠账（shop 那一半）---------------------------------------------------------


def test_debt_makes_the_balance_negative_so_spending_is_refused() -> None:
    """欠账时 diamond 是负数。商城和抽宠物都拿它判余额 —— 不用在每个花钻石的地方另加判断。"""
    w = shop.Wallet(0, 0, 0, diamond_debt=300)
    assert w.diamond == -300
    assert w.balance_of("diamond") < 1
    assert shop.Wallet(7, 3, 1).diamond == 10, "没欠账时照旧是付费 + 赠送"


def test_settle_debt_repays_from_paid_first_then_free() -> None:
    w = shop.Wallet(0, 0, 0, diamond_debt=300)
    assert shop.settle_debt(w, {"diamond_paid": 500, "diamond_free": 60}) == {
        "diamond_paid": 200, "diamond_free": 60, "diamond_debt": -300}
    assert shop.settle_debt(w, {"diamond_paid": 100, "diamond_free": 250}) == {
        "diamond_free": 50, "diamond_debt": -300}, "被欠账整个吃掉的那一列不能留下 0（流水 delta <> 0）"
    assert shop.settle_debt(w, {"diamond_free": 100}) == {"diamond_debt": -100}


def test_settle_debt_leaves_spending_coin_and_refunds_alone() -> None:
    w = shop.Wallet(0, 0, 50, diamond_debt=300)
    assert shop.settle_debt(w, {"coin": 100}) == {"coin": 100}
    assert shop.settle_debt(w, {"diamond_debt": 200}) == {"diamond_debt": 200}
    no_debt = shop.Wallet(10, 10, 0)
    changes = {"diamond_free": 100}
    assert shop.settle_debt(no_debt, changes) is changes


def test_every_credit_path_repays_debt_because_apply_does_it(monkeypatch) -> None:
    """邮件 / 七日登录 / 升级奖励都只调 _apply —— 欠账在那里抵，所有入账路径一处改全生效。"""
    conn, _ = wire(monkeypatch, [])
    after = asyncio.run(shop._apply(conn, PLAYER, shop.Wallet(0, 0, 0, 300), {"diamond_free": 100}, "mail", None))
    assert after == shop.Wallet(0, 0, 0, 200)
    assert conn.ledger() == [("diamond_debt", -100, "mail")]
    assert conn.wallet_update()[1:] == (0, 0, 0, 200)


def test_shop_purchase_is_refused_while_in_debt(monkeypatch) -> None:
    monkeypatch.setattr(shop, "item_by_id", lambda _id: shop.Item("p", "pet", "pet_x", "diamond", 75, "x", "x"))
    conn, _ = wire(monkeypatch, [
        ("from shop_orders where", None),
        ("from player_entitlements", None),
        ("for update", wallet_row(debt=300)),
    ])
    with pytest.raises(shop.ShopRejected) as exc:
        asyncio.run(shop.purchase(PLAYER, uuid.uuid4(), "p"))
    assert exc.value.code == "insufficient_funds"
    assert conn.wallet_update() is None and not conn.ledger()


# --- 目录 ---------------------------------------------------------------------


def test_real_catalog_loads_and_matches_the_design() -> None:
    """docs/充值系统设计.md 第二节：RM 1 = 10 钻、上线只开前 3 档、编号按档位起名。"""
    items = iap.catalog()
    assert [p.id for p in items.values()] == ["diamond_pack_%d" % n for n in range(1, 7)]
    for item in items.values():
        assert item.steam_prices["MYR"] == item.diamond * 10, "基础量严格 RM 1 = 10 钻（价格单位是 sen）"
    assert [p.enabled for p in items.values()] == [True, True, True, False, False, False]
    assert iap.amounts(items[PACK], first=True) == (500, 500)
    assert iap.amounts(items[PACK], first=False) == (500, 60)


@pytest.mark.parametrize("product, problem", [
    ({"id": "Diamond", "tier": 1, "diamond": 10, "steam_prices": {"MYR": 100}}, "不合法"),
    ({"id": "p", "tier": 0, "diamond": 10, "steam_prices": {"MYR": 100}}, "tier"),
    ({"id": "p", "tier": 1, "diamond": 0, "steam_prices": {"MYR": 100}}, "钻石数"),
    ({"id": "p", "tier": 1, "diamond": 10, "steam_prices": {"USD": 100}}, "MYR"),
    ({"id": "p", "tier": 1, "diamond": 10, "steam_prices": {"MYR": 0}}, "Steam 价"),
])
def test_bad_catalog_refuses_to_load(tmp_path, product, problem) -> None:
    path = tmp_path / "iap.json"
    path.write_text(json.dumps({"products": [product]}), encoding="utf-8")
    with pytest.raises(ValueError, match=problem):
        iap._load(path)


def test_duplicate_ids_and_tiers_refuse_to_load(tmp_path) -> None:
    one = {"id": "a", "tier": 1, "diamond": 10, "steam_prices": {"MYR": 100}}
    path = tmp_path / "iap.json"
    path.write_text(json.dumps({"products": [one, dict(one)]}), encoding="utf-8")
    with pytest.raises(ValueError, match="重复"):
        iap._load(path)
    path.write_text(json.dumps({"products": [one, dict(one, id="b")]}), encoding="utf-8")
    with pytest.raises(ValueError, match="tier"):
        iap._load(path)


# --- 建单 ---------------------------------------------------------------------


def test_closed_platform_refuses_new_orders(monkeypatch, _iap_settings) -> None:
    _iap_settings["s"] = _settings(iap_google_enabled=False)
    conn, _ = wire(monkeypatch, [])
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap.create_order(PLAYER, CLIENT, "google", PACK))
    assert exc.value.code == "iap_closed"
    assert not conn.queries, "关着的时候一条语句都不该发"


def test_disabled_tier_cannot_be_ordered(monkeypatch) -> None:
    wire(monkeypatch, [])
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap.create_order(PLAYER, CLIENT, "google", "diamond_pack_6"))
    assert exc.value.code == "unknown_product"


def test_retry_with_same_client_order_returns_the_same_order(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, [
        ("insert into iap_orders", None),
        ("where player_id = $1 and client_order_id = $2", order_row()),
    ])
    order, created = asyncio.run(iap.create_order(PLAYER, CLIENT, "google", PACK))
    assert (order.order_id, created) == (ORDER, False)


def test_same_client_order_for_another_tier_is_a_conflict(monkeypatch) -> None:
    wire(monkeypatch, [
        ("insert into iap_orders", None),
        ("where player_id = $1 and client_order_id = $2", order_row(product_id="diamond_pack_1")),
    ])
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap.create_order(PLAYER, CLIENT, "google", PACK))
    assert exc.value.code == "order_conflict"


# --- 入账 ---------------------------------------------------------------------


def test_first_purchase_doubles_with_the_extra_in_the_free_column(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db(first_inserted=True))
    outcome = asyncio.run(iap.credit(proof()))
    assert outcome.order.status == "credited" and outcome.order.first_bonus
    assert (outcome.order.diamond_paid, outcome.order.diamond_free) == (500, 500)
    assert conn.ledger() == [("diamond_paid", 500, "iap"), ("diamond_free", 500, "iap")]
    assert outcome.wallet.diamond == 1000


def test_later_purchase_gives_base_plus_regular_bonus(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db(first_inserted=False))
    outcome = asyncio.run(iap.credit(proof()))
    assert not outcome.order.first_bonus
    assert conn.ledger() == [("diamond_paid", 500, "iap"), ("diamond_free", 60, "iap")]


def test_credit_statement_order(monkeypatch) -> None:
    """锁订单 → 查凭证用没用过 → 锁钱包 → 定首充 → 改钱 → 改单。

    锁订单必须最先：重放（回执丢了的重试、Google 重复推的通知）要在动任何钱之前就认出来。
    改单必须最后：订单是 credited 而钱没到，那张单就再也不会被补。
    """
    conn, _ = wire(monkeypatch, credit_db())
    asyncio.run(iap.credit(proof()))
    order = [conn.index_of(f) for f in (
        "from iap_orders where order_id = $1 for update",
        "and external_id = $2 and order_id <> $3",
        "from player_wallets where player_id = $1 for update",
        "insert into iap_first_bonus",
        "update player_wallets",
        "update iap_orders set status = 'credited'",
    )]
    assert -1 not in order and order == sorted(order), conn.queries


def test_replay_of_a_credited_order_moves_no_money(monkeypatch) -> None:
    done = order_row(status="credited", environment="production", external_id="ext-1", credited_at=NOW,
                     diamond_paid=500, diamond_free=500, first_bonus=True)
    conn, _ = wire(monkeypatch, credit_db(order=done, wallet=wallet_row(paid=800)))
    outcome = asyncio.run(iap.credit(proof()))
    assert outcome.replayed and outcome.order.status == "credited"
    assert outcome.wallet.diamond == 800, "重放回的是当前余额"
    assert not conn.ledger() and conn.wallet_update() is None
    assert conn.count("iap_first_bonus") == 0


def test_cancelled_order_is_never_revived(monkeypatch) -> None:
    """已取消的单 Google 那边付了钱也不入账、不消耗：3 天后 Google 自己把钱退给玩家。"""
    conn, _ = wire(monkeypatch, credit_db(order=order_row(status="cancelled", note="google_canceled")))
    outcome = asyncio.run(iap.credit(proof()))
    assert outcome.order.status == "cancelled" and not conn.ledger()


def test_proof_already_used_by_another_order_is_refused(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db(taken=uuid.uuid4()))
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap.credit(proof()))
    assert exc.value.code == "proof_reused"
    assert not conn.ledger()


@pytest.mark.parametrize("order, bad", [
    (order_row(), {"product_id": "diamond_pack_1"}),
    (order_row(), {"platform": "apple"}),
    (order_row(platform="steam", environment="sandbox", external_id="t1"), {"platform": "steam", "external_id": "t1"}),
    (order_row(platform="steam", environment="production", external_id="t1"), {"platform": "steam", "external_id": "t2"}),
    (order_row(status="credited", environment="production", external_id="ext-1", credited_at=NOW), {"external_id": "ext-2"}),
])
def test_proof_that_does_not_match_the_order_is_refused(monkeypatch, order, bad) -> None:
    conn, _ = wire(monkeypatch, credit_db(order=order))
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap.credit(proof(**bad)))
    assert exc.value.code == "proof_mismatch"
    assert not conn.ledger()


def test_credit_repays_debt_first(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db(first_inserted=False, wallet=wallet_row(debt=300)))
    outcome = asyncio.run(iap.credit(proof()))
    assert conn.ledger() == [("diamond_paid", 200, "iap"), ("diamond_free", 60, "iap"), ("diamond_debt", -300, "iap")]
    assert outcome.wallet == shop.Wallet(200, 60, 0, 0)
    assert (outcome.order.diamond_paid, outcome.order.diamond_free) == (500, 60), "订单记的是这一单给了多少，不是净额"


# --- 测试单 ---------------------------------------------------------------------


def test_test_order_goes_entirely_to_the_free_column(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db(first_used=False))
    outcome = asyncio.run(iap.credit(proof(environment=iap.SANDBOX)))
    assert conn.ledger() == [("diamond_free", 1000, "iap_test")], "照真单的规则算（含首充双倍），但全进赠送列"
    assert (outcome.order.diamond_paid, outcome.order.diamond_free) == (0, 1000)
    assert outcome.order.environment == iap.SANDBOX


def test_test_order_does_not_use_up_the_first_bonus(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db())
    asyncio.run(iap.credit(proof(environment=iap.SANDBOX)))
    assert conn.count("insert into iap_first_bonus") == 0
    assert conn.count("select 1 from iap_first_bonus") == 1


def test_second_test_order_within_a_day_is_cancelled_without_money(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db(recent_tests=1))
    outcome = asyncio.run(iap.credit(proof(environment=iap.SANDBOX)))
    assert outcome.order.status == "cancelled" and outcome.order.note == "test_daily_limit"
    assert outcome.order.external_id == "ext-1", "记下凭证：重交时认得出是同一笔"
    assert not conn.ledger() and conn.wallet_update() is None


def test_test_orders_per_day_defaults_to_one() -> None:
    """🔴 正式上线时必须是 1。默认值就是线上值：.env 里忘了写这一项也不会放大。"""
    from app.config import Settings
    assert Settings.model_fields["iap_test_orders_per_day"].default == 1


def test_raised_test_limit_lets_testers_buy_again(monkeypatch, _iap_settings) -> None:
    """测流程那几天调大：同一个号 24 小时内第二张测试单照常入账。"""
    _iap_settings["s"] = _settings(iap_test_orders_per_day=3)
    conn, _ = wire(monkeypatch, credit_db(recent_tests=1))
    outcome = asyncio.run(iap.credit(proof(environment=iap.SANDBOX)))
    assert outcome.order.status == "credited" and conn.ledger() == [("diamond_free", 1000, "iap_test")]


# --- 退款 ---------------------------------------------------------------------


def refund_db(*, order, wallet) -> list[tuple[str, object]]:
    def refunded(order_id, note):
        return dict(order, status="refunded", refunded_at=NOW, note=note)
    return [
        ("where platform = $1 and external_id = $2 for update", order),
        ("from player_wallets where player_id = $1 for update", wallet),
        ("update iap_orders set status = 'refunded'", refunded),
        ("from player_wallets where player_id = $1", wallet),
    ]


CREDITED = order_row(status="credited", environment="production", external_id="ext-1", credited_at=NOW,
                     diamond_paid=500, diamond_free=500, first_bonus=True)


def test_refund_takes_paid_then_free_then_records_debt(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, refund_db(order=CREDITED, wallet=wallet_row(paid=500, free=200)))
    outcome = asyncio.run(iap.refund("google", "ext-1", "voided"))
    assert conn.ledger() == [("diamond_paid", -500, "refund"), ("diamond_free", -200, "refund"),
                             ("diamond_debt", 300, "refund")]
    assert outcome.wallet == shop.Wallet(0, 0, 0, 300) and outcome.wallet.diamond == -300
    assert outcome.order.status == "refunded"
    assert conn.count("iap_first_bonus") == 0, "退款不恢复首充资格"


def test_refund_with_enough_balance_leaves_no_debt(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, refund_db(order=CREDITED, wallet=wallet_row(paid=900, free=300)))
    asyncio.run(iap.refund("google", "ext-1", "voided"))
    assert conn.ledger() == [("diamond_paid", -900, "refund"), ("diamond_free", -100, "refund")]


@pytest.mark.parametrize("status", ["refunded", "pending", "cancelled"])
def test_refund_only_touches_credited_orders(monkeypatch, status) -> None:
    conn, _ = wire(monkeypatch, refund_db(order=dict(CREDITED, status=status), wallet=wallet_row(paid=500)))
    outcome = asyncio.run(iap.refund("google", "ext-1", "voided"))
    assert outcome.replayed and not conn.ledger()


def test_refund_for_an_unknown_order_returns_none(monkeypatch) -> None:
    wire(monkeypatch, [("where platform = $1 and external_id = $2 for update", None)])
    assert asyncio.run(iap.refund("google", "nope", "voided")) is None


# --- Google -----------------------------------------------------------------


@pytest.fixture
def google_key(tmp_path, _iap_settings):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    path = tmp_path / "sa.json"
    path.write_text(json.dumps({"client_email": "glory-play-billing@x.iam.gserviceaccount.com",
                                "private_key": pem, "private_key_id": "kid1",
                                "token_uri": "https://oauth2.googleapis.com/token"}), encoding="utf-8")
    _iap_settings["s"] = _settings(google_play_service_account_file=str(path))
    return key


def google_handler(purchase: dict, seen: list, *, status: int = 200, consume_status: int = 204, pool=None):
    def handler(request: httpx.Request) -> httpx.Response:
        if pool is not None:
            assert pool.active == 0, "向 Google 核实时手上握着数据库连接"
        seen.append(request)
        if request.url.host == "oauth2.googleapis.com":
            return httpx.Response(200, json={"access_token": "ya29.test", "expires_in": 3600})
        if request.url.path.endswith(":consume"):
            return httpx.Response(consume_status)
        return httpx.Response(status, json=purchase)
    return handler


def google_purchase(**overrides) -> dict:
    body = {"purchaseState": 0, "consumptionState": 0, "purchaseType": None,
            "obfuscatedExternalProfileId": str(ORDER),
            "obfuscatedExternalAccountId": iap_google.account_tag(PLAYER), "orderId": "GPA.1"}
    body.update(overrides)
    return {k: v for k, v in body.items() if v is not None}


def test_google_request_shape_and_service_account_assertion(google_key) -> None:
    seen: list[httpx.Request] = []
    got = asyncio.run(iap_google.get_purchase(PACK, TOKEN, httpx.MockTransport(google_handler(google_purchase(), seen))))
    assert got.state == iap_google.PURCHASED and not got.test
    token_req, get_req = seen
    assertion = dict(x.split("=", 1) for x in token_req.content.decode().split("&"))["assertion"]
    claims = jwt.decode(assertion, google_key.public_key(), algorithms=["RS256"],
                        audience="https://oauth2.googleapis.com/token")
    assert claims["scope"] == iap_google.SCOPE
    assert get_req.url.path == ("/androidpublisher/v3/applications/com.glory.game.google"
                                "/purchases/products/%s/tokens/%s" % (PACK, TOKEN))
    assert get_req.headers["Authorization"] == "Bearer ya29.test"


def test_google_errors_split_into_ours_and_theirs(google_key) -> None:
    for status, kind in ((404, iap_google.GoogleRejected), (410, iap_google.GoogleRejected),
                         (401, iap_google.GoogleUnavailable), (500, iap_google.GoogleUnavailable)):
        iap_google.reset()
        with pytest.raises(kind) as exc:
            asyncio.run(iap_google.get_purchase(PACK, TOKEN, httpx.MockTransport(
                google_handler({}, [], status=status))))
        assert TOKEN not in str(exc.value), "付款凭证不进报错"


def test_google_token_with_a_slash_never_reaches_the_url() -> None:
    with pytest.raises(iap_google.GoogleRejected):
        asyncio.run(iap_google.get_purchase(PACK, "abc/../../" + "a" * 20))


def test_google_missing_service_account_is_ours(_iap_settings) -> None:
    with pytest.raises(iap_google.GoogleUnavailable, match="SERVICE_ACCOUNT"):
        asyncio.run(iap_google.get_purchase(PACK, TOKEN))


def test_google_confirm_credits_then_consumes_without_holding_a_connection(monkeypatch, google_key) -> None:
    conn, pool = wire(monkeypatch, credit_db() + [("update iap_orders set consumed_at", None)])
    seen: list[httpx.Request] = []
    order = iap._order_of(order_row())
    outcome = asyncio.run(iap_google.confirm(order, TOKEN, httpx.MockTransport(
        google_handler(google_purchase(), seen, pool=pool))))
    assert outcome.order.status == "credited"
    assert outcome.order.external_id == iap_google.token_key(TOKEN), "去重键是凭证的 sha256"
    assert outcome.order.environment == iap.PRODUCTION
    assert seen[-1].url.path.endswith(":consume"), "入账提交之后才消耗"
    assert conn.count("set consumed_at = now()") == 1


def test_google_license_tester_purchase_is_a_test_order(monkeypatch, google_key) -> None:
    conn, _ = wire(monkeypatch, credit_db() + [("update iap_orders set consumed_at", None)])
    outcome = asyncio.run(iap_google.confirm(iap._order_of(order_row()), TOKEN, httpx.MockTransport(
        google_handler(google_purchase(purchaseType=0), []))))
    assert outcome.order.environment == iap.SANDBOX
    assert conn.ledger() == [("diamond_free", 1000, "iap_test")]


def test_google_consume_failure_does_not_fail_the_credit(monkeypatch, google_key) -> None:
    conn, _ = wire(monkeypatch, credit_db())
    outcome = asyncio.run(iap_google.confirm(iap._order_of(order_row()), TOKEN, httpx.MockTransport(
        google_handler(google_purchase(), [], consume_status=503))))
    assert outcome.order.status == "credited"
    assert conn.count("set consumed_at") == 0, "没消耗成功就不记，留给之后补"


def test_google_pending_payment_is_not_credited(monkeypatch, google_key) -> None:
    conn, _ = wire(monkeypatch, [("from iap_orders where order_id = $1", order_row()),
                                 ("from player_wallets where player_id = $1", wallet_row())])
    seen: list[httpx.Request] = []
    outcome = asyncio.run(iap_google.confirm(iap._order_of(order_row()), TOKEN, httpx.MockTransport(
        google_handler(google_purchase(purchaseState=2), seen))))
    assert outcome.order.status == "pending"
    assert not conn.ledger() and not any(r.url.path.endswith(":consume") for r in seen)


@pytest.mark.parametrize("bad", [
    {"obfuscatedExternalProfileId": str(uuid.uuid4())},
    {"obfuscatedExternalAccountId": iap_google.account_tag(OTHER)},
    {"obfuscatedExternalProfileId": None},
])
def test_google_token_bound_to_another_order_or_player_is_refused(monkeypatch, google_key, bad) -> None:
    conn, _ = wire(monkeypatch, credit_db())
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap_google.confirm(iap._order_of(order_row()), TOKEN, httpx.MockTransport(
            google_handler(google_purchase(**bad), []))))
    assert exc.value.code == "proof_mismatch" and not conn.ledger()


def test_google_test_order_over_the_limit_is_still_consumed(monkeypatch, google_key) -> None:
    """不消耗的话客户端每次启动都会再交一次这张凭证。"""
    wire(monkeypatch, credit_db(recent_tests=1) + [("update iap_orders set consumed_at", None)])
    seen: list[httpx.Request] = []
    outcome = asyncio.run(iap_google.confirm(iap._order_of(order_row()), TOKEN, httpx.MockTransport(
        google_handler(google_purchase(purchaseType=0), seen))))
    assert outcome.order.note == "test_daily_limit"
    assert seen[-1].url.path.endswith(":consume")


# --- Apple ------------------------------------------------------------------


def _name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def _cert(cn, issuer_cn, key, issuer_key, *, ca, oid=None, start=None, days=3650):
    start = start or dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(_name(cn)).issuer_name(_name(issuer_cn))
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(start).not_valid_after(start + dt.timedelta(days=days))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True))
    if oid is not None:
        builder = builder.add_extension(x509.UnrecognizedExtension(oid, b"\x05\x00"), critical=False)
    return builder.sign(issuer_key, hashes.SHA256())


class AppleChain:
    def __init__(self, tmp_path, *, leaf_oid=iap_apple.LEAF_OID, leaf_days=3650) -> None:
        self.root_key = ec.generate_private_key(ec.SECP256R1())
        self.mid_key = ec.generate_private_key(ec.SECP256R1())
        self.leaf_key = ec.generate_private_key(ec.SECP256R1())
        self.root = _cert("Test Root", "Test Root", self.root_key, self.root_key, ca=True)
        self.mid = _cert("Test WWDR", "Test Root", self.mid_key, self.root_key, ca=True,
                         oid=iap_apple.INTERMEDIATE_OID)
        self.leaf = _cert("Test Leaf", "Test WWDR", self.leaf_key, self.mid_key, ca=False,
                          oid=leaf_oid, days=leaf_days)
        self.root_path = tmp_path / "root.cer"
        self.root_path.write_bytes(self.root.public_bytes(serialization.Encoding.DER))

    def sign(self, **overrides) -> str:
        payload = {"transactionId": "2000000123", "originalTransactionId": "2000000123",
                   "bundleId": "com.superforge.glory", "productId": PACK, "type": "Consumable",
                   "appAccountToken": str(ORDER), "environment": "Production",
                   "signedDate": int(dt.datetime(2026, 10, 27, tzinfo=dt.timezone.utc).timestamp() * 1000),
                   "price": 50000, "currency": "MYR"}
        payload.update(overrides)
        payload = {k: v for k, v in payload.items() if v is not None}
        x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode()
               for c in (self.leaf, self.mid, self.root)]
        return jwt.encode(payload, self.leaf_key, algorithm="ES256", headers={"x5c": x5c})


@pytest.fixture
def apple(tmp_path, _iap_settings):
    chain = AppleChain(tmp_path)
    _iap_settings["s"] = _settings(apple_root_cert_file=str(chain.root_path))
    return chain


def test_apple_valid_transaction_verifies(apple) -> None:
    tx = iap_apple.verify(apple.sign())
    assert (tx.transaction_id, tx.product_id, tx.environment) == ("2000000123", PACK, "Production")
    assert tx.app_account_token == str(ORDER)


def test_apple_chain_signed_by_someone_else_is_refused(tmp_path, _iap_settings) -> None:
    """🔴 x5c 里自带的根不算数：任何人都能拿一套自签证书签出「付过款」。"""
    (tmp_path / "ours").mkdir()
    (tmp_path / "forged").mkdir()
    ours, forged = AppleChain(tmp_path / "ours"), AppleChain(tmp_path / "forged")
    _iap_settings["s"] = _settings(apple_root_cert_file=str(ours.root_path))
    with pytest.raises(iap_apple.AppleRejected, match="证书链"):
        iap_apple.verify(forged.sign())


def test_apple_leaf_without_the_app_store_oid_is_refused(tmp_path, _iap_settings) -> None:
    chain = AppleChain(tmp_path, leaf_oid=None)
    _iap_settings["s"] = _settings(apple_root_cert_file=str(chain.root_path))
    with pytest.raises(iap_apple.AppleRejected, match="不是 App Store"):
        iap_apple.verify(chain.sign())


def test_apple_tampered_payload_is_refused(apple) -> None:
    head, body, sig = apple.sign().split(".")
    claims = json.loads(base64.urlsafe_b64decode(body + "=="))
    claims["productId"] = "diamond_pack_6"
    forged_body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    with pytest.raises(iap_apple.AppleRejected, match="签名"):
        iap_apple.verify(".".join((head, forged_body, sig)))


def test_apple_other_bundle_is_refused(apple) -> None:
    with pytest.raises(iap_apple.AppleRejected, match="不是这个 App"):
        iap_apple.verify(apple.sign(bundleId="com.example.other"))


def test_apple_certificate_validity_is_judged_at_signed_date(tmp_path, _iap_settings) -> None:
    """签的那一刻证书有效就算数 —— 退款这类事可能几个月后才来。"""
    chain = AppleChain(tmp_path, leaf_days=30)  # 2020-01-01 起 30 天
    _iap_settings["s"] = _settings(apple_root_cert_file=str(chain.root_path))
    inside = int(dt.datetime(2020, 1, 15, tzinfo=dt.timezone.utc).timestamp() * 1000)
    assert iap_apple.verify(chain.sign(signedDate=inside)).transaction_id
    with pytest.raises(iap_apple.AppleRejected, match="有效期"):
        iap_apple.verify(chain.sign())  # 2026 年签的，证书早过期了


def test_apple_missing_root_is_ours(_iap_settings) -> None:
    with pytest.raises(iap_apple.AppleUnavailable, match="APPLE_ROOT_CERT_FILE"):
        iap_apple.verify("x.y.z")


def test_apple_confirm_credits_with_transaction_id(monkeypatch, apple) -> None:
    conn, _ = wire(monkeypatch, credit_db(order=order_row(platform="apple")))
    outcome = asyncio.run(iap_apple.confirm(iap._order_of(order_row(platform="apple")), apple.sign()))
    assert outcome.order.external_id == "2000000123"
    assert (outcome.order.price_amount, outcome.order.price_currency) == (5000, "MYR"), "千分之一单位换成 sen"
    assert conn.ledger() == [("diamond_paid", 500, "iap"), ("diamond_free", 500, "iap")]


def test_apple_sandbox_is_a_test_order(monkeypatch, apple) -> None:
    conn, _ = wire(monkeypatch, credit_db(order=order_row(platform="apple")))
    asyncio.run(iap_apple.confirm(iap._order_of(order_row(platform="apple")), apple.sign(environment="Sandbox")))
    assert conn.ledger() == [("diamond_free", 1000, "iap_test")]


@pytest.mark.parametrize("bad, code", [
    ({"appAccountToken": str(uuid.uuid4())}, "proof_mismatch"),
    ({"productId": "diamond_pack_1"}, "proof_mismatch"),
])
def test_apple_transaction_for_another_order_is_refused(monkeypatch, apple, bad, code) -> None:
    conn, _ = wire(monkeypatch, credit_db(order=order_row(platform="apple")))
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap_apple.confirm(iap._order_of(order_row(platform="apple")), apple.sign(**bad)))
    assert exc.value.code == code and not conn.ledger()


@pytest.mark.parametrize("bad", [{"type": "Non-Consumable"}, {"environment": "Xcode"}])
def test_apple_wrong_type_or_environment_is_refused(monkeypatch, apple, bad) -> None:
    conn, _ = wire(monkeypatch, credit_db(order=order_row(platform="apple")))
    with pytest.raises(iap_apple.AppleRejected):
        asyncio.run(iap_apple.confirm(iap._order_of(order_row(platform="apple")), apple.sign(**bad)))
    assert not conn.ledger()


# --- Steam ------------------------------------------------------------------


def steam_handler(seen: list, *, status: str = "Approved", currency: str = "MYR", init_ok: bool = True,
                  steamid: str = STEAM_ID, finalize_ok: bool = True, pool=None):
    def ok(params):
        return httpx.Response(200, json={"response": {"result": "OK", "params": params}})

    def handler(request: httpx.Request) -> httpx.Response:
        if pool is not None:
            assert pool.active == 0, "向 Steam 下单 / 核实时手上握着数据库连接"
        seen.append(request)
        path = request.url.path
        if path.endswith("/GetUserInfo/v2/"):
            return ok({"state": "", "country": "MY", "currency": currency, "status": "Active"})
        if path.endswith("/InitTxn/v3/"):
            if not init_ok:
                return httpx.Response(200, json={"response": {"result": "Failure",
                                                              "error": {"errorcode": 7, "errordesc": "bad"}}})
            return ok({"orderid": "42", "transid": "9001"})
        if path.endswith("/QueryTxn/v3/"):
            return ok({"orderid": "42", "transid": "9001", "steamid": steamid, "status": status})
        if path.endswith("/FinalizeTxn/v2/"):
            if not finalize_ok:
                return httpx.Response(200, json={"response": {"result": "Failure",
                                                              "error": {"errorcode": 101, "errordesc": "late"}}})
            return ok({"orderid": "42", "transid": "9001"})
        raise AssertionError(path)
    return handler


def steam_order(**overrides) -> dict:
    base = dict(platform="steam", steam_id=STEAM_ID, environment="production", external_id="9001",
                price_amount=5000, price_currency="MYR")
    base.update(overrides)
    return order_row(**base)


def test_steam_begin_request_shape(monkeypatch) -> None:
    created = steam_order(external_id=None)
    conn, pool = wire(monkeypatch, [
        ("insert into iap_orders", created),
        ("update iap_orders set external_id", None),
        ("from iap_orders where order_id = $1", steam_order()),
        ("from player_wallets where player_id = $1", wallet_row()),
    ])
    seen: list[httpx.Request] = []
    outcome = asyncio.run(iap_steam.begin(PLAYER, CLIENT, PACK, STEAM_ID, "zh",
                                          httpx.MockTransport(steam_handler(seen, pool=pool))))
    assert outcome.order.status == "pending"
    init = next(r for r in seen if r.url.path.endswith("/InitTxn/v3/"))
    assert init.url.path == "/ISteamMicroTxn/InitTxn/v3/"
    form = dict(x.split("=", 1) for x in init.content.decode().split("&"))
    assert form["orderid"] == "42" and form["steamid"] == STEAM_ID
    assert form["itemid%5B0%5D"] == "3" and form["amount%5B0%5D"] == "5000" and form["currency"] == "MYR"
    assert form["usersession"] == "client" and form["language"] == "zh"
    insert = conn.args[conn.index_of("insert into iap_orders")]
    assert insert[6:9] == (iap.PRODUCTION, 5000, "MYR"), "环境和价格下单时就定了"


def test_steam_browser_order_asks_with_ip_and_returns_the_url(monkeypatch, _iap_settings) -> None:
    """usersession=web：沙盒检查脚本、以及以后 overlay 弹不出来时的退路。开关关着也能用（只给服务器脚本）。"""
    _iap_settings["s"] = _settings(iap_steam_enabled=False)
    wire(monkeypatch, [("insert into iap_orders", steam_order(external_id=None)),
                       ("from iap_orders where order_id = $1", steam_order()),
                       ("from player_wallets where player_id = $1", wallet_row())])
    seen: list[httpx.Request] = []

    def handler(request):
        if request.url.path.endswith("/InitTxn/v3/"):
            seen.append(request)
            return httpx.Response(200, json={"response": {"result": "OK", "params": {
                "orderid": "42", "transid": "9001", "steamurl": "https://store.steampowered.com/checkout/approvetxn/9001"}}})
        seen.append(request)
        return steam_handler([])(request)

    outcome, url = asyncio.run(iap_steam.begin_in_browser(
        PLAYER, CLIENT, PACK, STEAM_ID, "en", "203.0.113.7", even_if_closed=True,
        transport=httpx.MockTransport(handler)))
    assert url.endswith("/approvetxn/9001") and outcome.order.status == "pending"
    info = next(r for r in seen if r.url.path.endswith("/GetUserInfo/v2/"))
    assert info.url.params["ipaddress"] == "203.0.113.7"
    init = next(r for r in seen if r.url.path.endswith("/InitTxn/v3/"))
    form = dict(x.split("=", 1) for x in init.content.decode().split("&"))
    assert form["usersession"] == "web" and form["ipaddress"] == "203.0.113.7"


def test_player_routes_never_bypass_the_switch() -> None:
    """even_if_closed 只给服务器上的运营脚本。玩家走的路由里出现它 = 开关形同虚设。"""
    assert "even_if_closed" not in (REPO / "backend" / "app" / "routes" / "iap.py").read_text(encoding="utf-8")


def test_steam_wallet_in_another_currency_pays_in_usd(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, [("insert into iap_orders", steam_order(external_id=None)),
                                 ("from iap_orders where order_id = $1", steam_order()),
                                 ("from player_wallets where player_id = $1", wallet_row())])
    asyncio.run(iap_steam.begin(PLAYER, CLIENT, PACK, STEAM_ID, "en",
                                httpx.MockTransport(steam_handler([], currency="EUR"))))
    insert = conn.args[conn.index_of("insert into iap_orders")]
    assert insert[7:9] == (1199, "USD")


def test_steam_testers_go_to_the_sandbox(monkeypatch, _iap_settings) -> None:
    _iap_settings["s"] = _settings(steam_sandbox_steam_ids=" 1, %s ," % STEAM_ID)
    conn, _ = wire(monkeypatch, [("insert into iap_orders", steam_order(external_id=None, environment="sandbox")),
                                 ("from iap_orders where order_id = $1", steam_order(environment="sandbox")),
                                 ("from player_wallets where player_id = $1", wallet_row())])
    seen: list[httpx.Request] = []
    asyncio.run(iap_steam.begin(PLAYER, CLIENT, PACK, STEAM_ID, "en", httpx.MockTransport(steam_handler(seen))))
    assert all(r.url.path.startswith("/ISteamMicroTxnSandbox/") for r in seen)
    assert conn.args[conn.index_of("insert into iap_orders")][6] == iap.SANDBOX


def test_steam_retry_does_not_place_a_second_steam_order(monkeypatch) -> None:
    wire(monkeypatch, [("insert into iap_orders", None),
                       ("where player_id = $1 and client_order_id = $2", steam_order()),
                       ("from iap_orders where order_id = $1", steam_order()),
                       ("from player_wallets where player_id = $1", wallet_row())])
    seen: list[httpx.Request] = []
    asyncio.run(iap_steam.begin(PLAYER, CLIENT, PACK, STEAM_ID, "en", httpx.MockTransport(steam_handler(seen))))
    assert not any(r.url.path.endswith("/InitTxn/v3/") for r in seen)


def test_steam_init_failure_cancels_the_order(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, [
        ("insert into iap_orders", steam_order(external_id=None)),
        ("from iap_orders where order_id = $1 for update", steam_order(external_id=None)),
        ("update iap_orders set status = 'cancelled'", lambda oid, note: steam_order(status="cancelled", note=note)),
        ("from player_wallets where player_id = $1", wallet_row()),
    ])

    def handler(request):
        if request.url.path.endswith("/QueryTxn/v3/"):
            return httpx.Response(200, json={"response": {"result": "Failure", "error": {"errorcode": 3}}})
        return steam_handler([], init_ok=False)(request)

    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap_steam.begin(PLAYER, CLIENT, PACK, STEAM_ID, "en", httpx.MockTransport(handler)))
    assert exc.value.code == "steam_init_failed"
    assert conn.count("set status = 'cancelled'") == 1


def test_steam_settle_finalizes_then_credits(monkeypatch) -> None:
    conn, pool = wire(monkeypatch, credit_db(order=steam_order()))
    seen: list[httpx.Request] = []
    outcome = asyncio.run(iap_steam.settle(iap._order_of(steam_order()), transport=httpx.MockTransport(
        steam_handler(seen, pool=pool))))
    paths = [r.url.path.rsplit("/", 3)[-3] for r in seen]
    assert paths == ["QueryTxn", "FinalizeTxn"], "先问状态、批准了才扣款"
    assert outcome.order.status == "credited" and outcome.order.external_id == "9001"
    assert conn.ledger() == [("diamond_paid", 500, "iap"), ("diamond_free", 500, "iap")]


def test_steam_already_finalized_is_credited_without_finalizing_again(monkeypatch) -> None:
    wire(monkeypatch, credit_db(order=steam_order()))
    seen: list[httpx.Request] = []
    outcome = asyncio.run(iap_steam.settle(iap._order_of(steam_order()), transport=httpx.MockTransport(
        steam_handler(seen, status="Succeeded"))))
    assert outcome.order.status == "credited"
    assert not any(r.url.path.endswith("/FinalizeTxn/v2/") for r in seen)


def test_steam_client_says_declined_but_steam_approved_wins(monkeypatch) -> None:
    """以 Steam 为准，不以客户端为准。"""
    wire(monkeypatch, credit_db(order=steam_order()))
    outcome = asyncio.run(iap_steam.settle(iap._order_of(steam_order()), declined=True,
                                           transport=httpx.MockTransport(steam_handler([]))))
    assert outcome.order.status == "credited"


@pytest.mark.parametrize("status, declined, expect", [
    ("Init", True, "cancelled"),
    ("Init", False, "pending"),
    ("Failed", False, "cancelled"),
])
def test_steam_settle_without_payment(monkeypatch, status, declined, expect) -> None:
    conn, _ = wire(monkeypatch, [
        ("from iap_orders where order_id = $1 for update", steam_order()),
        ("update iap_orders set status = 'cancelled'", lambda oid, note: steam_order(status="cancelled", note=note)),
        ("from iap_orders where order_id = $1", steam_order()),
        ("from player_wallets where player_id = $1", wallet_row()),
    ])
    outcome = asyncio.run(iap_steam.settle(iap._order_of(steam_order()), declined=declined,
                                           transport=httpx.MockTransport(steam_handler([], status=status))))
    assert outcome.order.status == expect and not conn.ledger()


def test_steam_txn_for_another_steam_account_is_refused(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, credit_db(order=steam_order()))
    with pytest.raises(iap.IapRejected) as exc:
        asyncio.run(iap_steam.settle(iap._order_of(steam_order()), transport=httpx.MockTransport(
            steam_handler([], steamid="76561198000000999"))))
    assert exc.value.code == "proof_mismatch" and not conn.ledger()


def test_steam_key_never_appears_in_errors(monkeypatch) -> None:
    def handler(request):
        return httpx.Response(403, text="denied " + request.url.params.get("key", ""))
    with pytest.raises(steam.SteamUnavailable) as exc:
        asyncio.run(iap_steam.query_txn(42, False, httpx.MockTransport(handler)))
    assert KEY not in str(exc.value)


# --- 接口 ---------------------------------------------------------------------


class _FakeVerifier:
    async def verify(self, token: str) -> Claims:
        if token != "token-a":
            raise TokenError("令牌校验失败")
        return Claims(auth_uid="auth-a", is_anonymous=False, expires_at=0)


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)

    async def _lookup(auth_uid: str):
        return players.Player(PLAYER, "阿甲", False, "AAAA2222") if auth_uid == "auth-a" else None

    async def _valid_session(_auth_uid, _session_id):
        return None

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    monkeypatch.setattr(login_sessions, "require", _valid_session)
    iap_routes._order_limiter.reset()
    iap_routes._confirm_limiter.reset()
    with TestClient(app) as c:
        yield c
    get_settings.cache_clear()


AUTH = {"Authorization": "Bearer token-a"}


def test_routes_are_wired_into_the_app(client) -> None:
    """接进了 main.py：没登录是 401（鉴权拦下），不是 404（根本没这个接口）。"""
    assert client.get("/v1/iap/catalog", params={"platform": "google"}).status_code == 401
    assert client.get("/v1/iap/orders/%s" % ORDER).status_code == 401
    for path in ("/v1/iap/orders", "/v1/iap/google/confirm", "/v1/iap/apple/confirm", "/v1/iap/steam/confirm"):
        assert client.post(path, json={}).status_code in (401, 422), path


def test_order_body_has_no_price_or_amount() -> None:
    """客户端只发意图。价格、钻石数都从服务器目录取。"""
    assert set(iap_routes.CreateOrderBody.model_fields) == {
        "client_order_id", "platform", "product_id", "steam_ticket", "language"}


def test_catalog_shows_first_bonus_per_tier_and_debt(monkeypatch, client) -> None:
    wire(monkeypatch, [("select product_id from iap_first_bonus", [{"product_id": "diamond_pack_1"}]),
                       ("from player_wallets where player_id = $1", wallet_row(debt=120))])
    r = client.get("/v1/iap/catalog", params={"platform": "google"}, headers=AUTH)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["open"] is True and body["diamond"] == -120 and body["debt"] == 120
    assert [(p["id"], p["first_bonus"]) for p in body["products"]] == [
        ("diamond_pack_1", False), ("diamond_pack_2", True), ("diamond_pack_3", True)]
    assert body["products"][0]["steam_prices"] == {}, "只有 Steam 才发价格"


def test_google_order_response_carries_what_billing_needs(monkeypatch, client) -> None:
    wire(monkeypatch, [("insert into iap_orders", order_row()),
                       ("from iap_orders where order_id = $1", order_row()),
                       ("from player_wallets where player_id = $1", wallet_row())])
    r = client.post("/v1/iap/orders", headers=AUTH, json={
        "client_order_id": str(CLIENT), "platform": "google", "product_id": PACK})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["order_id"] == str(ORDER) and body["status"] == "pending"
    assert body["obfuscated_account_id"] == iap_google.account_tag(PLAYER)


def test_steam_order_with_switch_off_never_contacts_steam(monkeypatch, client, _iap_settings) -> None:
    _iap_settings["s"] = _settings(iap_steam_enabled=False)
    wire(monkeypatch, [])

    async def boom(*_a, **_k):
        raise AssertionError("开关关着还去连 Steam")

    monkeypatch.setattr(steam, "authenticate_ticket", boom)
    r = client.post("/v1/iap/orders", headers=AUTH, json={
        "client_order_id": str(CLIENT), "platform": "steam", "product_id": PACK, "steam_ticket": "ab" * 20})
    assert r.status_code == 503 and r.headers["X-Glory-Reason"] == "iap_closed"


def test_steam_account_not_linked_to_this_player_is_refused(monkeypatch, client) -> None:
    wire(monkeypatch, [])

    async def ticket(_t):
        return steam.SteamUser(steam_id=STEAM_ID, owner_steam_id=STEAM_ID)

    async def identities(self, _token):
        return False, [LinkedIdentity(STEAM_PROVIDER, steam.placeholder_email("76561198000000999"))]

    monkeypatch.setattr(steam, "authenticate_ticket", ticket)
    monkeypatch.setattr(iap_routes.SupabaseAuth, "linked_identities", identities)
    r = client.post("/v1/iap/orders", headers=AUTH, json={
        "client_order_id": str(CLIENT), "platform": "steam", "product_id": PACK, "steam_ticket": "ab" * 20})
    assert r.status_code == 403 and r.headers["X-Glory-Reason"] == "steam_not_linked"


def test_confirm_works_even_when_the_switch_is_off(monkeypatch, client, _iap_settings, google_key) -> None:
    """🔴 关开关只挡建新单 —— 已经付了钱的单必须照样能入账。"""
    _iap_settings["s"] = _settings(iap_google_enabled=False,
                                   google_play_service_account_file=_iap_settings["s"].google_play_service_account_file)
    wire(monkeypatch, [("from iap_orders where order_id = $1 and player_id = $2", order_row())]
         + credit_db() + [("update iap_orders set consumed_at", None)])
    real_client = httpx.AsyncClient

    def fake_client(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(google_handler(google_purchase(), []))
        return real_client(*args, **kwargs)

    monkeypatch.setattr(iap_google.httpx, "AsyncClient", fake_client)
    r = client.post("/v1/iap/google/confirm", headers=AUTH, json={"order_id": str(ORDER), "purchase_token": TOKEN})
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "credited" and r.json()["credited"] == 1000


def test_someone_elses_order_looks_like_no_order(monkeypatch, client) -> None:
    wire(monkeypatch, [("from iap_orders where order_id = $1 and player_id = $2", None)])
    r = client.post("/v1/iap/google/confirm", headers=AUTH, json={"order_id": str(ORDER), "purchase_token": TOKEN})
    assert r.status_code == 404 and r.headers["X-Glory-Reason"] == "unknown_order"


def test_platform_outage_is_503_so_the_client_shows_processing(monkeypatch, client) -> None:
    """服务器没配服务账号 / 连不上 Google：503，客户端显示「处理中」，不能显示失败。"""
    wire(monkeypatch, [("from iap_orders where order_id = $1 and player_id = $2", order_row()),
                       ("from player_wallets where player_id = $1", wallet_row())])
    r = client.post("/v1/iap/google/confirm", headers=AUTH, json={"order_id": str(ORDER), "purchase_token": TOKEN})
    assert r.status_code == 503 and r.headers["X-Glory-Reason"] == "platform_unavailable"


# --- 迁移、部署、自检 -----------------------------------------------------------


def test_migration_dedups_by_platform_and_external_id() -> None:
    assert "create unique index if not exists iap_orders_external" in SQL_040_CODE
    assert "on iap_orders (platform, external_id) where external_id is not null" in SQL_040_CODE
    assert "unique (player_id, client_order_id)" in SQL_040_CODE


def test_migration_keeps_debt_and_balance_exclusive() -> None:
    assert "check (diamond_debt = 0 or (diamond_paid = 0 and diamond_free = 0))" in SQL_040_CODE
    assert "check (diamond_debt >= 0)" in SQL_040_CODE


def test_migration_removes_the_dead_reservation_on_shop_orders() -> None:
    """010 给充值留的 external_id 永远用不上了。留着就是地雷：下一个人会以为充值去重在那里。"""
    assert "drop index if exists shop_orders_external" in SQL_040_CODE
    assert "alter table shop_orders drop column if exists external_id" in SQL_040_CODE
    assert "external_id" not in (REPO / "backend" / "app" / "shop.py").read_text(encoding="utf-8")


def test_iap_orders_are_never_pruned() -> None:
    """同 wallet_ledger：退款要回溯到具体哪一笔充值，注销后平台也可能发来退款通知。"""
    assert "iap_orders" not in (REPO / "backend" / "app" / "maintenance.py").read_text(encoding="utf-8")


def test_deploy_copies_the_catalog() -> None:
    assert "iap_products.json" in (REPO / "deploy" / "update.sh").read_text(encoding="utf-8")


def test_pet_draw_odds_shown_to_players_match_the_server() -> None:
    """🔴 钻石能用钱买之后，Google 和 Apple 都要求抽之前公示概率（docs/充值系统设计.md 第九、十三节）。

    公示文字在 scenes/menu/PetDrawDialog.gd 里是写死的，真规则在 backend/app/pet_draw.py。
    改了一边忘了另一边，商店审核看到的就是一个假概率。
    """
    from app import pet_draw
    dialog = (REPO / "scenes" / "menu" / "PetDrawDialog.gd").read_text(encoding="utf-8")
    draw_py = (REPO / "backend" / "app" / "pet_draw.py").read_text(encoding="utf-8")
    shop_routes_py = (REPO / "backend" / "app" / "routes" / "shop.py").read_text(encoding="utf-8")
    assert "secrets.randbelow(10) == 0" in draw_py and "chance_percent=10" in shop_routes_py, "抽中概率改了，公示也要改"
    assert "每抽消耗 %d 钻石" % pet_draw.PRICE in dialog and "%d gems per draw" % pet_draw.PRICE in dialog
    assert "概率 10%" in dialog and "10% pet chance" in dialog
    assert "第 %d 抽必得" % pet_draw.PITY_LIMIT in dialog and "draw %d guarantees" % pet_draw.PITY_LIMIT in dialog
    assert "%d 金币" % pet_draw.MISS_COIN in dialog and "%d coins" % pet_draw.MISS_COIN in dialog
    assert "保底命中才清零" in dialog, "能量只有保底那一抽才清零（pet_draw.draw 的 after_energy）"


def test_startup_check_prepares_the_wallet_and_order_statements() -> None:
    """040 漏跑时商城、抽宠物、邮件领取会一起 500 —— 要在部署那一刻就喊出来。"""
    names = {name for name, _ in schema_check._PREPARED}
    assert {"shop.LOCK_WALLET", "iap.LOCK_ORDER"} <= names
    assert any("040" in label for label, _sql, _hurts in schema_check._PROBES)


# =====================================================================================
# 第 2 步：平台通知、定时对账、到账 / 退款说明邮件
# =====================================================================================


# --- 说明邮件 -------------------------------------------------------------------


def _mail_args(conn: FakeConn) -> tuple:
    return next(a for q, a in zip(conn.queries, conn.args) if q.startswith("insert into mails"))


def test_credit_notice_mail_has_no_attachment(monkeypatch) -> None:
    """🔴 钱在 credit() 里已经进了付费列。邮件只说一句话 —— 带附件的话会再发一次、而且进赠送列。"""
    conn, _ = wire(monkeypatch, [])
    order = iap._order_of(order_row(status="credited", diamond_paid=500, diamond_free=500, first_bonus=True))
    asyncio.run(iap.mail_notice(iap.Outcome(order, shop.Wallet(500, 500, 0))))
    columns = next(q for q in conn.queries if q.startswith("insert into mails")).split("values")[0]
    assert "diamond" not in columns and "items" not in columns and "coin" not in columns
    player, title_zh, body_zh, _title_en, body_en, note = _mail_args(conn)
    assert player == PLAYER and title_zh == "充值到账"
    assert "1000" in body_zh and "首充" in body_zh and "#42" in body_zh and "1000" in body_en
    assert str(ORDER) in note


def test_refund_notice_mail_mentions_debt(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, [])
    order = iap._order_of(dict(CREDITED, status="refunded", refunded_at=NOW))
    asyncio.run(iap.mail_notice(iap.Outcome(order, shop.Wallet(0, 0, 0, 300))))
    _p, title_zh, body_zh, _t, body_en, _n = _mail_args(conn)
    assert title_zh == "充值已退款" and "1000" in body_zh and "欠 300" in body_zh and "300" in body_en


def test_notice_mail_skips_other_states_and_never_raises(monkeypatch) -> None:
    conn, _ = wire(monkeypatch, [])
    asyncio.run(iap.mail_notice(iap.Outcome(iap._order_of(order_row()), shop.EMPTY_WALLET)))
    assert not conn.queries

    class Broken:
        def acquire(self):
            raise RuntimeError("库挂了")

    monkeypatch.setattr(db, "pool", lambda: Broken())
    asyncio.run(iap.mail_notice(iap.Outcome(iap._order_of(order_row(status="credited")), shop.EMPTY_WALLET)))


# --- Google 推送身份 --------------------------------------------------------------


@pytest.fixture
def push_key():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update({"kid": "push-1", "alg": "RS256", "use": "sig"})
    return key, {"keys": [jwk]}


def push_token(key, **overrides) -> str:
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    claims = {"iss": "https://accounts.google.com", "aud": PUSH_AUDIENCE, "email": PUSH_ACCOUNT,
              "email_verified": True, "iat": now, "exp": now + 3600, "sub": "1234"}
    claims.update(overrides)
    claims = {k: v for k, v in claims.items() if v is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "push-1"})


def certs_transport(jwks: dict, seen: list | None = None) -> httpx.MockTransport:
    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request)
        assert str(request.url) == iap_google.CERTS_URL
        return httpx.Response(200, json=jwks)
    return httpx.MockTransport(handler)


def test_push_from_our_subscription_is_accepted(push_key) -> None:
    key, jwks = push_key
    asyncio.run(iap_google.verify_push("Bearer " + push_token(key), certs_transport(jwks)))


@pytest.mark.parametrize("claims", [
    {"aud": "https://someone-else.example/rtdn"},
    {"email": "attacker@evil.iam.gserviceaccount.com"},
    {"email_verified": False},
    {"iss": "https://evil.example"},
    {"email": None},
    {"exp": 1000},
])
def test_push_with_wrong_identity_is_refused(push_key, claims) -> None:
    key, jwks = push_key
    with pytest.raises(iap_google.GoogleRejected):
        asyncio.run(iap_google.verify_push("Bearer " + push_token(key, **claims), certs_transport(jwks)))


def test_push_signed_by_another_key_or_algorithm_is_refused(push_key) -> None:
    _key, jwks = push_key
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with pytest.raises(iap_google.GoogleRejected):
        asyncio.run(iap_google.verify_push("Bearer " + push_token(other), certs_transport(jwks)))
    hs = jwt.encode({"iss": "https://accounts.google.com", "aud": PUSH_AUDIENCE, "email": PUSH_ACCOUNT},
                    "shared-secret-shared-secret-shared", algorithm="HS256", headers={"kid": "push-1"})
    with pytest.raises(iap_google.GoogleRejected, match="算法"):
        asyncio.run(iap_google.verify_push("Bearer " + hs, certs_transport(jwks)))
    with pytest.raises(iap_google.GoogleRejected):
        asyncio.run(iap_google.verify_push(None, certs_transport(jwks)))


def test_push_without_configured_identity_is_ours(_iap_settings, push_key) -> None:
    """没配就 503：Pub/Sub 会一直重推，配好之后自动补上 —— 不能 2xx 把通知吞了。"""
    key, jwks = push_key
    _iap_settings["s"] = _settings(google_rtdn_audience="")
    with pytest.raises(iap_google.GoogleUnavailable, match="RTDN"):
        asyncio.run(iap_google.verify_push("Bearer " + push_token(key), certs_transport(jwks)))


def test_push_certs_are_cached(push_key) -> None:
    key, jwks = push_key
    seen: list[httpx.Request] = []
    for _ in range(3):
        asyncio.run(iap_google.verify_push("Bearer " + push_token(key), certs_transport(jwks, seen)))
    assert len(seen) == 1


# --- RTDN 内容 -----------------------------------------------------------------


def rtdn(data: dict) -> dict:
    return {"message": {"data": base64.b64encode(json.dumps(data).encode()).decode(), "messageId": "1"},
            "subscription": "projects/p/subscriptions/play-billing-rtdn-push"}


def one_time(kind: int, package: str = "com.glory.game.google") -> dict:
    return rtdn({"version": "1.0", "packageName": package, "eventTimeMillis": "1",
                 "oneTimeProductNotification": {"version": "1.0", "notificationType": kind,
                                                "purchaseToken": TOKEN, "sku": PACK}})


def voided(product_type: int = 2) -> dict:
    return rtdn({"version": "1.0", "packageName": "com.glory.game.google", "eventTimeMillis": "1",
                 "voidedPurchaseNotification": {"purchaseToken": TOKEN, "orderId": "GPA.1",
                                                "productType": product_type, "refundType": 1}})


@pytest.mark.parametrize("body, kind", [
    (one_time(1), "purchased"),
    (one_time(2), "canceled"),
    (one_time(1, package="com.other.app"), "ignored"),
    (voided(), "voided"),
    (voided(product_type=1), "ignored"),
    (rtdn({"version": "1.0", "packageName": "com.glory.game.google", "testNotification": {"version": "1.0"}}), "test"),
    (rtdn({"version": "1.0", "packageName": "com.glory.game.google", "subscriptionNotification": {}}), "ignored"),
])
def test_rtdn_kinds(body, kind) -> None:
    notice = iap_google.parse_rtdn(body)
    assert notice.kind == kind
    if kind in ("purchased", "canceled"):
        assert (notice.token, notice.product_id) == (TOKEN, PACK)


def test_purchase_notice_finds_the_order_by_its_obfuscated_id(monkeypatch, google_key) -> None:
    """玩家付完就关了游戏：通知按付款上的订单号找到单，照样入账、消耗。"""
    wire(monkeypatch, [("from iap_orders where order_id = $1 for update", order_row()),
                       ("from iap_orders where order_id = $1", order_row())]
         + credit_db() + [("update iap_orders set consumed_at", None)])
    seen: list[httpx.Request] = []
    outcome = asyncio.run(iap_google.on_purchase_notice(PACK, TOKEN, httpx.MockTransport(
        google_handler(google_purchase(), seen))))
    assert outcome.order.status == "credited" and not outcome.replayed
    assert seen[-1].url.path.endswith(":consume")


@pytest.mark.parametrize("profile", [None, "not-a-uuid"])
def test_purchase_notice_without_our_order_id_is_dropped(monkeypatch, google_key, profile) -> None:
    conn, _ = wire(monkeypatch, [])
    outcome = asyncio.run(iap_google.on_purchase_notice(PACK, TOKEN, httpx.MockTransport(
        google_handler(google_purchase(obfuscatedExternalProfileId=profile), []))))
    assert outcome is None and not conn.ledger()


def test_purchase_notice_for_a_missing_order_is_dropped(monkeypatch, google_key) -> None:
    conn, _ = wire(monkeypatch, [("from iap_orders where order_id = $1", None)])
    outcome = asyncio.run(iap_google.on_purchase_notice(PACK, TOKEN, httpx.MockTransport(
        google_handler(google_purchase(), []))))
    assert outcome is None and not conn.ledger()


# --- RTDN 接口 -----------------------------------------------------------------


@pytest.fixture
def trusted_push(monkeypatch):
    async def ok(_authorization, transport=None):
        return None
    monkeypatch.setattr(iap_google, "verify_push", ok)
    iap_routes._notify_limiter.reset()


def test_rtdn_without_valid_identity_is_401(client, monkeypatch) -> None:
    async def bad(_authorization, transport=None):
        raise iap_google.GoogleRejected("不对")
    monkeypatch.setattr(iap_google, "verify_push", bad)
    iap_routes._notify_limiter.reset()
    assert client.post("/iap/google/rtdn", json=one_time(1)).status_code == 401


def test_rtdn_path_skips_the_client_version_gate(client, trusted_push) -> None:
    """Pub/Sub 不带游戏的版本头。挂在 /v1 下的话会被补丁版本检查当成旧客户端挡掉。"""
    assert not iap_routes.notify_router.prefix.startswith("/v1")
    r = client.post("/iap/google/rtdn", json=rtdn({"version": "1.0", "packageName": "com.glory.game.google",
                                                    "testNotification": {"version": "1.0"}}))
    assert r.status_code == 204


def test_rtdn_garbage_is_acknowledged_not_retried(client, trusted_push) -> None:
    assert client.post("/iap/google/rtdn", json={"message": {"data": "!!!not base64 json"}}).status_code == 204


def test_rtdn_purchase_credits_and_mails(monkeypatch, client, trusted_push) -> None:
    done = iap.Outcome(iap._order_of(order_row(status="credited", diamond_paid=500, diamond_free=500)),
                       shop.Wallet(500, 500, 0))
    mailed: list = []

    async def notice(product_id, token, transport=None):
        assert (product_id, token) == (PACK, TOKEN)
        return done

    async def mail(outcome):
        mailed.append(outcome)

    monkeypatch.setattr(iap_google, "on_purchase_notice", notice)
    monkeypatch.setattr(iap, "mail_notice", mail)
    assert client.post("/iap/google/rtdn", json=one_time(1)).status_code == 204
    assert mailed == [done]


def test_rtdn_replayed_purchase_sends_no_second_mail(monkeypatch, client, trusted_push) -> None:
    done = iap.Outcome(iap._order_of(order_row(status="credited")), shop.EMPTY_WALLET, replayed=True)
    mailed: list = []

    async def notice(*_a, **_k):
        return done

    async def mail(outcome):
        mailed.append(outcome)

    monkeypatch.setattr(iap_google, "on_purchase_notice", notice)
    monkeypatch.setattr(iap, "mail_notice", mail)
    assert client.post("/iap/google/rtdn", json=one_time(1)).status_code == 204
    assert mailed == []


def test_rtdn_voided_claws_back_by_token_hash(monkeypatch, client, trusted_push) -> None:
    calls: list = []
    refunded = iap.Outcome(iap._order_of(dict(CREDITED, status="refunded", refunded_at=NOW)), shop.EMPTY_WALLET)

    async def refund(platform, external_id, note):
        calls.append((platform, external_id, note))
        return refunded

    async def mail(_outcome):
        calls.append("mail")

    monkeypatch.setattr(iap, "refund", refund)
    monkeypatch.setattr(iap, "mail_notice", mail)
    assert client.post("/iap/google/rtdn", json=voided()).status_code == 204
    assert calls == [("google", iap_google.token_key(TOKEN), "google_voided"), "mail"]


def test_rtdn_platform_outage_is_503_so_pubsub_retries(monkeypatch, client, trusted_push) -> None:
    async def down(*_a, **_k):
        raise iap_google.GoogleUnavailable("连不上")
    monkeypatch.setattr(iap_google, "on_purchase_notice", down)
    assert client.post("/iap/google/rtdn", json=one_time(1)).status_code == 503


# --- Apple 服务器通知 -----------------------------------------------------------


def apple_notice(chain: AppleChain, kind: str = "REFUND", *, bundle: str = "com.superforge.glory",
                 tx: str | None = None) -> str:
    x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode()
           for c in (chain.leaf, chain.mid, chain.root)]
    payload = {"notificationType": kind, "notificationUUID": "uuid-1", "version": "2.0",
               "signedDate": int(dt.datetime(2026, 10, 27, tzinfo=dt.timezone.utc).timestamp() * 1000),
               "data": {"bundleId": bundle, "environment": "Production",
                        "signedTransactionInfo": tx if tx is not None else chain.sign()}}
    return jwt.encode(payload, chain.leaf_key, algorithm="ES256", headers={"x5c": x5c})


def test_apple_refund_notification_claws_back_by_transaction_id(monkeypatch, apple) -> None:
    calls: list = []

    async def refund(platform, external_id, note):
        calls.append((platform, external_id, note))
        return None

    monkeypatch.setattr(iap, "refund", refund)
    what, _outcome = asyncio.run(iap_apple.on_notification(apple_notice(apple)))
    assert what == "refund" and calls == [("apple", "2000000123", "apple_refund")]


def test_apple_refund_reversed_moves_no_money(monkeypatch, apple) -> None:
    async def refund(*_a):
        raise AssertionError("退款撤销不该再扣一次")
    monkeypatch.setattr(iap, "refund", refund)
    assert asyncio.run(iap_apple.on_notification(apple_notice(apple, "REFUND_REVERSED")))[0] == "refund_reversed"
    assert asyncio.run(iap_apple.on_notification(apple_notice(apple, "CONSUMPTION_REQUEST")))[0] == "ignored"


def test_apple_notification_for_another_app_is_refused(apple) -> None:
    with pytest.raises(iap_apple.AppleRejected, match="不是这个 App"):
        iap_apple.verify_notification(apple_notice(apple, bundle="com.example.other"))


def test_apple_notification_with_a_forged_inner_transaction_is_refused(tmp_path, _iap_settings) -> None:
    """外层是真的、里面的交易是别人签的：两层都要验，不能只验外层。"""
    (tmp_path / "ours").mkdir()
    (tmp_path / "forged").mkdir()
    ours, forged = AppleChain(tmp_path / "ours"), AppleChain(tmp_path / "forged")
    _iap_settings["s"] = _settings(apple_root_cert_file=str(ours.root_path))
    with pytest.raises(iap_apple.AppleRejected, match="证书链"):
        iap_apple.verify_notification(apple_notice(ours, tx=forged.sign()))


def test_apple_notification_endpoint(monkeypatch, client, apple) -> None:
    iap_routes._notify_limiter.reset()
    mailed: list = []
    refunded = iap.Outcome(iap._order_of(dict(CREDITED, platform="apple", status="refunded", refunded_at=NOW)),
                           shop.EMPTY_WALLET)

    async def refund(*_a):
        return refunded

    async def mail(outcome):
        mailed.append(outcome)

    monkeypatch.setattr(iap, "refund", refund)
    monkeypatch.setattr(iap, "mail_notice", mail)
    r = client.post("/iap/apple/notifications", json={"signedPayload": apple_notice(apple)})
    assert r.status_code == 200 and mailed == [refunded]
    head, body, sig = apple_notice(apple).split(".")
    r = client.post("/iap/apple/notifications", json={"signedPayload": ".".join((head, body + "x", sig))})
    assert r.status_code == 400


# --- 定时对账 -------------------------------------------------------------------


def test_steam_report_parsing() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/ISteamMicroTxn/GetReport/v5/", "只问正式接口"
        assert request.url.params["type"] == "GAMESALES" and request.url.params["time"] == "2026-10-01T00:00:00Z"
        return httpx.Response(200, json={"response": {"result": "OK", "params": {"count": 2, "orders": [
            {"orderid": "42", "transid": "9001", "status": "Refunded", "time": "2026-10-27T01:00:00Z"},
            {"orderid": "bad"},
        ]}}})
    rows = asyncio.run(iap_steam.report("2026-10-01T00:00:00Z", httpx.MockTransport(handler)))
    assert rows == [iap_steam.ReportRow(42, "9001", "Refunded", "2026-10-27T01:00:00Z")]


@pytest.fixture
def sync_calls(monkeypatch):
    """把定时对账用到的 iap 函数换成记账的替身。"""
    calls: list = []

    async def cancel(order_id, note):
        calls.append(("cancel", order_id, note))

    async def mail(outcome):
        calls.append(("mail", outcome.order.order_id))

    async def mark(order_id):
        calls.append(("consumed", order_id))

    monkeypatch.setattr(iap, "cancel", cancel)
    monkeypatch.setattr(iap, "mail_notice", mail)
    monkeypatch.setattr(iap, "mark_consumed", mark)
    return calls


def _aged(minutes: int, **overrides) -> iap.Order:
    return iap._order_of(steam_order(order_id=uuid.uuid4(), created_at=NOW - dt.timedelta(minutes=minutes),
                                     **overrides))


def test_steam_sweep(monkeypatch, sync_calls) -> None:
    lost = _aged(11, external_id=None)
    starting = _aged(2, external_id=None)
    approved = _aged(5)
    stale = _aged(61)
    waiting = _aged(30)
    broken = _aged(5)

    async def pending(platform, max_age):
        assert platform == "steam"
        return [lost, starting, approved, stale, waiting, broken]

    async def settle(order, declined=False, transport=None):
        if order is broken:
            raise steam.SteamUnavailable("连不上")
        status = "credited" if order is approved else "pending"
        return iap.Outcome(dataclasses.replace(order, status=status), shop.EMPTY_WALLET)

    monkeypatch.setattr(iap, "pending_orders", pending)
    monkeypatch.setattr(iap_steam, "settle", settle)
    assert asyncio.run(iap_sync.sweep_steam(NOW)) == 1
    assert sync_calls == [
        ("cancel", lost.order_id, "steam_init_lost"),
        ("mail", approved.order_id),
        ("cancel", stale.order_id, "steam_timeout"),
    ], "下单还在路上的、半小时内还在等的不动；一张出错不耽误后面的"


def test_steam_refund_report_claws_back_and_advances(monkeypatch, sync_calls) -> None:
    pages = [[iap_steam.ReportRow(42, "9001", "Refunded", "2026-10-27T01:00:00Z"),
              iap_steam.ReportRow(43, "9002", "Succeeded", "2026-10-27T02:00:00Z"),
              iap_steam.ReportRow(44, "9003", "PartialRefund", "2026-10-27T03:00:00Z"),
              iap_steam.ReportRow(45, "9004", "Chargedback", "2026-10-27T00:30:00Z")]]
    refunds: list = []

    async def report(since, transport=None):
        return pages.pop(0) if pages else []

    async def refund(platform, external_id, note):
        refunds.append((external_id, note))
        return iap.Outcome(iap._order_of(dict(CREDITED, status="refunded", refunded_at=NOW)), shop.EMPTY_WALLET)

    monkeypatch.setattr(iap_steam, "report", report)
    monkeypatch.setattr(iap, "refund", refund)
    cursors = iap_sync.fresh_cursors(NOW)
    assert asyncio.run(iap_sync.steam_refunds(cursors)) == 2
    assert refunds == [("9001", "steam_refunded"), ("9004", "steam_chargedback")], "部分退款只记日志"
    assert cursors.steam_since == "2026-10-27T03:00:00Z"


def test_google_consume_retries_unconsumed(monkeypatch, sync_calls, google_key) -> None:
    order = iap._order_of(order_row(status="credited", purchase_token=TOKEN, credited_at=NOW))

    async def unconsumed(max_age):
        assert max_age == 3 * 86400, "超过 3 天 Google 已经自动退款了，补了也没用"
        return [order]

    async def consume(product_id, token, transport=None):
        return token == TOKEN

    monkeypatch.setattr(iap, "unconsumed_google_orders", unconsumed)
    monkeypatch.setattr(iap_google, "consume", consume)
    assert asyncio.run(iap_sync.google_consume()) == 1
    assert sync_calls == [("consumed", order.order_id)]


def test_google_voided_claws_back_and_never_asks_older_than_30_days(monkeypatch, sync_calls, google_key) -> None:
    asked: list = []
    refunds: list = []

    async def voided_since(start_ms, transport=None):
        asked.append(start_ms)
        return [iap_google.Voided(TOKEN, int(NOW.timestamp() * 1000))]

    async def refund(platform, external_id, note):
        refunds.append((platform, external_id))
        return None

    monkeypatch.setattr(iap_google, "voided_since", voided_since)
    monkeypatch.setattr(iap, "refund", refund)
    cursors = iap_sync.Cursors(steam_since="", google_since_ms=0)  # 很久没跑过
    asyncio.run(iap_sync.google_voided(cursors, NOW))
    assert asked[0] >= int((NOW - dt.timedelta(days=30)).timestamp() * 1000)
    assert refunds == [("google", iap_google.token_key(TOKEN))]
    assert cursors.google_since_ms == int(NOW.timestamp() * 1000)


def test_unconfigured_platforms_are_skipped_quietly(monkeypatch, _iap_settings) -> None:
    _iap_settings["s"] = _settings(steam_web_api_key="", google_play_service_account_file="")

    async def boom(*_a, **_k):
        raise AssertionError("没配好的平台不该去问")

    for module, name in ((iap, "pending_orders"), (iap, "unconsumed_google_orders"),
                         (iap_steam, "report"), (iap_google, "voided_since")):
        monkeypatch.setattr(module, name, boom)
    cursors = iap_sync.fresh_cursors(NOW)
    assert asyncio.run(iap_sync.sweep_steam(NOW)) == 0
    assert asyncio.run(iap_sync.steam_refunds(cursors)) == 0
    assert asyncio.run(iap_sync.google_consume()) == 0
    assert asyncio.run(iap_sync.google_voided(cursors, NOW)) == 0


def test_tick_runs_slow_jobs_every_tenth_round_and_survives_failures(monkeypatch) -> None:
    ran: list = []

    def job(name, fail=False):
        async def run(*_a, **_k):
            ran.append(name)
            if fail:
                raise RuntimeError(name)
            return 0
        return run

    monkeypatch.setattr(iap_sync, "sweep_steam", job("sweep", fail=True))
    monkeypatch.setattr(iap_sync, "steam_refunds", job("steam_refunds", fail=True))
    monkeypatch.setattr(iap_sync, "google_consume", job("consume"))
    monkeypatch.setattr(iap_sync, "google_voided", job("voided"))
    cursors = iap_sync.fresh_cursors(NOW)
    asyncio.run(iap_sync.tick(cursors, 1))
    assert ran == ["sweep", "steam_refunds", "consume", "voided"], "启动后第一圈就对一次账；一样出错不挡后面的"
    ran.clear()
    asyncio.run(iap_sync.tick(cursors, 2))
    assert ran == ["sweep"]
    ran.clear()
    asyncio.run(iap_sync.tick(cursors, 11))
    assert ran == ["sweep", "steam_refunds", "consume", "voided"]


def test_reconciler_is_started_and_stopped_with_the_server() -> None:
    main_py = (REPO / "backend" / "app" / "main.py").read_text(encoding="utf-8")
    assert "reconciler = asyncio.create_task(iap_sync.loop())" in main_py
    assert "voice_sweeper, reconciler)" in main_py, "停服时要一起取消"
    assert "app.include_router(iap_routes.notify_router)" in main_py
