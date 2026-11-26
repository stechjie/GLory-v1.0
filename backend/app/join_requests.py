"""好友界面「加入」的申请（2026-11-26）。

用户口径：在好友界面点好友那一行的「加入」，不能一按就进他的房间 ——
要先问那位好友，他点了「同意」才进。只管好友界面这一个入口：
被邀请的人点邀请上的「加入」照旧直接进，房间列表 / 输房间号加入也不变。

这里只是一张**内存里的小账本**（同 party.Parties：单进程、重启即清）：
  · 谁向谁申请进哪个房间、什么时候过期；
  · 回复时核对「这张申请确实是发给你的、还没过期」—— 否则任何人都能冒充
    好友给别人推一条「已同意」。

**它不是进房闸门**：真正进房走的是战斗服务器，那边不知道有这张申请。
这是界面上的礼貌问询，不是权限控制（用户定的范围就是这样）。
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass

# 申请多久没人理就作废。客户端两边的倒计时都用它（随推送下发），不各写各的。
TTL_SEC = 30.0


@dataclass
class JoinRequest:
    id: str
    requester: uuid.UUID
    target: uuid.UUID
    room_id: int
    expires_at: float


class JoinRequests:
    def __init__(self) -> None:
        # 一个人同一时刻只有一张申请在外面：再点别的好友，上一张作废。
        self._by_requester: dict[uuid.UUID, JoinRequest] = {}

    def _sweep(self, now: float) -> None:
        dead = [pid for pid, req in self._by_requester.items() if req.expires_at <= now]
        for pid in dead:
            del self._by_requester[pid]

    def create(self, requester: uuid.UUID, target: uuid.UUID, room_id: int,
               now: float | None = None) -> tuple[JoinRequest, JoinRequest | None]:
        """记一张新申请。返回 (新申请, 被它顶掉的那张或 None)。"""
        now = time.monotonic() if now is None else now
        self._sweep(now)
        replaced = self._by_requester.get(requester)
        request = JoinRequest(uuid.uuid4().hex, requester, target, int(room_id), now + TTL_SEC)
        self._by_requester[requester] = request
        return request, replaced

    def take(self, request_id: str, target: uuid.UUID,
             now: float | None = None) -> JoinRequest | None:
        """被申请的人回复时取走这张申请。不是发给他的 / 过期了 / 已经回过 ⇒ None。"""
        now = time.monotonic() if now is None else now
        self._sweep(now)
        for requester, request in self._by_requester.items():
            if request.id == request_id and request.target == target:
                del self._by_requester[requester]
                return request
        return None

    def cancel(self, requester: uuid.UUID, now: float | None = None) -> JoinRequest | None:
        """申请人自己撤回。没有在外面的申请 ⇒ None。"""
        now = time.monotonic() if now is None else now
        self._sweep(now)
        return self._by_requester.pop(requester, None)


_instance: JoinRequests | None = None


def current() -> JoinRequests:
    global _instance
    if _instance is None:
        _instance = JoinRequests()
    return _instance
