extends Node

# 门禁：3v3 房间（含离线自测）**座位标签**的字号与落点必须跟着座位状态走。
#
# ## 9.29 bug 文档第 4 条（这条门禁就是为它写的）
#
# 玩家反馈（离线自测房间）：
#   · 头像上面的文本本应显示「房主」，现在显示「未准备」
#   · 「假想敌A」的框框里「假想敌」消失了
#   · 「假想敌A」的字号和其他的「假想敌B」等**不一致**
# 修复要求：座位上面显示的样子与在线自定义房间一致。
#
# ## 根因（本轮先修「字号 + 不显示」两件，房主文案那条留待下一轮）
#
# `Team3v3Lobby._refresh()` 根据座位状态改写 `_placed` 里两条标签的
# `font_size / pos / size`，**但 `_placed` 只是「期望值」，真正落到 Label 上的是
# `_layout()`**。换座（`_on_slot_pressed`）与加/减假想敌（`_toggle_dummy`）这两条
# 路径只调 `_refresh()`、不调 `_layout()`，于是那个**状态刚变过的座位**会停在上一轮
# 的字号与位置上：
#
#   复现（离线，先落座 A 座 → 换到 C 座 → 把 A 座设成假想敌）：
#     · 圈外名牌 s0 停在 player 时代的 20 号字，而 s1/s3/s4/s5 是 28 号 ⇒ 字体不一致
#     · 圈内状态 s0 停在 player 时代「框下方」的坐标 ⇒ 字跑到框外，看上去像消失了
#
# 修法：把「一条 _placed 记录落到节点」抽成 `_apply_placement()`，`_layout()` 全量
# 用它，`_refresh()` 改完 `_placed` 就地也用它（`_apply_tracked`）—— 两条路径共用
# 同一份落点逻辑，不会出现「只在某一条路径上对」的半修。
#
# 同一份 bug 文档第 4 条还报了第一句现象：「本应显示『房主』，现在显示『未准备』」。
# 那条是另一个根因（`_leader_slot()` 离线硬编码 0 号位，而玩家换过座），本轮一并修。
#
# ## 这条门禁验什么（行为 + 结构，缺一不可）
#
#   1. 行为：走**真实入口**（_on_slot_pressed / _on_slot_ai）复现玩家那条路径后，
#      六个座位的圈外名牌字号必须**按状态分组一致**（dummy 全相等、player 全相等），
#      且 dummy ≠ player（否则「按 state 调字号」这段等于没生效）。
#   2. 行为：同一个座位**从 player 变成 dummy 后**，圈内状态标签的落点必须真的动到
#      「框内」那一组坐标（这正是「字消失」的判定），不能停在 player 组。
#   3. 行为：离线房间里「房主」必须落在玩家**自己**的座位上（原来硬编码 0 号位）。
#   4. 结构：`_refresh()` 改完 `_placed` 必须调落点函数；`_layout()` 与 `_refresh()`
#      必须共用同一个 `_apply_placement`（不许各写一份）。
#   5. 行为：反例对照 —— 只调 `_refresh()` 不调 `_layout()` 时也必须已经生效
#      （即 `_refresh()` 自带落点）。
#
# ## 跑
#   godot --headless --path <项目> tools/team_lobby_seat_label_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")
const LobbyScene := preload("res://scenes/menu/Team3v3Lobby.tscn")
const LOBBY_PATH := "res://scenes/menu/Team3v3Lobby.gd"

const CHECK_NAME := "team_lobby_seat_label"

# 与截图同尺寸，保证 scale 与真机一致（1672x941 参考画布）。
const VIEW := Vector2i(1266, 600)
# 参考画布尺寸（与 Team3v3Lobby.REF_SIZE 一致）。只用于把 SLOT_POS 换算到屏幕，
# 席位坐标本身仍从活实例读。
const REF_W := 1672.0
const REF_H := 941.0

var _h: CheckHarness
var _lobby: Control


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	# ★ 每个用例都必须 await：用例体里第一件事就是 `await _build_lobby()`，
	# 少了 await 的话函数会在那个挂起点**直接返回**，`_h.finish()` 立刻执行 ——
	# 后面的断言一条都不会跑到，门禁看着绿、其实什么都没验（无声失效）。
	await _case_seat_label_font_consistent_after_real_path()
	await _case_status_label_moves_into_frame()
	await _case_offline_host_label_on_own_seat()
	_case_apply_shared_by_layout_and_refresh()
	await _case_refresh_self_applies_placement()
	# 前提体检：这五个用例各自至少要贡献一条 checked；总数对不上就是有用例没跑。
	_h.expect(_h.checked_count() >= 20, "cases_not_executed",
		"检查项只有 %d 条（应 ≥20）—— 有用例没跑到（多半是忘了 await），门禁在无声失效" % _h.checked_count())
	_h.finish(get_tree())


# --- 1. 行为：走真实入口后六个座位的名牌字号按状态分组一致 ----------------------

func _case_seat_label_font_consistent_after_real_path() -> void:
	var lobby := await _build_lobby()
	if lobby == null:
		_h.fail("lobby_unavailable", "Team3v3Lobby 场景无法实例化，座位标签判据无法执行")
		return

	# 复现玩家路径：初始落在 A 座（_ready 里 _slot_states[0]="player"，且已 _layout()），
	# 再换到 C 座、把 A/B/1/2/3 都设成假想敌。全部走真实入口，不复刻实现。
	lobby.call("_on_slot_pressed", 2)
	await get_tree().process_frame
	for i in [0, 1, 3, 4, 5]:
		lobby.call("_on_slot_ai", i)
	await get_tree().process_frame

	var states: Array = lobby.get("_slot_states")
	_h.expect(str(states[2]) == "player", "seat2_not_player",
		"复现前置不成立：换座后 slot2 应为 player，实为 %s" % str(states[2]))
	var dummy_seats: Array[int] = []
	var player_seats: Array[int] = []
	for i in 6:
		if str(states[i]) == "dummy":
			dummy_seats.append(i)
		elif str(states[i]) == "player":
			player_seats.append(i)
	_h.expect(dummy_seats.size() == 5 and player_seats.size() == 1, "seat_mix_unexpected",
		"复现前置不成立：期望 5 假想敌 + 1 玩家，实为 dummy=%s player=%s" % [str(dummy_seats), str(player_seats)])

	# 前提体检：A 座（slot 0）确实经历过 player → dummy 的翻转，否则后面的断言会静默空过。
	_h.expect(dummy_seats.has(0), "seat0_not_dummy",
		"A 座没有变成假想敌 —— 本轮现象复现不出来，后面的「字号一致」断言等于空过")

	var name_fonts := _name_label_font_sizes(lobby)
	var dummy_fonts: Array[int] = []
	for i in dummy_seats:
		dummy_fonts.append(name_fonts[i])
	var dummy_min: int = dummy_fonts.min() if not dummy_fonts.is_empty() else -1
	var dummy_max: int = dummy_fonts.max() if not dummy_fonts.is_empty() else -1
	_h.expect(dummy_min == dummy_max and dummy_min > 0, "dummy_name_font_inconsistent",
		"假想敌座位的圈外名牌字号不一致（应全部相等）：%s" % str(_seat_font_report(states, name_fonts)))
	# 判据指着能坏的那一处：A 座就是那个「刚翻过状态」的座位，单独点名一次。
	_h.expect(name_fonts[0] == dummy_max, "seat_a_font_off_group",
		"「假想敌 A」的字号与其余假想敌不一致：seat0=%d, 其余=%d（%s）" % [
			name_fonts[0], dummy_max, str(_seat_font_report(states, name_fonts))])
	# 与 player 组必须不同 —— 否则「按 state 调字号」这段等于没生效。
	var player_font: int = name_fonts[player_seats[0]] if not player_seats.is_empty() else -1
	_h.expect(player_font > 0 and dummy_max > 0 and player_font != dummy_max, "state_font_not_distinct",
		"玩家座与假想敌座的名牌字号相同（%d == %d），按 state 调字号那段没有生效" % [player_font, dummy_max])


# --- 2. 行为：翻成 dummy 后圈内状态标签必须落进「框内」那一组 --------------------

func _case_status_label_moves_into_frame() -> void:
	var lobby := await _build_lobby()
	if lobby == null:
		_h.fail("lobby_unavailable_status", "Team3v3Lobby 场景无法实例化，圈内标签判据无法执行")
		return
	lobby.call("_on_slot_pressed", 2)
	await get_tree().process_frame
	for i in [0, 1, 3, 4, 5]:
		lobby.call("_on_slot_ai", i)
	await get_tree().process_frame

	var states: Array = lobby.get("_slot_states")
	var statuses: Array = lobby.get("_slot_status_lbls")
	var st0: Label = statuses[0]
	var st1: Label = statuses[1]
	var st2: Label = statuses[2]

	_h.expect(str(states[0]) == "dummy" and str(states[1]) == "dummy" and str(states[2]) == "player",
		"status_precondition_failed", "圈内标签复现前置不成立：states=%s" % str(states))

	# A 座（刚由 player 翻成 dummy）的圈内标签，必须与**本来就是 dummy** 的 B 座同组。
	# ★ 比的是**相对各自席位的偏移**，不是绝对坐标 —— slot0 与 slot1 的基点本来就不同
	# （SLOT_POS[0]=(447,229) vs SLOT_POS[1]=(739,229)），直接比绝对坐标会得出
	# 「永远不相等」的假红。
	var off0 := st0.position - _slot_anchor(0)
	var off1 := st1.position - _slot_anchor(1)
	var off2 := st2.position - _slot_anchor(2)
	# 用**像素距离**判等，不用 is_equal_approx：后者对两个独立算出的浮点位置过于严格
	# （席位基点各自 round 过，偏移会差零点几像素），会把「本来相等」判成红。
	_h.expect(off0.distance_to(off1) <= 1.0, "seat_a_status_pos_stale",
		"「假想敌 A」的圈内标签相对席位偏移没跟着状态变（停在 player 组）：seat0 偏移=%s vs 正常 dummy seat1 偏移=%s（差 %.2fpx）" % [
			str(off0.round()), str(off1.round()), off0.distance_to(off1)])
	_h.expect(st0.size.is_equal_approx(st1.size) or absf(st0.size.x - st1.size.x) <= 1.0, "seat_a_status_size_stale",
		"「假想敌 A」的圈内标签尺寸没跟着状态变：seat0=%s vs seat1=%s" % [
			str(st0.size.round()), str(st1.size.round())])
	_h.expect(_label_font_override(st0) == _label_font_override(st1), "seat_a_status_font_stale",
		"「假想敌 A」的圈内标签字号没跟着状态变：seat0=%d vs seat1=%d" % [
			_label_font_override(st0), _label_font_override(st1)])
	# 与 player 座必须不同 —— 证明「框内 / 框下方」两组偏移是真的两套。
	_h.expect(off0.distance_to(off2) > 4.0, "status_groups_identical",
		"假想敌座与玩家座的圈内标签相对席位偏移几乎相同（差 %.2fpx），说明两种落点没有区别 —— 判据失去判别力" % off0.distance_to(off2))
	_h.expect(st0.text == st1.text, "dummy_status_text_differs",
		"两个假想敌座的圈内文案不一致：s0='%s' vs s1='%s'" % [st0.text, st1.text])


# --- 3. 行为：离线房间里「房主」必须落在玩家自己的座位上 ------------------------

# bug 文档原文第一条现象：「本应显示『房主』，现在显示的是『未准备』」。
# 根因：`_leader_slot()` 离线硬编码 0，而离线玩家可能在别的座位（换过座）。
func _case_offline_host_label_on_own_seat() -> void:
	var lobby := await _build_lobby()
	if lobby == null:
		_h.fail("lobby_unavailable_host", "Team3v3Lobby 场景无法实例化，房主文案判据无法执行")
		return
	# 离线、玩家换到 C 座、其余全设假想敌 —— 就是截图里那张。
	lobby.call("_on_slot_pressed", 2)
	await get_tree().process_frame
	for i in [0, 1, 3, 4, 5]:
		lobby.call("_on_slot_ai", i)
	await get_tree().process_frame

	_h.expect(not lobby.call("_online"), "host_case_not_offline",
		"前置不成立：本用例假定离线房间")
	var my_slot: int = int(lobby.call("_my_slot"))
	var leader: int = int(lobby.call("_leader_slot"))
	var states: Array = lobby.get("_slot_states")
	_h.expect(str(states[my_slot]) == "player", "host_case_my_slot_not_player",
		"前置不成立：我的座位 slot%d 不是 player（states=%s）" % [my_slot, str(states)])
	_h.expect(leader == my_slot, "offline_leader_not_self",
		"离线房间的房主席位不是自己：_leader_slot()=%d，我的座位=%d —— 房主文案会写到别人的位子上" % [leader, my_slot])

	var statuses: Array = lobby.get("_slot_status_lbls")
	var mine := statuses[my_slot] as Label
	_h.expect(mine.text.contains("房主") or mine.text.contains("Host"), "own_seat_not_host",
		"离线自测时自己座位上方显示的是 '%s'，不是「房主」" % mine.text)
	# 那条 AI 座不该再被写成房主文案。
	for i in 6:
		if i == my_slot:
			continue
		var t := (statuses[i] as Label).text
		_h.expect(not (t.contains("房主") or t.contains("Host")), "host_on_wrong_seat",
			"非我座位 slot%d 显示了「房主」（text='%s'）" % [i, t])

	# 结构：离线分支不许再出现硬编码 0。
	var body := _strip_comments(_read(LOBBY_PATH))
	var fn := _func_body(body, "func _leader_slot(")
	_h.expect(not fn.is_empty(), "leader_slot_body_unreadable", "读不到 _leader_slot() 函数体")
	_h.expect(not fn.contains("else 0"), "offline_leader_hardcoded_zero",
		"_leader_slot() 离线分支又硬编码 0 了 —— 换过座的玩家会看到「未准备」而不是「房主」")
	_h.expect(fn.contains("_my_slot()"), "offline_leader_not_my_slot",
		"_leader_slot() 离线分支没有取 _my_slot()（离线房间里房主就是自己）")


# --- 4. 结构：_layout() 与 _refresh() 必须共用同一份落点逻辑 ---------------------

func _case_apply_shared_by_layout_and_refresh() -> void:
	var src := _read(LOBBY_PATH)
	if src.is_empty():
		_h.fail("lobby_source_missing", "读不到 %s" % LOBBY_PATH)
		return
	var body := _strip_comments(src)

	_h.expect(body.contains("func _apply_placement("), "apply_placement_missing",
		"缺少 _apply_placement()：落点逻辑被内联在某处，_refresh() 就没法共用")

	var layout_body := _func_body(body, "func _layout(")
	var refresh_body := _func_body(body, "func _refresh(")
	_h.expect(not layout_body.is_empty(), "layout_body_unreadable", "读不到 _layout() 函数体")
	_h.expect(not refresh_body.is_empty(), "refresh_body_unreadable", "读不到 _refresh() 函数体")

	# 两边都必须落到 _apply_placement / _apply_tracked（同一份实现）。
	_h.expect(layout_body.contains("_apply_placement("), "layout_not_using_apply_placement",
		"_layout() 没有用 _apply_placement() —— 落点逻辑被复制成两份了")
	_h.expect(refresh_body.contains("_apply_tracked(") or refresh_body.contains("_apply_placement("),
		"refresh_not_applying_placement",
		"_refresh() 改完 _placed 没有把改动落到节点上 —— 这正是 bug 文档第 4 条的根因")

	# 反向：_refresh() 不许再出现「只写 _placed 不落节点」的写法。
	# 判据落在「赋值 font_size / pos / size 之后必须紧跟一次落点调用」这一段窗口里。
	var window := _refresh_placement_window(refresh_body)
	_h.expect(not window.is_empty(), "refresh_placement_window_unreadable",
		"读不到 _refresh() 里改写 _placed 的那段代码 —— 判据失去作用域")
	var assignments := window.count("placement.font_size =")
	assignments += window.count("placement.pos =")
	assignments += window.count("placement.size =")
	var applies := window.count("_apply_tracked(") + window.count("_apply_placement(")
	_h.expect(assignments > 0, "refresh_no_placement_assignment",
		"_refresh() 里找不到对 _placed 的赋值 —— 判据锚点失效，请同步更新门禁")
	_h.expect(applies >= 2, "refresh_assignment_without_apply",
		"_refresh() 里改了 _placed 却只落点 %d 次（名牌与圈内标签应各落一次）—— 改完不落节点就是「停在旧字号」" % applies)


# --- 5. 行为：只用 _refresh()（不跟 _layout()）也必须生效 ------------------------

func _case_refresh_self_applies_placement() -> void:
	var lobby := await _build_lobby()
	if lobby == null:
		_h.fail("lobby_unavailable_refresh", "Team3v3Lobby 场景无法实例化，独立刷新判据无法执行")
		return
	# 直接改座位状态后**只**调 _refresh()：这条就是换座那条路径的真实形态。
	lobby.set("_local_slot", 2)
	lobby.set("_slot_states", ["dummy", "dummy", "player", "dummy", "dummy", "dummy"])
	lobby.set("_slot_ready", [true, true, false, true, true, true])
	lobby.call("_refresh")
	await get_tree().process_frame

	var name_fonts := _name_label_font_sizes(lobby)
	var statuses: Array = lobby.get("_slot_status_lbls")
	_h.expect(name_fonts[0] == name_fonts[1] and name_fonts[0] > 0, "refresh_only_font_inconsistent",
		"只调 _refresh() 时两个假想敌座的名牌字号不一致：seat0=%d seat1=%d" % [name_fonts[0], name_fonts[1]])
	var off0 := (statuses[0] as Label).position - _slot_anchor(0)
	var off1 := (statuses[1] as Label).position - _slot_anchor(1)
	_h.expect(off0.distance_to(off1) <= 1.0, "refresh_only_status_stale",
		"只调 _refresh() 时圈内标签相对席位偏移没生效：seat0=%s seat1=%s（差 %.2fpx）" % [
			str(off0.round()), str(off1.round()), off0.distance_to(off1)])


# --- 工具 ---------------------------------------------------------------------

func _build_lobby() -> Control:
	if _lobby != null and is_instance_valid(_lobby):
		_lobby.queue_free()
		_lobby = null
	get_viewport().size = VIEW
	var lobby: Control = LobbyScene.instantiate()
	add_child(lobby)
	await get_tree().process_frame
	_lobby = lobby
	return lobby


func _name_label_font_sizes(lobby: Control) -> Array[int]:
	var out: Array[int] = []
	var labels: Array = lobby.get("_slot_name_lbls")
	for i in 6:
		out.append(_label_font_override(labels[i] as Label))
	return out


func _label_font_override(label: Label) -> int:
	if label == null:
		return -1
	if not label.has_theme_font_size_override("font_size"):
		return -1
	return label.get_theme_font_size("font_size")


# 席位的屏幕基点：直接从**活着的 lobby 实例**读它自己的 SLOT_POS 常量，再套用
# 与 _layout() 相同的缩放规则。刻意不在这里复制一份坐标 —— 复制的那份会随实现
# 漂移，判据就变成自证。
func _slot_anchor(index: int) -> Vector2:
	if _lobby == null or not is_instance_valid(_lobby):
		return Vector2.ZERO
	var consts: Dictionary = (_lobby.get_script() as Script).get_script_constant_map()
	var slots: Array = consts.get("SLOT_POS", [])
	if index < 0 or index >= slots.size():
		return Vector2.ZERO
	var vp := get_viewport().get_visible_rect().size
	var scale := minf(vp.x / REF_W, vp.y / REF_H)
	var origin := (vp - Vector2(REF_W, REF_H) * scale) * 0.5
	return origin + (slots[index] as Vector2) * scale


func _seat_font_report(states: Array, fonts: Array[int]) -> String:
	var parts: Array[String] = []
	for i in 6:
		parts.append("s%d=%s/%d" % [i, str(states[i]), fonts[i]])
	return " ".join(parts)


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


# 去掉注释，保证结构断言不会把注释里的字样当成代码（"共享谓词会看不见调用点"那类假绿的镜像）。
func _strip_comments(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var l := str(line)
		var i := l.find("#")
		if i >= 0:
			l = l.substr(0, i)
		out.append(l)
	return "\n".join(out)


# 取 `func <头>` 到下一个顶层 func/const/var 之前的函数体。
func _func_body(src: String, header: String) -> String:
	var start := src.find(header)
	if start < 0:
		return ""
	var rest := src.substr(start + header.length())
	var ends: Array[int] = []
	for marker in ["\nfunc ", "\nconst ", "\nvar ", "\n@"]:
		var idx := rest.find(marker)
		if idx >= 0:
			ends.append(idx)
	if ends.is_empty():
		return rest
	return rest.substr(0, ends.min())


# _refresh() 里改写座位标签 _placed 的那段窗口（从第一条 placement. 赋值到最后一条
# 落点调用）。限定作用域是刻意的：整份文件里找 "_apply_tracked(" 会被别处的命中满足。
func _refresh_placement_window(refresh_body: String) -> String:
	var start := refresh_body.find("for placement in _placed:")
	if start < 0:
		return ""
	return refresh_body.substr(start)
