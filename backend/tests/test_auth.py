"""登录路径的行为用例。

真正连 Supabase 跑通那一遍是手动做的（见 backend/README.md 第 3 步），
这里覆盖的是**不需要真实凭据**的那些判据 —— 靠 httpx.MockTransport 把上游
换掉。让门禁依赖某人本机的 .env 就是另一种假绿。

重点在两类：
  1. 凭证不外泄：错误信息里绝不能出现 token
  2. 失败要说人话：匿名登录没开是最容易踩的一个坑，报错要直接指到那个开关
"""

from __future__ import annotations

import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.supabase_auth import AuthError, SupabaseAuth, _redact

client = TestClient(app)

SECRET_LOOKING_TOKEN = "v1.MRxxxxSUPER_SECRET_REFRESH_TOKEN_xxxx"


def _auth_with(handler) -> SupabaseAuth:
    return SupabaseAuth("https://example.supabase.co", "pk_test", httpx.MockTransport(handler))


# --- 路由层（不依赖上游）-------------------------------------------------------


def test_anonymous_requires_db() -> None:
    """数据库没连上时是配置问题，用 503 而不是 500。"""
    r = client.post("/v1/auth/anonymous", json={})
    assert r.status_code == 503
    assert "GLORY_DATABASE_URL" in r.json()["detail"]


def test_refresh_rejects_missing_token() -> None:
    """少了 refresh_token 应当被请求校验挡掉（422），不该进业务逻辑。"""
    assert client.post("/v1/auth/refresh", json={}).status_code == 422


def test_anonymous_rejects_malformed_player_id() -> None:
    """客户端提议的 player_id 必须是合法 UUID，畸形的在入口就挡掉。"""
    r = client.post("/v1/auth/anonymous", json={"player_id": "not-a-uuid"})
    assert r.status_code == 422


# --- Supabase 客户端层（MockTransport）-----------------------------------------


def test_anonymous_disabled_error_points_at_the_switch() -> None:
    """项目没开匿名登录时，报错要直接说是哪个开关。

    这是这条链路上最容易踩的坑：原始响应只是一个 422 加一句英文，
    不翻文档猜不到要去 Dashboard 打开 Allow anonymous sign-ins。
    """

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(422, json={"error_code": "anonymous_provider_disabled",
                                         "msg": "Anonymous sign-ins are disabled"})

    with pytest.raises(AuthError) as exc:
        asyncio.run(_auth_with(handler).sign_in_anonymously())
    assert "Allow anonymous sign-ins" in str(exc.value)


def test_refresh_error_never_contains_the_token() -> None:
    """刷新失败的错误信息里绝不能出现 refresh token 本身。

    错误信息会进日志、进监控、有时被截图贴出来。refresh token 能换出
    完整会话 —— 泄漏它等于泄漏账号。
    """

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"error": "invalid_grant"})

    with pytest.raises(AuthError) as exc:
        asyncio.run(_auth_with(handler).refresh(SECRET_LOOKING_TOKEN))
    assert SECRET_LOOKING_TOKEN not in str(exc.value)


def test_incomplete_session_is_rejected() -> None:
    """上游少给了任何一样就必须失败 —— 半个会话比没有会话更糟。

    只有 access_token 没有 refresh_token 的客户端，这一次能玩，
    下次启动就再也登不回同一个账号了，而且不报错。
    """

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"access_token": "a", "user": {"id": "u"}})  # 缺 refresh_token

    with pytest.raises(AuthError) as exc:
        asyncio.run(_auth_with(handler).sign_in_anonymously())
    assert "refresh_token" in str(exc.value)


def test_successful_session_is_parsed() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={
            "access_token": "at", "refresh_token": "rt", "expires_in": 3600,
            "user": {"id": "auth-uid-1", "is_anonymous": True},
        })

    session = asyncio.run(_auth_with(handler).sign_in_anonymously())
    assert (session.auth_uid, session.access_token, session.refresh_token) == ("auth-uid-1", "at", "rt")


def test_redact_flattens_and_truncates() -> None:
    """上游返回体可能很长、可能带换行。裁短并压平，免得撑爆一行日志。"""
    out = _redact("a\n  b\tc " + "x" * 500, limit=50)
    assert "\n" not in out and "\t" not in out
    assert len(out) <= 51  # 50 + 省略号
    assert out.startswith("a b c")
