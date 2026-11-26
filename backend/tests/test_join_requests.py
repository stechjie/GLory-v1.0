"""好友界面「加入」要好友同意（2026-11-26）。

两层：
  1. 账本（app/join_requests.py）：一人一张、过期作废、只有被申请的人能回、回过就没了。
  2. 接口（app/routes/join_requests.py）：只能向在线好友申请；推送发给对的人、带对的字段；
     顶掉上一张 / 撤回时通知上一位好友收框。

运行：python -m pytest tests/test_join_requests.py -q
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from app import db, friends, join_requests, players, profile, realtime
from app.config import get_settings
from app.jwt_verify import Claims, TokenError
from app.main import app
from app.routes import join_requests as routes
from app.routes import me as me_routes

A = uuid.UUID("11111111-1111-1111-1111-111111111111")
B = uuid.UUID("22222222-2222-2222-2222-222222222222")
C = uuid.UUID("33333333-3333-3333-3333-333333333333")


# --- 账本 ---------------------------------------------------------------------


def test_request_expires() -> None:
    book = join_requests.JoinRequests()
    request, replaced = book.create(A, B, 42, now=100.0)
    assert replaced is None and request.room_id == 42
    assert book.take(request.id, B, now=100.0 + join_requests.TTL_SEC + 0.1) is None


def test_only_target_can_reply_and_only_once() -> None:
    book = join_requests.JoinRequests()
    request, _ = book.create(A, B, 42, now=100.0)
    assert book.take(request.id, C, now=101.0) is None, "不是发给 C 的，C 不能替 B 回"
    taken = book.take(request.id, B, now=101.0)
    assert taken is not None and taken.requester == A and taken.room_id == 42
    assert book.take(request.id, B, now=102.0) is None, "回过一次就没了"


def test_new_request_replaces_previous() -> None:
    book = join_requests.JoinRequests()
    first, _ = book.create(A, B, 42, now=100.0)
    second, replaced = book.create(A, C, 43, now=101.0)
    assert replaced is not None and replaced.id == first.id
    assert book.take(first.id, B, now=102.0) is None, "被顶掉的那张不能再同意"
    assert book.take(second.id, C, now=102.0) is not None


def test_cancel_removes_request() -> None:
    book = join_requests.JoinRequests()
    request, _ = book.create(A, B, 42, now=100.0)
    cancelled = book.cancel(A, now=101.0)
    assert cancelled is not None and cancelled.id == request.id
    assert book.take(request.id, B, now=102.0) is None
    assert book.cancel(A, now=103.0) is None


# --- 接口 ---------------------------------------------------------------------


@dataclass
class _Player:
    player_id: uuid.UUID
    player_name: str
    friend_code: str


class _Verifier:
    async def verify(self, token: str) -> Claims:
        uid = {"token-a": "auth-a", "token-b": "auth-b"}.get(token)
        if uid is None:
            raise TokenError("bad token")
        return Claims(auth_uid=uid, is_anonymous=True, expires_at=0)


class _Hub:
    def __init__(self) -> None:
        self.online = {B}
        self.sent: list[tuple[uuid.UUID, dict]] = []

    def is_online(self, player_id: uuid.UUID) -> bool:
        return player_id in self.online

    async def send_to_player(self, player_id: uuid.UUID, payload: dict) -> int:
        self.sent.append((player_id, payload))
        return 1


@pytest.fixture
def wired(monkeypatch: pytest.MonkeyPatch):
    from http_fixture_support import isolate_http_services

    monkeypatch.setenv("GLORY_DISABLE_INSTANCE_LOCK", "true")
    monkeypatch.setenv("GLORY_SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("GLORY_DATABASE_URL", "")
    get_settings.cache_clear()
    isolate_http_services(monkeypatch, app)
    monkeypatch.setattr(db, "is_connected", lambda: True)
    monkeypatch.setattr(me_routes, "get_verifier", _Verifier)
    people = {"auth-a": _Player(A, "阿甲", "AAAA2222"), "auth-b": _Player(B, "阿乙", "BBBB3333")}

    async def _lookup(auth_uid: str):
        return people.get(auth_uid)

    monkeypatch.setattr(players, "get_by_auth_uid", _lookup)
    relations = {"BBBB3333": "friends", "CCCC4444": "friends", "DDDD5555": "none"}

    async def _relation(player_id, code):
        return relations.get(code, "none")

    monkeypatch.setattr(friends, "relation_to", _relation)
    by_code = {"BBBB3333": _Player(B, "阿乙", "BBBB3333"), "CCCC4444": _Player(C, "阿丙", "CCCC4444")}

    async def _by_code(code):
        return by_code.get(code)

    monkeypatch.setattr(profile, "get_by_friend_code", _by_code)
    hub = _Hub()
    monkeypatch.setattr(realtime, "hub", lambda: hub)
    book = join_requests.JoinRequests()
    monkeypatch.setattr(join_requests, "current", lambda: book)
    routes._request_limiter.reset()
    yield hub
    routes._request_limiter.reset()
    get_settings.cache_clear()


def _auth(who: str = "a") -> dict[str, str]:
    return {"Authorization": "Bearer token-%s" % who}


def test_request_pushes_to_friend(wired) -> None:
    hub = wired
    with TestClient(app) as client:
        r = client.post("/v1/me/join-requests", json={"friend_code": "bbbb3333", "room_id": 42},
                        headers=_auth())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["expires_sec"] == int(join_requests.TTL_SEC) and body["request_id"]
    assert len(hub.sent) == 1
    to, payload = hub.sent[0]
    assert to == B
    assert payload == {"t": "room_join_request", "request_id": body["request_id"], "room_id": 42,
                       "from_code": "AAAA2222", "from_name": "阿甲",
                       "expires_sec": int(join_requests.TTL_SEC)}


def test_request_only_to_friends(wired) -> None:
    hub = wired
    with TestClient(app) as client:
        r = client.post("/v1/me/join-requests", json={"friend_code": "DDDD5555", "room_id": 42},
                        headers=_auth())
    assert r.status_code == 403, r.text
    assert hub.sent == []


def test_request_needs_friend_online(wired) -> None:
    hub = wired
    with TestClient(app) as client:
        r = client.post("/v1/me/join-requests", json={"friend_code": "CCCC4444", "room_id": 42},
                        headers=_auth())
    assert r.status_code == 409, r.text
    assert "不在线" in r.json()["detail"]
    assert hub.sent == []


def test_request_is_rate_limited(wired) -> None:
    with TestClient(app) as client:
        first = client.post("/v1/me/join-requests", json={"friend_code": "BBBB3333", "room_id": 42},
                            headers=_auth())
        second = client.post("/v1/me/join-requests", json={"friend_code": "BBBB3333", "room_id": 42},
                             headers=_auth())
    assert first.status_code == 200 and second.status_code == 429


@pytest.mark.parametrize("accept", [True, False])
def test_reply_reaches_requester(wired, accept: bool) -> None:
    hub = wired
    with TestClient(app) as client:
        request_id = client.post("/v1/me/join-requests",
                                 json={"friend_code": "BBBB3333", "room_id": 42},
                                 headers=_auth()).json()["request_id"]
        hub.sent.clear()
        r = client.post("/v1/me/join-requests/%s/reply" % request_id, json={"accept": accept},
                        headers=_auth("b"))
        again = client.post("/v1/me/join-requests/%s/reply" % request_id, json={"accept": accept},
                            headers=_auth("b"))
    assert r.status_code == 204, r.text
    assert hub.sent == [(A, {"t": "room_join_reply", "request_id": request_id, "accept": accept,
                             "room_id": 42, "from_code": "BBBB3333", "from_name": "阿乙"})]
    assert again.status_code == 409, "同一张申请回第二次：已经没了"


def test_requester_cannot_approve_own_request(wired) -> None:
    """申请人自己拿着 request_id 去调 reply，不能给自己「同意」。"""
    hub = wired
    with TestClient(app) as client:
        request_id = client.post("/v1/me/join-requests",
                                 json={"friend_code": "BBBB3333", "room_id": 42},
                                 headers=_auth()).json()["request_id"]
        hub.sent.clear()
        r = client.post("/v1/me/join-requests/%s/reply" % request_id, json={"accept": True},
                        headers=_auth())
    assert r.status_code == 409, r.text
    assert hub.sent == []


def test_cancel_tells_friend_to_close_prompt(wired) -> None:
    hub = wired
    with TestClient(app) as client:
        request_id = client.post("/v1/me/join-requests",
                                 json={"friend_code": "BBBB3333", "room_id": 42},
                                 headers=_auth()).json()["request_id"]
        hub.sent.clear()
        r = client.delete("/v1/me/join-requests", headers=_auth())
        late = client.post("/v1/me/join-requests/%s/reply" % request_id, json={"accept": True},
                           headers=_auth("b"))
        empty = client.delete("/v1/me/join-requests", headers=_auth())
    assert r.status_code == 204
    assert hub.sent == [(B, {"t": "room_join_cancel", "request_id": request_id})]
    assert late.status_code == 409, "撤回之后对方再点同意：已经没了"
    assert empty.status_code == 204, "没有申请在外面时撤回也不报错"


def test_unknown_account_is_not_404(wired, monkeypatch: pytest.MonkeyPatch) -> None:
    """客户端把 404 / 405 当成「旧服务器没有这个接口」并退回直接加入，账号问题不能撞上这个码。"""
    async def _nobody(auth_uid: str):
        return None

    monkeypatch.setattr(players, "get_by_auth_uid", _nobody)
    with TestClient(app) as client:
        r = client.post("/v1/me/join-requests", json={"friend_code": "BBBB3333", "room_id": 42},
                        headers=_auth())
    assert r.status_code not in (404, 405), r.text
