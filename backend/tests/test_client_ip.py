"""限流的来源识别。

这一层错了，限流会**静默失效** —— 接口照常返回 200，看不出任何异常，
直到有人真的来刷。所以每条性质单独钉住。

最要紧的是 test_forged_header_from_untrusted_peer_is_ignored：
X-Forwarded-For 是客户端可以随便写的头，盲信它比不限流还糟，
因为你以为限住了。
"""

from __future__ import annotations

from dataclasses import dataclass

from app.routes.auth import TRUSTED_PROXIES, _client_ip


@dataclass
class _FakeClient:
    host: str


class _FakeRequest:
    """只提供 _client_ip 用到的两样：对端地址与请求头。"""

    def __init__(self, peer: str | None, headers: dict[str, str] | None = None) -> None:
        self.client = _FakeClient(peer) if peer is not None else None
        self.headers = headers or {}


def test_forged_header_from_untrusted_peer_is_ignored() -> None:
    """**本文件最重要的一条。**

    直连后端（绕过 Caddy）的请求，不管头里写什么，一律按真实对端计。
    否则攻击者每次换一个假 IP 就完全绕过限流。
    """
    req = _FakeRequest("203.0.113.9", {"X-Forwarded-For": "1.2.3.4"})
    assert _client_ip(req) == "203.0.113.9"


def test_header_is_used_when_peer_is_the_proxy() -> None:
    """来自 Caddy 的请求才采信转发头，否则所有玩家都会被算成 127.0.0.1。"""
    req = _FakeRequest("127.0.0.1", {"X-Forwarded-For": "198.51.100.7"})
    assert _client_ip(req) == "198.51.100.7"


def test_proxy_without_header_falls_back_to_peer() -> None:
    """Caddy 没带头（配置漏了）时不能崩，退回对端。

    这时全体共用一个额度 —— 不好，但比 500 强。
    """
    assert _client_ip(_FakeRequest("127.0.0.1")) == "127.0.0.1"
    assert _client_ip(_FakeRequest("127.0.0.1", {"X-Forwarded-For": "   "})) == "127.0.0.1"


def test_chained_header_takes_the_first_entry() -> None:
    """万一 Caddy 改成追加而不是覆盖，取第一段而不是整串。

    取整串的话每个链条都是一个新 key，限流会静默失效。
    """
    req = _FakeRequest("127.0.0.1", {"X-Forwarded-For": "198.51.100.7, 10.0.0.1"})
    assert _client_ip(req) == "198.51.100.7"


def test_missing_client_does_not_crash() -> None:
    """ASGI 规范允许没有 client 信息（某些测试与传输层）。"""
    assert _client_ip(_FakeRequest(None)) == "unknown"


def test_trusted_set_is_loopback_only() -> None:
    """可信代理只能是本机回环。

    后端只监听 127.0.0.1（deploy/glory-backend.service），Caddy 与它同机。
    往这个集合里加公网地址等于把伪造转发头的能力交出去 —— 加之前先想清楚。
    """
    assert TRUSTED_PROXIES == frozenset({"127.0.0.1", "::1"})


def test_distinct_clients_get_distinct_keys() -> None:
    """两个玩家必须被算成两个来源，否则额度是共用的。"""
    a = _client_ip(_FakeRequest("127.0.0.1", {"X-Forwarded-For": "198.51.100.7"}))
    b = _client_ip(_FakeRequest("127.0.0.1", {"X-Forwarded-For": "198.51.100.8"}))
    assert a != b
