extends RefCounted

# 房间邀请好友（bug提交和修复.docx 第 2 条，2026-09-27）。
#
# ## 为什么是一条「带类型的私聊」，而不是新的推送
#
# 要求 (2) 是「被邀请人会在聊天功能朋友消息里收到朋友邀请，有新消息的音效提示，和红点提示」。
# 把邀请做成 `kind="room_invite"` 的私聊，这三件事**全部白拿**：
# 发送走已经验过的 HTTPS（AccountManager.send_chat_message），
# 推送走 ② 的 WebSocket（routes/chat.py 的 dm 分支），
# 红点与音效走 ChatService._on_dm_push（CUE_CHAT_ALERT）。
# 新造一套「邀请专用推送」只会多一条要单独维护的红点与音效通路。
#
# ## 本文件只放纯判据
#
# 不碰界面、不碰网络、不碰 autoload。理由同 9.24/9.25 的教训：
# 把判定抽成 static 纯函数，门禁才能**直接驱动这一份实现**，
# 而不是在探针里复刻一份（复刻版会随生产代码漂移，测了等于没测）。
#
#   · payload 的组装与解析  —— 客户端与服务端各写一份就会漂（漂了不报错，只是邀请收不到）
#   · 失效判据（要求 5）    —— 离房 / 解散 / 已开打 / 20 分钟
#   · 发送限流（要求 4）    —— 同房一次 / 异房 10 秒

# 与 backend/app/chat.py 的 ROOM_INVITE_KIND 一致，门禁 tools/room_invite_check.gd 钉着。
# 对不上的症状是「发出去的邀请对方收不到」或「收到的邀请渲染成一条普通文本」，都不报错。
const KIND := "room_invite"

# 邀请框上的文案（要求 3）。
const TEXT_ZH := "我开启了新的房间，一起来玩吧"
const TEXT_EN := "I opened a new room — come join me!"

# 邀请有效期（要求 5）：20 分钟。
const EXPIRE_SEC := 20 * 60
# 同一邀请人换房间时的最小间隔（要求 4）：10 秒。
const RATE_LIMIT_SEC := 10

# 失效提示（要求 5）。与教程的「上阵棋子数目少于 N」走同一个出口（GloryToast），
# 所以「中上方 + 同一种格式」是天然的，不需要在这里再调位置。
const EXPIRED_ZH := "邀请已过时"
const EXPIRED_EN := "This invite has expired"

# 邀请框顶部的小标题。与主文案分开：主文案是那句必须逐字一致的邀请话术，
# 标题只是「这一类消息」的名字 —— 让方框一眼能和普通气泡区分开。
const TITLE_ZH := "房间邀请"
const TITLE_EN := "Room invite"

# is_expired 的 inviter_room_id 参数里，「查不到邀请人此刻在哪个房间」用这个哨兵。
#
# 🔴 必须与「0」分开：0 = **确定不在任何房间**（好友在列表里、room_id 为 null），
# 那是要求 5 的「离开该房间」的一种，必须判失效；
# 而「好友列表请求失败 / 列表里没这个人」是**不知道**，不能据此判失效。
# 把两者都写成 0 的结果是：网络抖一下 → 正常邀请被误杀，且不报错。
const UNKNOWN_ROOM := -1


# --- payload ------------------------------------------------------------------

# 邀请的机器可读部分。room_id 放这里、**不放 body**：
# body 要塞进 text_guard（会压换行、限 200 字），而且 set_locale 之后 body 是给人读的，
# 从里面正则抠房间号会在任何一次文案改动或本地化上悄悄失效。
static func make_payload(room_id: int) -> Dictionary:
	return {"room_id": int(room_id)}


static func is_invite(message: Dictionary) -> bool:
	return str(message.get("kind", "")) == KIND


# 从一条消息里取房间号；不是邀请、或房间号缺失时返回 0。
static func room_id_of(message: Dictionary) -> int:
	if not is_invite(message):
		return 0
	var payload: Variant = message.get("payload")
	if not (payload is Dictionary):
		return 0
	return int((payload as Dictionary).get("room_id", 0))


# 邀请框上显示的文案：优先用服务端存下来的 body（要求 3 的定死那句），
# body 空（老数据 / 被裁剪）时退回本地文案。
static func display_text(message: Dictionary) -> String:
	var body := str(message.get("body", ""))
	return body if not body.is_empty() else local_text()


static func local_text() -> String:
	return TEXT_EN if _en() else TEXT_ZH


static func expired_text() -> String:
	return EXPIRED_EN if _en() else EXPIRED_ZH


static func title_text() -> String:
	return TITLE_EN if _en() else TITLE_ZH


# --- 失效判据（要求 5）----------------------------------------------------------

# 四个失效条件，任一成立即失效：
#   1. payload_room_id <= 0        —— 房间已解散（号已回收，客户端拿不到这个号）
#   2. now - created >= 20 分钟    —— 邀请时长已过去 20 分钟
#   3. inviter_room_id != 房间号   —— 邀请人已离开该房间。**0 也算离开**（确定不在任何房间）；
#                                    只有 UNKNOWN_ROOM(-1) 才是「查不到」、跳过这一条
#   4. room_started == true        —— 该房间的对局已经开始
#
# 🔴 四条**必须都在这里判**，不要在界面里散着写：散着写一定会出现
# 「20 分钟那条到处都对、但漏了离房那条」这种只在特定操作顺序下才暴露的漂移。
#
# 🔴 「查不到」一律当**有效**（created_sec <= 0、inviter_room_id == UNKNOWN_ROOM），
# 但「确定不在房间」（0）**必须判失效** —— 那是要求 5 点名的第一种情况。
# 把哨兵与 0 混为一谈是最容易写出的那个 bug：不是误杀正常邀请，就是漏掉「已离房」。
static func is_expired(payload_room_id: int, created_sec: int, now_sec: int,
		inviter_room_id: int, room_started: bool) -> bool:
	if payload_room_id <= 0:
		return true
	if created_sec > 0 and now_sec - created_sec >= EXPIRE_SEC:
		return true
	if inviter_room_id != UNKNOWN_ROOM and inviter_room_id != payload_room_id:
		return true
	if room_started:
		return true
	return false


# 便捷重载：直接从一条消息判。
static func message_is_expired(message: Dictionary, created_sec: int, now_sec: int,
		inviter_room_id: int, room_started: bool) -> bool:
	return is_expired(room_id_of(message), created_sec, now_sec, inviter_room_id, room_started)


# --- 发送限流（要求 4）----------------------------------------------------------

# 返回空串 = 可以发；否则是给玩家看的原因。本地先拦一道（省一次往返、反馈即时），
# 服务端还会**再判一次**（本地判据在客户端，改个内存就能绕）。
#   "duplicate"    —— 同一邀请人 + 同一房间 + 同一位好友，只会发一次邀请消息
#   "rate_limited" —— 同一邀请人换房间时，两条邀请至少隔 10 秒
#
# 关于 "duplicate" 的口径：要求原文是「同一邀请人同一房间只会发送一次邀请消息」。
# 这里判的是 **(房间, 好友)** 这一对 —— 同一个房间里邀请第二个好友应该是允许的，
# 否则「邀请朋友进入房间」这个功能就只能邀请一个人。房间级别的「只发一次」由服务端
# 对 (room_id, 收件人) 去重实现，两边口径一致。
static func send_blocked_reason(now_sec: int, last_sent_sec: int, same_room_already_sent: bool) -> String:
	if same_room_already_sent:
		return "duplicate"
	if last_sent_sec > 0 and now_sec - last_sent_sec < RATE_LIMIT_SEC:
		return "rate_limited"
	return ""


static func send_blocked_text(reason: String) -> String:
	match reason:
		"duplicate":
			return "Already invited to this room" if _en() else "已经邀请过了"
		"rate_limited":
			return ("Please wait %d s before inviting again" % RATE_LIMIT_SEC) if _en() \
				else ("%d 秒后才能再次邀请" % RATE_LIMIT_SEC)
	return ""


# --- 显示去重（要求 4：被邀请方只会收到一次）------------------------------------

# 把「同一房间的重复邀请」在**渲染前**收敛成一条；多条时保留**最后（最新）**那条。
#
# 为什么在后端 chat._check_invite_rules 已经按 (邀请人, 房间, 收件人) 去重之外
# 还要这一层：
#   1. 旧数据 —— 去重上线之前已经落库的那两条不会被删，只能靠显示层收敛；
#   2. 兜底 —— 客户端与服务端任何一侧漏判，玩家看到的仍然是干净的一条。
# 键只取 room_id：一段会话里对方是固定的，一条邀请只可能指一个房间。
# room_id <= 0（payload 坏了）与普通文本都**不参与**去重 —— 坏的邀请各算各的。
static func dedupe_for_display(messages: Array) -> Array:
	var last_at := {}
	for i in messages.size():
		var rid := _display_room_id(messages[i])
		if rid > 0:
			last_at[rid] = i
	var out := []
	for i in messages.size():
		var rid := _display_room_id(messages[i])
		if rid > 0 and int(last_at.get(rid, i)) != i:
			continue
		out.append(messages[i])
	return out


# 这条消息如果是一条**房间号有效**的邀请，返回它的房间号；否则返回 0（不参与去重）。
static func _display_room_id(message: Variant) -> int:
	if message is Dictionary and is_invite(message):
		return room_id_of(message)
	return 0


# --- 小工具 -------------------------------------------------------------------

static func _en() -> bool:
	return TranslationServer.get_locale().begins_with("en")
