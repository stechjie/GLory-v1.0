"""系统邮件（`docs/邮件系统设计.md`）的行为用例。

同 test_shop 的分工：**不连数据库**。判据是纯函数、SQL 文本的静态一致性、路由接线，
以及用一个假连接钉住**语句的执行顺序**。真并发下的行锁归线上验证。

最重要的几组，它们的失败模式都**不会报错**：

  1. 领取的顺序：先锁状态行、再发钱发东西、最后记「已领」。反过来的话两台手机同时点，
     两次请求都会在记「已领」之前把东西发出去 —— 领了两份，账上只有一条「已领」。
  2. 已经领过就一分钱不动、一件东西不发。
  3. 钻石进赠送那一列，流水记 source=mail 和是哪封邮件。
  4. 附件里有不能发的东西（拼错、免费内容）整封不给玩家看 —— 不然玩家点了领取什么都没有。
  5. 群发的资格：只给当时已有的玩家 / 新玩家也给，由每封的开关决定。
  6. 内部备注和操作人不下发给玩家。

跑（从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q tests/test_mail.py
"""

from __future__ import annotations

import asyncio
import datetime as dt
import inspect
import pathlib
import re
import uuid
from dataclasses import dataclass, field

import pytest
from fastapi.testclient import TestClient

from app import db, mail, players, shop
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import mail as mail_routes
from app.routes import me as me_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_012 = (REPO / "database" / "012_mail.sql").read_text(encoding="utf-8")
CLIENT_SERVICE = (REPO / "scripts" / "autoload" / "MailService.gd").read_text(encoding="utf-8")

PLAYER_A = uuid.UUID("11111111-1111-1111-1111-111111111111")
NOW = dt.datetime(2026, 9, 17, 12, 0, tzinfo=dt.timezone.utc)


def _sql_code(sql: str) -> str:
    """去掉 SQL 注释，只留代码（注释里写着「不删行」之类的话，会被自己满足）。"""
    return "\n".join(line.split("--", 1)[0] for line in sql.splitlines())


SQL_012_CODE = _sql_code(SQL_012)

# 目录里卖的两样东西，与一样免费的头像。故意从目录里现读：
# 卖什么由 data/shop.json 决定，这里只要「一件卖的」「另一件卖的」。
SOLD = [i.grants for i in shop.items()]
FREE_AVATAR = "preset:avatar_001"


def mail_row(
    mail_id: int = 7,
    *,
    diamond: int = 0,
    coin: int = 0,
    items: list[str] | None = None,
    read: bool = False,
    claimed: bool = False,
) -> dict:
    return {
        "mail_id": mail_id,
        "title_zh": "补偿", "body_zh": "正文", "title_en": "", "body_en": "",
        "diamond": diamond, "coin": coin, "items": items or [],
        "created_at": NOW - dt.timedelta(days=1),
        "expires_at": NOW + dt.timedelta(days=29),
        "is_read": read, "is_claimed": claimed,
    }


# --- 假数据库 -----------------------------------------------------------------


class _Tx:
    def __init__(self, conn: FakeConn) -> None:
        self._conn = conn

    async def __aenter__(self):
        self._conn.queries.append("<begin>")
        return self

    async def __aexit__(self, *exc):
        self._conn.queries.append("<commit>")
        return False


class FakeConn:
    """按 SQL 片段返回预置结果（值可以是「参数 -> 结果」的函数），并**按顺序**记下每一条语句。"""

    def __init__(self, responses: list[tuple[str, object]], execute_status: str = "UPDATE 1") -> None:
        self.queries: list[str] = []
        self.args: list[tuple] = []
        self._responses = responses
        self._status = execute_status

    def _match(self, sql: str, args: tuple):
        for frag, value in self._responses:
            if frag in sql:
                return value(*args) if callable(value) else value
        return None

    def _record(self, sql: str, args: tuple) -> None:
        self.queries.append(" ".join(sql.split()))
        self.args.append(args)

    async def execute(self, sql: str, *args):
        self._record(sql, args)
        return self._status

    async def executemany(self, sql: str, rows):
        self._record(sql, tuple(rows))

    async def fetchrow(self, sql: str, *args):
        self._record(sql, args)
        return self._match(sql, args)

    async def fetchval(self, sql: str, *args):
        self._record(sql, args)
        return self._match(sql, args)

    async def fetch(self, sql: str, *args):
        self._record(sql, args)
        return self._match(sql, args) or []

    def transaction(self):
        return _Tx(self)

    # --- 给断言用的小工具 ---

    def index_of(self, frag: str) -> int:
        for i, q in enumerate(self.queries):
            if frag in q:
                return i
        return -1

    def count(self, frag: str) -> int:
        return sum(1 for q in self.queries if frag in q)

    def args_of(self, frag: str) -> list[tuple]:
        return [a for q, a in zip(self.queries, self._args_aligned()) if frag in q]

    def _args_aligned(self) -> list[tuple]:
        # queries 里混着 <begin>/<commit> 标记，args 没有；对齐一下。
        out: list[tuple] = []
        it = iter(self.args)
        for q in self.queries:
            out.append(() if q.startswith("<") else next(it))
        return out

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


def wire_db(monkeypatch: pytest.MonkeyPatch, responses, **kwargs) -> FakeConn:
    conn = FakeConn(responses, **kwargs)
    monkeypatch.setattr(db, "pool", lambda: FakePool(conn))
    monkeypatch.setattr(db, "is_connected", lambda: True)
    return conn


def owned_only(*content_ids: str):
    """_owns 的假答复：只有这几样算已拥有。"""
    owned = set(content_ids)
    return lambda _player, item: 1 if item in owned else None


WALLET = {"diamond_paid": 40, "diamond_free": 10, "coin": 0}


# --- 附件检查（纯函数）---------------------------------------------------------


def test_sold_content_is_mailable() -> None:
    assert SOLD, "data/shop.json 里没有任何商品，这组用例没法做"
    assert mail.item_problem(SOLD[:1]) == ""
    assert mail.item_problem([]) == ""


def test_free_content_and_typos_are_problems() -> None:
    """🔴 不在目录里的内容人人免费，发了等于没发；拼错的发了也用不了。
    两种都要让管理员看到，而不是让玩家点了领取什么都没有。"""
    assert shop.requires_entitlement(FREE_AVATAR) is False
    assert "不能发" in mail.item_problem([FREE_AVATAR])
    assert "不能发" in mail.item_problem(["pet_does_not_exist"])


def test_duplicate_and_oversized_attachments_are_problems() -> None:
    assert "重复" in mail.item_problem([SOLD[0], SOLD[0]])
    assert "最多" in mail.item_problem([SOLD[0]] * (mail.MAX_ITEMS + 1))


def test_claimable_rules() -> None:
    """有附件且没领才算能领。没有附件的邮件永远不算。"""
    assert mail._mail(mail_row(diamond=5)).claimable
    assert mail._mail(mail_row(items=SOLD[:1])).claimable
    assert not mail._mail(mail_row(diamond=5, claimed=True)).claimable
    assert not mail._mail(mail_row(read=True)).claimable


# --- 领取 🔴 ---------------------------------------------------------------------


def _claim_db(monkeypatch, row: dict | None, *, claimed_at=None, owned=()) -> FakeConn:
    return wire_db(monkeypatch, [
        ("from mails m", row),
        ("select claimed_at from mail_states", {"claimed_at": claimed_at}),
        ("from player_wallets", dict(WALLET)),
        ("from player_entitlements", owned_only(*owned)),
    ])


def test_claim_locks_state_before_paying_and_marks_claimed_last(monkeypatch) -> None:
    """★ 先锁状态行、再发钱发东西、最后记已领 —— 全在同一个事务里。"""
    conn = _claim_db(monkeypatch, mail_row(diamond=100, items=SOLD[:1]))
    result = asyncio.run(mail.claim(PLAYER_A, 7))

    begin = conn.index_of("<begin>")
    lock = conn.index_of("select claimed_at from mail_states")
    pay = conn.index_of("update player_wallets")
    grant = conn.index_of("into player_entitlements")
    mark = conn.index_of("update mail_states set claimed_at")
    commit = conn.index_of("<commit>")
    assert -1 not in (begin, lock, pay, grant, mark, commit)
    assert begin < lock < pay < mark < commit, conn.queries
    assert lock < grant < mark, conn.queries
    assert "for update" in conn.queries[lock]
    assert result.replayed is False
    assert result.mail_ids == (7,)
    assert result.granted == tuple(SOLD[:1])


def test_already_claimed_moves_nothing(monkeypatch) -> None:
    """★ 另一台手机刚领走 / 弱网重试：一分钱不动、一件东西不发、不再记一次已领。"""
    conn = _claim_db(monkeypatch, mail_row(diamond=100, items=SOLD[:1]), claimed_at=NOW)
    result = asyncio.run(mail.claim(PLAYER_A, 7))
    assert result.replayed is True
    assert result.mail_ids == ()
    assert result.diamond == 0 and result.granted == ()
    assert not conn.wrote_money()
    assert not conn.granted()
    assert conn.count("update mail_states set claimed_at") == 0
    # 余额照样回报（客户端拿它刷新）。
    assert result.wallet.diamond == 50


def test_diamonds_go_to_the_free_column_with_mail_source_and_id(monkeypatch) -> None:
    """邮件发的钱不是玩家付的：进 diamond_free，流水 source=mail、mail_id=这封。"""
    conn = _claim_db(monkeypatch, mail_row(mail_id=42, diamond=300, coin=5))
    result = asyncio.run(mail.claim(PLAYER_A, 42))

    ledger = conn.args_of("into wallet_ledger")
    currencies = {a[1] for a in ledger}
    assert currencies == {"diamond_free", "coin"}, ledger
    assert "diamond_paid" not in currencies
    for args in ledger:
        assert args[4] == "mail"       # source
        assert args[8] == 42           # mail_id
    assert result.wallet.diamond_free == 10 + 300
    assert result.wallet.diamond_paid == 40
    assert result.wallet.coin == 5


def test_other_money_paths_do_not_need_the_mail_column(monkeypatch) -> None:
    """部署顺序弄反（账号服务器先上、012 还没跑）时，坏的只能是邮件，不能是整个商城：
    只有邮件那一路的流水带 mail_id 这一列。"""
    conn = wire_db(monkeypatch, [])
    wallet = shop.Wallet(0, 10, 0)
    asyncio.run(shop._apply(conn, PLAYER_A, wallet, {"diamond_free": -5}, "shop", uuid.uuid4()))
    asyncio.run(shop._apply(conn, PLAYER_A, wallet, {"diamond_free": 5}, "mail", None, mail_id=9))
    inserts = [q for q in conn.queries if "into wallet_ledger" in q]
    assert len(inserts) == 2
    assert "mail_id" not in inserts[0]
    assert "mail_id" in inserts[1]
    assert conn.args_of("into wallet_ledger")[1][-1] == 9


def test_owned_items_are_skipped_and_the_rest_still_arrive(monkeypatch) -> None:
    """已经拥有就跳过、不折算；其余附件照常到账。"""
    if len(SOLD) < 2:
        pytest.skip("目录里只有一件商品")
    conn = _claim_db(monkeypatch, mail_row(items=SOLD[:2], diamond=10), owned=[SOLD[0]])
    result = asyncio.run(mail.claim(PLAYER_A, 7))
    assert result.skipped == (SOLD[0],)
    assert result.granted == (SOLD[1],)
    grants = conn.args_of("into player_entitlements")
    assert [a[1] for a in grants] == [SOLD[1]]
    assert grants[0][2] == "mail"
    assert result.diamond == 10


def test_item_only_mail_does_not_touch_the_wallet(monkeypatch) -> None:
    """钱包行是惰性建的（009）：只发东西的邮件不该给玩家建一行空钱包。"""
    conn = _claim_db(monkeypatch, mail_row(items=SOLD[:1]))
    result = asyncio.run(mail.claim(PLAYER_A, 7))
    assert conn.count("into player_wallets") == 0
    assert not conn.wrote_money()
    assert result.granted == tuple(SOLD[:1])


def test_claim_rejects_mail_without_attachments(monkeypatch) -> None:
    conn = _claim_db(monkeypatch, mail_row())
    with pytest.raises(mail.MailRejected) as exc:
        asyncio.run(mail.claim(PLAYER_A, 7))
    assert exc.value.code == "nothing_to_claim"
    assert conn.count("into mail_states") == 0 and conn.count("update mail_states") == 0


def test_claim_rejects_invisible_mail(monkeypatch) -> None:
    """不是发给他的 / 过期 / 撤回 / 删过 —— 查询里就查不到，一样都不能动。"""
    conn = _claim_db(monkeypatch, None)
    with pytest.raises(mail.MailRejected) as exc:
        asyncio.run(mail.claim(PLAYER_A, 7))
    assert exc.value.code == "mail_not_found"
    assert not conn.wrote_money() and not conn.granted()
    assert conn.count("into mail_states") == 0 and conn.count("update mail_states") == 0


def test_claim_rejects_mail_with_a_bad_attachment(monkeypatch) -> None:
    """附件有问题的整封不给看，领取也当作不存在。"""
    conn = _claim_db(monkeypatch, mail_row(diamond=100, items=[FREE_AVATAR]))
    with pytest.raises(mail.MailRejected) as exc:
        asyncio.run(mail.claim(PLAYER_A, 7))
    assert exc.value.code == "mail_not_found"
    assert not conn.wrote_money() and not conn.granted()


def test_claim_all_uses_one_transaction_per_mail_oldest_first(monkeypatch) -> None:
    """一封出错不连累其他几封；老的先领（两封有同一样东西时，和一封封点的结果一样）。"""
    rows = [mail_row(9, diamond=1), mail_row(8, read=True), mail_row(5, coin=2), mail_row(3, diamond=4, claimed=True)]
    conn = wire_db(monkeypatch, [
        ("from mails m", rows),
        ("select claimed_at from mail_states", {"claimed_at": None}),
        ("from player_wallets", dict(WALLET)),
        ("from player_entitlements", owned_only()),
    ])
    result = asyncio.run(mail.claim_all(PLAYER_A))
    assert result.mail_ids == (5, 9)   # 8 没附件、3 已领过
    assert conn.count("<begin>") == 2
    locked = [a[1] for a in conn.args_of("select claimed_at from mail_states")]
    assert locked == [5, 9]
    assert result.diamond == 1 and result.coin == 2


def test_claim_all_skips_mails_another_device_just_claimed(monkeypatch) -> None:
    rows = [mail_row(9, diamond=1), mail_row(5, diamond=2)]
    conn = wire_db(monkeypatch, [
        ("from mails m", rows),
        ("select claimed_at from mail_states", lambda _p, mid: {"claimed_at": NOW if mid == 5 else None}),
        ("from player_wallets", dict(WALLET)),
        ("from player_entitlements", owned_only()),
    ])
    result = asyncio.run(mail.claim_all(PLAYER_A))
    assert result.mail_ids == (9,)
    assert result.diamond == 1
    assert conn.count("into wallet_ledger") == 1


# --- 列表、已读、删除 ---------------------------------------------------------------


def test_list_hides_mails_with_bad_attachments(monkeypatch) -> None:
    wire_db(monkeypatch, [("from mails m", [mail_row(2, items=SOLD[:1]), mail_row(1, items=["pet_typo"])])])
    mails = asyncio.run(mail.list_mail(PLAYER_A))
    assert [m.mail_id for m in mails] == [2]


def test_mark_read_keeps_the_first_read_time(monkeypatch) -> None:
    conn = wire_db(monkeypatch, [("from mails m", mail_row())])
    asyncio.run(mail.mark_read(PLAYER_A, 7))
    upsert = conn.queries[conn.index_of("into mail_states")]
    assert "coalesce(mail_states.read_at" in upsert


def test_mark_read_rejects_invisible_mail(monkeypatch) -> None:
    """不能给别人的邮件 / 不存在的编号落状态行。"""
    conn = wire_db(monkeypatch, [("from mails m", None)])
    with pytest.raises(mail.MailRejected):
        asyncio.run(mail.mark_read(PLAYER_A, 7))
    assert conn.count("into mail_states") == 0


@pytest.mark.parametrize(("row", "code"), [
    (mail_row(diamond=5), "not_read"),
    (mail_row(diamond=5, read=True), "unclaimed_attachments"),
])
def test_delete_refuses_unread_or_unclaimed(monkeypatch, row, code) -> None:
    conn = wire_db(monkeypatch, [("from mails m", row)])
    with pytest.raises(mail.MailRejected) as exc:
        asyncio.run(mail.delete(PLAYER_A, 7))
    assert exc.value.code == code
    assert conn.count("set deleted_at") == 0


def test_delete_marks_only_this_player_and_mail(monkeypatch) -> None:
    conn = wire_db(monkeypatch, [("from mails m", mail_row(diamond=5, read=True, claimed=True))])
    asyncio.run(mail.delete(PLAYER_A, 7))
    assert conn.args_of("set deleted_at") == [(PLAYER_A, 7)]


def test_delete_read_only_takes_read_and_fully_claimed(monkeypatch) -> None:
    conn = wire_db(monkeypatch, [], execute_status="UPDATE 3")
    assert asyncio.run(mail.delete_read(PLAYER_A)) == 3
    sql = conn.queries[conn.index_of("set deleted_at")]
    assert "s.read_at is not null" in sql
    assert "s.claimed_at is not null" in sql
    assert "m.diamond = 0 and m.coin = 0 and cardinality(m.items) = 0" in sql


def test_visibility_rules_cover_both_kinds_of_broadcast() -> None:
    """群发的资格：开关打开谁都能收；没打开只给发送那一刻已经存在的玩家。"""
    sql = " ".join(mail._SELECT.split())
    assert "m.player_id = $1" in sql
    assert "m.include_new_players or p.created_at <= m.created_at" in sql
    assert "m.withdrawn_at is null" in sql
    assert "m.expires_at > now()" in sql
    assert "s.deleted_at is null" in sql


# --- 后台：推送与写回问题 ------------------------------------------------------------


@dataclass
class _Outbox:
    to_players: list = field(default_factory=list)
    broadcasts: int = 0
    problems: list = field(default_factory=list)


def _postman(batches: list[list[mail.ScanRow]], outbox: _Outbox, fail_write: bool = False) -> mail.Postman:
    queue = list(batches)
    seen: list[int] = []

    async def load(since: int):
        seen.append(since)
        return queue.pop(0) if queue else []

    async def write(changes):
        if fail_write:
            raise OSError("写不回去")
        outbox.problems.extend(changes)

    async def send(player_id, payload):
        assert payload == {"t": mail.PUSH_TYPE}
        outbox.to_players.append(player_id)
        return 1

    async def broadcast(payload):
        assert payload == {"t": mail.PUSH_TYPE}
        outbox.broadcasts += 1
        return 3

    postman = mail.Postman(load_scan=load, write_problems=write, send_to_player=send, broadcast=broadcast)
    postman.seen = seen   # 测试看它每轮从哪儿接着看
    return postman


def row(mail_id: int, player: uuid.UUID | None = PLAYER_A, items=(), problem: str = "") -> mail.ScanRow:
    return mail.ScanRow(mail_id=mail_id, player_id=player, items=tuple(items), problem=problem)


def test_first_round_pushes_nothing_but_records_problems() -> None:
    """刚重启时表里的都是旧邮件，玩家登录时本来就会拉列表 —— 不推。问题照写。"""
    out = _Outbox()
    p = _postman([[row(3), row(4, items=["pet_typo"])]], out)
    asyncio.run(p.refresh())
    assert out.to_players == [] and out.broadcasts == 0
    assert [c[0] for c in out.problems] == [4]
    assert "pet_typo" in out.problems[0][1]


def test_new_mail_is_pushed_once_per_player_and_broadcast_once() -> None:
    other = uuid.uuid4()
    out = _Outbox()
    p = _postman([[row(3)], [row(4), row(5), row(6, player=other), row(7, player=None), row(8, player=None)]], out)
    asyncio.run(p.refresh())
    asyncio.run(p.refresh())
    assert sorted(map(str, out.to_players)) == sorted([str(PLAYER_A), str(other)])
    assert out.broadcasts == 1
    assert p.seen == [0, 3]


def test_problem_mail_is_held_back_until_fixed_then_pushed() -> None:
    """管理员改好附件：问题清掉（写回 None）、邮件这时才推给玩家。"""
    out = _Outbox()
    p = _postman([
        [row(3)],
        [row(4, items=["pet_typo"])],
        [row(4, items=SOLD[:1], problem="附件里有不能发的东西：pet_typo")],
    ], out)
    asyncio.run(p.refresh())
    asyncio.run(p.refresh())
    assert out.to_players == []
    asyncio.run(p.refresh())
    assert out.to_players == [PLAYER_A]
    assert out.problems[-1] == (4, None)


def test_write_failure_does_not_stop_the_push() -> None:
    out = _Outbox()
    p = _postman([[row(3)], [row(4), row(5, items=["pet_typo"])]], out, fail_write=True)
    asyncio.run(p.refresh())
    asyncio.run(p.refresh())
    assert out.to_players == [PLAYER_A]


def test_push_type_matches_the_client() -> None:
    """对不上的话推送落进客户端「未知类型」分支：不报错，就是红点不亮。"""
    found = re.search(r'const PUSH_TYPE := "([a-z_]+)"', CLIENT_SERVICE)
    assert found, "MailService.gd 里没找到 PUSH_TYPE"
    assert found.group(1) == mail.PUSH_TYPE


def test_mail_loop_is_started_by_the_app() -> None:
    source = (REPO / "backend" / "app" / "main.py").read_text(encoding="utf-8")
    assert "mail.loop(mail.Postman.for_production())" in source
    assert "postman" in source.split("finally:", 1)[1], "关服时没取消邮件后台任务"


# --- SQL 的静态一致性 ----------------------------------------------------------------


def test_expected_tables_include_mail() -> None:
    for table in ("mails", "mail_states"):
        assert table in db.EXPECTED_TABLES


def test_new_tables_enable_rls_with_zero_policies() -> None:
    for table in ("mails", "mail_states"):
        assert "alter table %s enable row level security" % table in SQL_012_CODE
    assert "create policy" not in SQL_012_CODE.lower()


def test_mail_rows_are_never_deleted() -> None:
    """🔴 流水的 mail_id 指着邮件行，「这笔钻石是哪封邮件发的」要一直查得到。"""
    assert "delete from mails" not in SQL_012_CODE.lower()
    assert "delete from" not in inspect.getsource(mail).lower()
    maintenance = (REPO / "backend" / "app" / "maintenance.py").read_text(encoding="utf-8")
    assert "mails" not in maintenance and "mail_states" not in maintenance


def test_actor_is_required_everywhere() -> None:
    assert "actor        text not null" in SQL_012_CODE
    for fn in ("send_mail(", "send_mail_all("):
        assert "create function %s" % fn in SQL_012_CODE
    assert SQL_012_CODE.count("必须填操作人") == 2


def test_new_player_switch_only_applies_to_broadcasts() -> None:
    assert "check (player_id is null or not include_new_players)" in SQL_012_CODE
    assert "include_new_players boolean not null default false" in SQL_012_CODE


def test_defaults_and_caps_match_the_decisions() -> None:
    """默认 30 天（拍板）；单封上限防手滑；附件件数与后端一致。"""
    assert "default now() + interval '30 days'" in SQL_012_CODE
    assert len(re.findall(r"p_days\s+integer default 30", SQL_012_CODE)) == 2
    assert "cardinality(items) <= %d" % mail.MAX_ITEMS in SQL_012_CODE
    assert "check (diamond between 0 and 100000)" in SQL_012_CODE


def test_ledger_remembers_which_mail_paid() -> None:
    assert "alter table wallet_ledger add column mail_id bigint references mails(mail_id)" in SQL_012_CODE
    assert "mail" in shop.SOURCES
    assert "mail_id" in inspect.signature(shop._apply).parameters


def test_withdraw_marks_instead_of_deleting() -> None:
    body = SQL_012_CODE.split("create function withdraw_mail", 1)[1]
    assert "update mails set withdrawn_at = now()" in body
    assert "delete" not in body.lower()


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
    mail_routes._action_limiter.reset()
    yield
    mail_routes._action_limiter.reset()
    get_settings.cache_clear()


def _auth() -> dict[str, str]:
    return {"Authorization": "Bearer token-a"}


def test_mail_requires_login(wired) -> None:
    with TestClient(app) as client:
        assert client.get("/v1/me/mail").status_code == 401
        assert client.post("/v1/me/mail/claim-all").status_code == 401


def test_list_shape_is_relative_and_hides_internal_fields(wired, monkeypatch) -> None:
    """时间只发相对值；内部备注、操作人不下发。"""
    real_now = dt.datetime.now(dt.timezone.utc)
    row_ = mail_row(3, diamond=5, items=SOLD[:1])
    row_["created_at"] = real_now - dt.timedelta(hours=2)
    row_["expires_at"] = real_now + dt.timedelta(days=3)

    async def fake_list(player_id):
        assert player_id == PLAYER_A
        return [mail._mail(row_)]

    monkeypatch.setattr(mail, "list_mail", fake_list)
    with TestClient(app) as client:
        r = client.get("/v1/me/mail", headers=_auth())
    assert r.status_code == 200, r.text
    body = r.json()
    assert list(body) == ["mails"]
    entry = body["mails"][0]
    assert 7000 <= entry["age_sec"] <= 7300
    assert 3 * 86400 - 120 <= entry["expires_in_sec"] <= 3 * 86400
    assert "note" not in entry and "actor" not in entry
    assert "created_at" not in entry and "expires_at" not in entry
    item = entry["items"][0]
    sold = shop.content_item(SOLD[0])
    assert item == {"id": SOLD[0], "kind": sold.kind, "name": sold.name, "name_en": sold.name_en}


def test_claim_response_carries_the_new_wallet_total(wired, monkeypatch) -> None:
    async def fake_claim(player_id, mail_id):
        return mail.ClaimResult((mail_id,), 100, 0, tuple(SOLD[:1]), (), shop.Wallet(40, 110, 0), False)

    monkeypatch.setattr(mail, "claim", fake_claim)
    with TestClient(app) as client:
        r = client.post("/v1/me/mail/7/claim", headers=_auth())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["mail_ids"] == [7]
    # 分账不下发，只有合计（同 WalletResponse）。
    assert body["wallet"] == {"diamond": 150, "coin": 0}


def test_reject_codes_map_to_statuses(wired, monkeypatch) -> None:
    async def fake_claim(player_id, mail_id):
        raise mail.MailRejected(*mail.NOT_FOUND)

    monkeypatch.setattr(mail, "claim", fake_claim)
    with TestClient(app) as client:
        r = client.post("/v1/me/mail/7/claim", headers=_auth())
    assert r.status_code == 404
    assert r.headers["X-Glory-Reason"] == "mail_not_found"


def test_every_mail_rejection_code_has_a_status() -> None:
    source = inspect.getsource(mail)
    codes = set(re.findall(r'MailRejected\(\s*"([a-z_]+)"', source))
    codes |= {mail.NOT_FOUND[0]}
    assert len(codes) >= 4, "没扫到拒绝码，正则该更新了"
    missing = codes - set(mail_routes._STATUS_BY_CODE)
    assert not missing, "这些拒绝码没有对应状态码：%s" % sorted(missing)


def test_huge_mail_id_is_rejected_before_the_database(wired) -> None:
    with TestClient(app) as client:
        r = client.post("/v1/me/mail/%d/claim" % (2**63), headers=_auth())
    assert r.status_code == 422


def test_there_is_no_send_endpoint() -> None:
    """发信只在 Supabase 里（函数）。这边被拿到令牌也发不了钱。"""
    # 这版 FastAPI 把 include_router 包了一层，app.routes 里看不到子路由，直接看邮件那个 router。
    paths = [getattr(r, "path", "") for r in mail_routes.router.routes]
    assert len(paths) == 6, paths
    for path in paths:
        assert path.startswith("/v1/me/mail"), path
        assert "send" not in path and "grant" not in path, path
    main_source = (REPO / "backend" / "app" / "main.py").read_text(encoding="utf-8")
    assert "app.include_router(mail_routes.router)" in main_source
