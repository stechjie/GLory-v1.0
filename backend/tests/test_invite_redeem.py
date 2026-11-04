"""邀请码 / 兑换码：不连库的那一半（接口形状、错误码、规范化、配置上下限、审批摘要）。

真库上的行为（并发、上限、发奖不拖垮结算）在 test_invites_pg.py / test_redeem_pg.py。
"""

from __future__ import annotations

import uuid

import pydantic
import pytest
from fastapi.testclient import TestClient

from app import admin, invites, login_sessions, mail, players, redeem, shop
from app.config import Settings, get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import me as me_routes

PLAYER = uuid.UUID(int=4301)
AUTH = {"Authorization": "Bearer token-a"}


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
    from app import db
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _FakeVerifier)

    async def _lookup(auth_uid: str):
        return players.Player(PLAYER, "阿甲", False, "AAAA2222") if auth_uid == "auth-a" else None

    async def _valid_session(_auth_uid, _session_id):
        return None

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    monkeypatch.setattr(login_sessions, "require", _valid_session)
    with TestClient(app) as c:
        yield c
    get_settings.cache_clear()


# --- 接口 ---------------------------------------------------------------------


def test_routes_are_wired_and_need_login(client) -> None:
    """接进了 main.py：没登录是 401，不是 404。"""
    assert client.get("/v1/me/invite").status_code == 401
    assert client.post("/v1/me/invite/bind", json={"code": "AAAA2222"}).status_code == 401
    assert client.post("/v1/me/redeem", json={"code": "GLORY2026"}).status_code == 401


def test_invite_status_does_not_carry_invite_counts(monkeypatch, client) -> None:
    """🔴 2026-11-03 用户定：邀请人那边不显示邀请了几个、到账几个 —— 不显示的数字就不下发。

    以后谁想往状态里加「已邀请 N 人」，这条会红：先去问用户。
    """
    async def _status(_player_id):
        return invites.Status(can_bind=True, bound=False, rewarded=False, reward_level=5,
                              invitee_diamond=50, inviter_diamond=100)

    monkeypatch.setattr(invites, "status", _status)
    r = client.get("/v1/me/invite", headers=AUTH)
    assert r.status_code == 200
    assert set(r.json()) == {"can_bind", "bound", "rewarded", "reward_level",
                             "invitee_diamond", "inviter_diamond"}


@pytest.mark.parametrize("code, status", [
    ("invite_code_invalid", 400),
    ("invite_code_not_found", 404),
    ("invite_self", 409),
    ("invite_already_bound", 409),
    ("invite_window_closed", 409),
    ("invite_disabled", 409),
])
def test_bind_rejections_map_to_status_and_reason(monkeypatch, client, code, status) -> None:
    async def _bind(_player_id, _code):
        raise invites.InviteRejected(code, "给玩家看的话")

    monkeypatch.setattr(invites, "bind", _bind)
    r = client.post("/v1/me/invite/bind", json={"code": "AAAA2222"}, headers=AUTH)
    assert r.status_code == status
    assert r.headers["X-Glory-Reason"] == code
    assert r.json()["detail"] == "给玩家看的话"


@pytest.mark.parametrize("code, status", [
    ("redeem_invalid", 400),
    ("redeem_expired", 409),
    ("redeem_not_started", 409),
    ("redeem_already_claimed", 409),
    ("redeem_campaign_claimed", 409),
    ("redeem_used_up", 409),
    ("redeem_unavailable", 409),
])
def test_redeem_rejections_map_to_status_and_reason(monkeypatch, client, code, status) -> None:
    async def _claim(_player_id, _code):
        raise redeem.RedeemRejected(code, "给玩家看的话")

    monkeypatch.setattr(redeem, "claim", _claim)
    r = client.post("/v1/me/redeem", json={"code": "GLORY2026"}, headers=AUTH)
    assert r.status_code == status
    assert r.headers["X-Glory-Reason"] == code


def test_redeem_lockout_is_429_with_retry_after(monkeypatch, client) -> None:
    async def _claim(_player_id, _code):
        raise redeem.RedeemLocked(61)

    monkeypatch.setattr(redeem, "claim", _claim)
    r = client.post("/v1/me/redeem", json={"code": "GLORY2026"}, headers=AUTH)
    assert r.status_code == 429
    assert r.headers["Retry-After"] == "61"
    assert r.headers["X-Glory-Reason"] == "redeem_locked"
    assert "2 分钟" in r.json()["detail"], "61 秒向上取整是 2 分钟，不能说成 1 分钟"


def test_redeem_success_shape(monkeypatch, client) -> None:
    async def _claim(_player_id, _code):
        return redeem.Claimed(mail_id=7, diamond=100, coin=0, items=("pet_cat",))

    monkeypatch.setattr(redeem, "claim", _claim)
    r = client.post("/v1/me/redeem", json={"code": "GLORY2026"}, headers=AUTH)
    assert r.status_code == 200
    assert r.json() == {"mail_id": 7, "diamond": 100, "coin": 0, "items": ["pet_cat"]}


# --- 规范化 ---------------------------------------------------------------------


@pytest.mark.parametrize("raw", ["glory2026", " GLORY-2026 ", "glory 20 26", "ＧＬＯＲＹ２０２６", "GLORY　2026"])
def test_redeem_normalize_accepts_what_players_actually_type(raw) -> None:
    """全角（中文输入法）、空格、连字符、小写：看着一样的都要对得上。"""
    assert redeem.normalize(raw) == "GLORY2026"


def test_invite_normalize_turns_fullwidth_friend_code_into_ascii() -> None:
    assert invites.normalize("ａｂｃｄ ２３４５") == "ABCD2345"
    assert invites.FRIEND_CODE_RE.fullmatch(invites.normalize("abcd-2345"))
    # 好友码排掉了 0 O 1 I L：抄成这些字符的直接判格式不对，不去查库。
    assert not invites.FRIEND_CODE_RE.fullmatch("ABCD2340")


# --- 配置上下限 -------------------------------------------------------------------


@pytest.mark.parametrize("field, value", [
    ("invite_reward_level", 1),
    ("invite_reward_level", 21),
    ("invite_invitee_diamond", 0),
    ("invite_inviter_diamond", 100_001),
    ("invite_max_rewarded", -1),
    ("invite_bind_window_days", 0),
    ("redeem_failure_limit", 0),
    ("redeem_failure_window_seconds", 10),
])
def test_out_of_range_settings_fail_at_startup(field, value) -> None:
    """🔴 填错的数在启动时就报错，不能等到某个玩家升到 5 级、炸在对局结算里。"""
    with pytest.raises(pydantic.ValidationError):
        Settings(**{field: value})


def test_invite_defaults_are_what_the_user_decided() -> None:
    s = Settings()
    assert (s.invite_enabled, s.invite_reward_level, s.invite_invitee_diamond, s.invite_inviter_diamond,
            s.invite_max_rewarded, s.invite_bind_window_days) == (True, 5, 50, 100, 20, 7)


# --- 后台审批 -------------------------------------------------------------------


def _draft(**kw) -> admin.RedeemDraft:
    base = dict(mode="code", code="glory-2026", max_uses=5000, count=0, campaign="", diamond=100, coin=0,
                items=(), days=14, starts_at="", note="11 月活动")
    base.update(kw)
    return admin.RedeemDraft(**base)


def test_redeem_request_summary_states_the_total_exposure() -> None:
    """批的人要一眼看到「最多一共发出多少」—— 批的就是这个数。"""
    payload = admin._check_redeem(_draft())
    assert payload["code"] == "GLORY2026"
    summary = admin._redeem_summary(payload)
    assert "最多一共发出 500,000 钻石" in summary
    batch = admin._redeem_summary(admin._check_redeem(_draft(mode="batch", count=200, diamond=50)))
    assert "200 个单次兑换码" in batch and "最多一共发出 10,000 钻石" in batch


@pytest.mark.parametrize("kw, words", [
    ({"max_uses": 0}, "要么留空"),
    ({"max_uses": 1_000_001}, "要么留空"),
    ({"mode": "batch", "count": 5001}, "5000"),
    ({"diamond": 0, "coin": 0}, "至少填一样"),
    ({"code": "AB_CD"}, "4 到 24 位"),
    ({"days": 0}, "1 到 365"),
    ({"starts_at": "2026-11-10T10:00:00"}, "时区"),
])
def test_redeem_request_rejects_bad_drafts(kw, words) -> None:
    with pytest.raises(admin.AdminRejected) as exc:
        admin._check_redeem(_draft(**kw))
    assert words in exc.value.message


def test_unlimited_code_summary_says_there_is_no_total_cap() -> None:
    """不限人数（045，11-04 用户定）没有「最多一共发出」这个数 —— 摘要要明说没有上限，而不是算出一个 0。"""
    payload = admin._check_redeem(_draft(max_uses=None, diamond=100, days=14))
    assert payload["max_uses"] is None
    summary = admin._redeem_summary(payload)
    assert "不限人数" in summary and "没有总量上限" in summary and "每人 100 钻石" in summary
    assert "最多一共发出" not in summary


def test_summary_names_items_so_the_approver_knows_what_they_approve() -> None:
    """批的人看到的是名字；整族要写明是整族（一件附件 = 8 个棋子）。"""
    human = shop.content_item("human")
    frame = next(i for i in shop.items() if i.kind == "avatar_frame")
    summary = admin._redeem_summary(admin._check_redeem(_draft(items=("human", frame.grants))))
    assert "%s（整族 %d 个棋子）" % (human.name, len(human.requires)) in summary
    assert frame.name in summary and frame.grants not in summary


def test_attachable_catalog_groups_units_under_their_race() -> None:
    """后台选择器靠这份清单分组：种族带全部棋子，棋子指回种族；目录里登记的一样不少，下架的也在。"""
    catalog = admin.attachable_items()
    by_id = {c["content_id"]: c for c in catalog}
    assert len(by_id) == len(catalog), "清单里不能有重复的 content_id"
    races = [c for c in catalog if c["kind"] == "race"]
    assert {r["content_id"] for r in races} == {"human", "god", "dark", "undead", "crimson"}
    for race in races:
        assert race["parts"], race
        for part in race["parts"]:
            assert by_id[part]["kind"] == "unit" and by_id[part]["race"] == race["content_id"], part
    # 用户要的「皮肤」分组：三张棋盘皮肤都没上架（两张靠祈愿），只列在卖的话这一组是空的。
    assert {"prep_skin_ice", "prep_skin_sakura", "prep_skin_nightwisp"} <= set(by_id)
    assert {i.grants for i in shop.items()} <= set(by_id)
    for c in catalog:
        assert mail.item_problem([c["content_id"]]) == "", c
