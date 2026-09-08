"""Glory Game Backend —— 四层架构里的 ②。

    ① Godot ── HTTPS ──> ② 这里 ──> ④ Supabase (Auth + PostgreSQL)
    ① Godot ── ENet  ──> ③ 战斗服务器（另一条链路，见 docs/账号系统RFC.md 第六节）

职责边界（RFC 第三节）：
  - Godot **永远不直连** Supabase，只认 AccountManager 这一个门面打到这里。
  - 金币 / 钻石 / 抽卡 / 商城 / Rank / 奖励只能由这一层修改。
  - RLS 是第二道保险，不是游戏规则。

跑起来：
    backend/.venv/Scripts/python -m uvicorn app.main:app --reload --app-dir backend
"""

import logging
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import db
from app.config import get_settings
from app.routes import auth as auth_routes
from app.routes import debug as debug_routes
from app.routes import me as me_routes

# Windows 控制台默认是 cp1252，中文日志会被转义成 以... 甚至直接抛
# UnicodeEncodeError。这里是应用入口，把两个流拧成 UTF-8 是合适的做法。
# （也可以用环境变量 PYTHONIOENCODING=utf-8，但那要求每个人都记得设。）
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="backslashreplace")

def _configure_logging() -> None:
    """给 glory.* 这组 logger 装上 handler。

    uvicorn 只配置它自己的 logger，不碰别人的。不做这一步，应用自己的
    `log.info()` 会被完全吞掉 —— 只有 WARNING 以上才会经 logging 的
    lastResort 漏到 stderr。

    这个坑很安静：代码里写满了 log.info，跑起来一条都看不到，而你以为记了。
    实测踩过一次 —— 登录成功那条日志始终不出现，一度以为是没执行到。
    """
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(levelname)s:     [%(name)s] %(message)s"))
    glory_log = logging.getLogger("glory")
    glory_log.handlers.clear()
    glory_log.addHandler(handler)
    glory_log.setLevel(logging.INFO)
    # 不往上冒泡，免得 uvicorn 的 root handler 再打一遍。
    glory_log.propagate = False


_configure_logging()

log = logging.getLogger("glory.backend")

settings = get_settings()


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    missing = settings.missing_keys()
    if missing:
        # 刻意**不**直接退出：骨架要能在还没建 Supabase 项目时跑起来，
        # 否则第 1 步就没法单独验证。真正需要密钥的接口会各自 fail closed。
        log.warning("以下配置项还没填，需要它们的接口会拒绝服务：%s", ", ".join(missing))
    # 连接串为空时 connect() 不建池也不抛异常 —— 同样是为了让骨架能单独起来。
    await db.connect(settings.database_url)
    try:
        yield
    finally:
        await db.disconnect()


def doc_urls(is_dev: bool) -> dict[str, str | None]:
    """交互文档与 OpenAPI schema 的暴露策略。

    生产环境下**三个都必须是 None**。

    实测踩过：只关了 docs_url / redoc_url，漏了 openapi_url，于是线上
    /openapi.json 仍然返回 200 —— 那份 JSON 是完整的接口清单（每个端点、
    每个字段、每种参数），等于把攻击面图纸白送出去。/docs 关掉了看着像没事，
    实际最有价值的那份还开着。

    三个写在一起、由一个开关决定，就不会再漏其中一个。有测试钉着。
    """
    if not is_dev:
        return {"docs_url": None, "redoc_url": None, "openapi_url": None}
    return {"docs_url": "/docs", "redoc_url": None, "openapi_url": "/openapi.json"}


app = FastAPI(
    title="Glory Backend",
    version="0.1.0",
    lifespan=lifespan,
    **doc_urls(settings.is_dev),
)

app.include_router(auth_routes.router)
app.include_router(me_routes.router)

# 自检接口只在开发环境挂载。生产上它会把表结构和 RLS 状态说得太清楚，
# 而且没有任何生产用途 —— 少一个入口就少一个面。
if settings.is_dev:
    app.include_router(debug_routes.router)


@app.get("/health")
def health() -> dict:
    """存活探针。

    只报「配没配」，**绝不报值本身** —— health 端点通常对外可达。
    """
    missing = settings.missing_keys()
    return {
        "status": "ok",
        "environment": settings.environment,
        "configured": not missing,
        "missing_config": missing,
    }
