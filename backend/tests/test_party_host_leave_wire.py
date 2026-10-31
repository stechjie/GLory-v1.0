"""Exercise host departure with the real JSON WebSocket boundary."""
import json
import uuid
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from app import party, realtime
from app.routes import party as route


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.mark.anyio
async def test_host_departure_sends_json_notice_and_updated_party(monkeypatch):
    host, guest = uuid.uuid4(), uuid.uuid4()
    store = party.Parties()
    room = store.create(host, {"player_name": "Host", "friend_code": "HOST0001"}, "ranked", [])
    store.invite(host, guest)
    store.join(guest, room.id, {"player_name": "Guest", "friend_code": "GUEST001"})
    sent = []

    class WireHub:
        async def send_to_player(self, pid, payload):
            sent.append((pid, json.loads(json.dumps(payload))))
            return 1

    monkeypatch.setattr(route, "_me", AsyncMock(return_value=SimpleNamespace(player_id=host)))
    monkeypatch.setattr(party, "current", lambda: store)
    monkeypatch.setattr(realtime, "hub", lambda: WireHub())
    response = await route.leave(None)
    assert response.state["state"] == "none"
    assert store.of(guest).host == guest
    notices = [payload for pid, payload in sent if pid == guest and payload.get("kind") == "host_left"]
    assert len(notices) == 1
    assert notices[0]["members"] == [str(host), str(guest)]
    assert any(pid == guest and payload.get("t") == "party" for pid, payload in sent)
