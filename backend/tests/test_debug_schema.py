"""/v1/debug/schema 的行为用例。

这里只覆盖**不需要真实数据库**的那一半：没连上时必须干净地拒绝，而不是 500。
真正连库跑的那一半靠手动执行（见 backend/README.md 第 2 步），因为它需要真实
凭据，不能进自动化门禁 —— 让门禁依赖某人本机的 .env 就是另一种假绿。

TestClient 不当上下文管理器用时**不会跑 lifespan**，所以连接池不会建立。
这正好是"未配置"的状态，且与 .env 里填没填连接串无关 —— 测试因此是确定的。
"""

from fastapi.testclient import TestClient

from app import db
from app.main import app

client = TestClient(app)


def test_schema_returns_503_when_db_not_connected() -> None:
    """没连数据库时用 503（配置问题），不是 500（服务器出错）。

    这个区分不是洁癖：503 告诉运维"你少配了东西"，500 会让人去翻代码找 bug。
    """
    assert not db.is_connected(), "本用例的前提是连接池未建立"
    r = client.get("/v1/debug/schema")
    assert r.status_code == 503
    assert "GLORY_DATABASE_URL" in r.json()["detail"]


def test_schema_error_does_not_leak_connection_string() -> None:
    """503 的错误信息里只能出现**键名**，不能出现连接串本身。

    连接串含数据库密码。错误信息会进日志、进监控、有时会被截图贴出来。
    """
    body = client.get("/v1/debug/schema").text
    assert "postgresql://" not in body
    assert "@" not in body, "错误信息里不该出现连接串片段"


def test_expected_tables_match_migration_files() -> None:
    """db.EXPECTED_TABLES 必须和 database/ 下真实建了表的迁移文件对得上。

    这条挡的是"加了迁移文件却忘了加进检查清单" —— 那样新表就没人检查
    RLS 和 policy 了，而那两项是 RFC 第三节的硬规则。
    """
    import pathlib
    import re

    db_dir = pathlib.Path(__file__).resolve().parents[2] / "database"
    assert db_dir.is_dir(), f"找不到 {db_dir}"

    created: set[str] = set()
    for sql_file in db_dir.glob("*.sql"):
        text = sql_file.read_text(encoding="utf-8")
        created.update(re.findall(r"create\s+table\s+(?:if\s+not\s+exists\s+)?(\w+)", text, re.I))

    assert created == set(db.EXPECTED_TABLES), (
        f"database/ 里建的表是 {sorted(created)}，"
        f"但 db.EXPECTED_TABLES 是 {sorted(db.EXPECTED_TABLES)} —— 两边要一致"
    )
