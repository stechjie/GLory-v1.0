"""找 Steam 验票（docs/三方登录设计.md 第八节）。

电脑上的游戏用 GetAuthTicketForWebApi("glory-account") 向 Steam 要一张票，转成十六进制交上来。
这里拿**发行商 Web API 密钥**去问 Steam 这张票是谁的（ISteamUserAuth/AuthenticateUserTicket），
得到 SteamID；再顺手查一下 Steam 昵称（关联码确认时给手机看，防止被人骗着关联到别人的 Steam）。

🔴 密钥只能放在查询参数里（Steam 的约定），所以：
  - 请求地址**绝不进日志、绝不进报错**。报错只带 HTTP 状态码和 Steam 的错误码；
  - httpx 自己的请求日志（INFO 级，会打出带 key 的完整地址）在这里压到 WARNING。
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass

import httpx

from app.config import get_settings

log = logging.getLogger("glory.steam")
# httpx 在 INFO 级会把每个请求的完整地址打进日志 —— 那里面有发行商密钥。
logging.getLogger("httpx").setLevel(logging.WARNING)

PARTNER_API = "https://partner.steam-api.com"
_TIMEOUT = httpx.Timeout(10.0, connect=5.0)
# GetAuthTicketForWebApi 的票目前两三百字节，十六进制翻倍。给足余量，但挡住塞大包。
_TICKET_RE = re.compile(r"^[0-9a-fA-F]{16,8192}$")


class SteamRejected(RuntimeError):
    """票不对（过期、伪造、不是这个游戏的、identity 对不上）。message 可以外传。"""


class SteamUnavailable(RuntimeError):
    """没配密钥，或者连不上 Steam。message 不含密钥，可以外传。"""


@dataclass(frozen=True)
class SteamUser:
    steam_id: str
    # 家庭共享时是借出游戏的那个人。我们**只认 steam_id**（玩的人自己），这个只留着记日志。
    owner_steam_id: str


def _key() -> str:
    key = get_settings().steam_web_api_key.strip()
    if not key:
        raise SteamUnavailable("服务器没配 Steam 发行商密钥（GLORY_STEAM_WEB_API_KEY）")
    return key


async def authenticate_ticket(ticket: str, transport: httpx.AsyncBaseTransport | None = None) -> SteamUser:
    ticket = ticket.strip()
    if not _TICKET_RE.match(ticket):
        raise SteamRejected("Steam 票格式不对")
    s = get_settings()
    params = {"key": _key(), "appid": str(s.steam_app_id), "ticket": ticket,
              "identity": s.steam_ticket_identity}
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            resp = await client.get(f"{PARTNER_API}/ISteamUserAuth/AuthenticateUserTicket/v1/", params=params)
    except httpx.HTTPError as exc:
        raise SteamUnavailable(f"连不上 Steam（{type(exc).__name__}）") from None
    if resp.status_code in (401, 403):
        # 密钥不对、或者这把密钥所在的组没加这个游戏。是配置问题，不是玩家的票有问题。
        raise SteamUnavailable(f"Steam 拒绝了服务器的密钥（HTTP {resp.status_code}），检查发行商密钥和它所在的组")
    if resp.status_code >= 400:
        raise SteamUnavailable(f"Steam 验票出错（HTTP {resp.status_code}）")
    try:
        body = resp.json().get("response") or {}
    except ValueError:
        raise SteamUnavailable("Steam 回的不是 JSON") from None
    error = body.get("error")
    if error:
        raise SteamRejected(f"Steam 不认这张票（{error.get('errorcode')}：{str(error.get('errordesc', ''))[:80]}）")
    params_out = body.get("params") or {}
    steam_id = str(params_out.get("steamid") or "")
    if params_out.get("result") != "OK" or not steam_id.isdigit():
        raise SteamRejected("Steam 没有确认这张票")
    return SteamUser(steam_id=steam_id, owner_steam_id=str(params_out.get("ownersteamid") or steam_id))


async def persona_name(steam_id: str, transport: httpx.AsyncBaseTransport | None = None) -> str:
    """Steam 昵称。查不到就是空串 —— 只用来给人看，不该挡住登录或关联。"""
    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, transport=transport) as client:
            resp = await client.get(f"{PARTNER_API}/ISteamUser/GetPlayerSummaries/v2/",
                                    params={"key": _key(), "steamids": steam_id})
        players = (resp.json().get("response") or {}).get("players") or []
        return str(players[0].get("personaname") or "")[:64] if players else ""
    except (httpx.HTTPError, ValueError, SteamUnavailable, AttributeError, IndexError) as exc:
        log.warning("查 Steam 昵称失败：%s", type(exc).__name__)
        return ""


def placeholder_email(steam_id: str) -> str:
    """Steam 不给邮箱，但 Supabase 往没有邮箱的号（游客）上绑登录方式时必须有一个（第 0 步实测）。

    用保留域名 .invalid（RFC 2606）：信永远发不出去，换服务器域名也不受影响。10-23 定。
    """
    return f"steam-{steam_id}@steam.invalid"
