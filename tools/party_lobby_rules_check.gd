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

const CHECK_NAME := "party_lobby_rules"
const LOBBY_SRC := "res://scenes/menu/PartyLobby.gd"
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
	_h.expect(not src.contains("add.disabled = _local_only or not _is_host()"),
		"seat_slot_host_gate_gone",
		"空位的「+」按钮必须对成员放开（第 9(3) 条：成员方等待队友也要改为邀请好友）")
	_h.expect(src.contains("add.disabled = _local_only or bool(_room.get(\"queued\", false))"),
		"seat_slot_keeps_queue_gate",
		"放开房主闸之后，排队中仍然不能邀请（服务端会拒）—— 别把 queued 一起删了")


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
