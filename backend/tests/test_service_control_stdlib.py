"""服务控制（OPS-05）的判定与降级行为。不需要数据库，用替身池跑。

这个文件盯着的是**判错方向代价最大**的那几条：

  · 表不存在（035 没跑）必须**放行**，不能变成全服停服。
  · 读失败且没缓存必须**拒绝新准入**，不能假装正常。
  · `players_in_match()` 读失败回 None（不知道），**不是**空集合（没人在打）——
    混了的话维护一开就会把正在打的人全踢了。
  · 解除维护不能顺带把单独关掉的匹配打开。
"""

import asyncio
import sys
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import service_control as sc  # noqa: E402


class _FakePool:
    """只实现 service_control 用到的四个方法。想让哪次失败就塞个异常进去。"""

    def __init__(self, row=None, rows=(), error=None, status="DELETE 0"):
        self.row, self.rows, self.error, self.status = row, list(rows), error, status
        self.calls = []

    async def fetchrow(self, sql, *args):
        self.calls.append(("fetchrow", sql, args))
        if self.error:
            raise self.error
        return self.row

    async def fetch(self, sql, *args):
        self.calls.append(("fetch", sql, args))
        if self.error:
            raise self.error
        return self.rows

    async def execute(self, sql, *args):
        self.calls.append(("execute", sql, args))
        if self.error:
            raise self.error
        return self.status


class _FakeDb:
    def __init__(self, pool=None, connected=True):
        self._pool, self._connected = pool, connected

    def is_connected(self):
        return self._connected

    def pool(self):
        return self._pool

    @staticmethod
    def affected_rows(status):
        return int(str(status).rsplit(" ", 1)[-1])


class _MissingTable(Exception):
    sqlstate = "42P01"


def _row(**over):
    base = {
        "version": 7,
        "maintenance_enabled": False,
        "matchmaking_enabled": True,
        "maintenance_notice_zh": "", "maintenance_notice_en": "",
        "matchmaking_notice_zh": "", "matchmaking_notice_en": "",
        "expected_back_at": None, "change_reason": "", "actor": "",
        "changed_at": None,
    }
    base.update(over)
    return base


def _install(pool=None, connected=True):
    sc.reset()
    sc.db = _FakeDb(pool, connected)
    return pool


class GateTests(unittest.TestCase):
    """四种 source 下两道闸的判定。表格见 service_control 模块头。"""

    def test_absent_allows_everything(self):
        # 035 没跑 = 维护从来没开过。放行是正确答案，不是将就。
        self.assertTrue(sc.allows_new_entry(sc.ABSENT))
        self.assertTrue(sc.allows_matchmaking(sc.ABSENT))
        self.assertEqual("", sc.entry_block_reason(sc.ABSENT))
        self.assertEqual("", sc.matchmaking_block_reason(sc.ABSENT))

    def test_unknown_refuses_new_entry(self):
        # 任务书 §七.2 末尾：无法确定准入状态时拒绝新开局。
        self.assertFalse(sc.allows_new_entry(sc.UNKNOWN))
        self.assertFalse(sc.allows_matchmaking(sc.UNKNOWN))
        self.assertEqual("service_unavailable", sc.entry_block_reason(sc.UNKNOWN))
        self.assertEqual("service_unavailable", sc.matchmaking_block_reason(sc.UNKNOWN))

    def test_absent_and_unknown_disagree(self):
        # 这两个必须给出相反的结论 —— 合并它们正是 034 那次事故的形状。
        self.assertNotEqual(sc.allows_new_entry(sc.ABSENT), sc.allows_new_entry(sc.UNKNOWN))

    def test_normal_state_allows(self):
        s = sc.State(source="db")
        self.assertTrue(sc.allows_new_entry(s))
        self.assertTrue(sc.allows_matchmaking(s))

    def test_maintenance_blocks_both(self):
        s = sc.State(maintenance=True, matchmaking=True, source="db")
        self.assertFalse(sc.allows_new_entry(s))
        # 维护优先级高于关匹配：matchmaking 还是 True，但匹配照样关着。
        self.assertFalse(sc.allows_matchmaking(s))
        self.assertEqual("service_maintenance", sc.entry_block_reason(s))
        self.assertEqual("service_maintenance", sc.matchmaking_block_reason(s))

    def test_matchmaking_off_does_not_block_entry(self):
        # 只关匹配时，玩家照常进得了游戏，只是开不了新局。
        s = sc.State(maintenance=False, matchmaking=False, source="db")
        self.assertTrue(sc.allows_new_entry(s))
        self.assertFalse(sc.allows_matchmaking(s))
        self.assertEqual("", sc.entry_block_reason(s))
        self.assertEqual("matchmaking_disabled", sc.matchmaking_block_reason(s))

    def test_lifting_maintenance_keeps_matchmaking_closed(self):
        """解除维护不能顺带把之前单独关掉的匹配打开（任务书 §七.2）。"""
        during = sc.State(maintenance=True, matchmaking=False, source="db")
        self.assertFalse(sc.allows_matchmaking(during))
        # 只把 maintenance 放掉，matchmaking 那一列没动。
        after = sc.State(maintenance=False, matchmaking=False, source="db")
        self.assertTrue(sc.allows_new_entry(after))
        self.assertFalse(sc.allows_matchmaking(after), "解除维护把匹配也打开了")
        self.assertEqual("matchmaking_disabled", sc.matchmaking_block_reason(after))

    def test_block_reasons_are_distinct(self):
        """三个原因码不能混：客户端要显示的话不一样，清队列也要靠它区分。"""
        codes = {
            sc.matchmaking_block_reason(sc.State(maintenance=True, source="db")),
            sc.matchmaking_block_reason(sc.State(matchmaking=False, source="db")),
            sc.matchmaking_block_reason(sc.UNKNOWN),
        }
        self.assertEqual(3, len(codes), "原因码撞了：%s" % codes)


class PublicViewTests(unittest.TestCase):
    def test_internal_fields_never_leak(self):
        s = sc.State(maintenance=True, source="db", actor="admin@x", change_reason="内部讨论")
        view = sc.public_view(s)
        blob = repr(view)
        self.assertNotIn("admin@x", blob)
        self.assertNotIn("内部讨论", blob)
        self.assertNotIn("actor", view)
        self.assertNotIn("change_reason", view)

    def test_unknown_presents_as_maintenance_to_clients(self):
        # 读不出状态时对客户端就说「进不去」，别让它以为一切正常。
        self.assertTrue(sc.public_view(sc.UNKNOWN)["maintenance"])
        self.assertFalse(sc.public_view(sc.UNKNOWN)["matchmaking"])


class ReadTests(unittest.TestCase):
    def test_missing_table_reads_as_absent(self):
        _install(_FakePool(error=_MissingTable("relation \"service_control\" does not exist")))
        state = asyncio.run(sc.read())
        self.assertEqual("absent", state.source)
        self.assertTrue(sc.allows_new_entry(state))

    def test_missing_table_without_sqlstate_still_absent(self):
        # 替身 / 别的驱动可能不给 SQLSTATE，退路认消息文字。
        _install(_FakePool(error=RuntimeError('relation "match_entries" does not exist')))
        self.assertEqual("absent", asyncio.run(sc.read()).source)

    def test_real_row_is_read(self):
        _install(_FakePool(row=_row(maintenance_enabled=True, version=9)))
        state = asyncio.run(sc.read())
        self.assertEqual("db", state.source)
        self.assertTrue(state.maintenance)
        self.assertEqual(9, state.version)

    def test_read_failure_falls_back_to_fresh_cache(self):
        pool = _install(_FakePool(row=_row(maintenance_enabled=True)))
        self.assertTrue(asyncio.run(sc.read()).maintenance)
        # 把缓存推到「过了 TTL、但还在 60 秒宽限内」—— 这才会真去查库、然后回退到缓存。
        # 不能设成「刚刚」：那样 read() 直接命中缓存，压根不查库，测的就不是回退了。
        sc._cache_at = time.monotonic() - (sc._CACHE_TTL_SEC + 1.0)
        pool.error = RuntimeError("connection reset by peer")
        state = asyncio.run(sc.read())
        self.assertEqual("cache", state.source)
        self.assertTrue(state.maintenance, "抖一下就把维护状态丢了")
        self.assertFalse(sc.allows_new_entry(state))

    def test_cache_too_old_stops_being_a_fallback(self):
        """宽限期过了就不能再拿旧值顶 —— 数据库真挂了一分钟以上，
        宁可停新准入，也不要在「其实正在维护」时继续放人进来。"""
        pool = _install(_FakePool(row=_row(maintenance_enabled=False)))
        asyncio.run(sc.read())
        sc._cache_at = time.monotonic() - (sc._STALE_GRACE_SEC + 1.0)
        pool.error = RuntimeError("down")
        state = asyncio.run(sc.read())
        self.assertEqual("unknown", state.source)
        self.assertFalse(sc.allows_new_entry(state))

    def test_read_failure_without_cache_is_unknown(self):
        _install(_FakePool(error=RuntimeError("connection reset by peer")))
        state = asyncio.run(sc.read())
        self.assertEqual("unknown", state.source)
        self.assertFalse(sc.allows_new_entry(state))

    def test_disconnected_db_is_unknown_not_absent(self):
        # 没连上数据库 ≠ 表不存在。前者是故障，要拒绝新准入。
        _install(None, connected=False)
        self.assertEqual("unknown", asyncio.run(sc.read()).source)

    def test_cache_hit_avoids_second_query(self):
        pool = _install(_FakePool(row=_row()))
        asyncio.run(sc.read())
        asyncio.run(sc.read())
        self.assertEqual(1, len(pool.calls), "缓存没生效，每次都查库")

    def test_invalidate_forces_reread(self):
        # 后台改完开关靠它即时生效，不是靠等 TTL。
        pool = _install(_FakePool(row=_row()))
        asyncio.run(sc.read())
        sc.invalidate()
        asyncio.run(sc.read())
        self.assertEqual(2, len(pool.calls))


class MatchEntryTests(unittest.TestCase):
    def test_players_in_match_returns_none_on_failure(self):
        """🔴 读失败回 None，不是空集合。混了的话维护一开就踢光正在打的人。"""
        _install(_FakePool(error=RuntimeError("boom")))
        self.assertIsNone(asyncio.run(sc.players_in_match()))

    def test_players_in_match_empty_is_a_real_answer(self):
        _install(_FakePool(rows=[]))
        self.assertEqual(set(), asyncio.run(sc.players_in_match()))

    def test_players_in_match_reads_ids(self):
        a, b = uuid.uuid4(), uuid.uuid4()
        _install(_FakePool(rows=[{"player_id": a}, {"player_id": b}]))
        self.assertEqual({a, b}, asyncio.run(sc.players_in_match()))

    def test_record_entry_never_raises(self):
        """登记失败不能挡住发名片 —— 发不出名片比登记不上严重得多。"""
        _install(_FakePool(error=RuntimeError("boom")))
        asyncio.run(sc.record_entry(uuid.uuid4(), "m-1"))   # 不抛就算过

    def test_record_entry_keeps_empty_uid(self):
        # 自建房没有 match_uid，但同样要登记 —— 他们一样在打。
        pool = _install(_FakePool())
        pid = uuid.uuid4()
        asyncio.run(sc.record_entry(pid))
        self.assertEqual((pid, ""), pool.calls[0][2])

    def test_record_entry_truncates_long_uid(self):
        # 列上有 char_length <= 40 的约束，超长要截而不是让插入失败。
        pool = _install(_FakePool())
        asyncio.run(sc.record_entry(uuid.uuid4(), "x" * 100))
        self.assertEqual(40, len(pool.calls[0][2][1]))

    def test_clear_match_ignores_empty_uid(self):
        """空 uid 绝不能拿去删 —— 那会一次清掉所有自建房玩家的登记。"""
        pool = _install(_FakePool(status="DELETE 6"))
        self.assertEqual(0, asyncio.run(sc.clear_match("")))
        self.assertEqual([], pool.calls, "空 uid 居然发了删除语句")

    def test_clear_match_reports_rows(self):
        _install(_FakePool(status="DELETE 6"))
        self.assertEqual(6, asyncio.run(sc.clear_match("m-1")))

    def test_sweep_uses_the_max_age(self):
        pool = _install(_FakePool(status="DELETE 3"))
        self.assertEqual(3, asyncio.run(sc.sweep_entries()))
        self.assertEqual((float(sc.MATCH_ENTRY_MAX_AGE_SEC),), pool.calls[0][2])

    def test_max_age_is_longer_than_matchmaking_assignment(self):
        """入场登记必须活得比匹配分配（300 秒）久得多，否则就白做了 ——
        用那份分配判「在不在打」正是本模块要取代的做法。"""
        self.assertGreater(sc.MATCH_ENTRY_MAX_AGE_SEC, 300 * 4)


if __name__ == "__main__":
    unittest.main()
