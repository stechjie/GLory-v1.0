"""匹配队列（`docs/排位系统设计.md` 第五节）。第 4a 步：账号服务器这一半。

不连数据库、不连 WebSocket：发送口用一个记录消息的假函数，时钟用一个能手推的假时钟。
验的是**状态机**，不是网络。

最重要的几组，失败时都**不报错**：

  1. 解散一桌时，没拒绝的那几个必须回**队首**且不受罚。做成「回队尾」或者
     「一起踢出去」都不会报错 —— 只是拿别人的锅罚他们，而且只有等真玩家
     排到第二次才会有人发现。
  2. 断线宽限内的人还占着位次，但**不许被凑进一桌**。凑进去的结果一定是
     确认超时、整桌解散，白白让另外五个人等 30 秒。
  3. 两个模式的人不能互相匹配。混了的话排位和休闲会打进同一局。
  4. 名片加字段**不许升 CARD_VERSION**。升了等于旧战斗服务器拒掉所有新名片。
  5. 分配有 TTL。没 TTL 的话，一个匹配到了却再也没上线的人，下次登录会被
     塞进一局早就打完的对局。

跑：
    backend\\.venv\\Scripts\\python.exe -m pytest backend/tests/test_matchmaking.py -q -p no:cacheprovider
"""

from __future__ import annotations

import pathlib
import re
import uuid
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from app import db, loadout, matchmaking, players
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import loadout as loadout_routes
from app.routes import matchmaking as match_routes
from app.routes import me as me_routes

REPO = pathlib.Path(__file__).resolve().parents[2]
SQL_013 = (REPO / "database" / "013_match_history.sql").read_text(encoding="utf-8")
CARD_GD = (REPO / "scripts" / "multiplayer" / "BattleCard.gd").read_text(encoding="utf-8")


class _Clock:
    """手推的单调时钟。真 sleep 会让「确认超时」那组跑 30 秒。"""

    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


class _Recorder:
    def __init__(self) -> None:
        self.sent: list[tuple[uuid.UUID, dict]] = []

    async def __call__(self, player_id: uuid.UUID, payload: dict) -> int:
        self.sent.append((player_id, payload))
        return 1

    def states_for(self, player_id: uuid.UUID) -> list[str]:
        return [str(p.get("state", "")) for pid, p in self.sent if pid == player_id]

    def last_for(self, player_id: uuid.UUID) -> dict:
        for pid, payload in reversed(self.sent):
            if pid == player_id:
                return payload
        return {}

    def clear(self) -> None:
        self.sent.clear()


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
def mm():
    clock = _Clock()
    recorder = _Recorder()
    maker = matchmaking.Matchmaker(recorder, now=clock)
    return maker, recorder, clock


def _players(count: int) -> list[uuid.UUID]:
    # 固定 uuid，失败信息才读得懂（assign_teams 会按 bytes 排序）。
    return [uuid.UUID(int=i + 1) for i in range(count)]


def _fill(maker, players, mode=matchmaking.CASUAL) -> None:
    for pid in players:
        maker.join(pid, mode)


# --- 凑人 ---------------------------------------------------------------------


@pytest.mark.anyio
async def test_five_players_do_not_form_a_match(mm) -> None:
    maker, rec, _ = mm
    players = _players(5)
    _fill(maker, players)
    await maker.tick()
    assert all(maker.state_of(p)["state"] == "queued" for p in players)


@pytest.mark.anyio
async def test_six_players_form_a_match(mm) -> None:
    maker, rec, _ = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    for p in players:
        assert maker.state_of(p)["state"] == "found"
        assert "found" in rec.states_for(p)
    # 队列空了，不该有人还排着
    assert maker.queue_size(matchmaking.CASUAL) == 0


@pytest.mark.anyio
async def test_twelve_players_form_two_matches(mm) -> None:
    maker, _, _ = mm
    players = _players(12)
    _fill(maker, players)
    await maker.tick()
    uids = {maker.state_of(p)["match_uid"] for p in players}
    assert len(uids) == 2, "一轮 tick 应该能凑出两桌"


@pytest.mark.anyio
async def test_modes_do_not_mix(mm) -> None:
    """🔴 两个模式的人混进同一局 = 排位和休闲打到一起。"""
    maker, _, _ = mm
    casual = _players(3)
    ranked = [uuid.UUID(int=100 + i) for i in range(3)]
    _fill(maker, casual, matchmaking.CASUAL)
    _fill(maker, ranked, matchmaking.RANKED)
    await maker.tick()
    assert all(maker.state_of(p)["state"] == "queued" for p in casual + ranked)


def test_switching_mode_leaves_the_other_queue(mm) -> None:
    maker, _, _ = mm
    p = _players(1)[0]
    maker.join(p, matchmaking.CASUAL)
    maker.join(p, matchmaking.RANKED)
    assert maker.queue_size(matchmaking.CASUAL) == 0
    assert maker.queue_size(matchmaking.RANKED) == 1


def test_rejoining_does_not_move_position(mm) -> None:
    """断线重连会重发一次 join。重排到队尾等于惩罚掉线。"""
    maker, _, _ = mm
    players = _players(3)
    _fill(maker, players)
    before = maker.position_of(players[0], matchmaking.CASUAL)
    maker.join(players[0], matchmaking.CASUAL)
    assert maker.position_of(players[0], matchmaking.CASUAL) == before == 1


# --- 确认 ---------------------------------------------------------------------


@pytest.mark.anyio
async def test_all_six_must_accept(mm) -> None:
    maker, _, _ = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    for p in players[:5]:
        assert maker.accept(p)["state"] == "found"
    assert maker.accept(players[5])["state"] == "ready"
    for p in players:
        assert maker.state_of(p)["state"] == "ready"


@pytest.mark.anyio
async def test_accepting_twice_is_not_an_error(mm) -> None:
    """弱网下客户端会重发，玩家也会点两下。"""
    maker, _, _ = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    assert maker.accept(players[0])["state"] == "found"
    assert maker.accept(players[0])["state"] == "found"
    for p in players[1:]:
        maker.accept(p)
    # 全员确认之后再点一次，要回 ready 而不是 idle
    assert maker.accept(players[0])["state"] == "ready"


@pytest.mark.anyio
async def test_pending_player_cannot_requeue(mm) -> None:
    """已经在一桌里的人重排 = 把自己从那桌摘掉，另外五个陪着超时。"""
    maker, _, _ = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    assert maker.join(players[0], matchmaking.CASUAL)["state"] == "found"
    assert maker.queue_size(matchmaking.CASUAL) == 0


# --- 解散：这组是最重要的 ---------------------------------------------------------


@pytest.mark.anyio
async def test_decline_sends_the_innocent_back_to_the_front(mm) -> None:
    """🔴 没拒绝的五个人回**队首**，而且不受任何惩罚。

    回队尾 / 一起踢出去都不会报错 —— 只是拿别人的锅罚他们。
    """
    maker, rec, _ = mm
    waiting = _players(3)          # 先在队里排着的三个人
    matched = [uuid.UUID(int=50 + i) for i in range(6)]
    _fill(maker, matched)
    await maker.tick()
    _fill(maker, waiting)          # 这三个是后来的

    rec.clear()
    maker.leave(matched[0])        # 一个人拒绝

    assert maker.state_of(matched[0])["state"] == "idle"
    for p in matched[1:]:
        assert maker.state_of(p)["state"] == "queued"
    # 🔴 回的是队首：五个无辜的人排在后来那三个前面
    positions = [maker.position_of(p, matchmaking.CASUAL) for p in matched[1:]]
    assert sorted(positions) == [1, 2, 3, 4, 5], "没拒绝的人没回到队首：%s" % positions
    assert all(maker.position_of(p, matchmaking.CASUAL) > 5 for p in waiting)


@pytest.mark.anyio
async def test_accept_timeout_dissolves_and_only_blames_the_silent(mm) -> None:
    maker, rec, clock = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    for p in players[:5]:
        maker.accept(p)

    clock.advance(matchmaking.ACCEPT_TIMEOUT_SEC + 1)
    rec.clear()
    await maker.tick()

    assert maker.state_of(players[5])["state"] == "idle", "没确认的那个应该被移出队列"
    for p in players[:5]:
        assert maker.state_of(p)["state"] == "queued", "确认了的人不该受罚"


@pytest.mark.anyio
async def test_disconnect_while_pending_dissolves_immediately(mm) -> None:
    """待确认阶段断线：当场解散，别让另外五个陪着干等 30 秒。"""
    maker, _, _ = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    maker.on_disconnect(players[2])
    assert maker.state_of(players[2])["state"] == "idle"
    for p in players[:2] + players[3:]:
        assert maker.state_of(p)["state"] == "queued"


# --- 掉线宽限 -----------------------------------------------------------------


@pytest.mark.anyio
async def test_disconnected_waiter_keeps_position_but_is_not_matched(mm) -> None:
    """🔴 宽限内的人占着位次，但不许被凑进一桌。

    凑进去的结果一定是确认超时、整桌解散 —— 白白让另外五个人等 30 秒。
    """
    maker, _, clock = mm
    players = _players(6)
    _fill(maker, players)
    maker.on_disconnect(players[0])
    await maker.tick()
    # 只剩五个「活着的」，凑不成
    assert maker.state_of(players[1])["state"] == "queued"
    # 位次还在
    assert maker.position_of(players[0], matchmaking.CASUAL) == 1


@pytest.mark.anyio
async def test_disconnected_waiter_is_dropped_after_grace(mm) -> None:
    maker, _, clock = mm
    players = _players(3)
    _fill(maker, players)
    maker.on_disconnect(players[0])
    clock.advance(matchmaking.QUEUE_GRACE_SEC + 1)
    await maker.tick()
    assert maker.position_of(players[0], matchmaking.CASUAL) == 0
    assert maker.queue_size(matchmaking.CASUAL) == 2


@pytest.mark.anyio
async def test_seventh_player_fills_in_for_the_disconnected_one(mm) -> None:
    maker, _, _ = mm
    players = _players(6)
    _fill(maker, players)
    maker.on_disconnect(players[0])
    extra = uuid.UUID(int=77)
    maker.join(extra, matchmaking.CASUAL)
    await maker.tick()
    assert maker.state_of(extra)["state"] == "found"
    assert maker.state_of(players[0])["state"] == "queued", "掉线的人还排着，只是没被选中"


# --- 分配 ---------------------------------------------------------------------


@pytest.mark.anyio
async def test_assignment_expires(mm) -> None:
    """没 TTL 的话，一个匹配到了却再没上线的人，下次登录会被塞进一局早打完的对局。"""
    maker, _, clock = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    for p in players:
        maker.accept(p)
    assert maker.assignment_for(players[0]) is not None
    clock.advance(matchmaking.ASSIGNMENT_TTL_SEC + 1)
    assert maker.assignment_for(players[0]) is None
    assert maker.state_of(players[0])["state"] == "idle"


@pytest.mark.anyio
async def test_player_with_assignment_cannot_requeue(mm) -> None:
    """拿到分配还没去连的人重排 = 同时出现在两局里。"""
    maker, _, _ = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    for p in players:
        maker.accept(p)
    assert maker.join(players[0], matchmaking.CASUAL)["state"] == "ready"
    assert maker.queue_size(matchmaking.CASUAL) == 0


@pytest.mark.anyio
async def test_assignment_carries_the_same_match_uid_for_everyone(mm) -> None:
    maker, _, _ = mm
    players = _players(6)
    _fill(maker, players)
    await maker.tick()
    for p in players:
        maker.accept(p)
    uids = {maker.assignment_for(p).match_uid for p in players}
    assert len(uids) == 1, "六个人的会合键必须是同一个，否则会建出多个房间"


# --- 分队 ---------------------------------------------------------------------


def test_teams_are_three_and_three() -> None:
    players = _players(6)
    teams = matchmaking.assign_teams(players, {})
    assert teams.count(0) == 3 and teams.count(1) == 3


def test_snake_draft_splits_strong_and_weak() -> None:
    """🔴 3v3 里一个人的影响是 1/3。「前三对后三」会让强的全在一边。"""
    players = _players(6)
    ratings = {p: (600 - i * 100) for i, p in enumerate(players)}   # 600..100
    teams = matchmaking.assign_teams(players, ratings)
    by_team = [[], []]
    for p, team in zip(players, teams, strict=True):
        by_team[team].append(ratings[p])
    gap = abs(sum(by_team[0]) - sum(by_team[1]))
    assert gap <= 100, "两队分差 %d，蛇形分队没起作用：%s" % (gap, by_team)


def test_match_uid_matches_the_sql_constraint() -> None:
    """会合键最后会成为 match_records.match_uid（第 4b 步）。格式对不上 = 入库那一刻 500。"""
    pattern = re.search(r"match_uid_format check \(match_uid ~ '([^']+)'\)", SQL_013).group(1)
    for _ in range(20):
        assert re.match(pattern, matchmaking.new_match_uid())


# --- 名片带分配 ---------------------------------------------------------------


def _loadout(**over) -> loadout.Loadout:
    base = dict(
        player_id=str(uuid.UUID(int=1)), friend_code="AAAA2222", player_name="阿甲",
        avatar="a", avatar_frame="f", pet="", races=["god", "dark", "undead", "human"],
    )
    base.update(over)
    return loadout.Loadout(**base)


def test_card_without_assignment_has_no_match_fields() -> None:
    """自己建房 / 输房间号那条路不带这两个字段 —— 战斗服务器按名取，缺了走老路。"""
    payload = loadout.card_payload(_loadout())
    assert "match" not in payload and "team" not in payload


def test_card_with_assignment_carries_match_and_team() -> None:
    payload = loadout.card_payload(_loadout(), match_uid="a" * 32, team=1)
    assert payload["match"] == "a" * 32
    assert payload["team"] == 1


def test_adding_fields_does_not_bump_card_version() -> None:
    """🔴 升版本 = 旧战斗服务器拒掉**所有**新名片。

    加字段是向后兼容的（战斗服务器按名取、缺了用默认），只有**改字段含义**
    才该升版本。两边的常量必须一致。
    """
    gd = int(re.search(r"const VERSION\s*:=\s*(\d+)", CARD_GD).group(1))
    assert gd == loadout.CARD_VERSION == 1


def test_card_stays_within_what_the_battle_server_accepts() -> None:
    """多了两个字段之后仍要在 BattleCard.MAX_CARD_CHARS 以内。
    超了的表现是**匹配出来的对局所有人都进不去**，而自定义房间一切正常。"""
    limit = int(re.search(r"MAX_CARD_CHARS\s*:=\s*(\d+)", CARD_GD).group(1))
    fat = _loadout(
        player_name="字" * 24, avatar="upload:" + "a" * 64, avatar_frame="upload:" + "b" * 64,
        pet="p" * 32, races=[("r%02d" % i) + "x" * 29 for i in range(loadout.MAX_RACES)],
    )
    payload = loadout.card_payload(fat, match_uid="f" * 32, team=1)
    import json as _json

    body = _json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    # 线格式 = base64(body) + '.' + base64(256 字节签名)
    wire = len(body) * 4 // 3 + 1 + 344
    assert wire < limit, "带分配的最大名片 %d 字符，超过战斗服务器的 %d" % (wire, limit)


# --- 模式开关 -----------------------------------------------------------------


def test_both_modes_are_open_now() -> None:
    """第 5 步做完之后排位也开了。

    ⚠️ 「在 OPEN_MODES 里」只是「这个模式存在」，不是「随时能排」——
    排位还要过时间窗口和信誉分闸（backend/tests/test_ranked.py 那一组）。
    """
    assert matchmaking.OPEN_MODES == matchmaking.KNOWN_MODES == {
        matchmaking.CASUAL, matchmaking.RANKED}


def test_match_size_matches_the_battle_server() -> None:
    """六个座位是 NetworkService.TEAM_SLOTS。对不上的话会凑出一桌坐不下的人。"""
    net = (REPO / "scripts" / "autoload" / "NetworkService.gd").read_text(encoding="utf-8")
    slots = int(re.search(r"const TEAM_SLOTS\s*:=\s*(\d+)", net).group(1))
    assert slots == matchmaking.MATCH_SIZE == 6


# --- 接口（名片那条接线）-------------------------------------------------------


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


PLAYER_A = uuid.UUID(int=1)


class _GateConn:
    """排队接口现在要查信誉分（第 5b 步的闸）。这里扮演一个「满分、没被禁」的行。"""

    async def fetchrow(self, sql, *args):
        return {"score": 100, "banned_until": None}


class _GatePool:
    def acquire(self):
        class _A:
            async def __aenter__(self):
                return _GateConn()

            async def __aexit__(self, *e):
                return False

        return _A()


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
    monkeypatch.setattr(db, "pool", _GatePool)
    # 每个用例一个干净的匹配器，别让上一个用例的队列漏过来。
    matchmaking.install(matchmaking.Matchmaker(_Recorder()))
    loadout_routes._card_limiter.reset()
    match_routes._queue_limiter.reset()
    match_routes._state_limiter.reset()
    yield
    matchmaking.install(matchmaking.Matchmaker(_Recorder()))
    loadout_routes._card_limiter.reset()
    match_routes._queue_limiter.reset()
    match_routes._state_limiter.reset()
    get_settings.cache_clear()


def test_queue_requires_login(wired) -> None:
    assert TestClient(app).post("/v1/match/queue", json={"mode": "casual"}).status_code == 401


def test_ranked_queue_outside_the_window_says_why(wired) -> None:
    """🔴 排在一条永远凑不齐的队里，是最让人摸不着头脑的一种失败。

    窗口外要明说「19:00 - 23:00 开放」，不能默默排着。
    """
    import datetime as _dt

    from app import ranked as _ranked

    inside = _ranked.window_state()["accepting"]
    with TestClient(app) as client:
        r = client.post("/v1/match/queue", json={"mode": "ranked"},
                        headers={"Authorization": "Bearer token-a"})
    if inside:
        assert r.status_code == 200
    else:
        assert r.status_code == 409
        assert r.headers.get("X-Glory-Reason") == _ranked.GATE_WINDOW_CLOSED
    assert isinstance(_dt.timedelta(hours=8), _dt.timedelta)


def test_unknown_mode_is_400(wired) -> None:
    with TestClient(app) as client:
        r = client.post("/v1/match/queue", json={"mode": "battle_royale"},
                        headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 400
    assert r.headers.get("X-Glory-Reason") == "unknown_mode"


def test_queue_then_state_then_leave(wired) -> None:
    with TestClient(app) as client:
        headers = {"Authorization": "Bearer token-a"}
        # 用 casual：休闲不受时间窗口限制，这条用例验的是「进出队列」本身，
        # 不该因为跑测试的时间不在 19:00-23:00 就红。
        joined = client.post("/v1/match/queue", json={"mode": "casual"}, headers=headers)
        assert joined.status_code == 200
        assert joined.json()["state"]["state"] == "queued"
        assert client.get("/v1/match/state", headers=headers).json()["state"]["state"] == "queued"
        assert client.delete("/v1/match/queue", headers=headers).json()["state"]["state"] == "idle"
        assert client.get("/v1/match/state", headers=headers).json()["state"]["state"] == "idle"


def test_ws_state_shape_matches_the_http_one(wired) -> None:
    """🔴 推送与轮询必须是同一个形状，否则客户端要写两套解析 —— 那是会分叉的两处。"""
    with TestClient(app) as client:
        # ⚠️ 要在 with 里面铺状态：TestClient 的 with 会跑 lifespan，
        # 而 lifespan 里的 matchmaking.install() 会把外面装的实例换掉。
        matchmaking.current().join(PLAYER_A, matchmaking.CASUAL)
        http = client.get("/v1/match/state",
                          headers={"Authorization": "Bearer token-a"}).json()["state"]
    assert set(http) == set(matchmaking.queued_message(1, matchmaking.CASUAL))


def test_card_carries_the_assignment_after_everyone_accepts(wired, monkeypatch) -> None:
    """🔴 这一整套的接缝：匹配好之后领的名片必须带会合键。

    漏了的话六个人会各自建一个房间，症状是「匹配成功但大家都在空房里」。
    """
    captured: dict = {}

    async def _card(pid, match_uid="", team=-1):
        captured["match_uid"] = match_uid
        captured["team"] = team
        return "Ym9keQ==.c2ln"

    monkeypatch.setattr(loadout, "issue_card", _card)

    with TestClient(app) as client:
        # 同上：lifespan 会换掉匹配器实例，状态要在 with 里面铺。
        maker = matchmaking.current()
        maker._assignments[PLAYER_A] = matchmaking.Assignment(
            match_uid="b" * 32, mode=matchmaking.CASUAL, team=1,
            expires_at=maker._now() + 100)
        r = client.post("/v1/battle/card", headers={"Authorization": "Bearer token-a"})
    assert r.status_code == 200
    assert captured == {"match_uid": "b" * 32, "team": 1}


def test_card_without_assignment_asks_for_no_match(wired, monkeypatch) -> None:
    captured: dict = {}

    async def _card(pid, match_uid="", team=-1):
        captured["match_uid"] = match_uid
        captured["team"] = team
        return "Ym9keQ==.c2ln"

    monkeypatch.setattr(loadout, "issue_card", _card)
    with TestClient(app) as client:
        client.post("/v1/battle/card", headers={"Authorization": "Bearer token-a"})
    assert captured == {"match_uid": "", "team": -1}
