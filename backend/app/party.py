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
# 成员 WS 断开后，房间身份保留多久（单调时钟秒）。
#
# 为什么要有宽限：手机切后台 / 信号抖动 / 换设备重连都会先断一次 WS，那是常态
# 不是退房。立刻把人从 room.members 里摘掉，别人的房间界面会瞬间少一个人；
# 而这人重连回来又得重新被邀请一遍（邀请还要重发）。
#
# 但不能只有宽限、没有回收：**不摘就会留 ghost** —— 别人界面上他还坐在房里，
# 他自己那边其实早就回主菜单了（10.08 反馈第 8 条「tin y」就是这个）。
# 到期回收由 matchmaking 的后台 tick 调 prune_disconnected()，见那个函数的注释。
LEFT_GRACE_SEC = 60.0


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
    # 每个成员在当前队伍里的入座时刻（单调时钟）。房主退出时按它挑「待得最久」的人接班。
    joined_at: dict[uuid.UUID, float] = field(default_factory=dict)
    # 成员 -> 座位 0~2（10-08，对齐自定义房间的换位）。**会带进对局**：满 3 人的队伍进了对局，
    # 坐的就是这里选的位置（A/B/C = 不同的路），见 matchmaking._allocate_seats。
    seats: dict[uuid.UUID, int] = field(default_factory=dict)
    # 断线时刻（单调时钟）。> 0 = 这条 WS 已经断了、正在宽限期内。
    # 重连（任何一次成功动作）会清零；宽限到期仍为 > 0 就真的摘掉（见 on_disconnect）。
    dropped_at: dict[uuid.UUID, float] = field(default_factory=dict)


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
        room.joined_at[player] = self._now()
        room.seats[player] = 0
        self._rooms[room_id] = room
        self._member_room[player] = room_id
        return room

    def snapshot(self, room: Room) -> dict:
        return {
            "t": "party", "state": "room", "id": room.id, "mode": room.mode,
            "host_code": room.profiles[room.host]["friend_code"],
            "members": [
                {**room.profiles[pid], "ready": pid == room.host or pid in room.ready,
                 "host": pid == room.host, "seat": self.seat_of(room, pid)}
                for pid in room.members
            ],
            "pets": room.pets.copy(), "queued": room.queued,
            "version": room.version, "messages": room.messages.copy(),
            "voice_epoch": room.voice_epoch,
        }

    @staticmethod
    def seat_of(room: Room, player: uuid.UUID) -> int:
        seat = room.seats.get(player)
        if seat is None:
            # 不该发生（每条入队路径都排了座位）；万一有，按入队顺序给一个，不让快照缺字段。
            seat = room.members.index(player) if player in room.members else 0
        return seat

    @staticmethod
    def _free_seat(room: Room) -> int:
        taken = set(room.seats.values())
        return next((seat for seat in range(MAX_MEMBERS) if seat not in taken), 0)

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
        # 重新进入房间 = 重新计时，退房时按这个时间挑新队长。
        room.joined_at[player] = self._now()
        room.seats[player] = self._free_seat(room)
        room.dropped_at.pop(player, None)
        self._member_room[player] = room_id
        room.ready.clear()
        room.version += 1
        return room

    def leave(self, player: uuid.UUID) -> tuple[Room | None, list[uuid.UUID], bool, bool]:
        """退出队伍。返回 (房间, 原成员, 是否解散, 是否换了房主)。"""
        room = self.of(player)
        if room is None:
            return None, [], False, False
        old_members = room.members.copy()
        self._member_room.pop(player, None)
        if player == room.host:
            # 房主退出：房里还有别人就交接给「待得最久」的那位，只剩自己才解散。
            remaining = [pid for pid in room.members if pid != player]
            if not remaining:
                self._close_voice(room)
                self._member_room.pop(player, None)
                self._rooms.pop(room.id, None)
                return room, old_members, True, False
            successor = min(remaining, key=lambda pid: room.joined_at.get(pid, 0.0))
            room.host = successor
            room.members.remove(player)
            room.profiles.pop(player, None)
            room.joined_at.pop(player, None)
            room.seats.pop(player, None)
            room.ready.clear()
            room.version += 1
            return room, old_members, False, True
        room.members.remove(player)
        self._rotate_voice(room)
        room.profiles.pop(player, None)
        room.joined_at.pop(player, None)
        room.seats.pop(player, None)
        room.ready.clear()
        room.version += 1
        return room, old_members, False, False

    def kick(self, host: uuid.UUID, target: uuid.UUID) -> Room:
        """房主把一个成员移出队伍（10-08，对齐自定义房间的「×」）。排队中不能踢，要先取消匹配。"""
        room = self._require_host(host)
        self._require_editable(room)
        if target == host:
            raise PartyRejected("bad_target", "不能把自己移出队伍")
        if target not in room.members:
            raise PartyRejected("not_member", "这位玩家已经不在队伍里")
        self._member_room.pop(target, None)
        room.members.remove(target)
        room.profiles.pop(target, None)
        room.joined_at.pop(target, None)
        room.seats.pop(target, None)
        # 换语音房间：被踢的人手上那把钥匙进的是旧房间（自建 LiveKit 踢人不一定作废钥匙）。
        self._rotate_voice(room)
        room.ready.clear()
        room.version += 1
        return room

    def move_seat(self, player: uuid.UUID, seat: int) -> Room:
        """换到一个空位（10-08，同自定义房间点空位换座）。谁都能换自己；排队中不能换。

        不清准备状态：自定义房间换座也保留准备（NetworkService._room_do_move）。
        """
        room = self._require_member(player)
        self._require_editable(room)
        if not 0 <= seat < MAX_MEMBERS:
            raise PartyRejected("bad_seat", "没有这个位置")
        if any(pid != player and taken == seat for pid, taken in room.seats.items()):
            raise PartyRejected("seat_taken", "这个位置已经有人了")
        if room.seats.get(player) != seat:
            room.seats[player] = seat
            room.version += 1
        return room

    # --- 断线 / 在场（10.08 反馈第 8 条）----------------------------------------
    #
    # 「房间里有他、他自己却进不去」= ghost 成员。成因：WS 断开后没人通知 party，
    # room.members 里他的那一条永久留着（snapshot 直接遍历 members，谁在表里
    # 谁就显示在房间里）。修法两半，缺一不可：
    #   ① on_disconnect 记下断线时刻（不立刻摘，手机切后台是常态）；
    #   ② 后台 tick 调 prune_disconnected，宽限到期才真摘。
    def on_disconnect(self, player: uuid.UUID) -> None:
        """WS 断了。**不立刻退房** —— 先记断线时刻，进 LEFT_GRACE_SEC 宽限。

        宽限期里他仍是成员（别人看得见他、他重连回来还在原位）。到期没人回来，
        prune_disconnected 会把他摘掉，并像正常退房那样交接 / 解散。
        """
        room = self.of(player)
        if room is None:
            return
        if room.dropped_at.get(player, 0.0) <= 0.0:
            room.dropped_at[player] = self._now()

    def mark_present(self, player: uuid.UUID) -> bool:
        """这个人又活过来了（重连、或任何一次成功的房间动作）。返回是否清了标记。

        调用点分散在各路由里很容易漏 —— 所以除了显式调用，join / say / set_ready
        这些「只有活人才做得到」的动作也会顺手清（见 _touch_present）。
        """
        room = self.of(player)
        if room is None:
            return False
        if room.dropped_at.pop(player, 0.0) > 0.0:
            room.version += 1
            return True
        return False

    def prune_disconnected(self) -> list[Room]:
        """宽限到期的断线成员：按正常退房处理（交接房主 / 解散空房）。

        由 matchmaking 的后台 tick 每 TICK_SEC 调一次 —— party 自己没有循环，
        而 matchmaking 已经在同一个进程里跑循环、也已经 import 了 party
        （见 matchmaking._expire_stale 里对 party.current() 的调用）。
        返回**受了影响、需要重新广播**的房间。
        """
        now = self._now()
        touched: dict[str, Room] = {}
        for room in list(self._rooms.values()):
            stale = [pid for pid in room.members
                     if 0.0 < room.dropped_at.get(pid, 0.0) <= now - LEFT_GRACE_SEC]
            for pid in stale:
                _room, _members, _dissolved, _rotated = self.leave(pid)
                if _room is not None:
                    touched[_room.id] = _room
        # 已经解散的房间不该再广播（leave 返回的就是被 pop 掉的那个对象）。
        return [r for rid, r in touched.items() if self._rooms.get(rid) is r]

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
        # 取消匹配对全队生效，所以队里任何人（不只房主）都能按。
        room = self._require_member(player)
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
        # 能走到这里说明他刚刚做了一次**只有活人才做得到**的动作（邀请、改模式、
        # 准备、说话…）—— 顺手把断线标记清掉，不用指望每个路由都记得调 mark_present。
        self._touch_present(room, player)
        return room

    def _touch_present(self, room: Room, player: uuid.UUID) -> None:
        if room.dropped_at.pop(player, 0.0) > 0.0:
            room.version += 1

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
