"""赛季、赛季奖励与名片上的段位（`docs/排位系统设计.md` 第九节）。第 6 步。

结算的逻辑在 `database/015_ranked_seasons.sql` 的 `settle_season()` 函数里，
这里**验不了 plpgsql 的执行**（不连数据库）。所以这一组分两半：

  * 能执行的：`app/seasons.py` 的调度、名片上的段位字段
  * 只能读源码的：那个函数里几条**一旦写错就是灾难**的规则

最重要的几组，失败时都**不报错**：

  1. **幂等的认领**。后台任务会重复跑（重启、手动再点、以后两个实例），
     而重复结算一次 = 所有人**收到两份奖励**、分数被清两次。
  2. **`-1` 与 `0` 要分得开**。0 是「结算了但没人打排位」，-1 是「已经结算过」。
     混在一起的话调度器会把「已结算」记成「结算成功」。
  3. **归档表里的 tier 要存死**。014 里段位不存（是切片），归档行是唯一例外 ——
     以后改段位宽窄，历史段位不该跟着变。
  4. **名片上的 tier 默认 -1 不是 0**。0 是第一段，默认成 0 会让每个新玩家
     在房间里顶着一个没打过的段位。
  5. **赛季长度不许写进代码**。写死一次要发一次后端。

跑：
    backend\\.venv\\Scripts\\python.exe -m pytest backend/tests/test_seasons.py -q -p no:cacheprovider
"""

from __future__ import annotations

import pathlib
import re

import pytest

from app import loadout, ranked, seasons

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_015 = (REPO / "database" / "015_ranked_seasons.sql").read_text(encoding="utf-8")
SQL_012 = (REPO / "database" / "012_mail.sql").read_text(encoding="utf-8")
CARD_GD = (REPO / "scripts" / "multiplayer" / "BattleCard.gd").read_text(encoding="utf-8")


@pytest.fixture
def anyio_backend():
    return "asyncio"


# --- 结算函数里那几条硬规则（只能读源码）------------------------------------------


def _settle_body() -> str:
    return SQL_015.split("create function settle_season")[1].split("$$;")[0]


def test_settlement_claims_before_doing_anything() -> None:
    """🔴 幂等的全部防线。

    后台任务会重复跑（进程重启、手动再点一次、以后真起两个实例）。
    重复结算一次 = 所有人**收到两份奖励**、分数被清两次。

    认领必须是**第一句写操作**，而且条件里要有 `settled_at is null`。
    """
    body = _settle_body()
    claim = body.index("update ranked_seasons")
    assert "settled_at is null" in body[claim:claim + 200]
    # 认领之后必须能提前返回，否则认不到也会继续往下跑
    assert "return -1" in body
    # 归档 / 发奖 / 清零都要排在认领之后
    for later in ["insert into player_ranked_history", "insert into mails", "update player_ranked\n"]:
        assert body.index(later) > claim, "%s 排在了认领之前" % later


def test_already_settled_returns_minus_one_not_zero() -> None:
    """🔴 0 是「结算了但没人打排位」，-1 是「已经结算过」。

    混成一个值的话，调度器会把「已结算」记成「结算成功」并计数。
    """
    assert "return -1" in _settle_body()
    src = (REPO / "backend" / "app" / "seasons.py").read_text(encoding="utf-8")
    assert "< 0" in src, "seasons.py 没有把 -1 当成「已结算过」分开处理"


def test_settlement_requires_an_actor() -> None:
    """同 012 的 send_mail：发钱的东西必须查得到是谁发的。"""
    assert "p_actor is null or btrim(p_actor)" in _settle_body()


def test_history_stores_the_tier() -> None:
    """🔴 014 里段位**不存**（是分数的切片），归档表是唯一例外。

    归档行的 score 不再变，而「当时的段位」要按**当时的**切片算 ——
    以后改段位宽窄时，历史段位不该跟着变。
    """
    table = SQL_015.split("create table player_ranked_history")[1].split(");")[0]
    assert "tier" in table
    # 归档时是算出来写死的，不是以后再算
    assert "least(r.score / 100, 7)" in _settle_body()


def test_rewards_only_go_to_people_who_played() -> None:
    """一局没打就收到「赛季奖励」是噪音。"""
    assert "h.games > 0" in _settle_body()


def test_rewards_join_means_unconfigured_tiers_get_nothing() -> None:
    """没配奖励的段位**不发空邮件** —— 用 join 而不是 left join。"""
    body = _settle_body()
    mail_stmt = body[body.index("insert into mails"):body.index("get diagnostics v_mails")]
    assert "join ranked_season_rewards" in mail_stmt
    assert "left join" not in mail_stmt


def test_reset_keeps_the_row_and_bumps_the_season() -> None:
    """不删行：删了的话下一局排位又要走「没有就建」，而 player_credit 是另一张表、
    不跟着清 —— 信誉分是跨赛季的，那是设计如此。"""
    body = _settle_body()
    assert "delete from player_ranked" not in body
    assert "season = p_season + 1" in body
    assert "win_streak = 0" in body


def test_reward_columns_match_the_mail_table() -> None:
    """🔴 对不上的话，结算时才会撞约束 —— 而那时候是半夜的后台任务。"""
    rewards = SQL_015.split("create table ranked_season_rewards")[1].split("primary key")[0]
    for bound in ["diamond between 0 and 100000", "coin between 0 and 1000000"]:
        assert bound in rewards, "赛季奖励的 %s 与 012 的 mails 对不上" % bound
        assert bound in SQL_012
    # items 的正则也要同源
    shape = re.search(r"\^\[a-z0-9_:\]\{1,64\}", rewards)
    assert shape is not None and shape.group(0) in SQL_012


def test_season_length_is_not_in_the_code() -> None:
    """🔴 赛季多长还没拍板（第十节 10.1）。写死一次要发一次后端。

    它是 `ranked_seasons` 里管理员自己填的 `ends_at`。
    """
    src = (REPO / "backend" / "app" / "seasons.py").read_text(encoding="utf-8")
    for forbidden in ["timedelta(days=28", "timedelta(weeks=4", "SEASON_DAYS", "SEASON_LENGTH"]:
        assert forbidden not in src
    assert "ends_at <= now()" in src, "调度器该按表里的 ends_at 判，不是自己算"


# --- 调度（能执行的那一半）--------------------------------------------------------


class _FakeConn:
    def __init__(self, due: list[int], results: dict[int, int]) -> None:
        self.due = due
        self.results = results
        self.called: list[tuple] = []

    async def fetch(self, sql, *args):
        return [{"season": s} for s in self.due]

    async def fetchval(self, sql, *args):
        self.called.append(args)
        return self.results.get(int(args[0]), 0)


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
async def test_settle_due_calls_the_function_for_each_season(monkeypatch) -> None:
    from app import db

    conn = _FakeConn([1, 2], {1: 120, 2: 0})
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(db, "pool", lambda: _Pool(conn))
    assert await seasons.settle_due() == 2
    assert [c[0] for c in conn.called] == [1, 2]
    assert all(c[1] == seasons.AUTO_ACTOR for c in conn.called)


@pytest.mark.anyio
async def test_already_settled_is_not_counted(monkeypatch) -> None:
    """-1 = 别人刚刚结算过。**不是错误，但也不算「我结算了一个」。**"""
    from app import db

    conn = _FakeConn([7], {7: -1})
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(db, "pool", lambda: _Pool(conn))
    assert await seasons.settle_due() == 0


@pytest.mark.anyio
async def test_no_database_is_not_an_error(monkeypatch) -> None:
    from app import db

    monkeypatch.setattr(db, "is_connected", lambda: False)
    assert await seasons.settle_due() == 0


# --- 名片上的段位 -----------------------------------------------------------------


def _loadout(**over) -> loadout.Loadout:
    base = dict(player_id="p", friend_code="AAAA2222", player_name="阿甲",
                avatar="a", avatar_frame="f", pet="", races=[])
    base.update(over)
    return loadout.Loadout(**base)


def test_card_has_no_tier_for_players_who_never_ranked() -> None:
    """🔴 -1 而不是 0。0 是第一段 —— 默认成 0 会让每个新玩家在房间里
    顶着一个他没打过的段位。"""
    assert _loadout().tier == -1
    assert "tier" not in loadout.card_payload(_loadout())


def test_card_carries_the_tier_once_ranked() -> None:
    payload = loadout.card_payload(_loadout(tier=0))
    assert payload["tier"] == 0, "第一段（0）也要发 —— 它是真段位，不是「没有」"
    assert loadout.card_payload(_loadout(tier=7))["tier"] == 7


def test_battle_server_defaults_tier_to_minus_one_too() -> None:
    """两边的默认值必须一样。这边 -1、那边 0 的话，没打过排位的人会显示成黑铁。"""
    assert 'out["tier"] = int(raw.get("tier", -1))' in CARD_GD
    assert "static func tier_of(card: Dictionary) -> int:" in CARD_GD


def test_seat_profile_carries_tier_but_nothing_else_new() -> None:
    """🔴 seat_profiles 随 room_state **广播给同房间所有人**。

    能进去的只有「给别人看的」东西。player_id 之类绝不能加进来。
    """
    profile = CARD_GD.split("static func profile_of")[1].split("static func")[0]
    assert '"tier"' in profile
    for forbidden in ['"pid"', "player_id", '"jti"', '"match"']:
        assert forbidden not in profile, "%s 混进了广播给全房间的 seat_profiles" % forbidden


def test_adding_tier_did_not_bump_the_card_version() -> None:
    """加字段不升版本 —— 升了等于旧战斗服务器拒掉**所有**新名片。"""
    gd = int(re.search(r"const VERSION\s*:=\s*(\d+)", CARD_GD).group(1))
    assert gd == loadout.CARD_VERSION == 1


def test_tier_uses_the_single_conversion() -> None:
    """换算口径只有一处（ranked.tier_of）。loadout 自己除一遍就是第二个真相。"""
    src = (REPO / "backend" / "app" / "loadout.py").read_text(encoding="utf-8")
    assert "ranked.tier_of(" in src
    assert "// 100" not in src and "/ 100" not in src
    assert ranked.tier_of(0) == 0 and ranked.tier_of(700) == 7
