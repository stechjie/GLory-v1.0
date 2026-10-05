"""LiveKit tokens for the authenticated pre-match party only.

The token grants access to one random party room and microphone audio only.
Membership changes rotate the room and delete the old room, including on
self-hosted LiveKit where RemoveParticipant may not revoke an old token.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import time
from functools import lru_cache
from pathlib import Path

log = logging.getLogger("glory.party_voice")


class VoiceUnavailable(RuntimeError):
    pass


@lru_cache
def load_config(path: str) -> dict:
    if not path:
        raise VoiceUnavailable("队伍语音尚未配置")
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise VoiceUnavailable("队伍语音配置无法读取") from exc
    if not isinstance(data, dict):
        raise VoiceUnavailable("队伍语音配置格式无效")
    client_url = str(data.get("client_url", ""))
    admin_url = str(data.get("admin_url", ""))
    key = str(data.get("api_key", ""))
    secret = str(data.get("api_secret", ""))
    if not client_url.startswith(("wss://", "ws://")) or not admin_url.startswith(("http://", "https://")) \
            or not key or len(secret) < 32:
        raise VoiceUnavailable("队伍语音配置不完整")
    return {"client_url": client_url, "admin_url": admin_url.rstrip("/"),
            "api_key": key, "api_secret": secret}


def _segment(data: dict) -> str:
    raw = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def sign(config: dict, claims: dict) -> str:
    body = f'{_segment({"alg": "HS256", "typ": "JWT"})}.{_segment(claims)}'
    digest = hmac.new(config["api_secret"].encode(), body.encode(), hashlib.sha256).digest()
    return body + "." + base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def room_name(room_id: str, epoch: str) -> str:
    return f"party-{room_id}-{epoch}"


def issue(config: dict, room_id: str, epoch: str, code: str, name: str,
          now: int | None = None) -> dict:
    stamp = int(time.time()) if now is None else now
    room = room_name(room_id, epoch)
    claims = {
        "iss": config["api_key"], "sub": code, "name": name,
        "nbf": stamp, "exp": stamp + 600,
        "video": {"roomJoin": True, "room": room, "canSubscribe": True,
                  "canPublish": True, "canPublishSources": ["microphone"],
                  "canPublishData": False},
    }
    return {"url": config["client_url"], "room": room,
            "token": sign(config, claims)}


async def delete_room(config_path: str, room_id: str, epoch: str) -> None:
    try:
        config = load_config(config_path)
    except VoiceUnavailable:
        return
    stamp = int(time.time())
    token = sign(config, {"iss": config["api_key"], "nbf": stamp,
                          "exp": stamp + 60, "video": {"roomCreate": True}})
    try:
        import httpx
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.post(
                config["admin_url"] + "/twirp/livekit.RoomService/DeleteRoom",
                headers={"Authorization": "Bearer " + token},
                json={"room": room_name(room_id, epoch)})
        if response.status_code not in (200, 404):
            log.warning("party voice room deletion failed: http=%d", response.status_code)
    except Exception:  # noqa: BLE001 - voice failure cannot block party or match
        log.exception("party voice room deletion failed")


def schedule_delete(config_path: str, room_id: str, epoch: str) -> None:
    if config_path:
        asyncio.create_task(delete_room(config_path, room_id, epoch))
