"""公告接口（docs/公告系统设计.md）。

    GET /v1/announcements       当前看得到的公告。读进程内快照，不查公告表
    GET /media/{sha256}.{ext}   公告图片

## /media 平时走不到这里

生产上 Caddy 直接从 /var/lib/glory-media 给文件（deploy/Caddyfile）。请求能走到这个路由，
说明服务器上的 Caddy 配置还是旧版 —— 照样能用，只是每张图多过一道 Python。
留着它是为了部署顺序不咬人：先更新了后端、还没来得及改 Caddy 时，图片不会全部 404。
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Annotated

import asyncpg
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel

from app import announcements, db, players
from app.config import get_settings
from app.jwt_verify import Claims
from app.routes.me import current_claims

log = logging.getLogger("glory.announcements")

router = APIRouter(tags=["announcements"])


class ImageItem(BaseModel):
    # 相对地址（/media/...）。客户端拼上自己连的那个账号服务器地址 ——
    # 这样 --backend-url 切到本机时图片也跟着切过去。
    url: str
    # 客户端下载完用它校验：拿到的就是服务器检查过的那份字节，一个都不差。
    sha256: str
    width: int
    height: int
    size: int


class AnnouncementItem(BaseModel):
    id: int
    revision: int
    kind: str
    title_zh: str
    body_zh: str
    title_en: str
    body_en: str
    image: ImageItem | None = None
    popup: bool
    # Unix 秒。不发 ISO 串：Godot 解析 ISO 时区后缀的行为不可靠，秒数没有歧义。
    starts_at: int
    ends_at: int | None = None
    # 只因为预览好友码才看得到（草稿、还没开始的）。
    preview: bool = False
    # 只发给预览账号；普通玩家恒为空串。
    problem: str = ""


class AnnouncementsResponse(BaseModel):
    """列表包一层对象，不返回顶层数组 —— 客户端 _request 只接受 Dictionary（同 routes/chat.py）。"""

    announcements: list[AnnouncementItem]
    server_time: int


async def _friend_code(claims: Claims) -> str | None:
    """查「你是谁」，只为预览。**查不到就当普通玩家**，不让整份公告跟着失败。"""
    if not db.is_connected():
        return None
    try:
        player = await players.get_by_auth_uid(claims.auth_uid)
    except (asyncpg.PostgresError, OSError, db.NotConfigured):
        log.warning("查预览身份失败，按普通玩家返回公告", exc_info=True)
        return None
    return player.friend_code if player is not None else None


def _image_item(info: announcements.ImageInfo | None) -> ImageItem | None:
    if info is None:
        return None
    return ImageItem(url=f"/media/{info.filename}", sha256=info.sha256,
                     width=info.width, height=info.height, size=info.size)


@router.get("/v1/announcements", response_model=AnnouncementsResponse)
async def list_announcements(
    claims: Annotated[Claims, Depends(current_claims)],
) -> AnnouncementsResponse:
    board = announcements.current()
    code = await _friend_code(claims) if board.needs_identity() else None
    items: list[AnnouncementItem] = []
    for entry, preview in board.view_for(code):
        row = entry.row
        tester = code is not None and code in entry.preview_codes
        items.append(AnnouncementItem(
            id=row.announcement_id,
            revision=row.revision,
            kind=row.kind,
            title_zh=row.title_zh,
            body_zh=row.body_zh,
            title_en=row.title_en,
            body_en=row.body_en,
            image=_image_item(entry.image),
            popup=row.popup,
            starts_at=int(row.starts_at.timestamp()),
            ends_at=int(row.ends_at.timestamp()) if row.ends_at is not None else None,
            preview=preview,
            problem=entry.problem if tester else "",
        ))
    return AnnouncementsResponse(announcements=items, server_time=int(board.now().timestamp()))


@router.get("/media/{name}")
async def media(name: str) -> FileResponse:
    matched = announcements.MEDIA_NAME_RE.fullmatch(name)
    media_dir = get_settings().media_dir.strip()
    if matched is None or not media_dir:
        raise HTTPException(status_code=404, detail="没有这张图")
    path = Path(media_dir) / name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="没有这张图")
    # 文件名就是内容哈希，永远不变，所以可以让手机永久缓存。
    return FileResponse(
        path,
        media_type=announcements.MEDIA_TYPES[matched.group(1)],
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )
