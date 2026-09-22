"""匹配队列（`docs/排位系统设计.md` 第五、六节）。第 4a 步：只有账号服务器这一半。

    排队 → 凑齐 6 个人 → 六个人都点「确认」→ 每人领一张**带对局分配的出战名片**
    → 各自连战斗服务器，凭名片上的 match 认亲进同一个房间

## 🔴 没有「入场券」这个新东西 —— 分配写在出战名片里

第一版设计里它叫「排位入场券」。落地时发现那是在发明第四种做法：

    账号服务器不知道战斗服务器的房间号（房间是客户端连上去才建的），
    所以「匹配好了去几号房」这句话根本说不出口。

真正需要的是一个**会合键**：六个人各自连上去，谁先到谁建房，后到的认同一个键
进同一间。而「账号服务器盖章、入座前交给战斗服务器」这条路已经有了 ——
就是出战名片。于是分配就是名片上多三个字段（match / team / 过期），
不新开钥匙、不新开线格式、不新开验证路径。

`BattleCard.gd` 顶上那句「以后加皮肤、加要解锁的种族：往名片里加一个字段，
**不再发明新做法**」，说的就是这件事。

## 🔴 状态在进程内存里

与 `realtime.Hub` / `app/admission.py` 同一个前提：单进程单实例
（`app/single_instance.py`）。**重启 = 队列清空、待确认的对局作废。**

代价是可接受的：排队的人重连后重新排（他只损失排队时间），
已经拿到名片的人不受影响（名片在他手里，战斗服务器认的是签名不是这张表）。
**高峰期别部署** —— 同 admission 那条。

## 为什么确认框是必须的

匹配到的六个人里只要有一个已经挂机了，另外五个要陪着 AI 打完 21 回合
（一局 20~30 分钟）。确认框把「人还在不在」这件事**前置到开局之前**，
代价是所有人多等最多 ACCEPT_TIMEOUT_SEC 秒。

不确认的那个人被移出队列；**另外五个不受罚，并且回到队列最前面** ——
他们已经等过一轮了，再排到队尾是第二次惩罚。

## 这一步只做单排

`docs/排位系统设计.md` 第五节定的是「单排或满 3 人车队」。车队没做，
因为它要先有一套组队邀请/接受的流程（好友系统有了，组队没有），
而匹配器这边支持车队却没人组得起队，是写了一半的功能。

数据结构上没有堵死：`_Waiter.party` 留着，`_take_group` 按「一份一份地取」
而不是「一个一个地取」写。做车队时改的是那两处，不是重写。
"""

from __future__ import annotations

import asyncio
import logging
import secrets
import time
import uuid
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from app import ranked

log = logging.getLogger("glory.matchmaking")

# 一局六个人（NetworkService.TEAM_SLOTS）。3v3，slot < 3 是 A 队。
MATCH_SIZE = 6
TEAM_SIDE_SIZE = 3

# 能排队的模式。第 5 步（分数 / 段位 / 信誉分）做完之后 ranked 也开了。
#
# ⚠️ 排位**还要过时间窗口**（19:00–23:00，`ranked.window_state`）和信誉分闸
# （`ranked.queue_gate`）。「在 OPEN_MODES 里」只是「这个模式存在」，不是「随时能排」。
CASUAL = "casual"
RANKED = "ranked"
OPEN_MODES = frozenset({CASUAL, RANKED})
KNOWN_MODES = frozenset({CASUAL, RANKED})

# 确认框的时限。
#
# 英雄联盟那个框是 12 秒左右，但那是一局 30 分钟、随时能再排的游戏。
# 这里一局 20~30 分钟、而排位窗口只有 4 小时，凑齐一次六个人不容易 ——
# 给到 30 秒，宁可多等一会儿也别因为「刚好在切后台」就把一整桌拆掉。
ACCEPT_TIMEOUT_SEC = 30.0

# 名片领取的宽限。六个人都确认之后，这段时间内 /v1/battle/card 会带上对局分配。
#
# 必须**明显大于**名片自己的有效期（CARD_TTL_SEC = 60）：玩家点完确认还要过
# 加载界面、连战斗服务器、DTLS 握手。这里给 5 分钟 —— 到点还没连上的那个人，
# 战斗服务器那边的座位保留机制会接手，不归这里管。
ASSIGNMENT_TTL_SEC = 300.0

# 匹配循环的周期。排队是秒级体验，不需要更密。
TICK_SEC = 1.0

# 位次推送的节流。位次每秒都在变，但玩家看的是「大概还要多久」——
# 每秒推一次只是在烧电池。
POSITION_PUSH_SEC = 3.0

# 掉线宽限：排队中的人断开 WS 后，位次保留这么久。
# 手机切后台时引擎不跑帧，realtime 要 IDLE_TIMEOUT_SEC(95) 才判断开 ——
# 这里再给 60 秒，合起来够一次正常的切后台往返。
QUEUE_GRACE_SEC = 60.0

# 消息类型。客户端按 t 分发（scripts/autoload/RealtimeService.gd `_handle`）。
MESSAGE_TYPE = "match"

Send = Callable[[uuid.UUID, dict], Awaitable[int]]


# --- 对外的消息 ---------------------------------------------------------------


def queued_message(position: int, mode: str) -> dict:
    return {"t": MESSAGE_TYPE, "state": "queued", "position": int(position), "mode": mode}


def idle_message(reason: str = "") -> dict:
    out = {"t": MESSAGE_TYPE, "state": "idle"}
    if reason:
        out["reason"] = reason
    return out


def found_message(match_uid: str, mode: str, accept_sec: float) -> dict:
    """凑齐了，等确认。**这条不带名片** —— 名片等六个人都确认完才发得出去。"""
    return {
        "t": MESSAGE_TYPE, "state": "found", "match_uid": match_uid,
        "mode": mode, "accept_sec": int(accept_sec),
    }


def ready_message(match_uid: str, mode: str, team: int) -> dict:
    """六个人都确认了。客户端据此去 /v1/battle/card 领带分配的名片，然后连战斗服务器。

    🔴 **这里不发名片本身。** 名片有效期只有 60 秒，而玩家从点确认到真的连上去
    还要过加载界面。让客户端自己在要连的那一刻去领，有效期才是从那一刻算起。
    """
    return {
        "t": MESSAGE_TYPE, "state": "ready", "match_uid": match_uid,
        "mode": mode, "team": int(team),
    }


# --- 内部状态 -----------------------------------------------------------------


@dataclass
class _Waiter:
    mode: str
    joined_at: float
    # 断开 WS 的时刻；0 = 还连着。
    dropped_at: float = 0.0
    sent_position: int = 0
    # 车队成员（含自己）。这一步只有单排，所以永远是一个人 —— 留着是为了
    # 做车队时 _take_group 不用重写，见文件头最后一节。
    party: list[uuid.UUID] = field(default_factory=list)
    # 匹配分。casual 不用（全是 0），ranked 接第 5 步的分数。
    rating: int = 0


@dataclass
class _Member:
    player_id: uuid.UUID
    team: int
    accepted: bool = False


@dataclass
class _Pending:
    """已经凑齐、等六个人确认的一桌。"""

    match_uid: str
    mode: str
    members: list[_Member]
    deadline: float

    def member(self, player_id: uuid.UUID) -> _Member | None:
        for m in self.members:
            if m.player_id == player_id:
                return m
        return None


@dataclass
class Assignment:
    """确认完成之后留给 /v1/battle/card 取的对局分配。"""

    match_uid: str
    mode: str
    team: int
    expires_at: float


class Matchmaker:
    """队列 + 待确认表 + 分配表。进程内单例，见 `install()` / `current()`。

    join / leave / accept 都是同步的、中间没有 await —— 在同一个事件循环里
    它们天然是原子的，不需要锁（同 `admission.Admission` 那条）。
    只有 tick 里的发送会让出执行权，而发送前状态已经改完了。
    """

    def __init__(self, send: Send, *, now: Callable[[], float] = time.monotonic) -> None:
        self._send = send
        self._now = now
        # mode -> (player_id -> _Waiter)。按模式分队列：两个模式的人不能互相匹配。
        self._queues: dict[str, OrderedDict[uuid.UUID, _Waiter]] = {
            mode: OrderedDict() for mode in KNOWN_MODES
        }
        # player_id -> match_uid
        self._pending_of: dict[uuid.UUID, str] = {}
        self._pending: dict[str, _Pending] = {}
        self._assignments: dict[uuid.UUID, Assignment] = {}
        self._next_position_push = now()
        # 没按准备的人，等下一轮 tick 去扣信誉分。
        #
        # 为什么要攒着：join / leave / on_disconnect 都是**同步**的（同一个事件循环里
        # 天然原子，见类文档），而扣分要碰数据库。在同步函数里 await 会把那条不变量
        # 毁掉 —— 中间让出执行权，另一个请求就能看到半改完的队列。
        self._pending_penalties: list[uuid.UUID] = []

    # --- 排队 -----------------------------------------------------------------

    def join(self, player_id: uuid.UUID, mode: str) -> dict:
        """进队列。已经在待确认里的人**不许重排** —— 那会把自己从那一桌里摘掉。"""
        if player_id in self._pending_of:
            pending = self._pending[self._pending_of[player_id]]
            return found_message(pending.match_uid, pending.mode,
                                 max(0.0, pending.deadline - self._now()))
        # 已经拿到分配、还没去连战斗服务器：不许重排，否则会同时出现在两局里。
        if self.assignment_for(player_id) is not None:
            assignment = self._assignments[player_id]
            return ready_message(assignment.match_uid, assignment.mode, assignment.team)

        # 换模式 = 先退出原来那条队。
        for other in KNOWN_MODES:
            if other != mode:
                self._queues[other].pop(player_id, None)

        queue = self._queues[mode]
        waiter = queue.get(player_id)
        if waiter is not None:
            # 已经在队里：认回来（断线重连走的就是这条），**不挪位次**。
            waiter.dropped_at = 0.0
            return queued_message(self.position_of(player_id, mode), mode)

        queue[player_id] = _Waiter(mode=mode, joined_at=self._now(), party=[player_id])
        position = len(queue)
        queue[player_id].sent_position = position
        return queued_message(position, mode)

    def leave(self, player_id: uuid.UUID) -> dict:
        """主动退出。待确认阶段退出 = 拒绝，那一桌当场解散（见 _dissolve）。"""
        for queue in self._queues.values():
            queue.pop(player_id, None)
        match_uid = self._pending_of.get(player_id)
        if match_uid is not None:
            self._dissolve(self._pending[match_uid], declined_by=player_id)
        return idle_message()

    def on_disconnect(self, player_id: uuid.UUID) -> None:
        """WS 断了。**不立刻踢出队列** —— 手机切后台是常态不是异常。

        位次保留 QUEUE_GRACE_SEC，期间轮到他就先跳过（_take_group 只取还连着的）。
        待确认阶段断线则当场解散：让另外五个人早点回队列，比干等 30 秒强。
        """
        now = self._now()
        for queue in self._queues.values():
            waiter = queue.get(player_id)
            if waiter is not None and waiter.dropped_at <= 0.0:
                waiter.dropped_at = now
        match_uid = self._pending_of.get(player_id)
        if match_uid is not None:
            self._dissolve(self._pending[match_uid], declined_by=player_id)

    def position_of(self, player_id: uuid.UUID, mode: str) -> int:
        for index, pid in enumerate(self._queues[mode]):
            if pid == player_id:
                return index + 1
        return 0

    def queue_size(self, mode: str) -> int:
        return len(self._queues[mode])

    # --- 确认 -----------------------------------------------------------------

    def accept(self, player_id: uuid.UUID) -> dict:
        match_uid = self._pending_of.get(player_id)
        if match_uid is None:
            # 已经确认完、拿到分配了：把 ready 再说一遍（客户端重连后会重问）。
            assignment = self.assignment_for(player_id)
            if assignment is not None:
                return ready_message(assignment.match_uid, assignment.mode, assignment.team)
            return idle_message("no_pending_match")
        pending = self._pending[match_uid]
        member = pending.member(player_id)
        if member is None:
            return idle_message("no_pending_match")
        member.accepted = True
        if all(m.accepted for m in pending.members):
            self._finalise(pending)
            return ready_message(pending.match_uid, pending.mode, member.team)
        return found_message(pending.match_uid, pending.mode,
                             max(0.0, pending.deadline - self._now()))

    def state_of(self, player_id: uuid.UUID) -> dict:
        """当前状态。给 WS 断着的客户端轮询用 —— 推送不是唯一的送达路径。"""
        match_uid = self._pending_of.get(player_id)
        if match_uid is not None:
            pending = self._pending[match_uid]
            return found_message(pending.match_uid, pending.mode,
                                 max(0.0, pending.deadline - self._now()))
        assignment = self.assignment_for(player_id)
        if assignment is not None:
            return ready_message(assignment.match_uid, assignment.mode, assignment.team)
        for mode in KNOWN_MODES:
            if player_id in self._queues[mode]:
                return queued_message(self.position_of(player_id, mode), mode)
        return idle_message()

    # --- 分配（给 /v1/battle/card 取）---------------------------------------------

    def assignment_for(self, player_id: uuid.UUID) -> Assignment | None:
        """这个人有没有一份还没过期的对局分配。过期的顺手清掉。"""
        assignment = self._assignments.get(player_id)
        if assignment is None:
            return None
        if assignment.expires_at <= self._now():
            self._assignments.pop(player_id, None)
            return None
        return assignment

    def clear_assignment(self, player_id: uuid.UUID) -> None:
        self._assignments.pop(player_id, None)

    # --- 匹配循环 ---------------------------------------------------------------

    async def tick(self) -> None:
        now = self._now()
        messages: list[tuple[uuid.UUID, dict]] = []
        self._expire_stale(now, messages)
        for mode in OPEN_MODES:
            # 排位**只在窗口内凑新的一桌**（19:00–23:00，docs/排位系统设计.md 第二节）。
            # 已经开打的局不受影响 —— 00:00 关的是队列，不是对局。
            if mode == RANKED and not ranked.window_state()["accepting"]:
                continue
            while True:
                group = self._take_group(mode, now)
                if group is None:
                    break
                messages.extend(self._form(group, mode, now))
        messages.extend(self._position_updates(now))
        # 扣分放在发消息之前：被罚的那个人应该先收到 idle，再去查自己为什么被禁。
        if self._pending_penalties:
            pending = self._pending_penalties
            self._pending_penalties = []
            try:
                await ranked.punish_no_accept(pending)
            except Exception:  # noqa: BLE001 - 扣分失败不该让整轮 tick 挂掉
                log.exception("没按准备的扣分写不进去，这一批放过了")
        if messages:
            # 逐条发、互不影响：一条连接卡住不该拖住其他人的消息。
            await asyncio.gather(*(self._send_one(pid, payload) for pid, payload in messages))

    async def _send_one(self, player_id: uuid.UUID, payload: dict) -> int:
        try:
            return await self._send(player_id, payload)
        except Exception:  # noqa: BLE001 - 一条发不出去不该让整轮 tick 挂掉
            log.warning("匹配消息发不出去 player=%s", player_id, exc_info=True)
            return 0

    def _take_group(self, mode: str, now: float) -> list[uuid.UUID] | None:
        """按先来后到取一桌。**只取还连着的人。**

        断线宽限内的人留在队列里、占着位次，但不会被凑进一桌 ——
        把一个已经切后台的人凑进来，结果一定是确认超时、整桌解散，
        白白让另外五个人等 30 秒。
        """
        queue = self._queues[mode]
        picked: list[uuid.UUID] = []
        for pid, waiter in queue.items():
            if waiter.dropped_at > 0.0:
                continue
            # 一份一份地取：现在每份就是一个人，做车队时这里取的是整个 party。
            picked.extend(waiter.party or [pid])
            if len(picked) >= MATCH_SIZE:
                break
        if len(picked) < MATCH_SIZE:
            return None
        for pid in picked:
            queue.pop(pid, None)
        return picked[:MATCH_SIZE]

    def _form(self, players: list[uuid.UUID], mode: str, now: float) -> list[tuple[uuid.UUID, dict]]:
        match_uid = new_match_uid()
        members = [
            _Member(player_id=pid, team=team)
            for pid, team in zip(players, assign_teams(players, {}), strict=True)
        ]
        pending = _Pending(match_uid=match_uid, mode=mode, members=members,
                           deadline=now + ACCEPT_TIMEOUT_SEC)
        self._pending[match_uid] = pending
        for member in members:
            self._pending_of[member.player_id] = match_uid
        log.info("匹配成功 match=%s mode=%s players=%d", match_uid, mode, len(members))
        return [(m.player_id, found_message(match_uid, mode, ACCEPT_TIMEOUT_SEC))
                for m in members]

    def _expire_stale(self, now: float, messages: list[tuple[uuid.UUID, dict]]) -> None:
        # 确认超时的一桌。
        for pending in list(self._pending.values()):
            if pending.deadline > now:
                continue
            late = [m.player_id for m in pending.members if not m.accepted]
            messages.extend(self._dissolve(pending, timed_out=late))
        # 断线宽限到期的排队者。
        for mode, queue in self._queues.items():
            for pid in list(queue):
                waiter = queue[pid]
                if 0.0 < waiter.dropped_at <= now - QUEUE_GRACE_SEC:
                    queue.pop(pid, None)
                    log.info("排队者掉线超时移出队列 player=%s mode=%s", pid, mode)
        # 过期的分配（人一直没去连战斗服务器）。
        for pid, assignment in list(self._assignments.items()):
            if assignment.expires_at <= now:
                self._assignments.pop(pid, None)

    def _dissolve(self, pending: _Pending, *, declined_by: uuid.UUID | None = None,
                  timed_out: list[uuid.UUID] | None = None) -> list[tuple[uuid.UUID, dict]]:
        """拆一桌。

        🔴 **没拒绝的那几个回队列最前面，而且不受任何惩罚。**
        他们已经等过一轮了，再排到队尾就是拿别人的锅罚他们。
        """
        self._pending.pop(pending.match_uid, None)
        bad = set(timed_out or [])
        if declined_by is not None:
            bad.add(declined_by)
        out: list[tuple[uuid.UUID, dict]] = []
        queue = self._queues[pending.mode]
        for member in pending.members:
            self._pending_of.pop(member.player_id, None)
            if member.player_id in bad:
                # 🔴 只罚没确认的那几个。另外五个一个字都不动 ——
                # 他们已经等过排队、等过确认框了（第四节）。
                self._pending_penalties.append(member.player_id)
                out.append((member.player_id, idle_message("declined")))
                continue
            # 插到队首：OrderedDict 没有「插到开头」，所以先加再 move_to_end(last=False)。
            queue[member.player_id] = _Waiter(
                mode=pending.mode, joined_at=self._now(), party=[member.player_id])
            queue.move_to_end(member.player_id, last=False)
            out.append((member.player_id, queued_message(
                self.position_of(member.player_id, pending.mode), pending.mode)))
        log.info("对局解散 match=%s 拒绝/超时 %d 人", pending.match_uid, len(bad))
        return out

    def _finalise(self, pending: _Pending) -> None:
        """六个人都确认了：登记分配，等他们各自来领名片。"""
        self._pending.pop(pending.match_uid, None)
        expires_at = self._now() + ASSIGNMENT_TTL_SEC
        for member in pending.members:
            self._pending_of.pop(member.player_id, None)
            self._assignments[member.player_id] = Assignment(
                match_uid=pending.match_uid, mode=pending.mode,
                team=member.team, expires_at=expires_at)
        log.info("对局全员确认 match=%s mode=%s", pending.match_uid, pending.mode)

    def _position_updates(self, now: float) -> list[tuple[uuid.UUID, dict]]:
        if now < self._next_position_push:
            return []
        self._next_position_push = now + POSITION_PUSH_SEC
        out: list[tuple[uuid.UUID, dict]] = []
        for mode, queue in self._queues.items():
            for index, (pid, waiter) in enumerate(queue.items()):
                position = index + 1
                # 位次没变就不发。每秒给每个人推一条一样的消息只是在烧电池。
                if waiter.sent_position == position or waiter.dropped_at > 0.0:
                    continue
                waiter.sent_position = position
                out.append((pid, queued_message(position, mode)))
        return out


# --- 纯函数（好测）-------------------------------------------------------------


def new_match_uid() -> str:
    """32 位十六进制。与 `BattleReport.new_match_uid()` / `013` 的 match_uid_format 同格式。

    匹配出来的对局，**这个 uid 才是权威的** —— 战斗服务器那边不再自己摇一个，
    而是用名片上带过来的这个（第 4b 步）。不然同一局在匹配日志和对局历史里
    会是两个编号，对不上。
    """
    return secrets.token_hex(16)


def assign_teams(players: list[uuid.UUID], ratings: dict[uuid.UUID, int]) -> list[int]:
    """六个人分两队，返回与 players 同序的队伍号（0 = A 队，1 = B 队）。

    🔴 **蛇形分队**：按分排序后 1、4、5 对 2、3、6。

    为什么不是「前三个 vs 后三个」：3v3 里一个人的影响是 1/3，5v5 里是 1/5。
    队伍平均分差 100 分，在这里造成的胜率偏差比 MOBA 大得多
    （docs/排位系统设计.md 第五节）。

    casual 没有分（ratings 是空的，全按 0 算），这时蛇形退化成按入队顺序分 ——
    结果与「前三对后三」不同，但两者都无所谓。它是为 ranked 写的，
    现在就写好是为了那时候不用回头改这里再重跑一遍验证。
    """
    order = sorted(players, key=lambda pid: (-int(ratings.get(pid, 0)), pid.bytes))
    # 蛇形：0->A, 1->B, 2->B, 3->A, 4->A, 5->B …… 两队各拿到强弱交替的那一份
    pattern = [0, 1, 1, 0, 0, 1]
    team_of: dict[uuid.UUID, int] = {}
    counts = [0, 0]
    for index, pid in enumerate(order):
        team = pattern[index % len(pattern)]
        # 守卫：任何一队都不能超过 3 个人。人数不是 6 的倍数时上面的花样会失衡。
        if counts[team] >= TEAM_SIDE_SIZE:
            team = 1 - team
        counts[team] += 1
        team_of[pid] = team
    return [team_of[pid] for pid in players]


# --- 进程内单例 ---------------------------------------------------------------

_instance: Matchmaker | None = None


async def hub_send(player_id: uuid.UUID, payload: dict) -> int:
    from app import realtime

    return await realtime.hub().send_to_player(player_id, payload)


def install(instance: Matchmaker) -> Matchmaker:
    global _instance
    _instance = instance
    return instance


def current() -> Matchmaker:
    global _instance
    if _instance is None:
        _instance = Matchmaker(hub_send)
    return _instance


async def loop(target: Matchmaker) -> None:
    """后台匹配循环。由 app/main.py 的 lifespan 起停，同 admission.loop。"""
    while True:
        try:
            await asyncio.sleep(TICK_SEC)
            await target.tick()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - 一轮出错不该让循环停掉
            log.exception("匹配循环出错，下一轮再试")
