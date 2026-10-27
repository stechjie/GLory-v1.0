"""Voided-draw XP defense, real signed-report validation and progression writes."""
import base64
import json
import time
import uuid

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from app import battle_report, progression, ranked
from app.config import get_settings
from test_ranked import _FakeConn

PID = uuid.UUID(int=1)


@pytest.fixture
def anyio_backend():
    return "asyncio"


class ProgressConn(_FakeConn):
    def __init__(self):
        super().__init__({PID}, {PID: 0})
        self.xp, self.level = 0, 1

    async def fetchrow(self, sql, *args):
        if "player_progression" in sql:
            return {"xp": self.xp, "level": self.level}
        return await super().fetchrow(sql, *args)

    async def execute(self, sql, *args):
        if "update player_progression" in sql:
            self.xp, self.level = args[1], args[2]
        return await super().execute(sql, *args)


def report(reason="no_live_human", outcome="draw", online=True, mode="ranked", rounds=1):
    return {"match_uid": "a" * 32, "mode": mode, "outcome": outcome,
            "rounds": rounds, "end_reason": reason,
            "seats": [{"slot": 0, "team": 0, "player_id": PID,
                       "online_at_end": online, "was_ai": False}]}


@pytest.mark.anyio
@pytest.mark.parametrize("mode", ["ranked", "casual"])
@pytest.mark.parametrize("rounds", [1, 13, 14, 21])
@pytest.mark.parametrize("online", [False, True])
async def test_void_draw_has_no_xp_even_with_stale_online_flag(mode, rounds, online):
    conn = ProgressConn()
    await ranked.settle(conn, report(mode=mode, rounds=rounds, online=online))
    assert (conn.xp, conn.level) == (0, 1)


@pytest.mark.anyio
@pytest.mark.parametrize("outcome,expected", [("draw", 80), ("team_a", 110), ("team_b", 80)])
async def test_normally_completed_short_ranked_still_awards_xp(outcome, expected):
    conn = ProgressConn()
    await ranked.settle(conn, report(reason="", outcome=outcome, rounds=13))
    assert conn.xp == expected and conn.level == progression.level_for_xp(expected)


@pytest.mark.anyio
async def test_last_online_human_win_is_not_treated_as_void_draw():
    conn = ProgressConn()
    await ranked.settle(conn, report(reason="last_human_online", outcome="team_a"))
    assert conn.xp == 110


@pytest.mark.anyio
async def test_repeated_distinct_void_matches_cannot_level_up():
    conn = ProgressConn()
    for i in range(12):
        current = report()
        current["match_uid"] = f"{i:032x}"
        await ranked.settle(conn, current)
    assert (conn.xp, conn.level) == (0, 1)


def test_end_reason_is_signed_verified_and_retained_for_history(tmp_path, monkeypatch):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public = tmp_path / "report_public.pem"
    public.write_bytes(key.public_key().public_bytes(serialization.Encoding.PEM,
                                                   serialization.PublicFormat.SubjectPublicKeyInfo))
    monkeypatch.setenv("GLORY_BATTLE_REPORT_PUBLIC_KEY_FILE", str(public))
    get_settings.cache_clear()
    now = int(time.time())
    payload = {"v": 1, "mid": "a" * 32, "mode": "ranked", "out": "draw",
               "proto": 44, "epoch": 1, "room": 123456, "rounds": 1,
               "start": now - 5, "end": now, "hp": [50, 50], "stats": [],
               "end_reason": "no_live_human",
               "seats": [{"slot": i, "team": 0 if i < 3 else 1,
                          "pid": str(PID) if i == 0 else "", "online": i == 0,
                          "ai_rounds": 0, "gold": 0, "carrots": 0, "spent": 0,
                          "board": [], "treasures": []}
                         for i in range(6)]}
    body = json.dumps(payload).encode()
    signature = key.sign(body, padding.PKCS1v15(), hashes.SHA256())
    encoded_signature = base64.b64encode(signature).decode()
    wire = base64.b64encode(body).decode() + "." + encoded_signature
    try:
        clean = battle_report.verify(wire)
        assert clean["end_reason"] == "no_live_human"
        assert clean["settlement"]["end_reason"] == "no_live_human"
        tampered = body.replace(b"no_live_human", b"normal_finish")
        with pytest.raises(battle_report.ReportRejected) as error:
            battle_report.verify(base64.b64encode(tampered).decode() + "." + encoded_signature)
        assert error.value.code == "report_bad_signature"
    finally:
        get_settings.cache_clear()
