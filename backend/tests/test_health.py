"""/health 的行为用例。

这是后端的第一条门禁。判据看起来平淡，但两条都挡着真实的事故：

  1. **health 绝不能回显密钥的值。** 这个端点通常对外可达，
     一旦有人图方便把 settings 整个 dump 进去，密钥就从这里流出去了。
     所以这里显式断言：响应里出现的只能是**键名**。

  2. **没配密钥时也要能起来。** 骨架要能在还没建 Supabase 项目时跑，
     否则第 1 步就没法单独验证。需要密钥的接口各自 fail closed，
     不是让整个进程起不来。

跑（必须从 backend/ 目录，pytest.ini 在那里）：
    cd backend && .venv/Scripts/python -m pytest -q
"""

from fastapi.testclient import TestClient

from app.config import get_settings
from app.main import app

client = TestClient(app)


def test_health_ok() -> None:
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_health_reports_missing_config_by_name() -> None:
    """没配全时要如实报告，且只报键名。"""
    body = client.get("/health").json()
    assert "configured" in body
    assert isinstance(body["missing_config"], list)
    for name in body["missing_config"]:
        assert name.startswith("GLORY_"), f"missing_config 只应含键名，实得 {name!r}"


def test_health_never_leaks_secret_values() -> None:
    """核心断言：真实密钥的值绝不能出现在 /health 的响应里。

    用一个可识别的哨兵值临时冒充密钥，再断言它不出现在响应体中。
    """
    sentinel = "sb_secret_THIS_MUST_NEVER_APPEAR_IN_A_RESPONSE"
    settings = get_settings()
    original = settings.supabase_secret_key
    try:
        settings.supabase_secret_key = sentinel
        raw = client.get("/health").text
        assert sentinel not in raw, "密钥的值泄漏进了 /health 响应"
    finally:
        settings.supabase_secret_key = original
