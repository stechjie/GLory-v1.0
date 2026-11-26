extends Node

# 10.07 bug 文档第 11 / 12 / 13 / 14 条：休闲/排位房间的权限与房主交接。
#
# 这四条都横跨「服务端规则 + 客户端接线」，所以判据也分两层：
#   1. 结构（这里）：客户端源码里必须真的**去掉**那些把非房主挡在外面的条件，
#      并且接上新推送（party_notice）与新的取消路径。
#   2. 行为（Python）：`backend/tests/test_party_room_stdlib.py` 直接驱动
#      `app/party.py` 的实现验服务端规则（成员可邀请 / 房主交接 / 任意成员取消）。
#      ★ 不在这里复刻一份服务端逻辑 —— 复刻版会随生产代码漂移，测了等于没测。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/party_lobby_rules_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const LOBBY := preload("res://scenes/menu/PartyLobby.gd")
const TEAM3V3 := preload("res://scenes/menu/Team3v3Lobby.gd")

const CHECK_NAME := "party_lobby_rules"
const LOBBY_SRC := "res://scenes/menu/PartyLobby.gd"
const TEAM3V3_SRC := "res://scenes/menu/Team3v3Lobby.gd"
const QUEUE_PANEL_SRC := "res://scenes/menu/MatchQueuePanel.gd"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_case_member_can_invite()
	_case_notice_wired()
	_case_any_member_cancels()
	_case_host_left_does_not_kick()
	_case_queue_canceled_wired()
	_case_mode_notice_to_members()
	_case_party_invite_reaches_chat()
	_case_member_pets()
	_case_startable_sizes()
	_case_friend_buckets()
	_h.finish(get_tree())


func _read(path: String) -> String:
	var src := FileAccess.get_file_as_string(path)
	_h.expect(not src.is_empty(), "src_readable", "读不到 %s" % path)
	return src


# 切出一个 Python 顶层函数体（从 marker 到下一个**顶格** `@` / `def` / `async def`）。
# 与 _slice_func 的区别：Python 缩进用 4 空格、顶层定义可以带装饰器前缀，
# 所以结束判据按「行首不是空白」来认。找不到返回空串。
func _slice_func_py(src: String, marker: String) -> String:
	var norm := src.replace("\r\n", "\n")
	var start := norm.find(marker)
	if start < 0:
		return ""
	var rest := norm.substr(start)
	var lines := rest.split("\n")
	var out: Array[String] = []
	for i in range(lines.size()):
		var line: String = lines[i]
		if i > 0 and not line.is_empty() and not line.begins_with(" ") and not line.begins_with("\t"):
			break
		out.append(line)
	return "\n".join(out)


func _slice_func(src: String, name: String) -> String:
	var norm := src.replace("\r\n", "\n")
	var marker := "func " + name + "("
	var start := norm.find(marker)
	if start < 0:
		return ""
	var next := norm.find("\nfunc ", start + 1)
	if next < 0:
		return norm.substr(start)
	return norm.substr(start, next - start)


# 从 `marker` 起，切到**下一个同级分支**（`elif ` / `if kind ==`）为止。
# 用来把断言钉在某一个分支体内 —— 切到函数末尾会把后面分支的代码也算进来
# （比如 closed 分支里会「看到」match 分支的 back_requested）。
# 找不到 marker 返回空串（调用方断言跟着红，不会静默通过）。
func _slice_branch(body: String, marker: String) -> String:
	return _slice_until(body, marker, "")


# 从 `marker` 起、切到 `end_marker`（空前缀 = 下一个同级分支）为止。
# end_marker 非空时按它截断 —— 用于「这个分支一直到下一个 elif 顶格为止」。
func _slice_until(body: String, marker: String, end_marker: String) -> String:
	var norm := body.replace("\r\n", "\n")
	var start := norm.find(marker)
	if start < 0:
		return ""
	var rest := norm.substr(start)
	if not end_marker.is_empty():
		var cut := rest.find(end_marker)
		if cut > 0:
			return rest.substr(0, cut)
		return rest
	# 跳过 marker 自身所在行，再找下一个同级分支起点。
	var line_end := rest.find("\n")
	if line_end < 0:
		return rest
	var search_from := line_end + 1
	var best := -1
	for tok in ["\n\telif ", "\n\tif kind == ", "\n\t\tif ", "\n\t\telif "]:
		var idx := rest.find(tok, search_from)
		if idx >= 0 and (best < 0 or idx < best):
			best = idx
	if best < 0:
		return rest
	return rest.substr(0, best)


# 第 11 条：房间里**任何人都能邀请好友**。
#
# 修复前 `avatar/invite/quick` 三个控件的 disabled 里都有 `not _is_host()`，
# 非房主看到的邀请按钮全是灰的 —— 而且**完全静默**（点不动，提示也没有）。
# 服务端 `party.invite()` 一直是 `_require_member`，所以只要客户端别拦就行。
func _case_member_can_invite() -> void:
	var src := _read(LOBBY_SRC)
	_h.expect(not src.contains("not _is_host() or not online"),
		"invite_host_gate_gone",
		"邀请按钮不再按房主身份置灰（第 11 条：成员也能邀请）")
	_h.expect(not src.contains("not _is_host() or room_count"),
		"quick_host_gate_gone",
		"快捷邀请头像不再按房主身份置灰")
	# ★★ 10.07h 第 9(3) 条返工：座位区那个「+」空位按钮**这次要放开**了。
	#
	# 上一条断言原本是**反证**（「仍限房主，别顺手放开」）—— 那是第 11 条时的口径。
	# 用户 10.07h 真机反馈写得很明确：「成员方**等待队友也要改为邀请好友**，
	# 打开可邀请好友」⇒ 成员视角那个「+」必须能点开邀请抽屉。
	#
	# 所以这里把反证**翻转**成正向断言，同时保留它本来要防的东西：
	#   ① 房主闸（`not _is_host()`）必须没了；
	#   ② 但**不能连 `queued` 一起放开** —— 排队中邀请会被服务端拒
	#      （party.Room.invite → `if room.queued: raise`），放行只会给玩家一个
	#      必然失败的入口。这条是「有意识地放开」的边界，别顺手删。
	#
	# ★★ 10-08 用户改口径：「按位置是换位，邀请人的功能做在朋友列表就好」（同自定义房间）。
	#    ⇒ 空位**不再**拉出邀请抽屉，点了是换到那个位置；邀请只在好友列表里（点整行）。
	#    上面 9(3) 那条「成员也能点」仍然成立 —— 换位谁都能换自己。
	_h.expect(not src.contains("add.disabled = _local_only or not _is_host()"),
		"seat_slot_host_gate_gone",
		"空位对成员也要能点（9(3) 条；10-08 起点空位是换位，谁都能换自己）")
	_h.expect(src.contains("add.disabled = _local_only or bool(_room.get(\"queued\", false))"),
		"seat_slot_keeps_queue_gate",
		"排队中不能换位（队伍已锁定，服务端也会拒）—— 别把 queued 一起删了")
	_h.expect(src.contains("add.pressed.connect(_move_to_seat.bind(i))")
			and not src.contains("add.pressed.connect(_toggle_friends_drawer)"),
		"seat_slot_moves_not_invites",
		"10-08：点空位 = 换到那个位置（同自定义房间），不能再拉出邀请抽屉")
	# ★★ 10.19 用户改口径：「让玩家自己按邀请，有时候只是想看看那个人的 profile」。
	#    ⇒ 点好友那一行 / 头像不能直接邀请；右侧快捷头像栏点一下 = 打开好友抽屉。
	#    10.19 换皮后头像不再是单独的按钮，画在整行点击区上面（MOUSE_FILTER_IGNORE），点头像就是点行。
	# ★★ 11-26 与自定义房间统一：点好友行 = 弹好友卡片（LobbyPopover），卡片上
	#    [查看资料] [邀请] [私聊] 同一排；行尾不再单放「邀请」键。
	_h.expect(src.contains("row.pressed.connect(_open_friend_card.bind(code, row))")
			and not src.contains("row_tap.pressed.connect(func() -> void: _invite(code))")
			and not src.contains("avatar.pressed.connect(func() -> void: _invite(code))"),
		"friend_row_opens_card",
		"11-26：点好友行 / 头像是弹好友卡片，不能直接邀请")
	var card := _slice_func(src, "_open_friend_card")
	_h.expect(card.contains("LobbyPopover.open_friend_card(")
			and card.contains("_view_member_profile(code)")
			and card.contains("_invite_from_card(code, button)")
			and card.contains("LobbyPopover.open_private_chat(self, code)"),
		"friend_card_actions",
		"11-26：好友卡片要接上 查看资料 / 邀请 / 私聊 三个动作")
	_h.expect(not src.contains("invite.pressed.connect(func() -> void: _invite(code))"),
		"friend_row_no_inline_invite",
		"11-26：行尾的「邀请」键已拿掉，邀请只在好友卡片上")
	# 11-26（第二轮）：朋友列表改成一直摆在右边（同自定义房间），快捷头像栏和抽屉都拿掉了。
	_h.expect(not src.contains("_friend_rail") and not src.contains("_toggle_friends_drawer")
			and not src.contains("quick.pressed.connect("),
		"friend_rail_gone",
		"11-26：快捷头像栏 / 好友抽屉已拿掉，邀请只有「点好友行 → 卡片」这一条路")
	# 10-08：按键尺寸照自定义房间（Team3v3Lobby），钉住几颗主要的，免得以后又各改各的。
	var custom := _read("res://scenes/menu/Team3v3Lobby.gd")
	_h.expect(custom.contains("const VOICE_BTN_SIZE := Vector2(78, 60)")
			and src.contains("const VOICE_BTN_SIZE := Vector2(78, 60)"),
		"voice_btn_size_matches_custom", "组队房语音按钮尺寸要与自定义房间一致（78×60）")
	# 10.11 第 2 条：自定义房那颗键改成了 MENU_BTN_SIZE（原 MUTE_BTN_SIZE）——
	# 静音键整颗换成「设定」键，尺寸口径没变，仍是 140×62。
	_h.expect(custom.contains("const MENU_BTN_SIZE := Vector2(140, 62)")
			and src.contains("const TOP_BTN_SIZE := Vector2(140, 62)"),
		"top_btn_size_matches_custom", "组队房顶排按键尺寸要与自定义房间的右上角键一致（140×62）")
	_h.expect(custom.contains("const PHRASE_BTN_SIZE := Vector2(162, 40)")
			and src.contains("const PHRASE_BTN_SIZE := Vector2(162, 40)"),
		"phrase_btn_size_matches_custom", "快捷短语按钮尺寸要与自定义房间一致（162×40）")


# 第 12 / 13 条：房主交接与换模式提示走新的 party_notice 推送。
func _case_notice_wired() -> void:
	var src := _read(LOBBY_SRC)
	_h.expect(src.contains("party_notice"), "notice_kind_handled",
		"客户端必须处理 party_notice 推送（房主交接 / 换模式提示）")
	_h.expect(src.contains("mode_changed"), "mode_changed_handled",
		"换模式提示要认 kind=mode_changed")
	_h.expect(src.contains("_sticky_notice"), "sticky_notice_present",
		"提示要顶过紧随其后的房间快照重绘（服务器先推 notice 再推 room）")
	_h.expect(src.contains("NOTICE_SEC"), "notice_ttl_present",
		"提示要能自动消失，别一直挂在通知栏上")


# 第 14 条：队里**任意成员**取消排队都返回房间，而不是退房。
#
# 修复前 MatchQueuePanel 对非房主调 `leave_party()` —— 那是退房，
# 所以「队员按取消」= 该队员掉出队伍（用户报的就是这个）。
func _case_any_member_cancels() -> void:
	var src := _read(QUEUE_PANEL_SRC)
	_h.expect(src.contains("cancel_party_match"), "cancel_calls_cancel",
		"取消排队必须调 cancel_party_match（全队回房间）")
	_h.expect(not src.contains("AccountManager.leave_party()"),
		"no_leave_party_on_cancel",
		"取消排队路径上不能再出现 leave_party() —— 那是退房（第 14 条的成因）")


# ★★ 10.07h 第 9(4) 条返工：房主退出**不能**把成员一起踢回主界面。
#
# 服务端 `party.Room.leave()`：房里还有别人就交接给「待得最久」的那位，只有
# 只剩自己才解散。所以「房间解散」是**只剩一人**时才该发生的事。
# 客户端把成员踢走的路径只有一条隐患：收到 `{"t":"party","state":"closed"}` 就
# `back_requested` —— 而这条消息服务器其实只推给**退出的房主本人**。
# 一旦它被推/被顺带发到成员手上，成员就被无条件踢出。
#
# 修法的判据：closed 分支必须**先自证**（复查一次房间），不能直接退。
func _case_host_left_does_not_kick() -> void:
	var src := _read(LOBBY_SRC)
	# ★ 全部断言都钉在 `_on_realtime` **函数体内**并按分支切片 ——
	#   直接对整文件做 contains 会假绿：`_refresh_room_now()` / `_show_sticky_notice(...)`
	#   在 host_left 分支里也出现，于是把 closed 分支改回 back_requested 门禁照样绿
	#   （变异实测骗过一次）。
	var realtime := _slice_func(src, "_on_realtime")
	_h.expect(not realtime.is_empty(), "realtime_present", "读不到 _on_realtime 函数体")
	var closed := _slice_until(realtime, '== "closed"', "\n\telif kind == \"party_notice\":")
	_h.expect(not closed.is_empty(), "closed_branch_present", "找不到 party/closed 分支")
	_h.expect(closed.contains("_refresh_room_now()"), "closed_rechecks",
		"收到 party/closed 必须先就地复查房间状态，再决定退不退（第 9(4) 条）")
	_h.expect(not closed.contains("back_requested.emit()"), "closed_never_kicks_directly",
		"closed 分支里不能直接 back_requested —— 那正是「房主走了成员被踢」的成因")
	# 复查必须是**只读**的：不能复用 _load_room（那条路在非 room 时会自动建房）。
	_h.expect(src.contains("func _refresh_room_now() -> void:"), "refresh_helper_exists",
		"必须有独立的只读复查 _refresh_room_now() -> void")
	var refresh_body := _slice_func(src, "_refresh_room_now")
	_h.expect(refresh_body.contains("AccountManager.fetch_party()"),
		"refresh_uses_fetch", "复查要读到当前房间状态（fetch_party）")
	_h.expect(not refresh_body.contains("create_party")
		and not refresh_body.contains("join_party")
		and not refresh_body.contains("set_party_mode"),
		"refresh_is_readonly",
		"复查**只读**：不能建房/入房/改模式（否则「我已被踢」会被拖回一个空房间）")
	# host_left 通知不能被直接丢掉（它也是「我升级成房主了」的信号源）。
	_h.expect(src.contains("\"host_left\""), "host_left_handled",
		"必须处理 party_notice 的 kind=host_left（房主交接）")
	_h.expect(not src.contains("if str(payload.get(\"kind\", \"\")) != \"mode_changed\":\n\t\t\treturn"),
		"no_early_return_swallows_host_left",
		"不能再用「非 mode_changed 就 return」把 host_left 一起吞掉")
	# ★★ 10.07i：`host_left` 必须真的**推到留下来的成员**手上。
	# 上一版只发给「退出的房主本人」（他自己已经不在房里了，等于白推），
	# 成员全靠后面那条 broadcast 刷新 —— 一丢就停在旧房主视图。
	var route_src := FileAccess.get_file_as_string("res://backend/app/routes/party.py")
	if _h.expect(not route_src.is_empty(), "be_route_readable_host_left",
			"读不到 backend/app/routes/party.py"):
		var leave_src := _slice_func_py(route_src, "async def leave(")
		_h.expect(not leave_src.is_empty(), "be_leave_present", "读不到后端 leave 路由")
		_h.expect(leave_src.contains("for pid in old_members:"),
			"be_host_left_to_members",
			"host_left 必须遍历其余成员推送（不能只发给退出的房主本人）")
		_h.expect(leave_src.contains("\"kind\": \"host_left\""),
			"be_host_left_payload",
			"host_left 的 payload 要带 kind=host_left（客户端靠它认）")
		_h.expect(leave_src.contains("new_host_code"),
			"be_host_left_new_host",
			"host_left 要带上新队长好友码，成员侧才知道接手的是谁")


# ★★ 10.07h/i 第 9(6) 条返工：**任意成员**取消排队 → 所有人回房、匹配弹窗关闭、提示取消者。
func _case_queue_canceled_wired() -> void:
	var src := _read(LOBBY_SRC)
	_h.expect(src.contains("signal queue_canceled"), "queue_canceled_signal",
		"PartyLobby 必须发 queue_canceled 信号（与 queue_started 配对）")
	# ★★ 10.07i：取消判据改成**闩**（`_party_queue_active`），不能再用
	#   `_room.queued` / `_queue_opened` —— 服务器 `/cancel` 的顺序是
	#   「先广播 party(queued=false) 再推 match idle」，等 idle 到达时那两个
	#   字段已被快照抹平（真机表现：房主一直显示匹配中）。
	_h.expect(src.contains("var _party_queue_active := false"),
		"queue_latch_field", "必须有一个不随 queued=false 落的「正在排队」闩")
	# ★ 变异实测：只查「字段存在」会被 `_party_queue_active = true` 改成 `= false` 骗过
	#   （闩永远不立 ⇒ 取消检测彻底失效，但字段声明还在）。必须**正面断言它被立起来**，
	#   而且是在「进队」那一支里立的。
	var apply_body := _slice_func(src, "_apply")
	var latch_set := _slice_branch(apply_body, "_party_queue_active = true")
	_h.expect(not latch_set.is_empty(), "queue_latch_is_set",
		"进队时必须把闩立起来（_party_queue_active = true）—— 只声明不赋值等于没有")
	_h.expect(src.contains("var was_queued := _party_queue_active"),
		"detect_cancel_via_latch",
		"取消检测要用闩，不能用会被 party 快照抹平的 _room.queued / _queue_opened")
	_h.expect(not src.contains("var was_queued := bool(_room.get(\"queued\", false)) or _queue_opened"),
		"no_stale_queue_judgement",
		"旧的 _room.queued or _queue_opened 判据必须删掉（它会被播放顺序骗）")
	# ★★ 10.07i：`match state=queued` 是**正常排队回波**，绝不能触发取消 ——
	#   否则房主一点开始匹配，自己这条回波就把刚弹出的「匹配中」面板关掉
	#   （用户真机原话：「再次修复后，反而 bug 增加了。现在点开始匹配后发现匹配中弹窗消失了」）。
	var realtime := _slice_func(src, "_on_realtime")
	var queued_branch := _slice_until(realtime, 'match_state == "queued"', "\n\t\telif match_state == \"idle\":")
	_h.expect(not queued_branch.is_empty(), "queued_branch_present",
		"match 分支必须把 state=queued 单独分开处理")
	_h.expect(not queued_branch.contains("queue_canceled.emit"),
		"queued_never_cancels",
		"state=queued 绝不能发 queue_canceled（那会把房主自己的排队回波读成取消）")
	_h.expect(not queued_branch.contains("back_requested.emit"),
		"queued_never_kicks",
		"state=queued 绝不能 back_requested")
	# 昵称要显示出来（需求：提示 XXX 取消了排队，无数字 ID）。
	_h.expect(src.contains("取消了排队"), "cancel_tip_text",
		"必须给出「XXX 取消了排队」的提示文案")
	_h.expect(not src.contains("#%s 取消了排队"),
		"cancel_tip_no_id", "提示里的昵称不能带 #ID")
	# ★★ 10.07i：自己按取消不能提示「队友取消了排队」（主语错了）——
	#   Main 关面板时要通知房间落闩。
	_h.expect(src.contains("func note_self_canceled_queue() -> void:"),
		"self_cancel_helper", "PartyLobby 要有 note_self_canceled_queue() 供 Main 调")
	var main_src := FileAccess.get_file_as_string("res://scenes/main/Main.gd")
	if _h.expect(not main_src.is_empty(), "main_readable", "读不到 Main.gd"):
		_h.expect(main_src.contains("lobby.connect(\"queue_canceled\""),
			"main_connects_cancel", "Main 必须接 queue_canceled")
		_h.expect(main_src.contains("ModalStack.pop(MATCH_QUEUE_MODAL_ID)"),
			"main_pops_queue_panel", "收到取消要关掉「匹配中」弹窗")
		# ★ 变异实测：这条原来写成「不含某个**具体** lambda 文本」，只要把 lambda 体
		#   换一个字（`pass`）就绕过去了 —— 典型的弱否定断言。
		#   改成**正面断言**：dismissed 连到的必须是 `_on_match_queue_dismissed`，
		#   且整文件里不能再出现任何 `panel.connect("dismissed", func(` 的匿名写法。
		_h.expect(main_src.contains("panel.connect(\"dismissed\", _on_match_queue_dismissed)"),
			"main_dismiss_goes_through_helper",
			"面板 dismissed 必须连到 _on_match_queue_dismissed（要顺手落闩）")
		_h.expect(not main_src.contains("panel.connect(\"dismissed\", func("),
			"main_dismiss_not_anonymous",
			"面板 dismissed 不能再挂匿名 lambda（挂了就落不了闩，会误报「队友取消了排队」）")
		_h.expect(main_src.contains("child.call(\"note_self_canceled_queue\")"),
			"main_notifies_self_cancel",
			"自己取消排队后要通知房间落闩，否则会误报「队友取消了排队」")
	# ★ 后端必须把取消者昵称送出来 —— 只断言「有 mode_changed / 房主更换了」证明不了
	#   这条（变异实测：删掉 by_name 门禁照样绿）。「提示 XXX 取消了排队」靠它。
	var mk_src := FileAccess.get_file_as_string("res://backend/app/matchmaking.py")
	if _h.expect(not mk_src.is_empty(), "be_matchmaking_readable", "读不到 backend/app/matchmaking.py"):
		_h.expect(mk_src.contains("def idle_message(reason: str = \"\", by_name: str = \"\") -> dict:"),
			"be_idle_message_signature", "idle_message 必须支持 by_name 参数")
		_h.expect(mk_src.contains("out[\"by_name\"] = by_name"),
			"be_idle_message_sets_by_name", "idle_message 必须把 by_name 放进消息里")
	var route_src2 := FileAccess.get_file_as_string("res://backend/app/routes/party.py")
	if _h.expect(not route_src2.is_empty(), "be_route_readable2", "读不到 backend/app/routes/party.py"):
		_h.expect(route_src2.contains("matchmaking.idle_message(\"party_cancelled\", by_name=my_name)"),
			"be_leave_passes_canceller",
			"取消排队必须把取消者昵称推给其他成员（用 by_name=）")


# ★★ 10.07h 第 9(5) 条返工：房主换模式，**成员**要看到提示。
func _case_mode_notice_to_members() -> void:
	var src := _read(LOBBY_SRC)
	# ★ 切到 mode_changed 分支断言 —— 对整文件 contains 会假绿（host_left 分支里
	#   也有同一行 `_show_sticky_notice(str(payload.get("text", "")))`，变异实测骗过一次）。
	var realtime := _slice_func(src, "_on_realtime")
	# mode_changed 分支：10-08 起 party_notice 按 kind 走 match（host_left / kicked / mode_changed），
	# 从 `"mode_changed":` 那一支起，到 `elif kind == "match"` 为止。
	# （原来的锚点是「非 mode_changed 就 return」那一行，而上面 no_early_return_swallows_host_left
	#  又禁止那一行出现 —— 两条断言不可能同时为真。）
	var mode_branch := _slice_until(realtime, "\"mode_changed\":", "\n\telif kind == \"match\":")
	_h.expect(not mode_branch.is_empty(), "mode_branch_present",
		"找不到 kind=mode_changed 分支")
	# 提示要真的写进 _notice（而不是只记 sticky 不算显示）。
	_h.expect(mode_branch.contains("_show_sticky_notice(str(payload.get(\"text\", \"\")))"),
		"mode_notice_shown",
		"换模式提示必须显示出来（走 _show_sticky_notice）")
	# 服务端只推给非房主，客户端也要保证房主自己不重复显示。
	_h.expect(mode_branch.contains("if _preview == \"\" and not _is_host():"),
		"mode_notice_skips_host",
		"换模式提示只给成员看（房主是自己操作的）")
	# 提示必须能顶过紧随其后的房间快照重绘。
	_h.expect(src.contains("_sticky_notice"), "mode_notice_sticky",
		"提示要 sticky（服务器先推 notice 再推 room 快照，_apply 会重写 _notice）")
	# 后端确实推了这条。
	var route_src := FileAccess.get_file_as_string("res://backend/app/routes/party.py")
	if _h.expect(not route_src.is_empty(), "be_route_readable", "读不到 backend/app/routes/party.py"):
		_h.expect(route_src.contains("mode_changed"), "be_mode_notice",
			"服务端换模式必须推 party_notice/kind=mode_changed")
		_h.expect(route_src.contains("房主更换了"), "be_mode_text",
			"服务端提示文案必须是「房主更换了休闲/排位模式」")


# ★★ 10.07i 第 9(2) 条返工：组队邀请后，**被邀请人**的聊天里要有这条邀请消息
# （与自定义房间邀请同一套口径，只是文案不同：标题「组队邀请」、正文
# 「快来加入队伍，一起战斗吧」、按钮「加入」）。
#
# 根因：服务端 `invite()` 里 `chat.send(...)` **只落库**，推送是调用方的事；
# 上一版把返回值丢掉了 ⇒ 消息进了库却从没推给收件人，在线时聊天里看不到。
# 这里钉三件事：① 后端把 dm 推出去；② dm 的 kind 是 party_invite；
# ③ 客户端聊天界面认这个 kind（气泡 + 列表预览都不空白）。
func _case_party_invite_reaches_chat() -> void:
	var route_src := FileAccess.get_file_as_string("res://backend/app/routes/party.py")
	if _h.expect(not route_src.is_empty(), "be_invite_readable",
			"读不到 backend/app/routes/party.py"):
		var invite_src := _slice_func_py(route_src, "async def invite(")
		_h.expect(not invite_src.is_empty(), "be_invite_present", "读不到后端 invite 路由")
		# ① 落库的返回值必须接住（丢掉 = 无法推送）。
		_h.expect(invite_src.contains("sent = await chat.send("),
			"be_invite_keeps_send_result",
			"invite 必须接住 chat.send 的返回值（丢掉就永远推不出去）")
		# ② 必须真的把 dm 推给收件人（chat.send 只落库，不推送）。
		_h.expect(invite_src.contains("\"t\": \"dm\""),
			"be_invite_pushes_dm",
			"组队邀请必须推一条 dm 给收件人（否则聊天里没有这条消息）")
		_h.expect(invite_src.contains("sent.deliver_to is not None"),
			"be_invite_deliver_guard",
			"按 deliver_to 判是否推送（与 routes/chat.py 同口径；None = 静默丢弃/重发）")
		_h.expect(invite_src.contains("chat.PARTY_INVITE_KIND"),
			"be_invite_kind",
			"落库与推送都要用 PARTY_INVITE_KIND（kind 对不上则渲染成普通文本）")
	var chat_src := FileAccess.get_file_as_string("res://scenes/menu/ChatScreen.gd")
	if _h.expect(not chat_src.is_empty(), "chat_readable", "读不到 ChatScreen.gd"):
		_h.expect(chat_src.contains("RoomInvite.is_any_invite(msg)"),
			"chat_renders_party_bubble",
			"聊天界面要把组队邀请也渲染成邀请卡片（is_any_invite）")
		_h.expect(chat_src.contains("RoomInvite.party_display_text(msg)"),
			"chat_party_text",
			"组队邀请正文读 party_display_text（缺 body 时退回本地文案，不显示空白）")


# ★★ 11-26（用户改口径，替掉 10.09 那套「房主勾选展示宠物」）：
#   · 房间里走动的宠物 = **每个成员当前的出战宠物**，一人一只，脚下写玩家名字；
#   · 「宠物」键 = 直接换**自己的**出战宠物，谁都能点；
#   · 排队中不能换；只听得到自己那只的脚步声。
#
# 判据分两层：
#   1. 客户端（这里）：member_pet_of / pet_switch_locked 两个纯静态合同直接喂数据；
#      真 new 一个房间界面调 _stage_members()；再钉接线（_apply → _sync_stage、
#      面板点一行 → PlayerProfile.set_active）。
#   2. 服务端行为：`backend/tests/test_party_room_stdlib.py`（成员条目带 pet、换宠物后
#      快照跟着变）与 `backend/tests/test_shop.py`（排队中换宠物 409、换完推房间快照）。
func _case_member_pets() -> void:
	var src := _read(LOBBY_SRC)
	# 行为：某个成员该出哪只。
	_h.expect(LOBBY.member_pet_of({"pet": "pet_fox"}, false, "pet_cat", "pet_dog") == "pet_fox",
		"member_pet_from_snapshot", "队友的宠物以房间快照里他那一条的 pet 为准")
	_h.expect(LOBBY.member_pet_of({"pet": "pet_fox"}, true, "pet_cat", "") == "pet_cat",
		"own_pet_from_profile", "自己那只用本机的出战宠物（换了马上就对，不等快照）")
	_h.expect(LOBBY.member_pet_of({"pet": "pet_fox"}, true, "", "") == "pet_fox",
		"own_pet_falls_back_to_snapshot", "本机还没拿到宠物数据时，自己那只退回快照里的")
	_h.expect(LOBBY.member_pet_of({"host": true}, false, "pet_cat", "pet_dog") == "pet_dog",
		"old_server_host_pet", "旧账号服务器（成员条目没有 pet）：房主那只用快照的 host_pet")
	_h.expect(LOBBY.member_pet_of({"host": false}, false, "pet_cat", "pet_dog") == "",
		"old_server_member_no_pet", "旧账号服务器：其他队友不出宠物（不拿别人的宠物冒充）")
	_h.expect(LOBBY.member_pet_of({}, false, "pet_cat", "") == "",
		"member_without_pet_empty", "没有宠物的成员留空（舞台那边不出模型）")
	# 行为：面板上的行什么时候点不动。
	_h.expect(not LOBBY.pet_switch_locked(false, false, false),
		"pet_switch_open", "连着队伍、没在排队、没在等上一次回包 ⇒ 能换")
	_h.expect(LOBBY.pet_switch_locked(false, true, false),
		"pet_switch_locked_in_queue", "排队中不能换出战宠物")
	_h.expect(LOBBY.pet_switch_locked(true, false, false),
		"pet_switch_locked_local_only", "队伍服务没连上时不能换")
	_h.expect(LOBBY.pet_switch_locked(false, false, true),
		"pet_switch_locked_while_pending", "上一次还没回包时不能再点第二只")
	# 行为：真 new 一个房间界面、真调 _stage_members()。
	var lobby := LOBBY.new()
	var self_code := str(AccountManager.profile.get("friend_code", ""))
	if self_code.is_empty():
		self_code = "SELF0001"
	var saved_profile: Dictionary = AccountManager.profile
	var saved_active := str(PlayerProfile.active_pet)
	AccountManager.profile = {"friend_code": self_code, "player_name": "我"}
	PlayerProfile.active_pet = "pet_probe_self"
	lobby._preview = ""
	lobby._room = {"host_code": "MATE0002", "host_pet": "pet_probe_host", "members": [
		{"friend_code": "MATE0002", "player_name": "队友", "host": true, "pet": "pet_probe_mate"},
		{"friend_code": self_code, "player_name": "我", "host": false, "pet": "pet_probe_stale"},
		{"friend_code": "MATE0003", "player_name": "新人", "host": false},
	]}
	var staged: Array = lobby._stage_members()
	_h.expect(staged.size() == 3, "stage_one_entry_per_member", "一个成员一条（实得 %d）" % staged.size())
	if staged.size() == 3:
		_h.expect(str(staged[0].key) == "MATE0002" and str(staged[0].pet) == "pet_probe_mate"
				and not bool(staged[0].audible),
			"stage_mate_pet", "队友：出他自己的出战宠物，脚步声不响")
		_h.expect(str(staged[1].key) == self_code and str(staged[1].pet) == "pet_probe_self"
				and bool(staged[1].audible),
			"stage_own_pet", "自己：出本机的出战宠物（不是快照里那只旧的），只有这只有脚步声")
		_h.expect(str(staged[2].pet) == "",
			"stage_no_pet_member", "没有 pet 的队友留空")
		_h.expect(not str(staged[0].name).is_empty() and not str(staged[0].name).contains("#"),
			"stage_name_plain", "模型脚下写的是玩家名字，不带 #好友码")
	AccountManager.profile = saved_profile
	PlayerProfile.active_pet = saved_active
	lobby.free()
	# 接线：_apply / 本地兜底 / 自己换宠物，都要把成员表交给舞台。
	var sync_body := _slice_func(src, "_sync_stage")
	_h.expect(sync_body.contains("_stage.configure_party_members(_stage_members()"),
		"stage_gets_members", "宠物舞台要按「一个成员一只」重建（configure_party_members）")
	_h.expect(not src.contains("configure_party_display("),
		"old_display_list_gone", "旧的「展示宠物列表」那条路不能留着（两套一起跑会各出各的）")
	var apply_body := _slice_func(src, "_apply")
	_h.expect(apply_body.contains("_sync_stage()"), "apply_syncs_stage",
		"房间快照一来就要重排场上的宠物（有人进出 / 队友换了宠物）")
	var local_body := _slice_func(src, "_on_local_pets_changed")
	_h.expect(local_body.contains("_sync_stage()") and local_body.contains("_render_pets()"),
		"own_switch_repaints", "自己换了出战宠物：面板和场上那只马上跟着变")
	# 接线：面板点一行 = 换自己的出战宠物（走背包里换出战的同一个接口）。
	var render_body := _slice_func(src, "_render_pets")
	_h.expect(render_body.contains("choice.pressed.connect(_switch_pet.bind(pet_id))"),
		"pet_row_switches", "面板上点一只 = 换成出战宠物")
	_h.expect(render_body.contains("choice.disabled = locked"),
		"pet_row_lock_wired", "排队中 / 没连上 / 等回包时整列点不动")
	var switch_body := _slice_func(src, "_switch_pet")
	_h.expect(switch_body.contains("await PlayerProfile.set_active(pet_id)"),
		"switch_uses_profile_api", "换出战宠物走 PlayerProfile.set_active（和背包同一个接口）")
	_h.expect(switch_body.contains("pet_switch_locked("),
		"switch_second_gate", "_switch_pet 自己再判一次锁（面板那行禁用是第一道）")
	_h.expect(not src.contains("set_party_pets"),
		"display_pets_api_unused", "「展示宠物」取消了，客户端不该再调 set_party_pets")
	# 「宠物」键：谁都看得到，排队中禁用（不是藏起来 —— 藏了玩家会以为功能没了）。
	_h.expect(apply_body.contains("_pet_toggle.disabled = bool(_room.get(\"queued\", false))")
			and not apply_body.contains("_pet_toggle.visible = host"),
		"pet_button_for_everyone", "「宠物」键不再只给房主；排队中禁用")
	# 服务端：成员条目带 pet；换宠物同步进房间并广播；排队中拒绝。
	var party_src := FileAccess.get_file_as_string("res://backend/app/party.py")
	if _h.expect(not party_src.is_empty(), "be_party_readable_1126", "读不到 backend/app/party.py"):
		_h.expect(party_src.contains("\"pet\": room.active_pets.get(pid, \"\")"),
			"be_snapshot_member_pet", "房间快照的每个成员条目必须带 pet（他的出战宠物）")
		_h.expect(party_src.contains("\"host_pet\": room.active_pets.get(room.host, \"\")"),
			"be_snapshot_host_pet", "快照仍带 host_pet（旧客户端还在读它）")
		_h.expect(party_src.contains("def set_member_pet(self, player: uuid.UUID, pet_id: str)"),
			"be_set_member_pet", "要有 set_member_pet：成员换了出战宠物，房间里那份跟着换")
		_h.expect(party_src.contains("def room_locked_for_pet(self, player: uuid.UUID) -> bool:"),
			"be_room_locked_for_pet", "要有 room_locked_for_pet：排队中不许换")
	var shop_src := FileAccess.get_file_as_string("res://backend/app/routes/shop.py")
	if _h.expect(not shop_src.is_empty(), "be_shop_readable_1126", "读不到 backend/app/routes/shop.py"):
		_h.expect(shop_src.contains("party.current().room_locked_for_pet(me.player_id)"),
			"be_switch_rejects_in_queue", "换出战宠物的接口：排队中要拒绝")
		_h.expect(shop_src.contains("party.current().set_member_pet(me.player_id, pets.active)"),
			"be_switch_updates_room", "换出战宠物成功后要同步进队伍房间（队友才看得到）")
	var route_src := FileAccess.get_file_as_string("res://backend/app/routes/party.py")
	if _h.expect(not route_src.is_empty(), "be_route_readable_1009", "读不到 backend/app/routes/party.py"):
		_h.expect(route_src.contains("pets_state.active"),
			"be_route_passes_active", "建房/入房路由要把玩家的出战宠物交给服务端")



# ★★ 10.15b：「几个人能开始匹配」由**服务器下发**（房间快照的 `startable_sizes`）——
# 开关 `GLORY_PARTY_FULL_TEAM_ONLY` 只在账号服务器的 `.env` 里，翻它**不用出新客户端包**。
# 也就是说客户端**必须**真的读快照：自己硬编码一份，服务端翻了开关客户端毫无反应，而且**静默**。
#
# 判据分两层，客户端这半边在这里；服务端规则在 `backend/tests/test_party_room_stdlib.py`
# （`test_snapshot_tells_client_which_sizes_can_start`，两条分支都断言）。
#   ① **结构** —— `_startable_sizes()` 从 `_room` 取 `startable_sizes`、逐个 `int()`
#      （JSON 里的数字到客户端是 float，`Array.has(2)` 不认 `2.0`）、类型不对时回落旧口径；
#      灰按钮那处**必须走 `_startable_sizes()`** —— 回头用常量 ⇒ 新服务端放开 2 人组队也还是灰的。
#   ② **运行期** —— 真 new 一个房间界面、手塞 `_room` 调真函数，覆盖服务端真会下发的几种形态。
func _case_startable_sizes() -> void:
	var src := _read(LOBBY_SRC)
	# ① 结构
	var body := _slice_func(src, "_startable_sizes")
	_h.expect(not body.is_empty(), "sizes_helper_present",
		"读不到 _startable_sizes()（灰按钮的人数判据就是它）")
	_h.expect(body.contains("_room.get(\"startable_sizes\")"),
		"sizes_reads_snapshot",
		"_startable_sizes() 必须真的从房间快照取 startable_sizes（否则服务端开关翻不动）")
	_h.expect(body.contains("int(value)"),
		"sizes_coerces_to_int",
		"快照里的数字到客户端是 float，必须逐个 int() —— 否则 has(2) 对不上 2.0，永远开不了")
	_h.expect(body.contains("is Array") and body.contains("STARTABLE_SIZES"),
		"sizes_type_guard_falls_back",
		"快照没这个键 / 类型不对（旧服务端）时必须回落到 STARTABLE_SIZES")
	_h.expect(src.contains("const STARTABLE_SIZES := [1, 3]"),
		"sizes_fallback_is_old_rule",
		"回落口径必须是改动前的 [1, 3]（旧服务端本来就只让单人或满 3 人开）")
	_h.expect(src.contains("_startable_sizes().has("),
		"sizes_gate_goes_through_helper",
		"开始匹配的人数判据必须走 _startable_sizes()")
	_h.expect(not src.contains("STARTABLE_SIZES.has("),
		"sizes_no_direct_constant_use",
		"不许再出现 STARTABLE_SIZES.has(...)：那是改动前的写法，会让服务端的开关彻底失效")
	# ② 运行期。用 Callable 而不是直接调用：哪天这个函数改名 / 被删，直接调用会让**整个脚本
	#    解析失败** ⇒ 场景没有脚本 ⇒ 进程不退出（「假挂」而不是判红，见 10-15 的教训）。
	var lobby: Control = LOBBY.new()
	var sizes := Callable(lobby, "_startable_sizes")
	var callable_ok := _h.expect(sizes.is_valid(), "sizes_helper_callable",
		"房间界面上没有可调用的 _startable_sizes() —— 结构断言全绿也白搭")
	# ★ Callable 失效时**不能直接 call()**：那会抛运行期错误把本函数当场中断，下面 6 条
	#   运行期断言一条都不会执行（实测 checked 131→125）—— 正是「该量的没量到」的形态。
	#   显式记账：那 6 条不是「通过」，是「无从执行」。
	if not callable_ok:
		_h.fail("sizes_runtime_unavailable",
			"_startable_sizes() 不存在 ⇒ 6 条运行期判据无从执行（不是通过）")
		lobby.free()
		return
	# 旧服务端：快照里根本没这个键。
	lobby._room = {}
	_h.expect(sizes.call() == [1, 3], "sizes_runtime_old_server",
		"快照没有 startable_sizes（旧服务端 / 未部署）⇒ 运行期回落 [1, 3]")
	_h.expect(not sizes.call().has(2), "sizes_runtime_old_server_blocks_two",
		"旧服务端口径下 2 人不能开匹配（回落值必须是旧的，不能偷偷放开）")
	# 新服务端、开关关（默认）：快照 [1,2,3]；JSON 真形态是 float。
	lobby._room = {"startable_sizes": [1.0, 2.0, 3.0]}
	_h.expect(sizes.call() == [1, 2, 3], "sizes_runtime_float_coerced",
		"快照下发 [1.0,2.0,3.0]（float）⇒ 必须转成 [1,2,3]")
	_h.expect(sizes.call().has(2), "sizes_runtime_two_allowed",
		"服务端放开 2 人组队时客户端必须认 —— 这条就是「翻开关不用出包」的客户端判据")
	# 新服务端、开关开：快照 [1,3]。
	lobby._room = {"startable_sizes": [1.0, 3.0]}
	_h.expect(not sizes.call().has(2) and sizes.call().has(3),
		"sizes_runtime_two_blocked", "服务端只给 [1,3] ⇒ 2 人灰、3 人可开")
	# 脏数据：类型不对 ⇒ 回落，不许崩、也不许当真。
	lobby._room = {"startable_sizes": "1,2,3"}
	_h.expect(sizes.call() == [1, 3], "sizes_runtime_bad_type_falls_back",
		"startable_sizes 不是 Array ⇒ 回落 [1,3]")
	lobby.free()
	_h.note("startable_sizes：服务端可达集合只有 [1,3] 与 [1,2,3]（MAX_MEMBERS=3）；"
		+ "灰按钮旁「只能单人或满 3 人开始匹配」是硬编码文案，这两种集合下都不会说谎，故不钉死。"
		+ "哪天服务端能下发别的集合，PartyLobby.gd 那句文案要跟着改。")



# 10.11 bug 第 3 / 9 条：好友列表的分档与过滤。
#
# 第 3 条（排位/休闲房间）：「可邀请 → 对局中 → 离线」三档；对局中那位按钮写「对局中」并禁用。
# 第 9 条（自定义房间）：只显示「在线且不在对局中」的好友。
#
# 判据分两层，缺一不可：
#   ① **行为** —— 直接调两个纯判据函数（_friend_bucket / _can_invite_online_friend），
#      覆盖「离线压过 in_match」「字段缺失」「脏数据」这些结构断言看不出来的分支；
#   ② **结构** —— 这两个函数真的被渲染路径用上了。「定义了不接线」在这里完全静默：
#      列表照旧按老规则渲染，用例全绿。
func _case_friend_buckets() -> void:
	var lobby: Control = LOBBY.new()
	# ① 行为：三档判据。
	_h.expect(lobby._friend_bucket({"online": false, "in_match": true}) == lobby.FRIEND_OFFLINE,
		"bucket_offline_wins", "离线必须归离线档 —— 哪怕 in_match 还是掉线那一刻的值")
	_h.expect(lobby._friend_bucket({"online": true, "in_match": true}) == lobby.FRIEND_IN_MATCH,
		"bucket_in_match", "在线且对局中 -> 对局中档")
	_h.expect(lobby._friend_bucket({"online": true, "in_match": false}) == lobby.FRIEND_INVITABLE,
		"bucket_invitable", "在线且不在对局中 -> 可邀请档")
	_h.expect(lobby._friend_bucket({}) == lobby.FRIEND_OFFLINE,
		"bucket_missing_fields", "字段缺失按离线处理 —— 旧后端不返回 in_match 时不能误判成可邀请")
	_h.expect(lobby.FRIEND_INVITABLE == 0 and lobby.FRIEND_IN_MATCH == 1 and lobby.FRIEND_OFFLINE == 2,
		"bucket_order", "三档的数值就是排序：可邀请(0) -> 对局中(1) -> 离线(2)")
	lobby.free()

	# ② 结构：分档真的接进了渲染路径。
	var src := _read(LOBBY_SRC)
	_h.expect(src.contains("for bucket in [FRIEND_INVITABLE, FRIEND_IN_MATCH, FRIEND_OFFLINE]"),
		"friend_rows_bucketed", "好友列表必须按三档依次渲染（不是只按在线/离线两档）")
	_h.expect(src.contains("str(f.get(\"in_match\", false))"), "friend_signature_includes_in_match",
		"内容签名必须带 in_match —— 否则数据变了列表不重建（10.10 的签名去重是按内容跳过的）")
	var row := _slice_func(src, "_render_friends")
	if _h.expect(not row.is_empty(), "friend_render_found", "切不出 PartyLobby._render_friends"):
		_h.expect(row.contains("_friend_list.add_child(_friend_row(friend, bucket))"),
			"friend_rows_built_per_bucket", "三档里的每个好友都要出一行（11-26 起列表一直摆着，离线的也列）")
	# 11-26：「对局中写『对局中』并禁用」从行尾键搬到了好友卡片的邀请键上。
	var invite_state := _slice_func(src, "_friend_invite_state")
	if _h.expect(not invite_state.is_empty(), "friend_invite_state_found", "切不出 PartyLobby._friend_invite_state"):
		_h.expect(invite_state.contains("FRIEND_IN_MATCH:")
				and invite_state.contains("return {\"text\": _text(\"对局中\", \"In match\"), \"enabled\": false}"),
			"in_match_button_disabled", "对局中那一档，卡片上的邀请键要写「对局中」且禁用")
		_h.expect(invite_state.contains("return {\"text\": _text(\"离线\", \"Offline\"), \"enabled\": false}"),
			"offline_button_disabled", "离线那一档，卡片上的邀请键要写「离线」且禁用")
		_h.expect(invite_state.contains("members.size() >= 3"),
			"full_party_button_disabled", "队伍满 3 人时卡片上的邀请键要禁用")

	# 第 9 条：自定义房间的好友列表。
	# ★★ 11-26 用户改口径：列表显示**全部**好友（在线 / 对局中 / 离线），
	#    _can_invite_online_friend 从「列表过滤」改成「卡片上的邀请键能不能点」。判据本身不变。
	var t3: Node = TEAM3V3.new()
	_h.expect(t3._can_invite_online_friend({"online": true, "in_match": false}),
		"t3_online_invitable", "在线且不在对局中 -> 能邀请")
	_h.expect(not t3._can_invite_online_friend({"online": true, "in_match": true}),
		"t3_in_match_hidden", "在线但在对局中 -> 不能邀请")
	_h.expect(not t3._can_invite_online_friend({"online": false, "in_match": false}),
		"t3_offline_hidden", "不在线 -> 不能邀请")
	_h.expect(not t3._can_invite_online_friend({"online": false, "in_match": true}),
		"t3_offline_after_match_hidden", "离开对局但对局未结束（离线 + in_match）-> 不能邀请")
	_h.expect(not t3._can_invite_online_friend("nonsense"),
		"t3_non_dict_hidden", "非字典项直接跳过（后端列表混进脏数据也不能崩）")
	# 三档与排位房同口径。
	_h.expect(t3._friend_bucket({"online": false, "in_match": true}) == t3.FRIEND_OFFLINE
			and t3._friend_bucket({"online": true, "in_match": true}) == t3.FRIEND_IN_MATCH
			and t3._friend_bucket({"online": true, "in_match": false}) == t3.FRIEND_INVITABLE
			and t3._friend_bucket({}) == t3.FRIEND_OFFLINE,
		"t3_buckets", "自定义房间的三档判据要与排位房一致")
	# ★ 10.11 第 6 条 i：**已经在本房间里**的好友不该被邀请
	#   （对他在点邀请没有意义 —— 邀请消息指向的就是他已经在的那个房）。
	#   自定义房间的成员只存在于战斗服务器上，账号服务器不知道 ⇒ 只能客户端判。
	var saved_room := int(NetworkService.team_room_id)
	NetworkService.team_room_id = 4242
	var t3r: Node = TEAM3V3.new()
	_h.expect(not t3r._can_invite_online_friend(
			{"online": true, "in_match": false, "room_id": 4242}), "t3_same_room_hidden",
		"已经在本房间的好友 → 不能邀请（第 6 条 i：点了既不发消息也不弹窗）")
	_h.expect(not bool(t3r._friend_invite_state(
			{"friend_code": "ABCD2345", "online": true, "in_match": false, "room_id": 4242}).get("enabled", true)),
		"t3_same_room_card_disabled", "已经在本房间的好友 → 卡片上的邀请键禁用")
	_h.expect(t3r._can_invite_online_friend(
			{"online": true, "in_match": false, "room_id": 99}), "t3_other_room_shown",
		"在别的房间的好友 → 能邀请（第 6 条 j：别的房间的邀请要能发出去）")
	_h.expect(t3r._can_invite_online_friend(
			{"online": true, "in_match": false, "room_id": null}), "t3_null_room_shown",
		"room_id 为 null（后端「房间不可见」）时既不能崩、也不能误判成同房间")
	_h.expect(t3r._can_invite_online_friend({"online": true, "in_match": false}),
		"t3_missing_room_shown", "没有 room_id 字段（旧后端）→ 能邀请，不能误判")
	t3r.free()
	NetworkService.team_room_id = saved_room
	t3.free()

	var t3_src := _read(TEAM3V3_SRC)
	var render := _slice_func(t3_src, "_render_online_friends")
	if _h.expect(not render.is_empty(), "t3_render_found", "切不出 Team3v3Lobby._render_online_friends"):
		_h.expect(render.contains("for bucket in [FRIEND_INVITABLE, FRIEND_IN_MATCH, FRIEND_OFFLINE]")
				and not render.contains("_can_invite_online_friend(entry)"),
			"t3_all_friends_bucketed", "11-26：列表按三档列出全部好友，不再按「能不能邀请」过滤")
	var invite_state := _slice_func(t3_src, "_friend_invite_state")
	if _h.expect(not invite_state.is_empty(), "t3_invite_state_found", "切不出 Team3v3Lobby._friend_invite_state"):
		_h.expect(invite_state.contains("_can_invite_online_friend(entry)"),
			"t3_filter_wired", "卡片上的邀请键必须经过 _can_invite_online_friend —— 定义了不接线等于没做")
