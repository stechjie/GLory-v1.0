"""语音消息的上传口（app/voice_clips.py、database/033_voice_clips.sql）。

    POST /v1/voice/clips?scope=private|world|match
      Content-Type: audio/wav        请求体就是录音本身（16 kHz 单声道 16 位 WAV）
      -> {"clip_id": "...", "seconds": 12.3, "media": "<sha256>.ogg"}

拿到 clip_id 之后，三个渠道各自按自己的路发消息：私聊与世界频道走账号服务器落库，
房间与对局内走战斗服务器转发（不落库）。**这里不碰消息，只负责文件。**

## 🔴 这是账号服务器上第一个「玩家能往里写文件」的口

在它之前，媒体目录只有服务器自己写（公告图片是服务端去取回来再转的）。所以这里的每一道
都不是洁癖：大小上限、时长上限、重新编码、每天与每分钟的配额、过期清理。
少任何一道，这台机器就成了别人的免费网盘。
"""

from __future__ import annotations

import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel

from app import db, players, voice_clips
from app.config import get_settings
from app.jwt_verify import Claims
from app.routes.me import current_claims

log = logging.getLogger("glory.routes.voice")

router = APIRouter(prefix="/v1", tags=["voice"])


class ClipResponse(BaseModel):
    clip_id: uuid.UUID
    seconds: float
    media: str


async def _me(claims: Claims) -> players.Player:
    if not db.is_connected():
        raise HTTPException(status_code=503, detail="数据库未配置")
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    return player


@router.post("/voice/clips", response_model=ClipResponse)
async def upload_clip(
    request: Request,
    claims: Annotated[Claims, Depends(current_claims)],
    scope: Annotated[str, Query(pattern="^(private|world|match)$")] = "private",
) -> ClipResponse:
    me = await _me(claims)

    # 先看 Content-Length 再读 body：超大的请求不该先被完整读进内存再拒。
    # 这个头是客户端写的，所以下面读完还要再量一次真实长度。
    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > voice_clips.MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="录音太大了，请重录",
                            headers={"X-Glory-Reason": "too_large"})
    body = await request.body()
    if len(body) > voice_clips.MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="录音太大了，请重录",
                            headers={"X-Glory-Reason": "too_large"})

    try:
        clip = await voice_clips.upload(me.player_id, scope, body, get_settings().media_dir)
    except voice_clips.ClipRejected as exc:
        raise HTTPException(status_code=exc.status, detail=exc.message,
                            headers={"X-Glory-Reason": exc.code}) from None
    return ClipResponse(clip_id=clip.clip_id, seconds=clip.seconds, media=clip.media_name)
