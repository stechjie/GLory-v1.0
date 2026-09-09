"""玩家资料接口。

    GET   /v1/me/profile              自己的完整资料（含隐藏字段与可见性开关）
    PATCH /v1/me/profile              昵称 / 头像 / 头像框 / 展示宠物
    PUT   /v1/me/bio                  性别 / 生日 / 地区 / 签名 + 可见性
    GET   /v1/players/by-code/{code}  公开视图

设计文档：docs/玩家资料系统设计.md。

**自己看自己刻意只有一个 GET**，不拆成 /me + /me/bio 两次往返 ——
底层本来就是一次 join，拆开只会让资料页发两个并发请求，
多一处会出「头像到了、名字没到」的中间态。

**公开视图用好友码定位，不用 player_id。** player_id 是内部身份，
没必要出现在客户端可见的地址里。
"""

from __future__ import annotations

import logging
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path
from pydantic import BaseModel, Field

from app import avatar_catalog, db, players, profile, text_guard
from app.jwt_verify import Claims
from app.routes.me import current_claims

log = logging.getLogger("glory.profile")

router = APIRouter(prefix="/v1", tags=["profile"])

# 与 database/002_player_bio.sql 的 gender_allowed 一致。
#
# 'undisclosed' 仍然合法（老数据里有），但**新客户端一律不写它** ——
# 「不显示」统一走 gender_visibility 开关。同一件事有两种表示法，
# 以后必然出不一致，见 docs/玩家资料系统设计.md 第三节。
GENDERS = {"male", "female", "other", "undisclosed"}
VISIBILITIES = {"public", "private"}


# --- 响应模型 -----------------------------------------------------------------


class SelfProfileResponse(BaseModel):
    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    showcase_pet: str | None
    days_since_created: int
    # null 表示「还没设过」。设过之后前端要把生日输入框变只读 —— 只能设一次。
    gender: str | None
    birth_month: int | None
    birth_day: int | None
    region: str | None
    signature: str | None
    gender_visibility: str
    birth_visibility: str
    region_visibility: str
    # 冷却中才有值（ISO 时间串）。null = 现在就能改名。
    rename_available_at: str | None


class PublicProfileResponse(BaseModel):
    """陌生人看到的。

    ⚠️ **隐藏字段不在这个模型里出现，而不是出现但为 null。**
    路由上挂了 response_model_exclude_none=True，所以 private 的字段
    在 JSON 里连 key 都没有。门禁直接断言 key 不存在。

    副作用是「没填」和「填了但隐藏」对观众完全一样 —— 这是**想要的**：
    观众不该能分辨出对方是没写生日，还是写了不给他看。
    """

    friend_code: str
    player_name: str
    avatar: str
    avatar_frame: str
    days_since_created: int
    showcase_pet: str | None = None
    gender: str | None = None
    birth_month: int | None = None
    birth_day: int | None = None
    region: str | None = None
    signature: str | None = None


# --- 请求模型 -----------------------------------------------------------------


class IdentityPatch(BaseModel):
    """全部可选：只改传上来的那几个字段。

    showcase_pet 的三态：不传 = 不动；传字符串 = 设置；传 "" = 清空。
    用一个 null 同时表达「不动」和「清空」是这类接口最经典的 bug。
    """

    player_name: str | None = None
    avatar: str | None = None
    avatar_frame: str | None = None
    showcase_pet: str | None = None


class BioPut(BaseModel):
    """整份覆盖。签名传空串或不传都表示清空 —— 清空即删除，没有单独的删除接口。"""

    gender: str | None = None
    birth_month: int | None = Field(default=None, ge=1, le=12)
    birth_day: int | None = Field(default=None, ge=1, le=31)
    region: str | None = None
    signature: str | None = None
    gender_visibility: str = "public"
    birth_visibility: str = "public"
    region_visibility: str = "public"


# --- 组装 ---------------------------------------------------------------------


def _require_db() -> None:
    if not db.is_connected():
        raise HTTPException(
            status_code=503,
            detail="数据库未配置：backend/.env 里的 GLORY_DATABASE_URL 是空的",
        )


async def _current_profile(claims: Claims) -> profile.SelfProfile:
    _require_db()
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="该身份没有对应的玩家，请重新登录")
    row = await profile.get_self(player.player_id)
    if row is None:
        # 上一句刚查到玩家，这里查不到只可能是并发删号。
        raise HTTPException(status_code=404, detail="玩家资料不存在")
    return row


def to_self(row: profile.SelfProfile) -> SelfProfileResponse:
    ready = row.rename_available_at()
    return SelfProfileResponse(
        friend_code=row.friend_code,
        player_name=row.player_name,
        avatar=row.avatar,
        avatar_frame=row.avatar_frame,
        showcase_pet=row.showcase_pet,
        days_since_created=row.days_since_created,
        gender=row.gender,
        birth_month=row.birth_month,
        birth_day=row.birth_day,
        region=row.region,
        signature=row.signature,
        gender_visibility=row.gender_visibility,
        birth_visibility=row.birth_visibility,
        region_visibility=row.region_visibility,
        rename_available_at=ready.isoformat() if ready else None,
    )


def to_public(row: profile.SelfProfile) -> PublicProfileResponse:
    """**裁剪的唯一实现。** 门禁钉着这个函数。

    private 的字段在这里就不进模型 —— 不是「返回了再让客户端别显示」。
    加新字段时必须想清楚它属于哪一档，否则默认就泄漏了。
    """
    public = PublicProfileResponse(
        friend_code=row.friend_code,
        player_name=row.player_name,
        avatar=row.avatar,
        avatar_frame=row.avatar_frame,
        days_since_created=row.days_since_created,
        showcase_pet=row.showcase_pet,
    )
    if row.gender_visibility == "public":
        public.gender = row.gender
    if row.birth_visibility == "public":
        public.birth_month = row.birth_month
        public.birth_day = row.birth_day
    if row.region_visibility == "public":
        public.region = row.region
    # 签名刻意没有开关：它是表达，清空即隐藏。
    public.signature = row.signature
    return public


# --- 接口 ---------------------------------------------------------------------


@router.get("/me/profile", response_model=SelfProfileResponse)
async def me_profile(
    claims: Annotated[Claims, Depends(current_claims)],
) -> SelfProfileResponse:
    return to_self(await _current_profile(claims))


@router.patch("/me/profile", response_model=SelfProfileResponse)
async def patch_me_profile(
    body: IdentityPatch,
    claims: Annotated[Claims, Depends(current_claims)],
) -> SelfProfileResponse:
    row = await _current_profile(claims)

    name: str | None = None
    if body.player_name is not None:
        try:
            name = text_guard.clean_player_name(body.player_name)
        except text_guard.TextRejected as exc:
            raise HTTPException(status_code=400, detail=exc.message) from None

    avatar: str | None = None
    frame: str | None = None
    try:
        if body.avatar is not None:
            avatar = avatar_catalog.check_avatar(body.avatar)
        if body.avatar_frame is not None:
            frame = avatar_catalog.check_frame(body.avatar_frame)
    except avatar_catalog.AvatarRejected as exc:
        raise HTTPException(status_code=400, detail=exc.message) from None

    clear_pet = body.showcase_pet == ""
    pet = None if clear_pet else body.showcase_pet

    try:
        updated = await profile.update_identity(
            row.player_id,
            player_name=name,
            avatar=avatar,
            avatar_frame=frame,
            showcase_pet=pet,
            clear_showcase_pet=clear_pet,
        )
    except profile.ProfileRejected as exc:
        raise HTTPException(status_code=409, detail=exc.message) from None
    return to_self(updated)


@router.put("/me/bio", response_model=SelfProfileResponse)
async def put_me_bio(
    body: BioPut,
    claims: Annotated[Claims, Depends(current_claims)],
) -> SelfProfileResponse:
    row = await _current_profile(claims)

    if body.gender is not None and body.gender not in GENDERS:
        raise HTTPException(status_code=400, detail="性别取值不合法")
    for value in (body.gender_visibility, body.birth_visibility, body.region_visibility):
        if value not in VISIBILITIES:
            raise HTTPException(status_code=400, detail="可见性取值不合法")

    # 月日要么都填要么都不填。database/002 有同名约束，这里先挡是为了给 400 而不是 500。
    if (body.birth_month is None) != (body.birth_day is None):
        raise HTTPException(status_code=400, detail="生日的月和日要一起填")

    region = body.region.upper() if body.region else None
    if region is not None and (len(region) != 2 or not region.isalpha()):
        raise HTTPException(status_code=400, detail="地区要是两位国家代码")

    try:
        signature = text_guard.clean_signature(body.signature)
    except text_guard.TextRejected as exc:
        raise HTTPException(status_code=400, detail=exc.message) from None

    updated = await profile.update_bio(
        row.player_id,
        gender=body.gender,
        birth_month=body.birth_month,
        birth_day=body.birth_day,
        region=region,
        signature=signature,
        gender_visibility=body.gender_visibility,
        birth_visibility=body.birth_visibility,
        region_visibility=body.region_visibility,
    )
    return to_self(updated)


@router.get(
    "/players/by-code/{code}",
    response_model=PublicProfileResponse,
    response_model_exclude_none=True,
)
async def public_profile(
    code: Annotated[str, Path(min_length=8, max_length=8)],
) -> PublicProfileResponse:
    """公开视图。**不需要登录** —— 它只返回玩家自己选择公开的内容。

    好友码是大小写不敏感的：玩家会照着截图手抄，不该因为按了大写锁失败。
    库里存的一律是大写。
    """
    _require_db()
    row = await profile.get_by_friend_code(code.upper())
    if row is None:
        raise HTTPException(status_code=404, detail="没有这个好友码")
    return to_public(row)
