"""按来源 IP 的滑动窗口限流。

为什么需要它：匿名登录是**谁都能调**的接口，每调一次就在 Supabase 多一个用户、
在 players 多一行。Supabase Dashboard 自己也提醒过这一点 ——
不限流的话，任何人写个循环就能撑爆数据库并把 MAU 账单顶上去。

Supabase 建议的做法是给匿名登录挂 captcha。我们不走那条：captcha 塞进 Godot
客户端很难受，而且**我们本来就不需要** —— publishable key 不下发给客户端，
外面的人打不到 Supabase 的注册接口，只能走我们这个端点。既然入口只有一个，
在这里限流就够了。

### 两个必须知道的局限

1. **计数在进程内存里。** 开多个 worker 或多个实例时，每个进程各算各的，
   实际额度会翻倍。真上量之后要换成 Redis 或在反向代理层做。
2. **来源识别在 routes/auth.py 的 `_client_ip()`。** 它只在请求确实来自可信
   代理（本机回环，也就是同机的 Caddy）时才采信 X-Forwarded-For；直连本服务的
   请求一律按真实对端计。那个头是客户端可以随便写的，盲信它比不限流还糟 ——
   你会以为限住了。有测试钉着（tests/test_client_ip.py）。

   仍然挡不住的：同一出口 IP 的人共用额度（办公室、校园网、运营商 NAT），
   以及手上有大量 IP 的攻击者。那是按 IP 限流的固有边界。
"""

from __future__ import annotations

import time
from collections import OrderedDict, deque


class RateLimited(Exception):
    def __init__(self, retry_after: int) -> None:
        super().__init__(f"请求过于频繁，请 {retry_after} 秒后再试")
        self.retry_after = retry_after


class SlidingWindowLimiter:
    """每个 key 一个时间戳队列，窗口外的自动出队。

    用滑动窗口而不是固定窗口：固定窗口在边界处允许两倍突发
    （窗口末尾打满 + 下个窗口开头再打满），而账号创建正是最不该被突发的那类。
    """

    def __init__(self, limit: int, window_seconds: float, max_keys: int = 10_000) -> None:
        self.limit = max(1, limit)
        # 只挡住 <= 0（那会让窗口数学直接失效），**不做别的夹取**。
        # 上一版写的是 max(1.0, window_seconds)，于是传 0.3 秒会被悄悄变成 1 秒 ——
        # 静默改掉调用方配置的值，是限流器最不该有的行为：
        # 你以为配了 A，实际跑的是 B，而且哪里都不会告诉你。
        self.window = window_seconds if window_seconds > 0 else 1.0
        # 有上限的 LRU：不设上限的话，攻击者换一批 IP 就能把内存撑起来 ——
        # 限流器自己反倒成了攻击面。
        self.max_keys = max(1, max_keys)
        self._hits: OrderedDict[str, deque[float]] = OrderedDict()

    def check(self, key: str) -> None:
        """放行则返回，超额抛 RateLimited。"""
        now = time.monotonic()
        window_start = now - self.window

        stamps = self._hits.get(key)
        if stamps is None:
            stamps = deque()
            self._hits[key] = stamps
        else:
            self._hits.move_to_end(key)

        while stamps and stamps[0] <= window_start:
            stamps.popleft()

        if len(stamps) >= self.limit:
            # 最早那一次滑出窗口时就能再来一发。
            retry_after = max(1, int(stamps[0] + self.window - now) + 1)
            raise RateLimited(retry_after)

        stamps.append(now)
        self._evict_if_needed()

    def _evict_if_needed(self) -> None:
        while len(self._hits) > self.max_keys:
            # 丢最久没动的那个。被丢掉的 key 相当于重新计数 ——
            # 在被塞满的极端情况下这是有意的取舍：宁可放宽，也不让内存无限涨。
            self._hits.popitem(last=False)

    def reset(self) -> None:
        """给测试用。"""
        self._hits.clear()
