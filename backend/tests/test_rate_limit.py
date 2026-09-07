"""限流的行为用例。

限流是那种"平时看不出有没有生效"的东西 —— 不测的话，写错了也一切正常，
直到有人真的来刷。所以这里把每条性质都单独钉住。
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes import auth as auth_routes

client = TestClient(app)


# --- 限流器本身 ---------------------------------------------------------------


def test_allows_up_to_limit_then_blocks() -> None:
    limiter = SlidingWindowLimiter(limit=3, window_seconds=60)
    for _ in range(3):
        limiter.check("1.2.3.4")
    with pytest.raises(RateLimited):
        limiter.check("1.2.3.4")


def test_keys_are_independent() -> None:
    """一个人被限了不能连累别人。"""
    limiter = SlidingWindowLimiter(limit=1, window_seconds=60)
    limiter.check("a")
    limiter.check("b")  # 不该受 a 影响
    with pytest.raises(RateLimited):
        limiter.check("a")


def test_retry_after_is_usable() -> None:
    """Retry-After 必须是正数秒 —— 客户端要照着它退避。"""
    limiter = SlidingWindowLimiter(limit=1, window_seconds=60)
    limiter.check("x")
    with pytest.raises(RateLimited) as exc:
        limiter.check("x")
    assert 0 < exc.value.retry_after <= 61


def test_window_slides() -> None:
    """窗口过去之后要放行 —— 否则限流会变成永久封禁。"""
    limiter = SlidingWindowLimiter(limit=2, window_seconds=0.3)
    limiter.check("x")
    limiter.check("x")
    with pytest.raises(RateLimited):
        limiter.check("x")
    time.sleep(0.35)
    limiter.check("x")  # 不该再抛


def test_key_table_is_bounded() -> None:
    """内存必须有上限。

    不设上限的话，攻击者换一批来源就能把内存撑起来 ——
    限流器自己反倒成了攻击面。
    """
    limiter = SlidingWindowLimiter(limit=5, window_seconds=60, max_keys=32)
    for i in range(500):
        limiter.check(f"ip-{i}")
    assert len(limiter._hits) <= 32


# --- 接口层 -------------------------------------------------------------------


def test_anonymous_endpoint_returns_429_with_header() -> None:
    """超额时必须是 429 且带 Retry-After。

    注意限流在 _require_db 之前生效 —— 没配数据库时前几次是 503，
    但**额度照样被消耗**。这是有意的：限流要在做任何工作之前就挡住，
    否则「先干活再拒绝」本身就是可被利用的开销。
    """
    limiter = auth_routes._anonymous_limiter
    limiter.reset()
    original_limit = limiter.limit
    limiter.limit = 2
    try:
        seen = [client.post("/v1/auth/anonymous", json={}).status_code for _ in range(3)]
        assert seen[:2] == [503, 503], f"前两次应当是 503（没配数据库），实得 {seen[:2]}"
        assert seen[2] == 429, f"第三次应当被限流，实得 {seen[2]}"

        blocked = client.post("/v1/auth/anonymous", json={})
        assert blocked.status_code == 429
        assert int(blocked.headers["Retry-After"]) > 0
    finally:
        limiter.limit = original_limit
        limiter.reset()


def test_refresh_limit_is_looser_than_anonymous() -> None:
    """刷新是每次启动的正常动作，注册一辈子只该有一次。

    两个额度要是写反了，正常玩家会在启动时被限流 —— 而那看起来像是服务器坏了。
    """
    assert auth_routes._refresh_limiter.limit > auth_routes._anonymous_limiter.limit
