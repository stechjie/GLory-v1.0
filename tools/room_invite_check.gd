extends Node

# 房间邀请好友（bug提交和修复.docx 第 2 条）的门禁。
#
# ## 两类断言都要有（9.24 的教训：缺哪类就有哪类盲区）
#
#   · **行为断言** —— 直接驱动生产实现 scripts/multiplayer/RoomInvite.gd 的 static 纯函数：
#     失效三判据、限流两判据、payload 组装/解析、文案。探针**只驱动那一份实现**，
#     绝不在这里复刻一份判据（复刻版会跟生产漂移，测了等于没测）。
#   · **结构断言** —— 「谁在调用它」。行为断言看不见接线：把 lobby 的邀请调用删掉，
#     纯函数照样全绿。所以另加一组「调用点还在不在」的存在性断言
#     （注释感知：只认**没被注释掉**的代码，见 _has_live_code）。
#
# ## 判据不自证
#
# 失效判据的期望值由**需求原文**独立写出（20 分钟 = 1200 秒、发送 CD 5 秒、
# 同房同好友一次），不从被测量反推。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const RoomInvite := preload("res://scripts/multiplayer/RoomInvite.gd")
const MenuScript := preload("res://scenes/menu/MainMenu.gd")

const CHECK_NAME := "room_invite"

# 需求里的数，**在这里独立写死**，不引用 RoomInvite 的常量 ——
# 否则把 EXPIRE_SEC 改成 5 分钟，断言会跟着一起改，等于没判。
const WANT_EXPIRE_SEC := 1200
# 2026-10-11 第 6 条 c：「该类消息，同一房间只能发送一次，**发送 CD 5 秒**」
# （旧口径是「换房间才计时，间隔 10 秒」，已被本条推翻）。
const WANT_RATE_SEC := 5

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_behavior_constants()
	_behavior_payload()
	_behavior_expiry()
	_behavior_rate_limit()
	_behavior_dedupe()
	_behavior_same_room_suppressed()
	_behavior_join_rejected()
	_structure_client()
	_structure_same_room_suppression()
	_structure_backend_pipeline()
	_structure_no_room_state_in_account_server()
	_structure_in_match_marker()
	_structure_single_spelling()
	_h.finish(get_tree())


# --- 行为：常量与文案 ----------------------------------------------------------

func _behavior_constants() -> void:
	_h.expect(RoomInvite.KIND == "room_invite", "kind_value",
		"kind 必须是 room_invite（与 backend/app/chat.py 的 ROOM_INVITE_KIND 同值）")
	_h.expect(RoomInvite.EXPIRE_SEC == WANT_EXPIRE_SEC, "expire_const",
		"有效期常量必须是需求里的 20 分钟（%d 秒）" % WANT_EXPIRE_SEC)
	_h.expect(RoomInvite.RATE_LIMIT_SEC == WANT_RATE_SEC, "rate_const",
		"发送冷却常量必须是需求里的 %d 秒（10.11 第 6 条 c）" % WANT_RATE_SEC)
	# 文案逐字等于需求（要求 3）。
	_h.expect(RoomInvite.TEXT_ZH == "我开启了新的房间，一起来玩吧", "text_zh",
		"邀请框文案必须逐字等于需求给的那句")
	_h.expect(RoomInvite.EXPIRED_ZH == "邀请已过时", "expired_zh",
		"失效提示必须逐字等于「邀请已过时」")
	# 后端常量对得上（对不上的症状是「邀请发出去对方收不到」，不报错）。
	var backend := FileAccess.get_file_as_string("res://backend/app/chat.py")
	_h.expect(backend.contains('ROOM_INVITE_KIND = "room_invite"'), "backend_kind",
		"后端 chat.py 必须定义同一个 ROOM_INVITE_KIND 字面量")
	# ★ 10.11 第 6 条 c：两边冷却必须同值 —— 客户端拦不住没关系（本地判据可绕），
	#   但**服务端比客户端严**的症状是「点了没反应、只回一条 409」，
	#   而**服务端比客户端松**就等于本地预判形同虚设。两种都不报错。
	_h.expect(backend.contains("ROOM_INVITE_RATE_SEC = %d" % WANT_RATE_SEC), "backend_rate_const",
		"后端 chat.py 的 ROOM_INVITE_RATE_SEC 必须是需求里的 %d 秒（与客户端同口径）" % WANT_RATE_SEC)
	# 组队邀请的发送冷却（routes/party.py 的 _invite_limiter）也必须是 1 次 / 5 秒 ——
	# 只改房间邀请那一半，玩家会发现「排位房邀请冷热不均」。
	var party_route := FileAccess.get_file_as_string("res://backend/app/routes/party.py")
	_h.expect(party_route.contains("_invite_limiter = SlidingWindowLimiter(1, %d.0)" % WANT_RATE_SEC),
		"backend_party_invite_limiter",
		"组队邀请的限流必须是 1 次 / %d 秒（10.11 第 6 条 c 同口径）" % WANT_RATE_SEC)
	# ★ 10.11 第 6 条 c 附带修复：邀请被判「重复」时回的状态码必须是 409。
	#   chat.py 里有两个去重码 —— 房间邀请走 invite_duplicate，组队邀请走
	#   party_invite_duplicate（chat._check_party_invite_rules，10.07 第 10 条）。
	#   后一个以前漏登记进 routes/chat.py 的 _STATUS_BY_CODE，而
	#   `.get(code, 400)` 会把它降级成 400 —— 客户端按状态码分派时会把「已经邀请过了」
	#   当未知错误处理。漏登记不报错，只是静默降级。
	var chat_route := FileAccess.get_file_as_string("res://backend/app/routes/chat.py")
	_h.expect(chat_route.contains('"invite_duplicate": 409'), "backend_status_invite_dup",
		"routes/chat.py 必须把房间邀请的去重码 invite_duplicate 登记成 409")
	_h.expect(chat_route.contains('"party_invite_duplicate": 409'), "backend_status_party_dup",
		"routes/chat.py 必须把组队邀请的去重码 party_invite_duplicate 登记成 409（漏登记会降级成 400）")


# --- 行为：payload -------------------------------------------------------------

func _behavior_payload() -> void:
	var payload := RoomInvite.make_payload(123)
	_h.expect(int(payload.get("room_id", 0)) == 123, "payload_room",
		"make_payload 把房间号放进 room_id")

	var invite := {"kind": "room_invite", "body": "x", "payload": {"room_id": 77}}
	_h.expect(RoomInvite.is_invite(invite), "is_invite_true", "kind 对了就是邀请")
	_h.expect(not RoomInvite.is_invite({"kind": "text", "body": "hi"}), "is_invite_false",
		"普通文本不是邀请")
	_h.expect(not RoomInvite.is_invite({"body": "hi"}), "is_invite_missing_kind",
		"没有 kind 字段时不是邀请（老消息不能崩）")
	_h.expect(RoomInvite.room_id_of(invite) == 77, "room_id_of", "从 payload 取到房间号")
	_h.expect(RoomInvite.room_id_of({"kind": "text", "body": "hi"}) == 0, "room_id_of_text",
		"普通文本取房间号返回 0")
	_h.expect(RoomInvite.room_id_of({"kind": "room_invite", "payload": "oops"}) == 0,
		"room_id_of_bad_payload", "payload 不是字典时返回 0 而不是崩")
	# 显示文案**跟随语言切换**（10.10 bug 第 1 条）。
	# 旧口径是「有 body 就用 body」，而服务端存的那句是**中文定死**的
	# （backend/app/routes/party.py 的 _party_invite_text）⇒ 英文界面下漏中文。
	_h.expect(RoomInvite.display_text({"body": "服务端存的", "kind": "room_invite"})
			== RoomInvite.local_text(),
		"display_follows_locale", "显示文案取本地化文案（跟随语言），不直接吃服务端中文 body")
	_h.expect(RoomInvite.TEXT_ZH != RoomInvite.TEXT_EN, "text_zh_vs_en",
		"中英文两句邀请文案必须不同，否则切语言看不出变化")
	_h.expect(not RoomInvite.display_text({"body": "", "kind": "room_invite"}).is_empty(),
		"display_fallback", "body 空时仍然有文案，不留空白框")


# --- 行为：失效三判据（要求 5）-------------------------------------------------
#
# 「房间已开局」不在这里：那由战斗服务器在加入时拒绝（见 _behavior_join_rejected）。

func _behavior_expiry() -> void:
	var room := 1000
	var now := 1_000_000
	var created := now - 60  # 一分钟前发的，没过期

	# 基线：一切都正常 → 有效。
	_h.expect(not RoomInvite.is_expired(room, created, now, room), "valid_baseline",
		"房间在、没超时、邀请人还在 → 有效")

	# ① 房间已解散（拿不到号）。
	_h.expect(RoomInvite.is_expired(0, created, now, 0), "expired_dissolved",
		"房间已解散（号回收）→ 失效")

	# ② 20 分钟到了。边界两侧都要判：1199 秒有效、1200 秒失效。
	var t1199 := now - (WANT_EXPIRE_SEC - 1)
	var t1200 := now - WANT_EXPIRE_SEC
	_h.expect(not RoomInvite.is_expired(room, t1199, now, room), "boundary_1199",
		"过去 %d 秒仍然有效（边界内侧）" % (WANT_EXPIRE_SEC - 1))
	_h.expect(RoomInvite.is_expired(room, t1200, now, room), "boundary_1200",
		"过去 %d 秒即失效（边界上）" % WANT_EXPIRE_SEC)

	# ③ 邀请人已离开该房间：换到别的号、或确定不在任何房间（0），都要失效。
	_h.expect(RoomInvite.is_expired(room, created, now, room + 1), "expired_left_room",
		"邀请人换到别的房间 → 失效")
	_h.expect(RoomInvite.is_expired(room, created, now, 0), "expired_left_all",
		"邀请人已不在任何房间（0 = 确定）→ 失效")

	# 🔴 「查不到」一律当有效 —— 但必须与「0 = 确定不在房间」分开：
	#    0 走上面 expired_left_all（失效），UNKNOWN_ROOM 才放过。
	_h.expect(not RoomInvite.is_expired(room, 0, now, room), "unknown_created_ok",
		"拿不到创建时间 → 当有效（误杀比漏判严重）")
	_h.expect(not RoomInvite.is_expired(room, created, now, RoomInvite.UNKNOWN_ROOM),
		"unknown_inviter_ok", "查不到邀请人房间（哨兵）→ 不因这一条判失效")
	_h.expect(RoomInvite.UNKNOWN_ROOM != 0, "unknown_room_sentinel",
		"哨兵必须不等于 0 —— 否则「查不到」与「确定不在房间」又混成一个值")


# --- 行为：发送限流（要求 4 + 10.11 第 6 条 c）---------------------------------
#
# 两个原因：
#   "duplicate"    —— (房间, 好友) 只发一次
#   "rate_limited" —— 两次邀请之间至少隔 WANT_RATE_SEC 秒，**与房间号无关**
func _behavior_rate_limit() -> void:
	var now := 2_000_000
	# 同一房间对同一位好友只发一次。
	_h.expect(RoomInvite.send_blocked_reason(now, 0, true) == "duplicate", "block_duplicate",
		"同房同好友已发过 → duplicate")
	# 发送冷却 5 秒：4 秒拦、5 秒放（边界两侧）。
	_h.expect(RoomInvite.send_blocked_reason(now, now - 4, false) == "rate_limited",
		"block_rate_4s", "距上次 4 秒 → rate_limited")
	_h.expect(RoomInvite.send_blocked_reason(now, now - WANT_RATE_SEC, false) == "",
		"allow_rate_5s", "距上次正好 %d 秒 → 放行（边界上）" % WANT_RATE_SEC)
	_h.expect(RoomInvite.send_blocked_reason(now, now - 60, false) == "", "allow_after_minute",
		"距上次一分钟 → 放行")
	# 🔴 冷却**与房间号无关**（10.11 第 6 条 c 推翻了 9.28 的「只在换房才计时」）：
	#    接口里那两个房间号参数已经删掉了 —— 正面钉住「同一次会话里隔够 5 秒
	#    就能连着邀第二位好友」。旧实现在这里要求「换了房才计时」，口径完全不同。
	_h.expect(RoomInvite.send_blocked_reason(now, now - WANT_RATE_SEC, false) == "",
		"allow_same_room_second_friend",
		"同一房间隔 %d 秒邀第二位好友 → 放行（冷却只看时间，不看房间）" % WANT_RATE_SEC)
	# 从没发过。
	_h.expect(RoomInvite.send_blocked_reason(now, 0, false) == "", "allow_first",
		"本场第一次邀请 → 放行")
	# 两个原因都给得出人话（不给空串，否则提示是一条空白）。
	_h.expect(not RoomInvite.send_blocked_text("duplicate").is_empty()
		and not RoomInvite.send_blocked_text("rate_limited").is_empty(),
		"block_text", "两种拦截原因都有可读文案")
	# 提示里报出来的秒数必须就是常量本身 —— 写成别的数字，玩家会等错时间。
	_h.expect(RoomInvite.send_blocked_text("rate_limited").contains(str(WANT_RATE_SEC)),
		"block_text_seconds", "「请稍后再试」的秒数必须报 %d" % WANT_RATE_SEC)


# --- 行为：显示去重（要求 4：被邀请方只会收到一次）------------------------------

func _behavior_dedupe() -> void:
	var a := {"message_id": 1, "kind": "room_invite", "payload": {"room_id": 7}, "body": "x"}
	var b := {"message_id": 2, "kind": "text", "body": "hi"}
	var c := {"message_id": 3, "kind": "room_invite", "payload": {"room_id": 7}, "body": "x"}
	var d := {"message_id": 4, "kind": "room_invite", "payload": {"room_id": 9}, "body": "x"}
	var out := RoomInvite.dedupe_for_display([a, b, c, d])
	_h.expect(out.size() == 3, "dedupe_count", "同房重复邀请只留一条，实测 %d 条" % out.size())
	var kept: Array[int] = []
	for m in out:
		kept.append(int((m as Dictionary).get("message_id", 0)))
	_h.expect(not kept.has(1) and kept.has(3), "dedupe_keeps_latest",
		"同一房间保留最后一条（1 隐藏、3 保留），实测 %s" % str(kept))
	_h.expect(kept.has(2) and kept.has(4), "dedupe_keeps_others",
		"普通消息与其他房间的邀请都要保留，实测 %s" % str(kept))
	_h.expect(RoomInvite.dedupe_for_display([b]).size() == 1, "dedupe_noop",
		"没有邀请时原样返回（不去重）")
	# payload 坏的邀请不参与去重（各算各的），也不能崩。
	var broken := {"message_id": 5, "kind": "room_invite", "payload": "oops", "body": "x"}
	_h.expect(RoomInvite.dedupe_for_display([broken, broken.duplicate()]).size() == 2,
		"dedupe_broken_payload", "坏 payload 的邀请不去重，也不崩")


# --- 行为：同房间的邀请不再弹气泡（10.11 第 6 条）--------------------------------
#
# 需求原文（两个房间同一套）：
#   · 排位房间：「不再收到同房间的邀请提示（但保留朋友里的邀请消息）」
#   · 自定义房间：「改为和排位一样，可以收到除本房间外的邀请提示，同房间的邀请提示
#     不再提示（但保留朋友里的邀请消息）」
#
# 直接驱动 RoomInvite.targets_room 的真表。期望值按需求独立写出：
#   同房 → true（掐气泡）；异房 → false（照旧弹）。
# 两个「不知道」都判 false（宁可多弹一张，也不吞掉一条正常邀请 —— 吞掉不报错）。
func _behavior_same_room_suppressed() -> void:
	# ① 正命中：邀请的房间 == 我待的房间 → 掐。
	_h.expect(RoomInvite.targets_room("1000", 1000), "same_room_true",
		"邀请的房间号 == 当前房间号 → 判成「同房间邀请」，气泡要掐")
	# ② 异房：照旧弹。
	_h.expect(not RoomInvite.targets_room("1001", 1000), "other_room_false",
		"别的房间的邀请 → 照旧弹")
	# ③ 我不在任何房间（主菜单）：同房间无从谈起 → 照旧弹。
	_h.expect(not RoomInvite.targets_room("1000", 0), "no_current_room_false",
		"我不在任何房间（0）时不该判成同房间 —— 否则主菜单收到自己的邀请会被吞")
	_h.expect(not RoomInvite.targets_room("1000", -1), "bad_current_room_false",
		"当前房间号非法（<=0）时一律照旧弹")
	# ④ payload 坏 / 空：宁可多弹不要吞。
	_h.expect(not RoomInvite.targets_room("", 1000), "empty_invite_false",
		"邀请号为空（payload 坏）时照旧弹 —— 吞掉是不报错的")
	_h.expect(not RoomInvite.targets_room("abc", 1000), "non_numeric_invite_false",
		"邀请号不是纯数字时照旧弹（既不崩、也不误判同房间）")
	# ⑤ 两侧都要能吃：payload 里可能是 int，Main 侧统一 str() 过一遍；前导零要归一。
	_h.expect(RoomInvite.targets_room("0007", 7), "leading_zero_still_matches",
		"「0007」与 7 是同一个房间号（to_int 归一），不该因前导零漏判")
	# ⑥ 反向：不能恒 true（恒 true 会把**所有**邀请气泡都吞掉，玩家再也看不到）。
	var any_false := false
	for case in [["1001", 1000], ["5", 6], ["", 0], ["x", 3]]:
		if not RoomInvite.targets_room(str(case[0]), int(case[1])):
			any_false = true
	_h.expect(any_false, "not_always_true",
		"targets_room 不能恒 true —— 否则房间里所有邀请气泡都不弹了")


# --- 行为：加入被拒要说出原因（2026-09-29）---------------------------------------
#
# 9.28 反馈第 3 条「点立即参与一直显示连接中」的真正原因：战斗服务器拒绝时，原因只写进
# 「自定房间」面板里的状态行；从邀请 / 好友列表加入时面板没开，原因丢了，
# 加入开头写上的「连接中…」也一直挂着。
#
# 直接驱动真实的 MainMenu.show_join_rejected。**不进树**：_ready() 要碰网络、钱包与音乐，
# 而这里只关心那两行字。期望文案按用户原话独立写死（「已开局」「房间已关闭」）。
func _behavior_join_rejected() -> void:
	var saved_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("zh_CN")
	var menu: MenuScript = MenuScript.new()
	var net_status := Label.new()
	menu._net_status = net_status

	# 面板没开（从邀请 / 好友列表进来）：收回「连接中…」，弹提示说原因。
	for case in [["room_started", "房间已开局"], ["room_not_found", "房间已关闭"], ["room_full", "房间已满"]]:
		net_status.text = "连接中…"
		GloryToast.reset_counters_for_check()
		menu.show_join_rejected(str(case[0]))
		_h.expect(net_status.text.is_empty(), "join_rejected_still_connecting",
			"%s 被拒后顶上还挂着「%s」" % [case[0], net_status.text])
		_h.expect(GloryToast.shown_count() == 1 and GloryToast.last_text() == str(case[1]),
			"join_rejected_silent", "%s 被拒应提示「%s」，实测弹了 %d 次、最后一条「%s」" % [
				case[0], case[1], GloryToast.shown_count(), GloryToast.last_text()])

	# 面板开着（玩家自己输的号）：写进面板，不另弹；号可能打错，所以是「找不到房间」。
	var room_status := Label.new()
	menu._room_status = room_status
	net_status.text = "连接中…"
	GloryToast.reset_counters_for_check()
	menu.show_join_rejected("room_not_found")
	_h.expect(room_status.text == "找不到房间" and GloryToast.shown_count() == 0,
		"join_rejected_panel", "面板开着时应写进面板「找不到房间」且不弹提示，实测面板「%s」、弹了 %d 次" % [
			room_status.text, GloryToast.shown_count()])
	_h.expect(net_status.text.is_empty(), "join_rejected_panel_connecting",
		"面板开着时被拒，顶上的「连接中…」也要收回")

	GloryToast.dismiss()
	GloryToast.reset_counters_for_check()
	room_status.free()
	net_status.free()
	menu.free()
	TranslationServer.set_locale(saved_locale)


# --- 结构：接线还在不在 --------------------------------------------------------

func _structure_client() -> void:
	var chat := FileAccess.get_file_as_string("res://scenes/menu/ChatScreen.gd")
	var lobby := FileAccess.get_file_as_string("res://scenes/menu/Team3v3Lobby.gd")
	var main := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	var account := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")

	# ChatScreen：邀请框 + 立即参与 + 失效出口。
	_h.expect(_has_live_code(chat, "signal join_room_requested"),
		"chat_signal", "ChatScreen 必须有 join_room_requested 信号")
	_h.expect(_has_live_code(chat, "RoomInvite.is_invite(msg)"),
		"chat_branch", "ChatScreen 的气泡必须分流邀请（否则邀请渲染成普通文本）")
	_h.expect(_has_live_code(chat, "RoomInvite.expired_text()"),
		"chat_expired", "失效时必须走 RoomInvite.expired_text()（单一文案源）")
	_h.expect(chat.contains("立即参与"), "chat_join_label", "邀请框上必须有「立即参与」按钮")
	_h.expect(_has_live_code(chat, "join_room_requested.emit(room_id)"),
		"chat_emit", "有效邀请必须发 join_room_requested 去加入")
	_h.expect(_has_live_code(chat, "RoomInvite.is_expired("),
		"chat_expiry_call", "点「立即参与」必须过 RoomInvite.is_expired 这一关")

	# Team3v3Lobby：点好友名发邀请 + 亮一下 + 走限流。
	_h.expect(_has_live_code(lobby, "RoomInvite.send_blocked_reason"),
		"lobby_rate", "大厅发邀请前必须过 send_blocked_reason（要求 4）")
	_h.expect(_has_live_code(lobby, "RoomInvite.make_payload"),
		"lobby_payload", "大厅邀请必须带 make_payload 造的 payload")
	_h.expect(_has_live_code(lobby, "_flash_row("),
		"lobby_flash", "点击成功要亮一下（要求 1）")
	_h.expect(_has_live_code(lobby, "gui_input.connect"),
		"lobby_clickable", "朋友列表每一行必须可点（点击好友 ID 即邀请）")

	# Main：把信号接到已有的加入路径。
	_h.expect(_has_live_code(main, "join_room_requested.connect"),
		"main_route", "Main 必须把 join_room_requested 接进加入流程")

	# ★★ 10.11 第 6 条 d：**组队邀请的「加入」原来是一根断线**。
	#    ChatScreen 声明并 emit 了 join_party_requested，全仓却没有任何 connect ——
	#    点「加入」什么都不会发生（用户原话「好像未实现，点击无反应」）。
	#    这条断言只认「真的接了」，光有信号/emit 不算（那正是坏掉时的样子）。
	_h.expect(_has_live_code(chat, "signal join_party_requested"),
		"chat_party_signal", "ChatScreen 必须有 join_party_requested 信号")
	_h.expect(_has_live_code(main, "join_party_requested.connect"),
		"main_party_route",
		"Main 必须把 join_party_requested 接进队伍大厅 —— 没接就等于「点了没反应」")
	# emit 时要把 mode 一起带出去：开大厅要调 PartyLobby.configure(mode, invite_id)。
	_h.expect(_has_live_code(chat, "join_party_requested.emit(party_id, RoomInvite.party_mode_of(msg))"),
		"chat_party_mode",
		"emit 组队邀请时必须带上 mode（payload 里服务端存了 casual/ranked）")
	# g) 点了「加入 / 立即参与」= 处理掉这条邀请 → 红点当场消失。
	_h.expect(_has_live_code(chat, "ChatService.mark_seen_locally(_open_code)"),
		"chat_join_clears_unread",
		"点「加入」「立即参与」后必须清本地红点（第 6 条 g：相当于处理了这条邀请消息）")

	# ★ 10.11 第 6 条 i：好友**已在本房间**时，点了既不发邀请消息也不弹气泡。
	#   自定义房间的成员只存在于战斗服务器上，账号服务器不知道 ⇒ 只能客户端判，
	#   所以这条必须落在发消息那一处（_on_invite_friend）而不是服务端。
	var invite_body := _func_body(lobby, "func _on_invite_friend(")
	_h.expect(invite_body.contains("friend_room == room_id") and invite_body.contains("return"),
		"lobby_same_room_no_message",
		"_on_invite_friend 里必须判「好友已在本房间」并 return（第 6 条 i）")
	# 渲染那一步也要拦（否则点得到、点了没反应，玩家以为坏了）。
	_h.expect(_has_live_code(lobby, "_friend_room_id(friend) == mine"),
		"lobby_same_room_not_rendered",
		"_can_invite_online_friend 必须把「已在本房间」的好友排除（第 6 条 i）")

	# AccountManager：发送必须能带 kind/payload。
	_h.expect(account.contains("func send_chat_message(") and account.contains("kind: String"),
		"account_kind_param", "send_chat_message 必须能带 kind 参数")

	# 点击反馈的顺序（要求 1）：必须**先亮一下、再判限流**。
	# 反过来的话，「同一房间已经邀请过」时点了什么都不发生 —— 玩家以为没点到，
	# 而那正是实测「点击没有亮一下」的原因。
	var flash_at := lobby.find("_flash_row(row)")
	var check_at := lobby.find("send_blocked_reason")
	_h.expect(flash_at >= 0 and check_at >= 0 and flash_at < check_at, "lobby_flash_first",
		"必须先 _flash_row 再 send_blocked_reason，实测 flash@%d check@%d" % [flash_at, check_at])

	# 不再弹「已经邀请过了」：旧写法把拦截原因整个交给 send_blocked_text(blocked)，
	# 于是 duplicate 也被弹出来。断言那个写法与那句话都消失（注释感知）。
	_h.expect(not _has_live_code(lobby, "send_blocked_text(blocked)"), "lobby_no_dup_toast",
		"不得再用 send_blocked_text(blocked) —— 那会把「已经邀请过了」弹给玩家")
	_h.expect(not _has_live_code(lobby, "已经邀请过了"), "lobby_no_dup_word",
		"大厅源码里不该再有「已经邀请过了」这句提示")

	# 显示层去重 + 邀请框方框化（要求 3/4）。
	_h.expect(_has_live_code(chat, "RoomInvite.dedupe_for_display("), "chat_dedupe",
		"ChatScreen 渲染前必须过 dedupe_for_display（同房重复邀请只显示一条）")
	_h.expect(_has_live_code(chat, "RoomInvite.title_text()"), "chat_invite_title",
		"邀请框要有小标题（与普通气泡区分开）")


# --- 结构：同房间抑制落在**统一入口**（10.11 第 6 条）---------------------------
#
# 只行为对了不够：把 Main.gd 里那处 `if ... targets_room(...): return` 删掉，
# 纯函数照样全绿。所以另钉「抑制真的接上了」。
#
# 而且必须落在 _show_invite_bubble（统一入口）而不是某个来源的调用点：
# 三种来源（排位组队推送 party_invite、自定义房间推送 room_invite、私聊链 room_invite）
# 最后都汇到它 —— 只堵一处会出现「某个入口还在弹」，而且完全静默。
func _structure_same_room_suppression() -> void:
	var main := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	if not _h.expect(not main.is_empty(), "main_src_readable_bug6", "读不到 Main.gd"):
		return
	_h.expect(_has_live_code(main, "RoomInviteScript.targets_room("),
		"main_calls_targets_room", "Main 必须调 RoomInvite.targets_room 判同房间")
	_h.expect(_has_live_code(main,
			"if RoomInviteScript.targets_room(invite_id, NetworkService.team_room_id):"),
		"main_suppression_condition",
		"抑制条件必须是 targets_room(invite_id, NetworkService.team_room_id)（两个实参都不能写死）")
	# 抑制必须在 _show_invite_bubble 内部 —— 只看整份文件 contains 的话，
	# 把调用挪到某一个来源的处理函数里（只堵住一种来源）照样绿。
	var body := _func_body(main, "func _show_invite_bubble(")
	_h.expect(body.contains("targets_room(") and body.contains("return"),
		"suppression_in_unified_entry",
		"抑制必须落在统一入口 _show_invite_bubble 内（三条来源都汇到它，漏一处就静默漏弹）")


# --- 结构：后端把 kind 带出去的三处管道 -----------------------------------------
#
# 这三处任何一处漏掉，症状都是「邀请在收件人那头渲染成普通文本 / 收不到」，都不报错。
# 实测（2026-09-27 第二轮）踩到的就是：客户端传了 kind，后端**根本没读**
# （SendBody 没字段），于是邀请按 text 落库、按 text 推送；连 history 也把 kind 丢了。
func _structure_backend_pipeline() -> void:
	var routes := FileAccess.get_file_as_string("res://backend/app/routes/chat.py")
	var chat := FileAccess.get_file_as_string("res://backend/app/chat.py")

	_h.expect(chat.contains("import json"), "backend_json_import",
		"chat.py 必须 import json —— payload 编解码用它，漏了邀请一进库就 NameError")
	_h.expect(_has_live_code(chat, "select message_id, sender_id, body, created_at, kind, payload"),
		"backend_history_select", "history 的 SQL 必须把 kind/payload 选出来")
	_h.expect(_has_live_code(chat, "_decode_payload(r[\"payload\"])"), "backend_history_decode",
		"history 组装 Message 时必须解出 payload")
	_h.expect(_has_live_code(chat, "Message(message_id, sender_id, body, row[\"created_at\"], kind, payload)"),
		"backend_send_return_kind", "chat.send 的返回 Message 必须带 kind/payload")
	# 🔴 「SendBody 有 kind」这条必须**限定在 SendBody 类体里**判 ——
	# MessageItem 也有一个同名的 `kind: str = "text"`，直接对整份 routes 做 contains
	# 会被它顶上：SendBody 把字段删了，断言照样绿（本轮实测踩到的假绿）。
	var send_body := _class_body(routes, "class SendBody(BaseModel):")
	_h.expect(send_body.contains("kind: str = \"text\""), "backend_sendbody_kind",
		"routes 的 SendBody 类体里必须有 kind 字段（没有它，客户端传了也丢）")
	_h.expect(send_body.contains("payload: dict | None"), "backend_sendbody_payload",
		"routes 的 SendBody 类体里必须有 payload 字段")
	_h.expect(_has_live_code(routes, "_validated_invite_payload(body)"), "backend_invite_validate",
		"routes 必须校验 invite payload（房间号 > 0）")
	_h.expect(_has_live_code(routes, "text, body.client_msg_id, kind, payload"), "backend_pass_through",
		"routes 必须把 kind/payload 转发给 chat.send —— 不转发就是「传了没人读」")


# --- 结构：房间开没开局不进账号服务器（2026-09-29 用户定；2026-10-11 部分推翻）------
#
# 9.28 曾让邀请人的客户端经心跳把「房间开打了没」写进账号服务器的数据库
# （player_presence.room_started，database/022），好让邀请点之前就变灰。
# 用户明确不要：点了由战斗服务器拒绝、提示「房间已开局」就够，房间状态不进数据库。
#
# ★ 10.11 bug 第 3/9 条**加回了同类信息，但换了名字与用途**：`player_presence.in_match`
#   （database/032）。区别是 —— 那个字段**不参与任何拦截**（加入时的拦截仍只在战斗
#   服务器上），只用来让好友列表显示「对局中」、把邀请按钮变灰。用户 10.11 拍板推翻
#   了 9.29 的「这条信息一律不进账号服务器」。
#   所以这里**只继续禁旧名字与旧迁移**，正向要求见 _structure_in_match_marker()。
func _structure_no_room_state_in_account_server() -> void:
	for path in ["res://backend/app/presence.py", "res://backend/app/friends.py",
			"res://backend/app/routes/presence.py", "res://backend/app/routes/friends.py",
			"res://scripts/autoload/AccountManager.gd"]:
		var src := FileAccess.get_file_as_string(path)
		if not _h.expect(not src.is_empty(), "room_state_source_unreadable", "读不到 %s" % path):
			continue
		_h.expect(not _has_live_code(src, "room_started"), "room_state_in_account_server",
			"%s 又在读写 room_started —— 那个字段 9.29 已作废；要报对局状态用 in_match（032）" % path)
	_h.expect(not FileAccess.file_exists("res://database/022_presence_room_started.sql"),
		"room_state_migration_back", "database/022_presence_room_started.sql 又回来了 —— 已作废，编号不再使用")


# --- 结构：in_match 这条链一路都在（10.11 bug 第 3/9 条）-------------------------
#
# 「字段加了但没接线」是这一批最容易出的错：接口 204、用例全绿，好友那边永远显示
# 不在对局中。所以逐层正面断言：迁移 -> 心跳写库 -> 好友列表读出来 -> 路由回给客户端
# -> 客户端上报。少任何一层，这条功能就是静默失效。
func _structure_in_match_marker() -> void:
	_h.expect(FileAccess.file_exists("res://database/032_presence_in_match.sql"),
		"in_match_migration_present", "缺 database/032_presence_in_match.sql —— 加列必须走迁移")
	var migration := FileAccess.get_file_as_string("res://database/032_presence_in_match.sql")
	_h.expect(migration.contains("add column if not exists in_match"),
		"in_match_migration_idempotent", "迁移必须是 add column if not exists（人工在 SQL Editor 可能贴两遍）")

	var presence_src := FileAccess.get_file_as_string("res://backend/app/presence.py")
	_h.expect(_has_live_code(presence_src, "in_match = excluded.in_match"),
		"in_match_heartbeat_writes", "心跳的 upsert 必须把 in_match 写进去（只收下不写库 = 永远显示不在对局中）")
	_h.expect(_has_live_code(presence_src, "\"in_match\": bool(in_match) if room_visible else False"),
		"in_match_push_privacy", "推送必须按 room_visibility 决定给不给 in_match（与拉取同口径）")

	var friends_src := FileAccess.get_file_as_string("res://backend/app/friends.py")
	_h.expect(_has_live_code(friends_src, "pr.in_match"), "in_match_friends_select",
		"好友列表的 SQL 必须把 pr.in_match 选出来")
	_h.expect(_has_live_code(friends_src, "def _in_match_visible("), "in_match_visible_helper",
		"friends 必须有 _in_match_visible 这条唯一判据（不在线 / 关掉房间可见性都不算）")

	var route_presence := FileAccess.get_file_as_string("res://backend/app/routes/presence.py")
	_h.expect(_class_body(route_presence, "class HeartbeatBody(BaseModel):").contains("in_match: bool"),
		"in_match_heartbeat_body", "PUT /v1/me/presence 的 body 必须收 in_match")
	_h.expect(_has_live_code(route_presence, "await presence.heartbeat(player_id, body.room_id, body.in_match)"),
		"in_match_route_passes", "路由必须把 body.in_match 转发给 presence.heartbeat（收下了不转发 = 永远 false）")
	var route_friends := FileAccess.get_file_as_string("res://backend/app/routes/friends.py")
	_h.expect(_class_body(route_friends, "class FriendItem(BaseModel):").contains("in_match: bool"),
		"in_match_friend_item", "GET /v1/me/friends 的每一项必须带 in_match")
	_h.expect(_has_live_code(route_friends, "in_match=r.in_match,"), "in_match_friend_item_filled",
		"好友列表组装必须把 r.in_match 填进 FriendItem（字段定义了但漏填 = 客户端永远收到 false）")

	var account_src := FileAccess.get_file_as_string("res://scripts/autoload/AccountManager.gd")
	_h.expect(_has_live_code(account_src, "\"in_match\": in_match"), "in_match_client_report",
		"客户端心跳必须把 in_match 发出去 —— 后端收不到就永远是 false")


# --- 结构：文案只有一处拼法 ----------------------------------------------------

func _structure_single_spelling() -> void:
	# 「我开启了新的房间」这句话**只能出现在 RoomInvite.gd**（脚本/场景范围内）。
	# 两处抄一遍的结果是：改文案时只改一处，两边的邀请长得不一样，且不报错。
	var dupes := _files_containing("res://scripts", "我开启了新的房间")
	dupes += _files_containing("res://scenes", "我开启了新的房间")
	_h.expect(dupes.size() == 1 and dupes[0].ends_with("RoomInvite.gd"), "single_text_spelling",
		"邀请文案只许在 RoomInvite.gd 出现，实测：%s" % str(dupes))

	var dup_expired := _files_containing("res://scripts", "邀请已过时")
	dup_expired += _files_containing("res://scenes", "邀请已过时")
	_h.expect(dup_expired.size() == 1 and dup_expired[0].ends_with("RoomInvite.gd"),
		"single_expired_spelling", "「邀请已过时」只许在 RoomInvite.gd 出现，实测：%s" % str(dup_expired))


# --- 小工具 -------------------------------------------------------------------

# 注释感知的「这段代码还活着吗」：把 GDScript 的 `#` 行注释剥掉再找。
#
# 为什么不能裸 contains：9.24 的坑 —— 把整行**注释掉**（或改成 `if false and ...`）
# 之后，源码文本里那个标识符照样在，裸 contains 依旧绿。这里只做
# 「调用点还在不在」这类存在性判断，所以剥行注释就够了（不做字符串字面量感知，
# 那需要完整词法；本文件里没有把 `#` 放进字符串的情况）。
func _has_live_code(source: String, needle: String) -> bool:
	for line in source.split("\n"):
		var code := line
		var hash := code.find("#")
		if hash >= 0:
			code = code.substr(0, hash)
		if code.contains(needle):
			return true
	return false


# 取出某个函数体源码（`func header` → 下一个顶格 `func `/`static func `/`@` 之前）。
#
# 用途：把「某处调用落在某个函数里」这类断言限定在那个函数体内 —— 直接对整份文件
# contains("targets_room(") 的话，把调用从统一入口挪到某一个来源的调用点、或挪进
# 注释都照样绿（10.11 第 6 条的变异实测）。GDScript 方法都在第 0 列，按顶格切即可。
func _func_body(source: String, header: String) -> String:
	var start := source.find(header)
	if start < 0:
		return ""
	var rest := source.substr(start + header.length())
	var cut := rest.length()
	for marker in ["\nfunc ", "\nstatic func ", "\n@"]:
		var at := rest.find(marker)
		if at >= 0:
			cut = mini(cut, at)
	return rest.substr(0, cut)


# 取出某个 Python 类的源码块（class 行 → 下一个顶层 class/def/装饰器之前）。
#
# 用途：把「SendBody 必须有 kind」这类断言**限定在那个类里**。直接对整份文件
# contains('kind: str = "text"') 会被 MessageItem 的同名字段顶上 ——
# 两个类共用一个字段名时，那个断言就永远绿（本轮实测踩到的假绿）。
func _class_body(source: String, header: String) -> String:
	var start := source.find(header)
	if start < 0:
		return ""
	var rest := source.substr(start + header.length())
	var cut := rest.length()
	for marker in ["\nclass ", "\ndef ", "\nasync def ", "\n@"]:
		var at := rest.find(marker)
		if at >= 0:
			cut = mini(cut, at)
	return rest.substr(0, cut)


# 在某个目录下递归找出**含该字符串**的 .gd 文件（用于「文案只有一处」）。
func _files_containing(root: String, needle: String) -> Array[String]:
	var out: Array[String] = []
	_walk(root, needle, out)
	out.sort()
	return out


func _walk(dir_path: String, needle: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full: String = dir_path.path_join(name)
		if dir.current_is_dir():
			_walk(full, needle, out)
		elif name.ends_with(".gd"):
			# 注释感知：注释里出现那句话不算「第二处拼法」——
			# 把说明写成注释是正常的，判据该盯的是**真在代码里拼的那一份**。
			if _has_live_code(FileAccess.get_file_as_string(full), needle):
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
