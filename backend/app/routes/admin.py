"""网页后台的接口与页面（docs/运营后台设计.md）。

    GET  /admin/                 页面（backend/admin_web/）
    POST /admin/api/login        邮箱密码 → 要验证码（或先绑验证器）
    POST /admin/api/login/code   验证码 → 登录
    …    /admin/api/*            其余接口都要登录；会改东西的还要 X-Glory-Admin: 1 头

**不收玩家的令牌。** 这里只认后台自己的会话 Cookie（app/admin_auth.py），
玩家的 access token 打过来只会得到 401。
"""

from __future__ import annotations

import pathlib
import uuid
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, Field

from app import admin, admin_auth, db
from app.admin_auth import Admin, current_admin, writing_admin
from app.config import get_settings

router = APIRouter(tags=["admin"])

WEB_DIR = pathlib.Path(__file__).resolve().parents[2] / "admin_web"

# 页面的安全头。只许加载本站的脚本和样式；二维码是 data: 图片。
PAGE_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"),
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
}

# 原图上限，与 announcements.UPLOAD_MAX_BYTES 一致（那边判得更细，这里只防撑爆内存）。
IMAGE_UPLOAD_MAX = 10 * 1024 * 1024

Me = Annotated[Admin, Depends(current_admin)]
Writer = Annotated[Admin, Depends(writing_admin)]


def rejected_response(exc: admin.AdminRejected) -> JSONResponse:
    return JSONResponse(status_code=exc.status, content={"detail": exc.message})


def _require_db() -> None:
    if not db.is_connected():
        raise HTTPException(status_code=503, detail="数据库未配置")


# --- 页面 -----------------------------------------------------------------------


@router.get("/admin", include_in_schema=False)
async def admin_root() -> RedirectResponse:
    return RedirectResponse("/admin/")


@router.get("/admin/", include_in_schema=False)
async def admin_page() -> FileResponse:
    return FileResponse(WEB_DIR / "index.html", headers=PAGE_HEADERS)


_STATIC = {"admin.js": "text/javascript; charset=utf-8", "admin.css": "text/css; charset=utf-8"}


@router.get("/admin/static/{name}", include_in_schema=False)
async def admin_static(name: str) -> FileResponse:
    # 白名单，不拼路径：没有路径穿越的余地。
    if name not in _STATIC:
        raise HTTPException(status_code=404)
    return FileResponse(WEB_DIR / name, media_type=_STATIC[name], headers={"Cache-Control": "no-cache"})


# --- 登录 -----------------------------------------------------------------------


class LoginBody(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=256)


class CodeBody(BaseModel):
    code: str = Field(pattern=r"^\d{6}$")


@router.post("/admin/api/login")
async def login(body: LoginBody, request: Request, response: Response) -> dict:
    admin_auth.check_login_rate(request)
    _require_db()
    token, answer = await admin_auth.begin_login(admin_auth.auth_client(), body.email.strip(), body.password)
    response.set_cookie(admin_auth.PENDING_COOKIE, token, max_age=int(admin_auth.PENDING_TTL_SEC),
                        **admin_auth.cookie_kwargs())
    return answer


@router.post("/admin/api/login/code")
async def login_code(body: CodeBody, request: Request, response: Response) -> dict:
    admin_auth.check_login_rate(request)
    _require_db()
    pending = request.cookies.get(admin_auth.PENDING_COOKIE, "")
    token, name = await admin_auth.finish_login(admin_auth.auth_client(), pending, body.code)
    response.set_cookie(admin_auth.SESSION_COOKIE, token, max_age=int(admin_auth.SESSION_TTL_SEC),
                        **admin_auth.cookie_kwargs())
    response.delete_cookie(admin_auth.PENDING_COOKIE, path=admin_auth.COOKIE_PATH)
    return {"name": name}


@router.post("/admin/api/logout")
async def logout(request: Request, response: Response) -> dict:
    admin_auth.logout(request.cookies.get(admin_auth.SESSION_COOKIE, ""))
    response.delete_cookie(admin_auth.SESSION_COOKIE, path=admin_auth.COOKIE_PATH)
    return {"ok": True}


@router.get("/admin/api/me")
async def me(who: Me) -> dict:
    # environment 让页面顶上一直标着「正式服 / 测试」—— 在正式服上手滑的代价不一样。
    return {"name": who.name, "environment": get_settings().environment}


# --- 玩家 -----------------------------------------------------------------------


@router.get("/admin/api/players")
async def search(q: str, _who: Me) -> dict:
    return {"players": await admin.search_players(q)}


@router.get("/admin/api/players/{player_id}")
async def player(player_id: uuid.UUID, _who: Me) -> dict:
    return await admin.player_detail(player_id)


class BanBody(BaseModel):
    days: int | None = None      # 不填 = 永久
    reason: str = Field(max_length=200)
    note: str = Field(default="", max_length=500)


class NoteBody(BaseModel):
    note: str = Field(default="", max_length=500)


@router.post("/admin/api/players/{player_id}/ban")
async def ban(player_id: uuid.UUID, body: BanBody, who: Writer) -> dict:
    return await admin.ban(who, player_id, body.days, body.reason, body.note)


@router.post("/admin/api/players/{player_id}/unban")
async def unban(player_id: uuid.UUID, body: NoteBody, who: Writer) -> dict:
    return await admin.unban(who, player_id, body.note)


class GrantBody(BaseModel):
    kind: Literal["grant_diamonds", "grant_coin"]
    amount: int
    reason: str = Field(max_length=200)
    request_key: uuid.UUID


@router.post("/admin/api/players/{player_id}/grant")
async def grant(player_id: uuid.UUID, body: GrantBody, who: Writer) -> dict:
    return await admin.request_grant(who, body.kind, player_id, body.amount, body.reason, body.request_key)


# --- 审批 -----------------------------------------------------------------------


@router.get("/admin/api/requests")
async def requests(_who: Me, all: bool = False) -> dict:  # noqa: A002 - 查询参数名
    return {"requests": await admin.list_requests(pending_only=not all)}


class DecisionBody(BaseModel):
    note: str = Field(default="", max_length=200)


@router.post("/admin/api/requests/{request_id}/approve")
async def approve(request_id: int, body: DecisionBody, who: Writer) -> dict:
    return await admin.decide(who, request_id, True, body.note)


@router.post("/admin/api/requests/{request_id}/reject")
async def reject(request_id: int, body: DecisionBody, who: Writer) -> dict:
    return await admin.decide(who, request_id, False, body.note)


@router.post("/admin/api/requests/{request_id}/cancel")
async def cancel(request_id: int, who: Writer) -> dict:
    return await admin.cancel(who, request_id)


# --- 邮件 -----------------------------------------------------------------------


class MailBody(BaseModel):
    to: str = Field(pattern=r"^(all|[0-9a-fA-F-]{36})$")
    title_zh: str = Field(max_length=60)
    body_zh: str = Field(default="", max_length=2000)
    title_en: str = Field(default="", max_length=60)
    body_en: str = Field(default="", max_length=2000)
    diamond: int = 0
    coin: int = 0
    items: list[str] = Field(default_factory=list, max_length=10)
    days: int = 30
    include_new_players: bool = False
    note: str = Field(default="", max_length=200)
    request_key: uuid.UUID


@router.post("/admin/api/mails")
async def send_mail(body: MailBody, who: Writer) -> dict:
    draft = admin.MailDraft(
        to=body.to.lower(), title_zh=body.title_zh, body_zh=body.body_zh, title_en=body.title_en,
        body_en=body.body_en, diamond=body.diamond, coin=body.coin, items=tuple(body.items),
        days=body.days, include_new_players=body.include_new_players, note=body.note)
    return await admin.submit_mail(who, draft, body.request_key)


@router.get("/admin/api/mails")
async def mails(_who: Me) -> dict:
    return {"mails": await admin.recent_mails(), "catalog": admin.attachable_items()}


@router.post("/admin/api/mails/{mail_id}/withdraw")
async def withdraw(mail_id: int, who: Writer) -> dict:
    return await admin.withdraw_mail(who, mail_id)


# --- 公告 -----------------------------------------------------------------------


class AnnouncementBody(BaseModel):
    kind: str = "news"
    status: str = "draft"
    title_zh: str = Field(max_length=60)
    body_zh: str = Field(default="", max_length=4000)
    title_en: str = Field(default="", max_length=80)
    body_en: str = Field(default="", max_length=8000)
    image: str = Field(default="", max_length=200)
    popup: bool = False
    sort_order: int = 0
    starts_at: str
    ends_at: str | None = None
    preview_codes: str = Field(default="", max_length=200)
    version: str | None = None
    bump_revision: bool = False


@router.get("/admin/api/announcements")
async def announcements(_who: Me) -> dict:
    return {"announcements": await admin.list_announcements()}


@router.post("/admin/api/announcements")
async def create_announcement(body: AnnouncementBody, who: Writer) -> dict:
    return await admin.save_announcement(who, None, body.model_dump(), None, False)


@router.put("/admin/api/announcements/{announcement_id}")
async def update_announcement(announcement_id: int, body: AnnouncementBody, who: Writer) -> dict:
    return await admin.save_announcement(who, announcement_id, body.model_dump(), body.version, body.bump_revision)


@router.post("/admin/api/announcements/image")
async def upload_image(request: Request, who: Writer) -> dict:
    # 原始字节，不走 multipart（那要多装一个依赖）。边收边数，超了就停。
    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > IMAGE_UPLOAD_MAX:
            raise HTTPException(status_code=413, detail="原图最大 10 MB")
        chunks.append(chunk)
    if not chunks:
        raise HTTPException(status_code=400, detail="没有收到图片")
    return await admin.upload_announcement_image(who, b"".join(chunks))


# --- 操作记录 -------------------------------------------------------------------


@router.get("/admin/api/audit")
async def audit(_who: Me) -> dict:
    return {"audit": await admin.recent_audit()}
