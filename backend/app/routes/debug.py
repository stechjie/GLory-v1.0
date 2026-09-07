"""开发期自检接口。**生产环境不挂载**（见 main.py）。

这里不是"随便看看"的调试口，而是把 docs/账号系统RFC.md 第三节那两条硬规则
变成可以一眼验证的东西：

  1. 三张表都在（且和 database/ 里的迁移文件对得上）
  2. 每张表都开了 RLS，且 **policy 数为 0**

第 2 条尤其值得自动检查。零 policy 是刻意的设计 —— Godot 不直连 Supabase，
一切经 FastAPI（secret key 绕过 RLS），所以零 policy 意味着通过 Data API
谁都读不到。哪天有人在 Dashboard 上顺手加了一条 policy 想"临时调试一下"，
这个接口会立刻显示出来，而不是等到数据被客户端读走才发现。
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app import db

router = APIRouter(prefix="/v1/debug", tags=["debug"])


@router.get("/schema")
async def schema() -> dict:
    """检查账号层的表结构是否符合预期。"""
    if not db.is_connected():
        # 没配数据库是配置问题，不是服务器出错 —— 用 503 而不是 500。
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )

    tables = await db.inspect_schema()

    problems: list[str] = []
    for t in tables:
        if not t["exists"]:
            problems.append(f"{t['table']}: 表不存在，database/ 下的迁移可能没跑")
            continue
        if not t["rls_enabled"]:
            problems.append(f"{t['table']}: RLS 没开 —— 这是 RFC 第三节的硬规则")
        if t["policy_count"] != 0:
            problems.append(
                f"{t['table']}: 有 {t['policy_count']} 条 RLS policy，"
                "预期为 0（客户端不直连数据库，不该有 policy）"
            )

    return {"ok": not problems, "tables": tables, "problems": problems}
