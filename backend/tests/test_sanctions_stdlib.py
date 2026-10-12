"""人工处罚：禁语音 / 禁排位（OPS-02）。不需要数据库。

盯的是**判错了最贵**的那几条：

  · 三个范围必须互相独立 —— 撤销一个连带撤销另一个，受害者永远不知道
    自己为什么还被罚着（或者为什么突然不罚了）。
  · 禁语音是「禁说**不禁听**」（2026-10-12 用户拍板）。做成踢出语音房就违背了拍板。
  · 玩家看得到的字段里不许有内部备注与操作人（任务书 §二.3）。
"""

import asyncio
import base64
import datetime as dt
import json
import pathlib
import sys
import unittest
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from app import party_voice, sanctions  # noqa: E402

_SQL_036 = (pathlib.Path(__file__).resolve().parents[2]
            / "database" / "036_sanction_scopes.sql").read_text(encoding="utf-8")


class _Conn:
    def __init__(self, row=None, flag=False):
        self.row, self.flag, self.calls = row, flag, []

    async def fetchrow(self, sql, *args):
        self.calls.append(("fetchrow", sql, args))
        return self.row

    async def fetchval(self, sql, *args):
        self.calls.append(("fetchval", sql, args))
        return self.flag


class ScopeTests(unittest.TestCase):
    def test_known_scopes(self):
        for name in ("world", "voice", "ranked"):
            self.assertEqual(name, sanctions.clean_scope(name))

    def test_case_and_space_are_tolerated(self):
        self.assertEqual("voice", sanctions.clean_scope("  VOICE "))

    def test_unknown_scope_is_rejected(self):
        for bad in ("", None, "ban", "chat", "world;drop"):
            with self.assertRaises(ValueError):
                sanctions.clean_scope(bad)

    def test_account_ban_is_not_a_scope(self):
        """账号封禁走 016 的 player_bans，语义不一样（整号进不去、要强制下线）。
        混进来的话后台会以为能用同一套解除流程。"""
        self.assertNotIn("ban", sanctions.SCOPES)


class QueryTests(unittest.TestCase):
    def test_live_filters_by_scope(self):
        """🔴 不带 scope 的话，禁语音会把世界频道也封了。"""
        conn = _Conn(row={"reason": "刷屏", "ends_at": None})
        pid = uuid.uuid4()
        asyncio.run(sanctions.live(conn, pid, sanctions.SCOPE_VOICE))
        self.assertIn("scope = $2", conn.calls[0][1])
        self.assertEqual((pid, "voice"), conn.calls[0][2])

    def test_live_ignores_revoked_and_expired_in_sql(self):
        """到期判断必须在请求路径上有效（任务书 §四.3），不能只等定时任务。"""
        sql = sanctions._LIVE_SANCTION
        self.assertIn("revoked_at is null", sql)
        self.assertIn("ends_at > now()", sql)

    def test_any_live_uses_exists_not_latest(self):
        """同范围多条时「只要还有一条生效就继续限制」。
        改成「取最后一条」的话，撤销最新那条会把更早的也放过去。"""
        self.assertIn("exists(", sanctions._ANY_LIVE)
        self.assertIn("scope = $2", sanctions._ANY_LIVE)

    def test_live_returns_none_when_clean(self):
        self.assertIsNone(asyncio.run(sanctions.live(_Conn(row=None), uuid.uuid4(), "voice")))

    def test_is_sanctioned_is_a_bool(self):
        self.assertTrue(asyncio.run(sanctions.is_sanctioned(_Conn(flag=True), uuid.uuid4(), "voice")))
        self.assertFalse(asyncio.run(sanctions.is_sanctioned(_Conn(flag=False), uuid.uuid4(), "voice")))


class ClientViewTests(unittest.TestCase):
    def test_to_client_never_leaks_internal_fields(self):
        s = sanctions.Sanction("voice", "多次辱骂", dt.datetime(2026, 10, 20, tzinfo=dt.UTC))
        view = s.to_client()
        self.assertEqual({"scope", "reason", "ends_at"}, set(view))
        self.assertNotIn("note", view)
        self.assertNotIn("actor", view)

    def test_permanent_shows_as_null_not_a_magic_date(self):
        # 魔法年份（9999-12-31）迟早被当成真日期显示给玩家，016 的注释也说了这一条。
        self.assertIsNone(sanctions.Sanction("ranked", "r", None).to_client()["ends_at"])


class VoiceTokenTests(unittest.TestCase):
    """禁语音 = 禁说不禁听。"""

    CFG = {"api_key": "k", "api_secret": "s" * 32, "client_url": "wss://x"}

    def _claims(self, **kw):
        token = party_voice.issue(self.CFG, "room", "ep", "CODE", "名字", now=1000, **kw)["token"]
        body = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))

    def test_normal_player_can_publish(self):
        self.assertTrue(self._claims()["video"]["canPublish"])

    def test_muted_player_cannot_publish(self):
        self.assertFalse(self._claims(can_publish=False)["video"]["canPublish"])

    def test_muted_player_can_still_listen(self):
        """🔴 这条就是拍板的内容。做成踢出语音房 / canSubscribe=False 都算违背。"""
        self.assertTrue(self._claims(can_publish=False)["video"]["canSubscribe"],
                        "禁语音把收听也禁了")

    def test_microphone_only_is_unchanged(self):
        # 原来的约束不能因为加了开关就松掉。
        v = self._claims()["video"]
        self.assertEqual(["microphone"], v["canPublishSources"])
        self.assertFalse(v["canPublishData"])


class MigrationTests(unittest.TestCase):
    """036 的两条要害。SQL 是手工在 Supabase 跑的，没有别的地方会检查它。"""

    def test_scope_check_allows_the_three_scopes(self):
        self.assertIn("check (scope in ('world', 'voice', 'ranked'))", _SQL_036)

    def test_unmute_takes_a_scope(self):
        self.assertIn("p_scope       text default 'world'", _SQL_036)

    def test_unmute_filters_by_scope(self):
        """🔴 整个 036 最要紧的一行。少了 `scope = p_scope`，
        解除世界频道禁言会连带把禁语音、禁排位一起解了，而且不会报错。"""
        body = _SQL_036.split("create function unmute_player")[1]
        self.assertIn("scope = p_scope", body)

    def test_mute_passes_the_scope_through(self):
        body = _SQL_036.split("create function mute_player")[1]
        self.assertIn("insert into player_mutes (player_id, scope,", body)

    def test_migration_warns_about_the_restart(self):
        """drop + create function 之后旧连接会报 cache lookup failed，
        和只建新表的 035 不一样。部署说明里必须写明。"""
        self.assertIn("重启", _SQL_036.split("## 三")[1].split("幂等")[0])


if __name__ == "__main__":
    unittest.main()
