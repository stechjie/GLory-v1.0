"""Authenticated pre-match party API. All changes are pushed and pollable."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app import db, friends, matchmaking, party, party_voice, players, profile, ranked, realtime, shop, text_guard
from app.config import get_settings
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

router = APIRouter(prefix="/v1/party", tags=["party"])
_chat_limiter = SlidingWindowLimiter(30, 60.0)
_invite_limiter = SlidingWindowLimiter(12, 60.0)
_voice_limiter = SlidingWindowLimiter(8, 60.0)


class CreateBody(BaseModel):
    mode: str = "casual"


class InviteBody(BaseModel):
    friend_code: str = Field(min_length=8, max_length=8)


class JoinBody(BaseModel):
    party_id: str = Field(min_length=8, max_length=64)


class ModeBody(BaseModel):
    mode: str


class PetsBody(BaseModel):
    pets: list[str] = Field(max_length=party.MAX_PETS)


class ReadyBody(BaseModel):
    ready: bool


class ChatBody(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


class StateResponse(BaseModel):
    state: dict


class VoiceResponse(BaseModel):
    url: str
    room: str
    token: str


async def _me(claims: Claims) -> players.Player:
    if not db.is_connected():
        raise HTTPException(status_code=503, detail="账号数据库暂不可用")
    player = await players.get_by_auth_uid(claims.auth_uid)
    if player is None:
        raise HTTPException(status_code=404, detail="找不到玩家账号")
    return player


def _reject(exc: party.PartyRejected) -> HTTPException:
    status = 403 if exc.code == "not_host" else 409
    return HTTPException(status_code=status, detail=exc.message,
                         headers={"X-Glory-Reason": exc.code})


async def _public_card(player_id: uuid.UUID) -> dict:
    row = await profile.get_self(player_id)
    if row is None:
        raise HTTPException(status_code=404, detail="找不到玩家资料")
    async with db.pool().acquire() as conn:
        rank_row = await conn.fetchrow(
            "select score from player_ranked where player_id = $1", player_id)
    return {
        "friend_code": row.friend_code, "player_name": row.player_name,
        "avatar": row.avatar, "avatar_frame": row.avatar_frame,
        "tier": ranked.tier_of(int(rank_row["score"])) if rank_row else -1,
    }


@router.get("", response_model=StateResponse)
async def state(claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    return StateResponse(state=party.current().state_of(me.player_id))


@router.get("/voice-token", response_model=VoiceResponse)
async def voice_token(claims: Annotated[Claims, Depends(current_claims)]) -> VoiceResponse:
    me = await _me(claims)
    try:
        _voice_limiter.check(str(me.player_id))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="获取语音连接太频繁") from exc
    room = party.current().of(me.player_id)
    if room is None:
        raise HTTPException(status_code=409, detail="你还没有进入队伍")
    try:
        config = party_voice.load_config(get_settings().party_voice_config_file)
    except party_voice.VoiceUnavailable as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from None
    card = room.profiles[me.player_id]
    room.voice_used = True
    return VoiceResponse(**party_voice.issue(
        config, room.id, room.voice_epoch,
        card["friend_code"], card["player_name"]))


@router.post("", response_model=StateResponse)
async def create(body: CreateBody,
                 claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    if matchmaking.current().state_of(me.player_id)["state"] != "idle":
        raise HTTPException(status_code=409, detail="请先结束当前匹配")
    try:
        pets = (await shop.read_pets(me.player_id)).owned[:party.MAX_PETS]
        room = party.current().create(me.player_id, await _public_card(me.player_id),
                                      body.mode, pets)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    return StateResponse(state=party.current().snapshot(room))


@router.post("/invite", response_model=StateResponse)
async def invite(body: InviteBody,
                 claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    code = body.friend_code.strip().upper()
    try:
        _invite_limiter.check(str(me.player_id))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="邀请太频繁，请稍后再试") from exc
    try:
        relation = await friends.relation_to(me.player_id, code)
    except friends.FriendsRejected:
        relation = "none"
    if relation != "friends":
        raise HTTPException(status_code=403, detail="只能邀请自己的好友")
    target = await profile.get_by_friend_code(code)
    if target is None or not realtime.hub().is_online(target.player_id):
        raise HTTPException(status_code=409, detail="好友当前不在线")
    try:
        room = party.current().invite(me.player_id, target.player_id)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    await realtime.hub().send_to_player(target.player_id, {
        "t": "party_invite", "party_id": room.id, "mode": room.mode,
        "host_name": room.profiles[room.host]["player_name"],
        "host_code": room.profiles[room.host]["friend_code"],
        "expires_sec": int(party.INVITE_TTL_SEC),
    })
    return StateResponse(state=party.current().snapshot(room))


@router.post("/join", response_model=StateResponse)
async def join(body: JoinBody,
               claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    if matchmaking.current().state_of(me.player_id)["state"] != "idle":
        raise HTTPException(status_code=409, detail="请先结束当前匹配")
    try:
        room = party.current().join(me.player_id, body.party_id,
                                    await _public_card(me.player_id))
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    await party.current().broadcast(room)
    return StateResponse(state=party.current().snapshot(room))


@router.delete("", response_model=StateResponse)
async def leave(claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    service = party.current()
    room = service.of(me.player_id)
    if room is not None and room.queued:
        affected = matchmaking.current().leave_group(me.player_id)
        service.mark_idle(room)
        for pid in affected:
            await realtime.hub().send_to_player(pid, matchmaking.idle_message())
    room, old_members, closed = service.leave(me.player_id)
    if room is not None:
        if closed:
            await service.notify_closed(old_members)
        else:
            await realtime.hub().send_to_player(me.player_id, {"t": "party", "state": "closed"})
            await service.broadcast(room)
    return StateResponse(state={"t": "party", "state": "none"})


@router.put("/mode", response_model=StateResponse)
async def mode(body: ModeBody,
               claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    try:
        room = party.current().mode(me.player_id, body.mode)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    await party.current().broadcast(room)
    return StateResponse(state=party.current().snapshot(room))


@router.put("/pets", response_model=StateResponse)
async def pets(body: PetsBody,
               claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    owned = set((await shop.read_pets(me.player_id)).owned)
    if any(pet_id not in owned for pet_id in body.pets):
        raise HTTPException(status_code=403, detail="只能展示自己拥有的宠物")
    try:
        room = party.current().pets(me.player_id, body.pets)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    await party.current().broadcast(room)
    return StateResponse(state=party.current().snapshot(room))


@router.put("/ready", response_model=StateResponse)
async def ready(body: ReadyBody,
                claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    try:
        room = party.current().set_ready(me.player_id, body.ready)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    await party.current().broadcast(room)
    return StateResponse(state=party.current().snapshot(room))


@router.post("/cancel", response_model=StateResponse)
async def cancel(claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    service = party.current()
    try:
        room = service.queued_room(me.player_id)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    members = matchmaking.current().leave_group(me.player_id)
    service.mark_idle(room)
    await service.broadcast(room)
    for pid in members:
        await realtime.hub().send_to_player(pid, matchmaking.idle_message())
    return StateResponse(state=service.snapshot(room))


@router.post("/start", response_model=StateResponse)
async def start(claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    service = party.current()
    try:
        room, members = service.members_for_start(me.player_id)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    version = room.version
    if room.mode not in matchmaking.OPEN_MODES:
        raise HTTPException(status_code=409, detail="这个模式还未开放")
    async with db.pool().acquire() as conn:
        for pid in members:
            reason = await ranked.queue_gate(conn, pid, room.mode)
            if reason:
                raise HTTPException(status_code=409, detail=(
                    "有队员暂时不能排位或休闲，请检查开放时间、禁赛与信誉分"))
        rows = await conn.fetch(
            "select player_id, score from player_ranked where player_id = any($1::uuid[])", members)
    ratings = {row["player_id"]: int(row["score"]) for row in rows}
    try:
        room = service.mark_queued(me.player_id, version)
        matchmaking.current().join_group(members, room.mode, ratings)
    except (party.PartyRejected, ValueError) as exc:
        service.mark_idle(room)
        if isinstance(exc, party.PartyRejected):
            raise _reject(exc) from None
        raise HTTPException(status_code=409, detail=str(exc)) from None
    await service.broadcast(room)
    for pid in members:
        await realtime.hub().send_to_player(pid, matchmaking.current().state_of(pid))
    return StateResponse(state=service.snapshot(room))


@router.post("/chat", response_model=StateResponse)
async def chat(body: ChatBody,
               claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    try:
        _chat_limiter.check(str(me.player_id))
    except RateLimited as exc:
        raise HTTPException(status_code=429, detail="发言太快，请稍后再试") from exc
    try:
        clean = text_guard.clean_chat_message(body.text)
    except text_guard.TextRejected as exc:
        raise HTTPException(status_code=400, detail=exc.message) from None
    try:
        room = party.current().say(me.player_id, clean)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    await party.current().broadcast(room)
    return StateResponse(state=party.current().snapshot(room))
