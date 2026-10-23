"""电脑（Steam）关联手机号用的 6 位码（docs/三方登录设计.md 第八节）。

流程：
  1. 电脑交 Steam 票 → 这里发一个 6 位码 + 一个轮询凭证，5 分钟有效、只能用一次；
  2. 手机（已登录）输入码 → 先看到「要关联到 Steam 用户 XXX 吗」→ 确认后，账号服务器把这个 Steam 绑到手机那个号上；
  3. 电脑拿轮询凭证看到「已关联」，再用 Steam 登录，就进了手机那个号。

码由**电脑出、手机输**：手机是已登录的一方，由它来确认最安全。反过来的话，别人骗你在电脑上输入他手机上的码，
你的 Steam 就进了他的号。

只放在进程内存里：码 5 分钟就过期，账号服务器重启丢了也就是让玩家重新出一个码，不值得建表
（账号服务器是单进程单实例，见 config.py 的 WebSocket 单实例那段）。
"""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass

CODE_TTL_SEC = 300.0

PENDING = "pending"
LINKING = "linking"  # 手机确认了、正在找 Supabase 绑，防止两台手机同时用同一个码
LINKED = "linked"
TAKEN = "taken"  # 这个 Steam 已经属于别的号（不合并）
EXPIRED = "expired"


@dataclass
class LinkCode:
    code: str
    poll_token: str
    steam_id: str
    name: str
    expires_at: float
    state: str = PENDING


_by_code: dict[str, LinkCode] = {}
_by_poll: dict[str, LinkCode] = {}


def reset() -> None:
    """只给测试用。"""
    _by_code.clear()
    _by_poll.clear()


def _prune(now: float) -> None:
    # 过期之后再留一会儿：电脑可能刚好在过期那一刻来问结果。
    for item in [c for c in _by_code.values() if c.expires_at + CODE_TTL_SEC < now]:
        _by_code.pop(item.code, None)
        _by_poll.pop(item.poll_token, None)


def issue(steam_id: str, name: str, now: float | None = None) -> LinkCode:
    """给这个 Steam 发一个新码。同一个 Steam 之前发的码立即作废 —— 屏幕上只该有一个有效的码。"""
    now = time.time() if now is None else now
    _prune(now)
    for old in [c for c in _by_code.values() if c.steam_id == steam_id and c.state == PENDING]:
        old.state = EXPIRED
    while True:
        code = f"{secrets.randbelow(1_000_000):06d}"
        if code not in _by_code:
            break
    item = LinkCode(code, secrets.token_urlsafe(24), steam_id, name, now + CODE_TTL_SEC)
    _by_code[code] = item
    _by_poll[item.poll_token] = item
    return item


def pending(code: str, now: float | None = None) -> LinkCode | None:
    """还能用的码。码不对、过期、用过了一律 None —— 不告诉对方是哪一种（防止拿它猜码）。"""
    now = time.time() if now is None else now
    item = _by_code.get(code.strip())
    if item is None or item.state != PENDING or item.expires_at < now:
        return None
    return item


def status(poll_token: str, now: float | None = None) -> str:
    now = time.time() if now is None else now
    item = _by_poll.get(poll_token)
    if item is None:
        return EXPIRED
    if item.state == PENDING and item.expires_at < now:
        return EXPIRED
    # 正在绑的那一小会儿，对电脑来说还是「等着」。
    return PENDING if item.state == LINKING else item.state
