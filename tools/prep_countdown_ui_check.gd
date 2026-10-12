extends Node

# 10.12 bug 文档第 6 条（备战阶段倒计时）—— **客户端可见的那一半**的判据。
#
# 为什么另起一个门禁：接手时已有的 `tools/bug_1012_356_check.gd` 把第 6 条测得很实，
# 但测的全是 `scripts/rounds/PrepDeadline.gd`（时长 / remaining / deploy 顺序 /
# 幂等 / 不白送）—— 那是**服务端与结算口径**。文档里真正写死的客户端表现有三处
# 它一条都没碰：
#   * 「准备」按钮文字后面跟「（xx s）」
#   * 最后 3 秒**屏幕正中间**的大号 3! / 2! / 1!
#   * 那个数字**不挡棋盘**（要能一边看数字一边继续操作）
# 这三种都恰好是"坏了也不报错"的类型：标签少一个后缀、提示框跑到屏幕外、
# 提示框变成 MOUSE_FILTER_STOP 把棋盘吃掉一半点击 —— 哪一个都不会抛异常。
#
# 判据：
#   A 非教学局里 PrepCountdown 被挂上（教学局里 _process 直接让开）
#   B 数字提示真的落在**屏幕正中**（读 global rect 与中心比，不是"设过 position"）
#   C 它不挡输入：mouse_filter == IGNORE；且字号够大、有描边（能看清）
#   D 只在 3 / 2 / 1 三秒显示，文案 "N!"；4 秒与 0 秒都不显示
#   E 准备按钮文字带「（N s）」后缀，且这个 N 真的来自倒计时
#   F 时长：PVE 35s、PVP/最终 50s
#   H **离线自测不装倒计时**（用户 10.12 追加口径：「离线自测还是保持原来的无倒计时」）
#     —— 判据是「节点不存在 + meta 没被写 + 按钮没有后缀」，外加一个反向对照
#     （offline_selftest 关掉后必须重新装上），否则本段会因为接线整体坏掉而假绿。
#   H2 接线判据（源码级）：倒计时的 if 必须带 is_offline_team_match()，而
#     prepare_local_bots()（第 5 条 AI 经济）**不能**被关进同一个 if。
#   H3 离线自测也**不自动上阵**（倒计时到点的另一半）：直接调
#     `_auto_deploy_at_deadline()`，棋盘字节必须不变；另配对照组证明判据非空转。
#   H4 **联机客机也必须看得见倒计时**（用户 10.12 返修口径：「第 6 点只不生效于离线
#     自测房间，其他房间对局要生效」）。判据三段：①服务端没给 prep 信息时倒计时
#     照常可见（meta 写下 + 按钮带后缀）②服务端给了 prep_seconds_left 时以服务端
#     为准（不能被本地时钟盖掉）③客机到点做本地自动上阵，但**不**替服务端置 ready。
#     ★ 自定义房间的房主在专服上也是 `is_host == false` 的客机，本段就是那条症状。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path . tools/prep_countdown_ui_check.tscn

const H := preload("res://tools/CheckHarness.gd")
const PREP := preload("res://scenes/prep/PrepScreen.tscn")
const Deadline := preload("res://scripts/rounds/PrepDeadline.gd")

const CHECK_NAME := "prep_countdown_ui"

var h
var _prep: Control
var _cd: Control
var _cue: Label


func _ready() -> void:
	h = H.new(CHECK_NAME)
	GameState.reset_run()
	GameState.tutorial_mode = false
	NetworkService.team_active = false
	NetworkService.is_host = false
	_prep = PREP.instantiate()
	add_child(_prep)
	for _i in 14:
		await get_tree().process_frame

	_cd = _prep.find_child("PrepCountdown", true, false)
	_cue = _prep.find_child("FinalSeconds", true, false)

	_section_wired()
	_section_centered_and_nonblocking()
	_section_cue_window()
	_section_button_label()
	_section_tutorial_hands_off()
	_section_durations()
	await _section_offline_selftest_has_no_countdown()
	_section_offline_selftest_wiring()
	await _section_offline_selftest_no_auto_deploy()
	await _section_online_client_countdown_visible()

	_prep.queue_free()
	await get_tree().process_frame
	GameState.tutorial_mode = false
	NetworkService.offline_selftest = false
	h.finish(get_tree())


# --- A 接线 -------------------------------------------------------------------

func _section_wired() -> void:
	if not h.expect(_cd != null, "countdown_missing",
			"非教学局的备战界面没有挂 PrepCountdown —— 倒计时整条都不存在"):
		return
	h.expect(_cd.get("_screen") == _prep, "countdown_screen_unbound",
		"PrepCountdown._screen 不是宿主备战界面（_ready 里 get_parent() 拿错层）")
	if not h.expect(_cue != null, "cue_missing", "PrepCountdown 里没有 FinalSeconds 数字标签"):
		return


# --- B/C 正中间 + 不挡棋盘 ------------------------------------------------------

func _section_centered_and_nonblocking() -> void:
	if _cue == null or _prep == null:
		return
	# ★ 不能拿 `global_position + size*0.5` 当中心：`_show_cue()` 会把 scale 打到
	#   1.25（脉冲），而 Control 的 scale 是绕 pivot_offset 缩放的 —— 矩形左上角
	#   会随之平移，但**视觉中心**不动。要量视觉中心就得走变换：
	#   local(0,0) 是左上角、local(size*0.5) 是矩形中心，用 global_transform 映过去。
	_cue.scale = Vector2.ONE          # 先复位，量静态布局
	var center := _cue_visual_center()
	var want := _prep.global_position + _prep.size * 0.5
	# 容差 1px：锚点按父级尺寸算，理论上正好 0；给 1px 免得被取整抖动打红。
	h.expect(absf(center.x - want.x) <= 1.0 and absf(center.y - want.y) <= 1.0,
		"cue_not_centered",
		"最后 3 秒的数字没在屏幕正中：提示中心 %s，屏幕中心 %s（偏差 %s）。文档要求「屏幕正中间」" % [
			str(center), str(want), str(center - want)])
	# 脉冲把 scale 打到 1.25；pivot 必须正好是矩形中心，否则每跳一下数字就甩偏一次。
	var pivot := _cue.pivot_offset
	h.expect(absf(pivot.x - _cue.size.x * 0.5) <= 1.0 and absf(pivot.y - _cue.size.y * 0.5) <= 1.0,
		"cue_pulse_pivot_off",
		"pivot_offset=%s 不是标签中心 %s —— 脉冲缩放会绕着一个角放大，数字每跳一次就偏一段" % [
			str(pivot), str(_cue.size * 0.5)])
	h.expect(_cue.mouse_filter == Control.MOUSE_FILTER_IGNORE, "cue_blocks_board",
		"数字提示的 mouse_filter=%d（应为 IGNORE=2）—— 它会吃掉棋盘的点击，文档要求「不挡住棋盘」" % _cue.mouse_filter)
	var vp := get_viewport().get_visible_rect().size
	h.expect(Rect2(Vector2.ZERO, vp).intersects(Rect2(_cue.global_position, _cue.size)),
		"cue_offscreen", "数字提示的矩形整块都在视口外，玩家根本看不到")
	h.expect(_cue.get_theme_font_size("font_size") >= 48, "cue_too_small",
		"数字提示字号只有 %d，文档要的是「大」号、能制造紧张感" % _cue.get_theme_font_size("font_size"))
	var ink := _cue.get_theme_color("font_color")
	h.expect(ink.a > 0.5, "cue_invisible_ink", "数字提示的前景色 alpha=%f，等于看不见" % ink.a)
	h.expect(_cue.get_theme_constant("outline_size") >= 1, "cue_no_outline",
		"数字提示没有描边 —— 压在浅色棋盘上会糊掉")


# 标签「视觉中心」的全局坐标：local(0,0) 是左上角、local(size*0.5) 是矩形中心。
# 走 global_transform 才能把 pivot 缩放的位移算进去（见上面的注释）。
func _cue_visual_center() -> Vector2:
	return _cue.get_global_transform() * (_cue.size * 0.5)


# --- D 只在最后 3 秒显示 -------------------------------------------------------

func _section_cue_window() -> void:
	if _cd == null or _cue == null:
		return
	_cd.call("_show_cue", 4)
	h.expect(not _cue.visible, "cue_shown_at_4",
		"第 4 秒就显示了倒计时提示 —— 文档只要求最后 3 秒")
	for n in [3, 2, 1]:
		_cd.call("_show_cue", n)
		h.expect(_cue.visible and _cue.text == "%d!" % n, "cue_wrong_at_%d" % n,
			"第 %d 秒应显示「%d!」，实际 visible=%s text=%s" % [n, n, str(_cue.visible), _cue.text])
		# 脉冲把 scale 打到 1.25；这里量的是**视觉中心**（含 pivot 缩放），
		# 证明"跳一下"不会把数字甩出屏幕正中。
		var c := _cue_visual_center()
		var w := _prep.global_position + _prep.size * 0.5
		h.expect(absf(c.x - w.x) <= 1.0 and absf(c.y - w.y) <= 1.0, "cue_drift_at_%d" % n,
			"显示第 %d 秒时脉冲把数字甩离了屏幕正中：视觉中心 %s，屏幕中心 %s（偏差 %s）" % [
				n, str(c), str(w), str(c - w)])
	_cd.call("_show_cue", 0)
	h.expect(not _cue.visible, "cue_shown_at_0", "到 0 秒还挂着提示 —— 应该交给自动上阵")


# --- E 准备按钮的「（N s）」后缀 ------------------------------------------------

func _section_button_label() -> void:
	var lbl: Variant = _prep.get("_start_battle_label")
	if not h.expect(lbl != null, "start_label_missing",
			"备战界面没有 _start_battle_label，第 6 条的「（xx s）」无处可写"):
		return
	# 倒计时真的在跑：_process 会把剩余整秒写进 meta。
	var live: Variant = _prep.get_meta("prep_countdown_seconds", -1)
	h.expect(int(live) >= 0, "countdown_meta_missing",
		"跑满 14 帧后 prep_countdown_seconds 仍是 %s —— 倒计时没有驱动按钮文案" % str(live))
	# 后缀用的是 meta 里那个数：把 meta 钉成 7 再刷一次，文案必须跟着变。
	_prep.set_meta("prep_countdown_seconds", 7)
	_prep.call("_refresh_start_button_label")
	h.expect(str((lbl as Label).text).contains("(7 s)"), "countdown_suffix_missing",
		"准备按钮文案没有「（xx s）」后缀：实际「%s」（把 meta 钉成 7 之后）" % str((lbl as Label).text))


# --- F 教学局不接管 ------------------------------------------------------------

func _section_tutorial_hands_off() -> void:
	if _cd == null or _cue == null:
		return
	GameState.tutorial_mode = true
	_cd.set("_expired", false)
	_cd.set("_deadline", 0.0)          # 已经过期
	_cd.call("_process", 0.016)
	h.expect(not bool(_cd.get("_expired")), "tutorial_countdown_expired",
		"教学局里倒计时仍然走到过期 —— 教学有自己的流程，会被自动上阵/自动开战打断")
	h.expect(not _cue.visible, "tutorial_cue_shown", "教学局里也弹了 3!/2!/1! 提示")
	GameState.tutorial_mode = false
	# 收尾：把 deadline 推远，免得本帧剩下的自动 _process 真的走到过期、
	# 在无队伍状态下触发一次开战请求（那是另一个副作用，不该由本门禁制造）。
	_cd.set("_expired", false)
	_cd.set("_deadline", Time.get_ticks_msec() / 1000.0 + 999.0)


# --- G 时长口径 ---------------------------------------------------------------

func _section_durations() -> void:
	var pve := 0
	var pvp := 0
	for r in range(1, 22):
		var kind := str(RoundService.schedule_kind_for_round(r))
		if kind in ["pvp", "final"] and pvp == 0:
			pvp = r
		elif not (kind in ["pvp", "final"]) and pve == 0:
			pve = r
	h.expect(pve > 0 and is_equal_approx(Deadline.duration(pve), 35.0), "pve_duration",
		"PVE（含 boss）回合时长应为 35 秒，第 %d 回合实测 %s" % [pve, str(Deadline.duration(pve))])
	h.expect(pvp > 0 and is_equal_approx(Deadline.duration(pvp), 50.0), "pvp_duration",
		"PVP 回合时长应为 50 秒，第 %d 回合实测 %s" % [pvp, str(Deadline.duration(pvp))])


# --- H 离线自测不装倒计时（用户 10.12 追加口径）--------------------------------

func _section_offline_selftest_has_no_countdown() -> void:
	# 夹具自检：先确认真能表示「离线自测对局」（team_active 为假 + offline_selftest 置起）。
	NetworkService.team_active = false
	NetworkService.is_host = false
	NetworkService.offline_selftest = true
	if not h.expect(NetworkService.is_offline_team_match(), "offline_fixture_broken",
			"offline_selftest 置起且无联机会话时 is_offline_team_match() 必须为真，否则本段测不到东西"):
		return

	var offline_prep := await _fresh_prep()
	var offline_cd: Node = offline_prep.find_child("PrepCountdown", true, false)
	h.expect(offline_cd == null, "offline_selftest_has_countdown",
		"离线自测的备战界面挂了 PrepCountdown —— 用户口径是「离线自测保持原来的无倒计时」")
	h.expect(int(offline_prep.get_meta("prep_countdown_seconds", -1)) == -1,
		"offline_selftest_wrote_meta",
		"离线自测里仍写了 prep_countdown_seconds —— 倒计时那套时钟在跑")
	var lbl: Variant = offline_prep.get("_start_battle_label")
	if lbl != null:
		offline_prep.call("_refresh_start_button_label")
		h.expect(not str((lbl as Label).text).contains(" s)"), "offline_selftest_suffix",
			"离线自测的准备按钮仍带「（xx s）」后缀：实际「%s」" % str((lbl as Label).text))
	offline_prep.queue_free()
	await get_tree().process_frame

	# 反向对照：offline_selftest 清掉后必须**重新装上**倒计时 —— 证明本段不是
	# 因为「PrepScreen 整体坏了 / 节点改名了」而假绿。
	NetworkService.offline_selftest = false
	h.expect(not NetworkService.is_offline_team_match(), "offline_flag_stuck",
		"清掉 offline_selftest 后仍被判成离线自测，判据卡死了")
	var online_prep := await _fresh_prep()
	h.expect(online_prep.find_child("PrepCountdown", true, false) != null,
		"countdown_lost_after_offline_toggle",
		"非离线自测的备战界面反而没有 PrepCountdown —— 接线被误伤")
	online_prep.queue_free()
	await get_tree().process_frame


func _fresh_prep() -> Control:
	GameState.tutorial_mode = false
	var prep: Control = PREP.instantiate()
	add_child(prep)
	for _i in 14:
		await get_tree().process_frame
	return prep


# --- H2 接线判据（源码级）：只让开倒计时，别把第 5 条的 AI 经济一起让开 ----------
#
# 行为判据看不到这一条：`prepare_local_bots()` 在没有 dummy 座位的夹具里本来就不
# 产生可观测副作用（`LiveBotEconomy.prepare` 只给 "dummy" 座位建机器人）。而
# 「把两个 if 合成一个」恰恰是最容易犯、后果又是「离线自测里 AI 对手没有经济」
# 的错。所以按 `match_exit_check` 的惯例，扫一眼源码里的**守卫**。
func _section_offline_selftest_wiring() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/prep/PrepScreen.gd")
	if not h.expect(not src.is_empty(), "prep_source_unreadable",
			"读不到 scenes/prep/PrepScreen.gd 源码，接线判据失效"):
		return
	var cd_guard := _guard_for(src, "PrepCountdown.gd")
	h.expect(cd_guard.contains("is_offline_team_match"), "countdown_not_offline_gated",
		"挂 PrepCountdown 的那个 if 里没有 is_offline_team_match() —— 离线自测会重新装上倒计时（守卫＝%s）" % cd_guard)
	var bots_guard := _guard_for(src, "prepare_local_bots")
	h.expect(bots_guard.contains("tutorial_mode") and not bots_guard.contains("is_offline_team_match"),
		"bots_gated_with_countdown",
		"prepare_local_bots() 的守卫是「%s」—— 它必须只由教学局让开；被和倒计时关进同一个 if 的话，第 5 条的 AI 经济会在离线自测里一起停掉" % bots_guard)


# 找出命中片段所在语句块的 `if` 守卫：从命中行往上找第一行以 "if " 开头的行。
# 注释行（strip 后以 # 开头）不会被误当成守卫。
func _guard_for(src: String, needle: String) -> String:
	var lines := src.split("\n")
	var hit := -1
	for i in lines.size():
		if lines[i].contains(needle):
			hit = i
			break
	if hit < 0:
		return ""
	for j in range(hit, -1, -1):
		var s := lines[j].strip_edges()
		if s.begins_with("if "):
			return s
	return ""


# --- H3 离线自测不自动上阵（倒计时的另一半：到点自动上阵）-----------------------
#
# 「保持原来的无倒计时」不只是那个 3!/2!/1! 与按钮后缀 —— 倒计时到点会把待命区
# 最左一枚棋自动挪上棋盘。离线自测既然没有倒计时，就也不该有这一步。
# 判据用**行为**：摆一枚棋在待命区，直接调 `_auto_deploy_at_deadline()`，
# 看棋盘字节有没有变。另配一个非离线自测的对照组，保证判据不是「函数整体坏了」而假绿。
func _section_offline_selftest_no_auto_deploy() -> void:
	var online_moved := await _auto_deploy_probe(false)
	var offline_moved := await _auto_deploy_probe(true)
	h.expect(online_moved, "auto_deploy_probe_broken",
		"对照组（非离线自测）里 _auto_deploy_at_deadline() 没把待命区棋子挪上棋盘 —— 本段判据失效，先修门禁")
	h.expect(not offline_moved, "offline_selftest_auto_deployed",
		"离线自测里 _auto_deploy_at_deadline() 仍然自动上阵 —— 用户口径是离线自测保持原来的无倒计时（含无自动上阵）")


# 返回「棋盘被改动了没有」。offline = true 时装成离线自测对局。
func _auto_deploy_probe(offline: bool) -> bool:
	GameState.tutorial_mode = false
	NetworkService.team_active = false
	NetworkService.is_host = false
	NetworkService.offline_selftest = offline
	var prep := await _fresh_prep()
	# 夹具在 prep 建好之后再摆：免得 _ready 里的 _refresh_all() 先动过它。
	var bench: Array = GameState.bench_slots
	bench.fill(null)
	if bench.size() > 0:
		bench[0] = _piece()
	var board: Array = GameState.board_slots
	board.fill(null)
	var before := var_to_bytes(board)
	prep.call("_auto_deploy_at_deadline")
	var moved := var_to_bytes(board) != before
	prep.queue_free()
	await get_tree().process_frame
	NetworkService.offline_selftest = false
	return moved


# 待命区棋子的夹具。**必须带 `def`**：`SynergyService.count_races_from_board()` 会读
# `cell.def.get("race", ...)`，只给 `{"id","star"}` 会在每次刷新时抛
# `Invalid access to property or key 'def'` —— 门禁本身照样 PASS，但日志里混进
# SCRIPT ERROR，下一次真错误就会被这堆噪音淹掉。
func _piece() -> Dictionary:
	return {"id": "god_guard", "star": 1, "def": {"id": "god_guard", "race": "god"}}


# --- H4 联机客机也要看得见倒计时（用户 10.12 返修口径）--------------------------
#
# 「第 6 点只不生效于离线自测房间，其他房间对局要生效」。**自定义房间的房主在专服上
# 也是 `is_host == false` 的客机**（他只是房间 leader，不是 ENet 主机），所以这一段
# 判的就是「自定义房间有没有倒计时」。
#
# 原实现把「服务端已确认 prep」当**前置条件**（没确认就 `_cue.hide(); return`），于是
# 服务器是旧包（`_build_room_state` 不发 `prep_seconds_left`）或阶段还没推到 prep 时，
# **整间房都看不到倒计时** —— 按钮没有「（xx s）」后缀、3/2/1 也不弹，且不报任何错。
# 现在服务端只是**优先来源**：给了就用它的，没给就退回本地时钟，绝不整块藏起来。
func _section_online_client_countdown_visible() -> void:
	# ① 服务端没给 prep 信息（旧包 / 阶段未到）：倒计时必须照常可见。
	var bare := await _client_prep(-1.0)
	h.expect(bare.find_child("PrepCountdown", true, false) != null, "client_countdown_missing",
		"联机客机的备战界面没有挂 PrepCountdown —— 倒计时整条不在")
	var secs := int(bare.get_meta("prep_countdown_seconds", -1))
	h.expect(secs >= 30, "client_countdown_frozen",
		"联机客机 + 服务端没给 prep 信息时倒计时整块停了（prep_countdown_seconds=%d，本地时钟本该给约 35）—— 这正是「自定义房间没有倒计时」" % secs)
	var lbl: Variant = bare.get("_start_battle_label")
	if lbl != null:
		bare.call("_refresh_start_button_label")
		h.expect(str((lbl as Label).text).contains(" s)"), "client_suffix_missing",
			"联机客机的准备按钮没有「（xx s）」后缀：实际「%s」" % str((lbl as Label).text))
	bare.queue_free()
	await get_tree().process_frame

	# ② 服务端给了 prep_seconds_left：必须以服务端为准，不能被本地时钟（约 35）盖掉。
	var served := await _client_prep(20.0)
	var secs2 := int(served.get_meta("prep_countdown_seconds", -1))
	h.expect(secs2 == 19 or secs2 == 20, "client_ignores_server_clock",
		"服务端给了 20 s，客机却按本地时钟显示 %d s —— 服务端权威被本地时钟盖掉" % secs2)
	served.queue_free()
	await get_tree().process_frame

	# ③ 客机到点：本地自动上阵照做（第 6 条要求「倒计时完成后…自动把待命区最左一枚
	#    放到棋盘」），但**不许**替服务端置 ready / 开回合 —— 那两条分支只给非联机与
	#    本地房主，服务端始终是唯一权威。
	GameState.tutorial_mode = false
	NetworkService.offline_selftest = false
	NetworkService.team_active = true
	NetworkService.is_host = false
	NetworkService.team_local_slot = 3
	# ② 段留下的服务端 prep 信息要先清掉，否则 `left` 会走服务端的 20 s 而不是
	# 「本地时钟已经到点」那条路，③ 段就测不到到期行为。
	NetworkService.server_phase = ""
	NetworkService.server_round_index = 0
	NetworkService.set("_prep_deadline_local", -1.0)
	var client := await _fresh_prep()
	var bench: Array = GameState.bench_slots
	bench.fill(null)
	if bench.size() > 0:
		bench[0] = _piece()
	var board: Array = GameState.board_slots
	board.fill(null)
	var board_before := var_to_bytes(board)
	var ready_before := var_to_bytes(NetworkService.team_ready)
	var cd: Node = client.find_child("PrepCountdown", true, false)
	if cd != null:
		cd.set("_deadline", 0.0)          # 本地时钟已经到点
		cd.call("_process", 0.016)
		h.expect(bool(cd.get("_expired")), "client_deadline_not_fired",
			"客机的倒计时走到 0 之后没有进入到期态 —— 后面那段自动上阵/开战都不会跑")
		h.expect(var_to_bytes(board) != board_before, "client_no_local_auto_deploy",
			"联机客机到点没有做本地自动上阵（待命区最左一枚没上棋盘）—— 第 6 条要求的那一步丢了")
		h.expect(var_to_bytes(NetworkService.team_ready) == ready_before,
			"client_pushed_ready",
			"联机客机到点擅自改了 team_ready —— 置 ready / 开回合只能由本地房主或服务端做")
	else:
		h.fail("client_countdown_missing_before_expiry", "客机夹具里没有 PrepCountdown，③ 段无法验证")
	client.queue_free()
	await get_tree().process_frame
	NetworkService.team_active = false
	NetworkService.is_host = false
	NetworkService.server_phase = ""
	NetworkService.server_round_index = 0
	NetworkService.set("_prep_deadline_local", -1.0)
	GameState.team_mode = false


# 夹具：把备战页装进「联机客机」状态。server_seconds < 0 表示服务端**没给** prep 信息
# （旧包 / 阶段未到）：`server_phase` 留空、`_prep_deadline_local` 保持 -1。
# ≥ 0 表示服务端已经确认 prep 并给了剩余秒数。
func _client_prep(server_seconds: float) -> Control:
	GameState.team_mode = true
	NetworkService.offline_selftest = false
	NetworkService.team_active = true
	NetworkService.is_host = false
	NetworkService.team_local_slot = 3
	NetworkService.team_slot_states = ["player", "dummy", "dummy", "player", "dummy", "dummy"]
	NetworkService.team_ready = [true, false, false, false, false, false]
	var served := server_seconds >= 0.0
	NetworkService.server_phase = NetworkService.ROOM_PREP if served else ""
	NetworkService.server_round_index = GameState.round_index if served else 0
	NetworkService.set("_prep_deadline_local",
		Time.get_ticks_msec() / 1000.0 + server_seconds if served else -1.0)
	return await _fresh_prep()
