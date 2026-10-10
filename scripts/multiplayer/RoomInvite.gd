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
#   · 失效判据（要求 5）    —— 离房 / 解散 / 20 分钟（已开局由战斗服务器在加入时拒绝）
#   · 发送限流（要求 4）    —— 同房同好友一次 / 两次邀请至少隔 5 秒（10.11 第 6 条 c）

# 与 backend/app/chat.py 的 ROOM_INVITE_KIND 一致，门禁 tools/room_invite_check.gd 钉着。
# 对不上的症状是「发出去的邀请对方收不到」或「收到的邀请渲染成一条普通文本」，都不报错。
const KIND := "room_invite"

# 10.07 第 10 条：排位/休闲的**组队邀请**也是同一种做法（带 kind 的私聊），
# 只是 kind 与 payload 不同。与 backend/app/chat.py 的 PARTY_INVITE_KIND 一致，
# 也与 ui/components/PartyInviteBubble.gd 的 KIND_TEAM 一致
# （tools/party_invite_bubble_check.gd 钉着）。
const PARTY_KIND := "party_invite"
# 组队邀请的文案（与 PartyInviteBubble 的 invite_team_body、服务端存的那句一致）。
const PARTY_TEXT_ZH := "快来加入队伍，一起战斗吧"
const PARTY_TEXT_EN := "Join my team — let's fight together!"
# 组队邀请框的小标题。
const PARTY_TITLE_ZH := "组队邀请"
const PARTY_TITLE_EN := "Team invite"

# 邀请框上的文案（要求 3）。
const TEXT_ZH := "我开启了新的房间，一起来玩吧"
const TEXT_EN := "I opened a new room — come join me!"

# 邀请有效期（要求 5）：20 分钟。
const EXPIRE_SEC := 20 * 60
# 同一邀请人两次邀请之间的最小间隔（2026-10-11 第 6 条 c：**5 秒**）。
#
# 🔴 这条口径改过一次，别照抄更早的注释：
#   · 2026-09-28 反馈第 5 条：当时是「**换房间**的邀请间隔 10 秒」—— 因为旧实现
#     不看房间号，同一个房间邀请第二个好友也被拦（玩家报的「10 秒后才能再次邀请」）。
#   · 2026-10-11 第 6 条 c 用户口径：「该类消息，同一房间只能发送一次，发送 CD 5 秒」。
#     「同一房间只能发送一次」= (房间, 好友) 去重（下面 duplicate 那条）；
#     「发送 CD 5 秒」= **任意两次邀请之间至少隔 5 秒**，不再区分换不换房。
#     5 秒足够短：压得住连点与刷屏，顺着一格一格邀几位好友也不会被挡住。
#
# 服务端 backend/app/chat.py 的 ROOM_INVITE_RATE_SEC 必须同值同口径 ——
# 只改客户端没用，服务端还会回 409 invite_rate_limited（tools/room_invite_check.gd 钉着）。
const RATE_LIMIT_SEC := 5

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


# --- 10.07 第 10 条：组队邀请 ---------------------------------------------------

# 这条消息是不是一条组队邀请。
static func is_party_invite(message: Dictionary) -> bool:
	return str(message.get("kind", "")) == PARTY_KIND


# 是不是**任何一种**邀请（房间 or 组队）。聊天界面用这个决定走哪个邀请气泡渲染。
static func is_any_invite(message: Dictionary) -> bool:
	return is_invite(message) or is_party_invite(message)


# 从一条组队邀请里取队伍号；不是组队邀请时返回空串。
static func party_id_of(message: Dictionary) -> String:
	if not is_party_invite(message):
		return ""
	var payload: Variant = message.get("payload")
	if not (payload is Dictionary):
		return ""
	return str((payload as Dictionary).get("party_id", ""))


# 从一条组队邀请里取**匹配模式**（casual / ranked）；不是组队邀请或字段缺失时返回空串。
#
# ★ 10.11 第 6 条 d：聊天卡片里点「加入」时要开对应的队伍大厅
# （PartyLobby.configure(mode, invite_id) 第一个参数就是它）。服务端落这条私聊时
# 已经把 mode 写进 payload（backend/app/routes/party.py 的 {"party_id":…, "mode":…}），
# 所以这里只是把它取出来 —— **取不到就返回空串**，由调用方决定兜底成哪种模式。
static func party_mode_of(message: Dictionary) -> String:
	if not is_party_invite(message):
		return ""
	var payload: Variant = message.get("payload")
	if not (payload is Dictionary):
		return ""
	return str((payload as Dictionary).get("mode", ""))


# 组队邀请的文案：**跟随语言切换**（10.10 bug 第 1 条）。
# 服务端存的 body 是中文定死那句（backend/app/routes/party.py 的 _party_invite_text），
# 直接拿它渲染 ⇒ 英文界面漏中文。所以以本地化文案为准，body 只做兜底。
static func party_display_text(message: Dictionary) -> String:
	var localized := party_local_text()
	if not localized.is_empty():
		return localized
	return str(message.get("body", ""))


static func party_local_text() -> String:
	return PARTY_TEXT_EN if _en() else PARTY_TEXT_ZH


static func party_title_text() -> String:
	return PARTY_TITLE_EN if _en() else PARTY_TITLE_ZH


# 从一条消息里取房间号；不是邀请、或房间号缺失时返回 0。
static func room_id_of(message: Dictionary) -> int:
	if not is_invite(message):
		return 0
	var payload: Variant = message.get("payload")
	if not (payload is Dictionary):
		return 0
	return int((payload as Dictionary).get("room_id", 0))


# 邀请框上显示的文案：**跟随语言切换**（10.10 bug 第 1 条）。
# 旧口径是「优先用服务端存的 body」—— 而那句 body 是中文定死的（要求 3 的历史行为），
# 于是英文界面下整条邀请漏中文。现在以本地化文案为准（local_text 恒非空），
# body 仅在拿不到文案时兜底。
static func display_text(message: Dictionary) -> String:
	var localized := local_text()
	if not localized.is_empty():
		return localized
	return str(message.get("body", ""))


static func local_text() -> String:
	return TEXT_EN if _en() else TEXT_ZH


static func expired_text() -> String:
	return EXPIRED_EN if _en() else EXPIRED_ZH


static func title_text() -> String:
	return TITLE_EN if _en() else TITLE_ZH


# --- 10.11 第 6 条：同房间的邀请不再弹气泡 --------------------------------------

# 这条邀请指的是不是「**我现在待着的那个房间**」。
#
# 用户口径（两个房间同一套）：
#   · 排位房间：「不再收到同房间的邀请提示（但保留朋友里的邀请消息）」
#   · 自定义房间：「改为和排位一样，可以收到除本房间外的邀请提示，同房间的邀请提示
#     不再提示（但保留朋友里的邀请消息）」
#
# 🔴 只用来掐**气泡**这一路。邀请消息本身照旧进「朋友」那一栏：组队邀请是服务端落的
# 一条 kind=party_invite 私聊，自定义房间邀请是一条 kind=room_invite 私聊 ——
# 两条都由 ChatService 收下、亮红点、放提示音（CUE_CHAT_ALERT，10 秒节流），
# 与气泡是**两条通路**。所以这里判 true 之后，「消息 / 红点 / 音效」全都还在，
# 只是不再往脸上弹一张卡片。
#
# 两边用的是**同一个房间号空间**：
#   · 本机当前房间 = `NetworkService.team_room_id`（进房时由房间快照的 room_id 写入）
#   · 邀请带的号   = payload.party_id（组队邀请）或 payload.room_id（自定义房间邀请）
#     —— backend/app/routes/party.py 那条 party_invite 推送与
#        chat.ROOM_INVITE_KIND 的 payload，都取自同一个 `room.id`。
#
# 两个「不知道」都判 false（＝照旧弹）：
#   · `current_room_id <= 0` —— 我没在任何房间（主菜单），同房间无从谈起；
#   · `invite_id` 不是纯数字   —— payload 坏了 / 空串。
# 宁可多弹一张卡片，也不要因为解析失败把一条**正常**邀请吞掉 —— 吞掉是不报错的。
static func targets_room(invite_id: String, current_room_id: int) -> bool:
	if current_room_id <= 0 or invite_id.is_empty() or not invite_id.is_valid_int():
		return false
	return invite_id.to_int() == current_room_id


# --- 失效判据（要求 5）----------------------------------------------------------

# 三个失效条件，任一成立即失效：
#   1. payload_room_id <= 0        —— 房间已解散（号已回收，客户端拿不到这个号）
#   2. now - created >= 20 分钟    —— 邀请时长已过去 20 分钟
#   3. inviter_room_id != 房间号   —— 邀请人已离开该房间。**0 也算离开**（确定不在任何房间）；
#                                    只有 UNKNOWN_ROOM(-1) 才是「查不到」、跳过这一条
#
# 「该房间已开局」**不在这里判**（2026-09-29 用户定）：房间开没开只有战斗服务器知道，
# 点「立即参与」加入时由它拒绝（room_started），客户端显示「房间已开局」。
# 9.28 曾让邀请人的客户端把「开打了没」经心跳写进账号服务器的数据库，好让邀请点之前就变灰 ——
# 用户明确不要这个体验，也不要房间状态进数据库，已整条撤掉（database/022 作废）。
#
# 🔴 三条**必须都在这里判**，不要在界面里散着写：散着写一定会出现
# 「20 分钟那条到处都对、但漏了离房那条」这种只在特定操作顺序下才暴露的漂移。
#
# 🔴 「查不到」一律当**有效**（created_sec <= 0、inviter_room_id == UNKNOWN_ROOM），
# 但「确定不在房间」（0）**必须判失效** —— 那是要求 5 点名的第一种情况。
# 把哨兵与 0 混为一谈是最容易写出的那个 bug：不是误杀正常邀请，就是漏掉「已离房」。
static func is_expired(payload_room_id: int, created_sec: int, now_sec: int,
		inviter_room_id: int) -> bool:
	if payload_room_id <= 0:
		return true
	if created_sec > 0 and now_sec - created_sec >= EXPIRE_SEC:
		return true
	if inviter_room_id != UNKNOWN_ROOM and inviter_room_id != payload_room_id:
		return true
	return false


# --- 发送限流（要求 4）----------------------------------------------------------

# 返回空串 = 可以发；否则是给玩家看的原因。本地先拦一道（省一次往返、反馈即时），
# 服务端还会**再判一次**（本地判据在客户端，改个内存就能绕）。
#   "duplicate"    —— 同一邀请人 + 同一房间 + 同一位好友，只会发一次邀请消息
#   "rate_limited" —— 两次邀请之间至少隔 RATE_LIMIT_SEC 秒（2026-10-11 第 6 条 c：5 秒）
#
# 关于 "duplicate" 的口径：要求原文是「同一邀请人同一房间只会发送一次邀请消息」。
# 这里判的是 **(房间, 好友)** 这一对 —— 同一个房间里邀请第二个好友应该是允许的，
# 否则「邀请朋友进入房间」这个功能就只能邀请一个人。房间级别的「只发一次」由服务端
# 对 (room_id, 收件人) 去重实现，两边口径一致。
#
# ## 🔴 2026-10-11 第 6 条 c：冷却**不再只在换房间时计时**
#
# 上一版（2026-09-28 反馈第 5 条）把冷却绑在「房间号变了」上：同一个房间里连邀
# 不同好友完全不限。现行口径是「该类消息……发送 CD 5 秒」—— 一条**与房间无关**的
# 发送频率限制（对应「同一房间只能发送一次」的仍然是上面那条 duplicate 去重）。
# 所以接口也简化了：不再需要 (current_room_id, last_sent_room_id) 这两个参数，
# 判据只剩「距上一次成功发送多久」。
# 服务端 chat.py:_check_invite_rules 的 (b) 用同一口径，两边必须一致。
static func send_blocked_reason(
		now_sec: int, last_sent_sec: int,
		same_room_already_sent: bool) -> String:
	if same_room_already_sent:
		return "duplicate"
	# last_sent_sec <= 0 表示「本次会话还没发过邀请」，不存在冷却。
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
