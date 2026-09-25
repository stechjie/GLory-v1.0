"""WebSocket 端点（`docs/聊天系统设计.md` 批次 B）。

    ws(s)://<backend>/v1/ws
      Authorization:     Bearer <supabase access_token>
      X-Device-Session:  <客户端生成的设备标识>
      X-Glory-Admission: enter | resume   （可选，旧版客户端不带；见 app/admission.py）

## 🔴 令牌走 header，不走 query string

`?token=xxx` 是 WebSocket 认证最常见的写法，因为浏览器的 `WebSocket` 构造器
不让设自定义头。**我们不受那个限制** —— 客户端是 Godot，
`WebSocketPeer.handshake_headers` 可以直接带 `Authorization`。

而 query string 会被写进每一层的访问日志（Caddy、反向代理、任何中间设备），
那等于把凭证抄进日志文件。同一条理由让 `jwt_verify.py` 的注释写着
「令牌本身是凭证，任何日志与异常都不准带上它」。

## 认证在 accept 之前完成

没通过就直接 `close()`，**不 accept**。未认证的连接不该拿到任何资源，
也不该进连接表。代价是客户端只拿得到一个关闭码、拿不到错误文案 ——
可以接受：它刚刚才发出令牌，认证失败的原因基本只有「过期了」，
刷新一次重连即可。
"""

from __future__ import annotations

import json
import logging
import re

from fastapi import APIRouter
from starlette.websockets import WebSocket, WebSocketDisconnect

from app import admission, bans, db, matchmaking, players, realtime
from app.config import get_settings
from app.jwt_verify import TokenError
from app.realtime import Connection
from app.routes.me import get_verifier

log = logging.getLogger("glory.ws")

router = APIRouter(tags=["ws"])

# 标准关闭码。1008 = Policy Violation，用于「你不该连进来」这一类。
CLOSE_POLICY = 1008
CLOSE_UNAVAILABLE = 1013  # Try Again Later：服务端没配好，不是客户端的错

# 设备标识的形状。客户端自己生成、自己持久化，服务端**不解释它的含义**，
# 只把它当成一个不透明串用来区分「同一台设备重连」与「换了台设备」。
#
# 仍然要校验：它会进日志。不限长度和字符集的话，一个构造出来的值就能往日志里
# 塞换行、控制字符、几 MB 的垃圾 —— 那是日志注入，也是磁盘攻击。
# 同 text_guard 对昵称做结构管控的理由。
_DEVICE_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


@router.websocket("/v1/ws")
async def realtime_endpoint(websocket: WebSocket) -> None:
    settings = get_settings()
    if not settings.supabase_url or not db.is_connected():
        # 配置没齐时 fail closed，且用一个**可区分**的码 ——
        # 让客户端知道这是「服务端没准备好，等会儿再来」，而不是「你的令牌不对」。
        # 两者的正确反应完全不同（重连 vs 重新登录）。
        await websocket.close(code=CLOSE_UNAVAILABLE)
        return

    device = websocket.headers.get("x-device-session", "")
    if not _DEVICE_RE.match(device):
        await websocket.close(code=CLOSE_POLICY)
        return

    authorization = websocket.headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        await websocket.close(code=CLOSE_POLICY)
        return

    try:
        claims = await get_verifier().verify(token.strip())
    except TokenError as exc:
        # 不记令牌，只记类型。exc 的 message 已经保证不含令牌本身。
        log.info("WS 认证失败：%s", exc)
        await websocket.close(code=CLOSE_POLICY)
        return

    try:
        player = await players.get_by_auth_uid(claims.auth_uid)
    except bans.AccountBanned as exc:
        # 被封的人**身份是真的**，所以这里例外地先 accept：说清楚原因再关，
        # 客户端才能显示「账号已被封禁」而不是一直当成握手失败重试（app/bans.py）。
        # 不进连接表、不占名额。
        await websocket.accept()
        await websocket.send_json(bans.banned_message(exc.ban))
        await websocket.close(code=bans.CLOSE_BANNED)
        return
    if player is None:
        # 令牌有效但没有对应玩家。同 /v1/me：**不自动补建**，
        # 建账号只有 /v1/auth/anonymous 一条路。
        await websocket.close(code=CLOSE_POLICY)
        return

    await websocket.accept()
    conn = Connection(player_id=player.player_id, device_session_id=device, websocket=websocket)
    hub = realtime.hub()
    # register 会踢掉同账号的旧连接，所以必须在 accept 之后 ——
    # 同设备重连时被踢的那条可能就是上一次的自己。
    await hub.register(conn)
    await hub.send(conn, {
        "t": "ready",
        "player_id": str(player.player_id),
        "heartbeat_sec": realtime.HEARTBEAT_INTERVAL_SEC,
    })
    # 名额放在 ready 之后：客户端先确认「连上了」，再看「进不进得去」。
    # join 也必须在 register 之后 —— 换设备时新连接要接过旧连接的名额。
    gate = admission.current()
    intent = admission.parse_intent(websocket.headers.get(admission.HEADER))
    decision = gate.join(conn, intent)
    if intent != admission.LEGACY:
        # 旧版客户端不认识这条消息，不发。它照样被放行、照样计入人数。
        await hub.send(conn, decision)
    log.info("WS 连接建立 player=%s 在线连接=%d 来意=%s 名额=%s",
             player.player_id, hub.connection_count(), intent, decision["state"])

    try:
        await _pump(hub, conn)
    except WebSocketDisconnect:
        pass
    except Exception:
        log.exception("WS 循环异常 player=%s", conn.player_id)
    finally:
        # 幂等，且不会误删顶号后新连接的那一条（见 Hub.unregister）。
        hub.unregister(conn)
        # 同样只认自己那条；名额进宽限期，不是立刻收回（见 admission 顶部）。
        gate.leave(conn)
        # 排队中的人进掉线宽限（不立刻踢出队列，手机切后台是常态）；
        # 待确认阶段断线则当场解散那一桌 —— 让另外五个人早点回队列，
        # 比陪着一个已经不在的人干等 30 秒强（app/matchmaking.py）。
        matchmaking.current().on_disconnect(conn.player_id)
        log.info("WS 断开 player=%s 在线连接=%d", conn.player_id, hub.connection_count())


async def _pump(hub: realtime.Hub, conn: Connection) -> None:
    """收消息循环。批次 B 只处理心跳，其余类型留给批次 C。"""
    while True:
        raw = await conn.websocket.receive_text()
        # 长度先判，再解析。反过来写的话，一个 50 MB 的 body 会先被完整解析一遍 ——
        # 同 NetProtocol.gd 顶部那条「任何容器都必须在常数级步数内被拒」。
        if len(raw.encode("utf-8")) > realtime.MAX_MESSAGE_BYTES:
            await hub.send(conn, {"t": "error", "code": "message_too_large"})
            continue
        conn.touch()
        try:
            payload = json.loads(raw)
        except ValueError:
            await hub.send(conn, {"t": "error", "code": "bad_json"})
            continue
        if not isinstance(payload, dict):
            await hub.send(conn, {"t": "error", "code": "bad_json"})
            continue

        kind = str(payload.get("t", ""))
        if kind == "ping":
            await hub.send(conn, {"t": "pong"})
            continue
        # 未知类型**不断开连接**：客户端比服务端新的时候（灰度、没更新的旧包）
        # 会发服务端不认识的东西，为此掐掉整条连接是过度反应。
        await hub.send(conn, {"t": "error", "code": "unknown_type"})
