"""Authenticated pre-match party API. All changes are pushed and pollable."""

from __future__ import annotations

import logging
import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app import chat, db, friends, matchmaking, party, party_voice, players, profile, ranked, realtime, shop, text_guard
from app.config import get_settings
from app.jwt_verify import Claims
from app.rate_limit import RateLimited, SlidingWindowLimiter
from app.routes.me import current_claims

log = logging.getLogger("glory.party")

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


class KickBody(BaseModel):
    friend_code: str = Field(min_length=8, max_length=8)


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


# --- 组队邀请落成私聊消息（10.07 第 10 条）--------------------------------------
#
# 文案与客户端 PartyInviteBubble 的 invite_team_body 是**同一句话**。服务端存的是
# 中文原句（客户端渲染时若 kind 匹配会用自己的本地化文案，见 ChatScreen 的 _bubble），
# 这里存一份是为了让「聊天记录」在任何端上都能读出内容 —— 空 body 的邀请消息
# 在列表预览里会显示成空白，看起来像丢消息。

def _party_invite_text() -> str:
    return "快来加入队伍，一起战斗吧"


def _party_invite_client_msg_id(party_id: str, target_id: uuid.UUID) -> uuid.UUID:
    """给「(队伍, 收件人)」这一对算一个**稳定**的 client_msg_id。

    作用有两个，都靠 chat.send 里 `on conflict (sender_id, client_msg_id)` 那条唯一约束：
      1. 去重 —— 同一队伍反复邀同一个人，第二次 insert 冲突、返回老记录、不再推送；
      2. ★ 幂等 —— 队伍解散、重建，只要队伍号相同就不会重复打扰。
    用 uuid5（确定性哈希）而不是 uuid4：uuid4 每次都不同，去重就完全失效。
    """
    return uuid.uuid5(uuid.NAMESPACE_URL, "glory:party_invite:%s:%s" % (party_id, target_id))


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
    # ★ 10.07 第 10 条：组队邀请**同时落一条私聊消息**，再走 dm 推送。
    #
    # 真机反馈「第10点邀请没邀请消息」：原来是纯实时推送（下面那条 party_invite），
    # 收件人只见到一个气泡，聊天列表里什么都没有 ⇒ 也就没有红点、没法「已读」。
    # 现在改成与第 6 条（自定义房邀请，见 chat.ROOM_INVITE_KIND 的文件头）**同一套口径**：
    # 落库 + dm 推送，"有消息 + 有音效 + 有红点 + 可已读" 四件事全部白拿。
    #
    # 去重：同一个队伍对同一个人只落一条（chat._check_party_invite_rules）。
    # 重复邀请时 chat.send 抛 ChatRejected —— **不当错误**，因为下面那条实时推送
    # 仍然要发（玩家可能只是没看到气泡，再发一次让他再看一眼）。
    #
    # ★★ 10.07i 第 9(2) 条返工（用户真机反馈「再次修复后，发现邀请后没有邀请消息，
    #    要改成和自定义房间一样，邀请后要在聊天里收到对方的邀请消息」）：
    #    `chat.send` **只负责落库**，推送是调用方的事（见 routes/chat.py 的 send_message：
    #    它在 send 之后自己 `send_to_player` 一条 `{"t": "dm", ...}`）。
    #    上一版在这里把返回值丢掉了 —— 消息进了库，**却从来没推给收件人**：
    #    被邀请人不在线的下一次拉列表能看到，在线时则要等到重开聊天界面才看得到，
    #    表现就是「邀请后聊天里没有邀请消息」。
    #    现在照 routes/chat.py 的形状把同一条推送补上。
    #    `deliver_to is None` 表示「被静默丢弃」或「重发」，两种情况都不推
    #    —— 与 routes/chat.py 的判据逐字一致。
    #
    # ★★ 10.07n 加固（线上事故：排位里邀请好友 → 「服务器出错了（HTTP 500）」）：
    #    事故成因是**迁移没跟上代码** —— 第 10 条用的 kind='party_invite' 不在
    #    chat_messages 那条 check 约束里（020 只放行 text / room_invite），
    #    insert 抛 CheckViolationError。它不属于 ChatRejected，冒到接口层就是 500。
    #    约束本身已由 database/030_chat_party_invite.sql 放宽 —— 那是**根治**；
    #    这里补的是**兜底**，理由是后果的严重性不对称：
    #      · 上面 `party.current().invite()` **已经改完内存状态**了；
    #      · 下面那条 party_invite 实时推送还没发。
    #    于是出事的瞬间最坏：邀请在服务端算数、房主看到报错、被邀请人完全不知情
    #    —— 表现就是「拉不了好友」，而且没有任何一边拿到可用的信息。
    #    ⇒ 私聊这条消息是**锦上添花**（气泡 / 红点 / 可已读），它失败只该降级、
    #      不该拦路：记一笔日志，然后照常发实时推送，至少「拉好友」这件事是成的。
    #    下次真机日志里看到这行，就去检查对应迁移跑没跑。
    try:
        sent = await chat.send(
            me.player_id,
            code,
            _party_invite_text(),
            _party_invite_client_msg_id(room.id, target.player_id),
            chat.PARTY_INVITE_KIND,
            {"party_id": room.id, "mode": room.mode},
        )
    except chat.ChatRejected:
        # 已经邀过同一个人（chat._check_party_invite_rules）：库里那条还在，不重落、不重推。
        sent = None
    except Exception as exc:  # noqa: BLE001 - 见上面 10.07n 那段，故意的宽捕获
        log.warning(
            "组队邀请的私聊消息没落上（%s: %s），改为只走实时推送 —— "
            "若为 CheckViolationError 请确认 database/030_chat_party_invite.sql 跑过 party=%s",
            type(exc).__name__, exc, room.id,
        )
        sent = None
    if sent is not None and sent.deliver_to is not None:
        # 形状与 routes/chat.py 的 MessageItem 一致（客户端两个入口共用一条解析）：
        # **少一个字段不会报错，只是那半边静默失效**，所以这里逐字段对齐。
        await realtime.hub().send_to_player(sent.deliver_to, {
            "t": "dm",
            "from": me.friend_code,
            "message": {
                "message_id": sent.message.message_id,
                "from_me": False,
                "body": sent.message.body,
                "created_at": sent.message.created_at.isoformat(),
                "kind": sent.message.kind,
                "payload": sent.message.payload,
            },
        })
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
        # 已经凑成一桌、在等六个人确认时走开 = 拒绝这一桌：拆桌，队友整队回房间（matchmaking._dissolve）。
        matchmaking.current().leave(me.player_id)
        service.mark_idle(room)
        # ★★ 10.07h 第 9(6) 条返工（用户真机反馈「其他成员取消了排位，但房主依然是
        #    显示匹配中，现改为：任意成员取消排位后，所有人返回房间，匹配中的弹窗
        #    自动关闭，并且提示 XXX（昵称，无数字 ID）取消了排队」）：
        #
        #    原来这里对**所有人**推一模一样的裸 `idle_message()`（无 reason、无名字）。
        #    客户端只能看出「队列没了」，推不出「是谁取消的」—— 于是房主那边的
        #    「匹配中」弹窗既不知道该关，也不知道该提示谁。
        #
        #    现在给**除取消者以外**的成员带上 `cancelled_by`（昵称，**不带 #ID**），
        #    取消者自己仍然收裸 idle（他就是那个动作的发起人，不用被通知）。
        my_name = str((room.profiles.get(me.player_id) or {}).get("player_name", ""))
        for pid in affected:
            if pid == me.player_id:
                await realtime.hub().send_to_player(pid, matchmaking.idle_message())
            else:
                await realtime.hub().send_to_player(
                    pid, matchmaking.idle_message("party_cancelled", by_name=my_name))
    room, old_members, closed, migrated = service.leave(me.player_id)
    if room is not None:
        if closed:
            await service.notify_closed(old_members)
        else:
            await realtime.hub().send_to_player(me.player_id, {"t": "party", "state": "closed"})
            if migrated:
                # ★★ 10.07i 第 9(4) 条返工（用户真机反馈「现在房主退出后，房间依旧解散，
                #    非房主成员强制被返回主界面。要改成非房主成员要在房主离开后自动成为
                #    房主，且由进入房间时间更长的玩家担任」）：
                #
                #    交接本身在 `party.Parties.leave()` 里是对的（successor = 进房最早者）。
                #    问题在**通知**：这条 `host_left` 只发给了**退出的房主本人**，
                #    留下来的成员什么也没收到。成员侧只能等下面那条 `broadcast`，
                #    万一它丢/晚（弱网、切后台、刚好在重连），成员就停在旧房主视图 ——
                #    表现就是「房主没了、房间好像散了」，于是被自己的兜底逻辑踢回主界面。
                #
                #    现在把 `host_left` 发给**其余成员**（`old_members` 去掉退出者）。
                #    成员收到后立刻 `_refresh_room_now()` 自证一次，界面就地换成
                #    「我是房主」；不必依赖 broadcast 的时序。
                new_host_code = str(room.profiles.get(room.host, {}).get("friend_code", ""))
                for pid in old_members:
                    if pid == me.player_id:
                        continue
                    await realtime.hub().send_to_player(pid, {
                        "t": "party_notice", "kind": "host_left",
                        "text": "房主已退出队伍", "host_code": new_host_code,
                        "members": old_members,
                    })
            await service.broadcast(room)
    return StateResponse(state={"t": "party", "state": "none"})


@router.post("/kick", response_model=StateResponse)
async def kick(body: KickBody,
               claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    """房主把成员移出队伍（10-08，对齐自定义房间座位上的「×」）。"""
    me = await _me(claims)
    service = party.current()
    room = service.of(me.player_id)
    code = body.friend_code.strip().upper()
    target = None
    if room is not None:
        target = next((pid for pid, card in room.profiles.items()
                       if str(card.get("friend_code", "")).upper() == code), None)
    if target is None:
        raise HTTPException(status_code=409, detail="这位玩家已经不在队伍里")
    try:
        room = service.kick(me.player_id, target)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    # 先说为什么、再说房间没了：客户端收到 closed 会去复查房间、退回主界面，提示要赶在那之前。
    await realtime.hub().send_to_player(target, {
        "t": "party_notice", "kind": "kicked", "text": "你被房主移出了队伍"})
    await realtime.hub().send_to_player(target, {"t": "party", "state": "closed"})
    await service.broadcast(room)
    return StateResponse(state=service.snapshot(room))


@router.put("/mode", response_model=StateResponse)
async def mode(body: ModeBody,
               claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    me = await _me(claims)
    try:
        room = party.current().mode(me.player_id, body.mode)
    except party.PartyRejected as exc:
        raise _reject(exc) from None
    label = "休闲" if body.mode == "casual" else "排位"
    notice = {"t": "party_notice", "kind": "mode_changed", "mode": body.mode,
              "text": f"房主更换了{label}模式"}
    # 广播房间状态前先给非房主成员推条提示，让客户端弹提示语。
    for pid in room.members:
        if pid != me.player_id:
            await realtime.hub().send_to_player(pid, notice)
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
    # 确认阶段按取消 = 拒绝这一桌（同 leave 路由）：不拆的话那一桌会一直等他确认，超时还要罚他。
    matchmaking.current().leave(me.player_id)
    if not members:
        # 兜底：匹配服务里已经查不到这条队列，也别把整队卡在 queued 上。
        members = room.members.copy()
    service.mark_idle(room)
    await service.broadcast(room)
    # 任意成员取消都让全队回到房间：给所有人发 idle，客户端据此收起匹配界面。
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
    if len(members) not in matchmaking.PARTY_SIZES:
        raise HTTPException(status_code=409, detail="只能单人或满 3 人开始匹配，再邀请一位好友吧",
                            headers={"X-Glory-Reason": "party_size"})
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
async def send_chat(body: ChatBody,
                    claims: Annotated[Claims, Depends(current_claims)]) -> StateResponse:
    """队内聊天。

    ★★ 这个函数**不能**叫 `chat`（2026-10-07 线上事故，10.07n 修）。
    模块顶部有 `from app import chat, …`（私聊模块，invite() 要拿它落邀请消息）。
    Python 的模块顶层名只有一个命名空间 ⇒ 再定义一个 `async def chat` 会**把那个
    import 整个盖掉**，而且不报错、不警告：

        invite() 里的 chat.send(...)  →  实际拿到的是**这个路由函数**
                                      →  AttributeError: 'function' object has no attribute 'send'
                                      →  不在 except chat.ChatRejected 里  →  HTTP 500

    真机表现：排位房间里点「邀请好友」→「服务器出错了（HTTP 500），稍后再试」。
    HTTP 路径由上面的装饰器决定，函数名只影响 OpenAPI 的 operationId，
    所以改成 `send_chat` 对客户端没有任何影响（另一条先例：routes/chat.py 的
    send_message 也不叫 chat）。判据见
    backend/tests/test_no_module_shadowing_stdlib.py —— 全 backend 一律不许
    顶层定义和 import 进来的模块同名。
    """
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
