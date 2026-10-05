"""Small pre-match parties. State lives beside the account server's match queue.

Only public identity fields reach a party snapshot. Invitations expire, membership
is checked on every action, and a party is queued as one indivisible group.
"""

from __future__ import annotations

import secrets
import time
import uuid
from dataclasses import dataclass, field

from app import realtime, party_voice
from app.config import get_settings

MAX_MEMBERS = 3
MAX_PETS = 5
INVITE_TTL_SEC = 120.0
CHAT_LIMIT = 30


class PartyRejected(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass
class Room:
    id: str
    host: uuid.UUID
    mode: str
    members: list[uuid.UUID]
    profiles: dict[uuid.UUID, dict]
    pets: list[str] = field(default_factory=list)
    ready: set[uuid.UUID] = field(default_factory=set)
    queued: bool = False
    version: int = 1
    messages: list[dict] = field(default_factory=list)
    voice_epoch: str = field(default_factory=lambda: secrets.token_hex(6))
    voice_used: bool = False


class Parties:
    def __init__(self, *, now=time.monotonic) -> None:
        self._now = now
        self._rooms: dict[str, Room] = {}
        self._member_room: dict[uuid.UUID, str] = {}
        self._invites: dict[tuple[uuid.UUID, str], float] = {}

    def of(self, player: uuid.UUID) -> Room | None:
        room_id = self._member_room.get(player)
        return self._rooms.get(room_id) if room_id else None

    def by_id(self, room_id: str) -> Room | None:
        return self._rooms.get(room_id)

    def create(self, player: uuid.UUID, profile: dict, mode: str, pets: list[str]) -> Room:
        existing = self.of(player)
        if existing is not None:
            return existing
        if mode not in ("casual", "ranked"):
            raise PartyRejected("bad_mode", "没有这个匹配模式")
        room_id = secrets.token_urlsafe(12)
        room = Room(room_id, player, mode, [player], {player: profile}, pets=pets[:MAX_PETS])
        self._rooms[room_id] = room
        self._member_room[player] = room_id
        return room

    def snapshot(self, room: Room) -> dict:
        return {
            "t": "party", "state": "room", "id": room.id, "mode": room.mode,
            "host_code": room.profiles[room.host]["friend_code"],
            "members": [
                {**room.profiles[pid], "ready": pid == room.host or pid in room.ready,
                 "host": pid == room.host}
                for pid in room.members
            ],
            "pets": room.pets.copy(), "queued": room.queued,
            "version": room.version, "messages": room.messages.copy(),
            "voice_epoch": room.voice_epoch,
        }

    def state_of(self, player: uuid.UUID) -> dict:
        room = self.of(player)
        return self.snapshot(room) if room is not None else {"t": "party", "state": "none"}

    async def broadcast(self, room: Room) -> None:
        payload = self.snapshot(room)
        for pid in room.members:
            await realtime.hub().send_to_player(pid, payload)

    async def notify_closed(self, members: list[uuid.UUID]) -> None:
        for pid in members:
            await realtime.hub().send_to_player(pid, {"t": "party", "state": "closed"})

    def invite(self, player: uuid.UUID, target: uuid.UUID) -> Room:
        room = self._require_member(player)
        if room.queued:
            raise PartyRejected("in_queue", "排队时不能邀请好友")
        if len(room.members) >= MAX_MEMBERS:
            raise PartyRejected("full", "队伍已经满员")
        if target in room.members:
            raise PartyRejected("already_member", "好友已经在队伍里")
        existing = self.of(target)
        if existing is not None and (existing.host != target
                                     or len(existing.members) != 1 or existing.queued):
            raise PartyRejected("already_in_party", "好友已经在其他队伍里")
        self._invites[target, room.id] = self._now() + INVITE_TTL_SEC
        return room

    def join(self, player: uuid.UUID, room_id: str, profile: dict) -> Room:
        room = self._rooms.get(room_id)
        if room is None or self._invites.get((player, room_id), 0.0) <= self._now():
            raise PartyRejected("invite_expired", "组队邀请已失效")
        if room.queued or len(room.members) >= MAX_MEMBERS:
            raise PartyRejected("unavailable", "队伍已开始匹配或已经满员")
        existing = self.of(player)
        if existing is not None:
            # Main-menu entry creates a one-person room automatically. Accepting
            # an invitation replaces that empty room without an extra leave tap.
            if existing.host != player or len(existing.members) != 1 or existing.queued:
                raise PartyRejected("already_in_party", "你已在另一支队伍里")
            self._close_voice(existing)
            self._rooms.pop(existing.id, None)
            self._member_room.pop(player, None)
        self._invites.pop((player, room_id), None)
        self._rotate_voice(room)
        room.members.append(player)
        room.profiles[player] = profile
        self._member_room[player] = room_id
        room.ready.clear()
        room.version += 1
        return room

    def leave(self, player: uuid.UUID) -> tuple[Room | None, list[uuid.UUID], bool]:
        room = self.of(player)
        if room is None:
            return None, [], False
        old_members = room.members.copy()
        self._member_room.pop(player, None)
        if player == room.host:
            self._close_voice(room)
            for pid in room.members:
                self._member_room.pop(pid, None)
            self._rooms.pop(room.id, None)
            return room, old_members, True
        room.members.remove(player)
        self._rotate_voice(room)
        room.profiles.pop(player, None)
        room.ready.clear()
        room.version += 1
        return room, old_members, False

    def mode(self, player: uuid.UUID, mode: str) -> Room:
        room = self._require_host(player)
        self._require_editable(room)
        if mode not in ("casual", "ranked"):
            raise PartyRejected("bad_mode", "没有这个匹配模式")
        if room.mode != mode:
            room.mode = mode
            room.ready.clear()
            room.version += 1
        return room

    def pets(self, player: uuid.UUID, pet_ids: list[str]) -> Room:
        room = self._require_host(player)
        self._require_editable(room)
        if len(pet_ids) > MAX_PETS or len(set(pet_ids)) != len(pet_ids):
            raise PartyRejected("bad_pets", "最多展示 5 只不重复的宠物")
        room.pets = pet_ids.copy()
        room.version += 1
        return room

    def set_ready(self, player: uuid.UUID, ready: bool) -> Room:
        room = self._require_member(player)
        self._require_editable(room)
        if player == room.host:
            raise PartyRejected("host_ready", "房主直接按开始匹配")
        if ready:
            room.ready.add(player)
        else:
            room.ready.discard(player)
        room.version += 1
        return room

    def members_for_start(self, player: uuid.UUID) -> tuple[Room, list[uuid.UUID]]:
        room = self._require_host(player)
        self._require_editable(room)
        if any(pid not in room.ready for pid in room.members if pid != room.host):
            raise PartyRejected("not_ready", "请等待队友准备")
        return room, room.members.copy()

    def mark_queued(self, player: uuid.UUID, version: int) -> Room:
        room, _ = self.members_for_start(player)
        if room.version != version:
            raise PartyRejected("changed", "队伍状态已变化，请重试")
        room.queued = True
        room.version += 1
        return room

    def mark_idle(self, room: Room) -> None:
        if room.queued:
            room.queued = False
            room.ready.clear()
            room.version += 1

    def queued_room(self, player: uuid.UUID) -> Room:
        room = self._require_host(player)
        if not room.queued:
            raise PartyRejected("not_queued", "队伍当前没有排队")
        return room

    def finish_for_match(self, players: list[uuid.UUID]) -> None:
        """Close matched pre-match rooms after the six-player accept stage begins."""
        room_ids = {self._member_room[pid] for pid in players if pid in self._member_room}
        for room_id in room_ids:
            room = self._rooms.pop(room_id, None)
            if room is not None:
                self._close_voice(room)
                for pid in room.members:
                    self._member_room.pop(pid, None)

    def _close_voice(self, room: Room) -> None:
        if room.voice_used:
            party_voice.schedule_delete(get_settings().party_voice_config_file,
                                        room.id, room.voice_epoch)
            room.voice_used = False

    def _rotate_voice(self, room: Room) -> None:
        self._close_voice(room)
        room.voice_epoch = secrets.token_hex(6)

    def say(self, player: uuid.UUID, text: str) -> Room:
        room = self._require_member(player)
        room.messages.append({
            "code": room.profiles[player]["friend_code"],
            "name": room.profiles[player]["player_name"],
            "text": text, "at": int(time.time()),
        })
        del room.messages[:-CHAT_LIMIT]
        room.version += 1
        return room

    def _require_member(self, player: uuid.UUID) -> Room:
        room = self.of(player)
        if room is None:
            raise PartyRejected("not_in_party", "你还没有进入队伍")
        return room

    def _require_host(self, player: uuid.UUID) -> Room:
        room = self._require_member(player)
        if room.host != player:
            raise PartyRejected("not_host", "只有房主可以操作")
        return room

    @staticmethod
    def _require_editable(room: Room) -> None:
        if room.queued:
            raise PartyRejected("in_queue", "请先取消匹配")


_instance: Parties | None = None


def current() -> Parties:
    global _instance
    if _instance is None:
        _instance = Parties()
    return _instance


def install(instance: Parties) -> Parties:
    global _instance
    _instance = instance
    return instance
