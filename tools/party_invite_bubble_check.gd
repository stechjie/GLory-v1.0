extends Node

# 10.07 bug 文档第 6 / 10 条：主界面邀请气泡。
#
# 判据分两层：
#   1. 行为：`PartyInviteBubble` 的排队语义 —— 需求那几条写得很死，逐条钉：
#        · 多个邀请**覆盖**：同时来两条，只显示一张卡（MAX_VISIBLE=1）；
#        · 「处理完最新的后显示上一个」：把当前这条处理掉，**被顶掉的那条要回来**；
#        · 每条**独立计时**、最多 30 秒：排队的也要一起计时，不能永远挂着；
#        · 处理过的 party_id **不再弹第二次**（服务器可能重推）。
#   2. 结构：`Main` 里真的接了气泡，且**没有**再对邀请用 DialogService
#      （那走 ModalStack，栈顶 backdrop 是 STOP —— 与「不处理不影响主界面操作」相反）。
#
# ★ 行为断言走**真 PartyInviteBubble 实例**，不直读源码。
#   结构断言只补一条「接线在不在」，证明不了排队语义对不对。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/party_invite_bubble_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const BubbleScript := preload("res://ui/components/PartyInviteBubble.gd")
const MAIN_SRC := "res://scenes/main/Main.gd"

const CHECK_NAME := "party_invite_bubble"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	await get_tree().process_frame

	await _case_single_invite_shows()
	await _case_multiple_overwrites()
	await _case_handled_resurfaces_previous()
	await _case_duplicate_ignored()
	await _case_ttl_is_thirty_seconds()
	_case_on_handled_fires_on_all_paths()
	_case_main_wiring()
	await _case_anchor_from_chat_button()
	_case_bubble_look_and_feel()

	_h.finish(get_tree())


func _make() -> Node:
	var bubble: Node = BubbleScript.new()
	add_child(bubble)
	return bubble


func _entry_count(bubble: Node) -> int:
	return (bubble.get("_entries") as Array).size()


func _pending_count(bubble: Node) -> int:
	return (bubble.get("_pending") as Array).size()


# 1) 一条邀请 → 立刻显示一张卡，标题/正文按需求话术拼。
func _case_single_invite_shows() -> void:
	var bubble := _make()
	var ok := bool(bubble.call("offer", {
		"party_id": "p1", "host_name": "星河", "kind": "party"}))
	_h.expect(ok, "offer_accepted", "一条新邀请应当被接受并排上队")
	_h.expect(_entry_count(bubble) == 1, "one_card_visible",
		"一条邀请应显示一张卡，实际 %d" % _entry_count(bubble))
	var entries: Array = bubble.get("_entries")
	var card: Variant = (entries[0] as Dictionary).get("card")
	_h.expect(card is Node and is_instance_valid(card), "card_is_node", "卡片必须是真节点")
	if card is Node:
		# 正文必须含昵称、且**不含 friend_code**（需求：只写朋友XX，没有 ID 数字）。
		var body := ""
		var found := _find_label((card as Node), "Body")
		if found != null:
			body = found.text
		_h.expect(body.contains("星河"), "body_has_nickname",
			"正文应含昵称「星河」，实际 '%s'" % body)
		_h.expect(not body.contains("#"), "body_has_no_id",
			"正文不应带 #ID（需求：朋友昵称，没有 ID 数字），实际 '%s'" % body)
	bubble.queue_free()


func _find_label(root: Node, name_text: String) -> Label:
	if root.name == name_text and root is Label:
		return root as Label
	for child in root.get_children():
		var hit := _find_label(child, name_text)
		if hit != null:
			return hit
	return null


# 2) 两条邀请 → 只显示一张（覆盖）。
func _case_multiple_overwrites() -> void:
	var bubble := _make()
	bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})
	bubble.call("offer", {"party_id": "p2", "host_name": "乙", "kind": "party"})
	_h.expect(_entry_count(bubble) == 1, "only_one_visible",
		"同时两条邀请只应显示一张卡（需求：多个邀请会覆盖），实际 %d" % _entry_count(bubble))
	_h.expect(_pending_count(bubble) == 1, "second_queued",
		"后一条不该被丢掉，应退回等待队列，实际 pending=%d" % _pending_count(bubble))
	bubble.queue_free()


# 3) 处理掉当前这条 → 队列里的上一条补位（需求原话：处理完最新的后显示上一个）。
func _case_handled_resurfaces_previous() -> void:
	var bubble := _make()
	bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})
	bubble.call("offer", {"party_id": "p2", "host_name": "乙", "kind": "party"})
	# 「稍后」= 处理掉当前正在显示的那条（p1）。
	bubble.call("_dismiss", "p1", "later")
	_h.expect(_entry_count(bubble) == 1, "previous_resurfaced",
		"处理掉当前这条后，排队等着的那条必须补位显示，实际 %d" % _entry_count(bubble))
	var entries: Array = bubble.get("_entries")
	if _entry_count(bubble) == 1:
		_h.expect(str((entries[0] as Dictionary).get("party_id", "")) == "p2",
			"resurfaced_is_the_other",
			"补位的应当是另一个 party_id(p2)，实际 %s" % str((entries[0] as Dictionary).get("party_id", "")))
	bubble.queue_free()


# 4) 同一个 party_id 重复推 → 不再弹（服务器重推 / 来回切页面）。
func _case_duplicate_ignored() -> void:
	var bubble := _make()
	_h.expect(bool(bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})),
		"first_ok", "首次邀请应被接受")
	_h.expect(not bool(bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})),
		"dup_rejected_while_showing", "同 party_id 正在显示时不该再排一条")
	bubble.call("_dismiss", "p1", "later")
	_h.expect(not bool(bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})),
		"handled_never_again", "处理过的邀请不该再弹（需求：处理过的邀请不再提示）")
	_h.expect(_entry_count(bubble) == 0, "nothing_shown_after_handled", "处理过的不该留下卡片")
	bubble.queue_free()


# 5) 30 秒上限：TTL 常量必须是 30，且排队的条目也带自己的绝对截止时刻。
func _case_ttl_is_thirty_seconds() -> void:
	var bubble := _make()
	bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})
	bubble.call("offer", {"party_id": "p2", "host_name": "乙", "kind": "party"})
	_h.expect(is_equal_approx(float(bubble.get("TTL_SEC")), 30.0), "ttl_is_30",
		"每条邀请最多保留 30 秒，实际 TTL_SEC=%s" % str(bubble.get("TTL_SEC")))
	var pending: Array = bubble.get("_pending")
	if pending.size() == 1:
		var deadline := float((pending[0] as Dictionary).get("deadline", 0.0))
		_h.expect(deadline > Time.get_ticks_msec() / 1000.0, "queued_has_deadline",
			"排队等待的那条也必须带自己的截止时刻（独立计时），实际 deadline=%f" % deadline)
	else:
		_h.expect(false, "pending_present", "应有 1 条在等待队列里，实际 %d" % pending.size())
	bubble.queue_free()


# 5.5) ★ 10.07 第 6/10 条返工（用户真机反馈「点击稍后后，红点仍然存在，
#      要改成点击稍后表示已读该信息，红点消失」）：
#      气泡被**任何方式处理**（稍后 / 加入 / 超时）时，都必须回调 `on_handled` 一次 ——
#      Main 用它去清发件人的本地红点。这是那条需求的技术落点。
func _case_on_handled_fires_on_all_paths() -> void:
	# —— 路径 a：「稍后」——
	var bubble := _make()
	var later_calls := [0]
	var accepted_calls := [0]
	bubble.call("offer", {
		"party_id": "p1", "host_name": "甲", "kind": "party",
		"on_handled": func(_pid: String) -> void: later_calls[0] += 1,
		"on_accept": func(_pid: String) -> void: accepted_calls[0] += 1,
	})
	bubble.call("_dismiss", "p1", "later")
	_h.expect(later_calls[0] == 1, "on_handled_later",
		"点「稍后」必须回调 on_handled 一次（= 标已读、清红点），实际 %d" % later_calls[0])
	_h.expect(accepted_calls[0] == 0, "on_accept_not_called_on_later",
		"点「稍后」不该触发 on_accept（不能误加入）")
	bubble.queue_free()

	# —— 路径 b：「超时」——
	var bubble2 := _make()
	var timeout_calls := [0]
	bubble2.call("offer", {
		"party_id": "p2", "host_name": "乙", "kind": "party",
		"on_handled": func(_pid: String) -> void: timeout_calls[0] += 1,
	})
	bubble2.call("_dismiss", "p2", "timeout")
	_h.expect(timeout_calls[0] == 1, "on_handled_timeout",
		"超时作废也必须回调 on_handled（否则红点永远留着）")
	bubble2.queue_free()

	# —— 路径 c：没给 on_handled 也不能崩（老调用点仍然能跑）——
	var bubble3 := _make()
	var survived := true
	bubble3.call("offer", {"party_id": "p3", "host_name": "丙", "kind": "party"})
	bubble3.call("_dismiss", "p3", "later")
	survived = _entry_count(bubble3) == 0
	_h.expect(survived, "on_handled_optional",
		"没传 on_handled 时 _dismiss 不能崩（Callable 有效性要先判）")
	bubble3.queue_free()

	# —— 结构：Main → ChatService.mark_seen_locally 的接线必须在 ——
	var src := FileAccess.get_file_as_string(MAIN_SRC)
	if not src.is_empty():
		_h.expect(src.contains("mark_seen_locally"), "main_clears_unread",
			"Main 处理气泡时必须调 ChatService.mark_seen_locally 清本地红点")
		_h.expect(src.contains("\"on_handled\""), "main_passes_on_handled",
			"Main 必须把 on_handled 传进 bubble.offer")
		# ★ 只断言「出现过 host_code」太弱：把取值改成 `:= ""` 也能骗过。
		#   改成钉**整条取值表达式** —— 必须真的从 payload 取 host_code 回退 from_code。
		_h.expect(src.contains(
			"str(payload.get(\"host_code\", payload.get(\"from_code\", \"\")))"),
			"main_uses_host_code", "发送人好友码必须从 payload.host_code 取（回退 from_code）")
		# 且必须把 sender_code 真交给 mark_seen_locally（不能清成常量）。
		_h.expect(src.contains("ChatService.mark_seen_locally(sender_code)"),
			"main_passes_sender_code", "mark_seen_locally 的实参必须是 sender_code")
	var bubble_src := FileAccess.get_file_as_string("res://ui/components/PartyInviteBubble.gd")
	if not bubble_src.is_empty():
		_h.expect(bubble_src.contains("handler is Callable"),
			"bubble_guards_callable", "气泡回调前必须先判 Callable 有效性")


# 6) 结构：Main 接了气泡，且邀请**不再**走 DialogService.confirm。
func _case_main_wiring() -> void:
	var src := FileAccess.get_file_as_string(MAIN_SRC)
	if not _h.expect(not src.is_empty(), "main_src_readable", "读不到 Main.gd"):
		return
	_h.expect(src.contains("PartyInviteBubble"), "bubble_referenced",
		"Main 必须引用 PartyInviteBubble")
	_h.expect(src.contains("_show_invite_bubble") or src.contains("bubble.offer"),
		"bubble_offered", "Main 必须把邀请交给气泡（offer）")
	_h.expect(src.contains("KIND_TEAM") and src.contains("KIND_PARTY"),
		"both_kinds_wired", "第 6 条（房间）与第 10 条（组队）两种邀请都要接上")
	_h.expect(src.contains("_invite_bubble"), "bubble_field_present",
		"Main 里应有 _invite_bubble 字段持住这一层")


# ★★ 10.07h 第 6 / 10 条返工：位置 —— 「从『聊天』UI 旁边引出」。
#
# 判据分三层，缺一层都证明不了需求被满足：
#   a) 气泡真的**按锚点摆**（行为）：喂一个锚点进去，`_list.position` 必须落在
#      锚点右边 ANCHOR_GAP、垂直居中。只断言「有个 set_anchor 方法」是空断言。
#   b) 锚点**来自聊天按钮**（结构）：`MainMenu.chat_invite_anchor()` 必须存在，
#      且真的是从**聊天图标节点**的全局矩形算的（不是写死常量）。
#   c) Main 真的把锚点**喂进去**（接线）：`_show_invite_bubble` 里必须有
#      `bubble.set_anchor(_chat_invite_anchor())`，且 `_chat_invite_anchor()`
#      对「主菜单不在」有守卫（`has_method` / `is_instance_valid`）。
func _case_anchor_from_chat_button() -> void:
	# —— a) 摆位行为 ——
	var bubble := _make()
	await get_tree().process_frame
	var anchor := Vector2(400.0, 300.0)
	bubble.call("set_anchor", anchor)
	bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})
	await get_tree().process_frame
	var list: Variant = bubble.get("_list")
	if _h.expect(list is Control, "list_is_control", "气泡栈必须是个 Control"):
		var ctrl := list as Control
		var gap := float(bubble.get("ANCHOR_GAP"))
		_h.expect(gap > 0.0, "anchor_gap_positive", "锚点与气泡之间要留间距，实际 %f" % gap)
		# x 必须 = 锚点.x + GAP（「在按钮右边」）。
		_h.expect(is_equal_approx(ctrl.position.x, anchor.x + gap), "placed_right_of_anchor",
			"气泡左边应贴在锚点右侧 %.1f 处，实际 x=%.1f（锚点 %.1f）" % [
				gap, ctrl.position.x, anchor.x])
		# y 必须让气泡**垂直居中于锚点**（尖角才对得准按钮中心）。
		var want_y := anchor.y - ctrl.size.y * 0.5
		_h.expect(absf(ctrl.position.y - want_y) < 0.5, "placed_vcentered_on_anchor",
			"气泡应垂直居中于锚点（期望 y≈%.1f），实际 y=%.1f" % [want_y, ctrl.position.y])
		# ★ 反向断言：不能再是「贴屏幕右边」的旧行为。
		_h.expect(not ctrl.anchor_left == 1.0 and not ctrl.anchor_right == 1.0,
			"not_right_edge_anchored",
			"返工前气泡锚在屏幕右上角（anchor_left/right=1.0），必须已改掉")
	bubble.queue_free()

	# —— a2) 拿不到锚点（INF）时不能把气泡扔到屏幕外/原点 ——
	var bubble2 := _make()
	await get_tree().process_frame
	bubble2.call("set_anchor", Vector2.INF)
	bubble2.call("offer", {"party_id": "p2", "host_name": "乙", "kind": "party"})
	await get_tree().process_frame
	var list2: Variant = bubble2.get("_list")
	if list2 is Control:
		var pos2 := (list2 as Control).position
		_h.expect(is_finite(pos2.x) and is_finite(pos2.y),
			"fallback_finite", "拿不到聊天按钮时必须走兜底位置，不能是 INF，实际 %s" % str(pos2))
		_h.expect(pos2.x > 0.0 and pos2.y > 0.0,
			"fallback_onscreen", "兜底位置也必须在屏幕内（左侧社交栏附近），实际 %s" % str(pos2))
	bubble2.queue_free()

	# —— b) 锚点来源必须真来自聊天按钮 ——
	var menu_src := FileAccess.get_file_as_string("res://scenes/menu/MainMenu.gd")
	if _h.expect(not menu_src.is_empty(), "menu_src_readable", "读不到 MainMenu.gd"):
		# ★ 断言到「函数签名整行」而不是 `contains("func chat_invite_anchor")`：
		#   后者改名成 `chat_invite_anchor_off()` 也会命中（变异实测骗过门禁）。
		_h.expect(menu_src.contains("func chat_invite_anchor() -> Vector2:"),
			"menu_exposes_anchor", "MainMenu 必须提供 chat_invite_anchor() -> Vector2")
		_h.expect(menu_src.contains("_chat_icon.get_global_rect()"),
			"menu_anchor_from_chat_icon",
			"锚点必须从聊天图标节点的全局矩形现算（随安全区/缩放变），不能写死常量")
		_h.expect(menu_src.contains("_chat_icon = _add_texture(TEX_CHAT"),
			"menu_keeps_chat_icon_ref",
			"聊天图标节点必须留引用（_chat_icon），否则拿不到它的位置")

	# —— c) Main 真的把锚点喂了进去 ——
	var main_src := FileAccess.get_file_as_string(MAIN_SRC)
	if not main_src.is_empty():
		_h.expect(main_src.contains("bubble.set_anchor(_chat_invite_anchor())"),
			"main_feeds_anchor",
			"_show_invite_bubble 必须把聊天按钮锚点喂给气泡（bubble.set_anchor(_chat_invite_anchor())）")
		_h.expect(main_src.contains("func _chat_invite_anchor", ),
			"main_anchor_helper", "Main 必须有 _chat_invite_anchor() 取锚点")
		_h.expect(main_src.contains("func _chat_invite_anchor() -> Vector2:"),
			"main_anchor_helper_signature",
			"_chat_invite_anchor 必须无参返回 Vector2（变异：改名即失效）")
		_h.expect(main_src.contains("_menu.has_method(\"chat_invite_anchor\")"),
			"main_guards_menu_method",
			"_chat_invite_anchor 必须先判主菜单有没有这个方法（别硬 call）")


# ★★ 10.07h 第 6 / 10 条返工：外观 —— 「重新设计出符合游戏风格和颜色」。
#
# 判据：气泡必须是**信息气泡框**（有指向按钮的尖角）＋**用 Tokens 的配色**
# （与主菜单其它弹层同一族），而不是返工前那种自己写死深灰色 + 方形卡片。
func _case_bubble_look_and_feel() -> void:
	var bubble := _make()
	bubble.call("offer", {"party_id": "p1", "host_name": "甲", "kind": "party"})
	var entries: Array = bubble.get("_entries")
	if not _h.expect(entries.size() == 1, "card_present_for_look",
		"应有 1 张卡可查外观，实际 %d" % entries.size()):
		bubble.queue_free()
		return
	var card: Variant = (entries[0] as Dictionary).get("card")
	if card is Node:
		var node := card as Node
		# 外层是 HBox（左尖角 + 右卡片）：结构上就说明有尖角。
		_h.expect(node is HBoxContainer, "card_outer_is_hbox",
			"气泡卡片外层应是 HBox（容纳左侧尖角 + 右侧卡片），实际 %s" % node.get_class())
		var tail := node.get_node_or_null("Tail")
		_h.expect(tail != null, "tail_present",
			"必须有一枚 Tail 尖角节点（需求：以信息气泡框的形式引出）")
		var panel := node.get_node_or_null("InvitePanel")
		_h.expect(panel != null, "panel_present", "尖角右边应有卡片本体 InvitePanel")
		if tail is Control:
			var tail_ctrl := tail as Control
			_h.expect(is_equal_approx(tail_ctrl.custom_minimum_size.x, float(bubble.get("TAIL_W"))),
				"tail_width_matches",
				"尖角宽度应等于 TAIL_W，实际 %.1f" % tail_ctrl.custom_minimum_size.x)
			_h.expect(tail_ctrl.draw.get_connections().size() > 0,
				"tail_draws_polygon",
				"尖角必须真的画了（_draw 有接线），否则就是一个透明占位")
		# 主按钮（加入/立即参与）必须是主操作样式，不是和「稍后」长得一样。
		var accept := node.get_node_or_null("InvitePanel")
		if accept != null:
			var accept_btn := _find_button(accept as Node, "Accept")
			var later_btn := _find_button(accept as Node, "Later")
			_h.expect(accept_btn != null and later_btn != null, "buttons_present",
				"气泡里必须有 Accept / Later 两个按钮")
			if accept_btn != null and later_btn != null:
				_h.expect(accept_btn.has_theme_stylebox_override("normal")
					and later_btn.has_theme_stylebox_override("normal"),
					"buttons_styled", "两个按钮都要有自定义样式（用 Tokens 配色，不是默认灰）")
	bubble.queue_free()

	# 配色必须来自 Tokens（与「雾林夜幕」那一族同源），不是本文件写死的字面量。
	var bubble_src := FileAccess.get_file_as_string("res://ui/components/PartyInviteBubble.gd")
	if not bubble_src.is_empty():
		_h.expect(bubble_src.contains("return Tokens.MIST_PANEL"), "bg_from_tokens",
			"气泡底色必须取 Tokens.MIST_PANEL（游戏风格配色），不能写死深灰字面量")
		_h.expect(bubble_src.contains("return Tokens.MIST_GOLD"), "edge_from_tokens",
			"气泡描边必须取 Tokens.MIST_GOLD")
		_h.expect(bubble_src.contains("return Tokens.MIST_GOLD_BRIGHT"), "title_from_tokens",
			"标题色必须取 Tokens.MIST_GOLD_BRIGHT")
		_h.expect(bubble_src.contains("return Tokens.MIST_TEXT"), "body_from_tokens",
			"正文色必须取 Tokens.MIST_TEXT")
		# 返工前那两行写死的颜色必须已经消失。
		_h.expect(not bubble_src.contains("Color(0.06, 0.08, 0.09, 0.94)"),
			"old_bg_literal_removed", "返工前写死的深灰底色字面量必须已删除")
		_h.expect(not bubble_src.contains("Color(1.0, 0.94, 0.84)"),
			"old_body_literal_removed", "返工前写死的正文色字面量必须已删除")


func _find_button(root: Node, name_text: String) -> Button:
	if root.name == name_text and root is Button:
		return root as Button
	for child in root.get_children():
		var hit := _find_button(child, name_text)
		if hit != null:
			return hit
	return null
