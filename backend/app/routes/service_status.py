"""GET /v1/service-status —— 客户端读全局开关（维护 / 关闭匹配）。

## 为什么**不要登录**

同 `/v1/match/window`：维护中的玩家很可能登不进来（那正是维护要的效果），
如果这个接口要登录，他就永远问不到「为什么进不去」，只能看到一句
「连不上服务器」。被封玩家申诉入口不可用也是同一类错误。

## 和 `/status.json` 的分工

`/status.json` 是 Caddy 直接给的手工静态文件（`scripts/account/ServiceStatus.gd`），
**账号服务器整个停机时**启动画面还读得到 —— 它只负责解释，不是准入依据。

这个接口是**权威状态**，但账号服务器不在就读不到。两个都要留着：
任务书 §七.3.9 明确要求保留前者，并与后台状态有明确同步与失败提示。

🔴 本接口只回公开字段。`actor` / `change_reason` 是内部信息，由 `public_view` 挡掉。
"""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel

from app import service_control

router = APIRouter(prefix="/v1", tags=["service"])


class ServiceStatusResponse(BaseModel):
    # 进不进得了游戏。读不出状态时这里是 true —— 不假装一切正常（任务书 §七.2）。
    maintenance: bool
    # 能不能开始排队 / 开新局。排位与休闲共用这一个。
    matchmaking: bool
    notice_zh: str
    notice_en: str
    # 仅供展示，到点不会自动开服。
    expected_back_at: str | None
    # 客户端可以拿它判断「状态变过没有」，不用比对每个字段。
    version: int


@router.get("/service-status", response_model=ServiceStatusResponse)
async def service_status() -> ServiceStatusResponse:
    return ServiceStatusResponse(**service_control.public_view(await service_control.read()))
