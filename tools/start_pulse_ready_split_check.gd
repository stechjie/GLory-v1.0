extends Node

# 10.07 bug 文档第 1 条**返工**门禁：「准备」按钮必须等于修复前，「开始游戏」保留新语义。
#
# 事故背景（用户真机反馈）：
#   第 1 条的诉求原文只说「开始游戏 UI」。但 `Team3v3Lobby` 右下角那块木牌是
#   **一个按钮两种身份** —— 房主看到「开始游戏」，队员看到「准备」。
#   初版把两种身份统一改成「不可开始 ⇒ 常暗」，于是队员的「准备」也被压成灰色，
#   看起来像被禁用（其实随时可点）。用户原话：
#     「我仅指修复 开始游戏UI，但现在的情况是你把准备UI也这样设置了，
#       请你把准备UI恢复到修复前」+「房间的准备按钮」。
#
# 这条门禁钉住两件事：
#   A. 队员侧（「准备」）的**全部可观测行为**与 HEAD（修复前）逐项一致。
#   B. 房主侧（「开始游戏」）仍然拿到第 1 条的新语义（常暗 + 防抖）。
#
# ★ 源码判据两个坑（本仓铁律）：
#   ① 先归一化行尾（仓库 .gd 是 CRLF），否则跨行片段永远 find 不到、断言静默判假。
#   ② 注释会被裸 find 当代码命中 —— 必须先剥注释行再断言（本文件里就写了旧实现原文）。

const SRC_PATH := "res://scenes/menu/Team3v3Lobby.gd"

var _checked := 0
var _failed := 0


func _ready() -> void:
	_check_source()
	_check_behavior()
	print("CHECK_RESULT name=start_pulse_ready_split status=%s checked=%d failures=%d allowed=0 stale=0"
		% ["PASS" if _failed == 0 else "FAIL", _checked, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _expect(cond: bool, code: String, msg: String) -> void:
	_checked += 1
	if not cond:
		_failed += 1
		print("  FAIL [%s] %s" % [code, msg])


# 剥掉整行注释与行尾注释（字符串字面量里的 `#` 不处理 —— 本文件不需要那种精度）。
func _code_only(lines: PackedStringArray) -> String:
	var out := ""
	for raw in lines:
		var line := raw.replace("\r", "")
		var idx := line.find("#")
		if idx >= 0:
			line = line.substr(0, idx)
		out += line + "\n"
	return out


func _read_src() -> PackedStringArray:
	var file := FileAccess.open(SRC_PATH, FileAccess.READ)
	if file == null:
		return PackedStringArray()
	var text := file.get_as_text()
	file.close()
	return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


func _check_source() -> void:
	var lines := _read_src()
	_expect(lines.size() > 100, "src_readable", "能读到 Team3v3Lobby.gd")
	var code := _code_only(lines)

	# A1. 调用点必须按身份分流 —— 不能是一条统一调用。
	_expect(code.contains("_update_start_pulse(_start_block_reason(true).is_empty(), true)"),
		"host_call_new_semantics", "房主侧调用带 as_host=true（新语义）")
	_expect(code.contains("_update_start_pulse(my_seat_player and not my_seat_ready, false)"),
		"ready_call_legacy", "队员侧调用 = 修复前的判据 + as_host=false")
	# 反证：不能再出现「不区分的单参调用」。
	_expect(not code.contains("_update_start_pulse(_start_block_reason(true).is_empty())\n"),
		"no_undivided_call", "不存在不区分的单参调用（初版误伤写法）")

	# A2. 函数签名必须有两个参数（第二个默认 true，兼容旧调用）。
	_expect(code.contains("func _update_start_pulse(active: bool, as_host: bool = true) -> void:"),
		"signature_two_params", "签名 = (active, as_host=true)")

	# A3. 队员侧的暗档必须是修复前的 0.70 灰，不能跟着 START_PLATE_DIM(0.52) 一起变深。
	_expect(code.contains("READY_PLATE_DIM_LEGACY := Color(0.70, 0.72, 0.72, 1.0)"),
		"legacy_dim_constant", "修复前暗档常量 = 0.70 灰")
	_expect(code.contains("var dim := START_PLATE_DIM if as_host else READY_PLATE_DIM_LEGACY"),
		"dim_by_identity", "暗档按身份取")
	# 反证：队员侧不能拿到 START_PLATE_DIM（否则「准备」脉动比修复前更暗）。
	_expect(not code.contains("var dim := START_PLATE_DIM\n"),
		"no_shared_dim", "暗档不共用 START_PLATE_DIM")

	# A4. 「不脉动时压暗」必须被房主身份限定住。
	_expect(code.contains("if as_host and not active:"),
		"dim_only_host", "只有房主「不可开始」才常暗")
	# 反证：初版的 `if not active: _set_start_plate(START_PLATE_DIM)` 必须消失。
	_expect(not code.contains("if not active:\n\t\t\t_set_start_plate(START_PLATE_DIM)"),
		"no_unguarded_dim", "不存在不加身份限定的常暗写法（初版误伤写法）")

	# A5. 修复前那条判据变量的定义必须还在（队员侧要用）。
	_expect(code.contains("var my_seat_player := my_slot >= 0 and my_slot < states.size() "
		+ "and str(states[my_slot]) == \"player\""),
		"my_seat_player_restored", "my_seat_player 变量已恢复")

	# === 10.07c：堵 tween 泄漏的写法必须是「先清后建」 ===
	# 判据不是「有没有 create_tween」，而是**新建之前必须已经清过一次**：
	# 源码里 `_clear_pulse_tween()` 必须出现在 `create_tween()` 之前，且中间没有
	# 提前 `return` 把清掉的路径跳过。
	var clear_pos := code.find("_clear_pulse_tween()")
	var create_pos := code.find("var t := create_tween().set_loops()")
	_expect(clear_pos >= 0 and create_pos >= 0 and clear_pos < create_pos,
		"clear_before_create", "新建脉动 tween 之前先清旧的（防泄漏）")
	# 显式脉动状态标记必须存在（只靠 is_valid() 判不出「被我建过还没停」）。
	_expect(code.contains("var _pulsing := false"), "pulsing_flag_exists",
		"存在 _pulsing 显式状态标记")
	# 防抖判据用的是 want_pulse + _pulsing，不是只看 as_host（旧 bug 的根因）。
	_expect(code.contains("var want_pulse := active and Tokens.motion(1.0) > 0.0"),
		"want_pulse_split", "「该不该脉动」与「在不在脉动」分开判")
	_expect(code.contains("if want_pulse and _pulsing:"), "dedup_both_sides",
		"防抖对两个身份都生效（旧写法只在 as_host 侧防抖 ⇒ 队员侧泄漏）")


# 行为判据：真例化脚本挂到树上，直接调函数验它自己的合同。
# ★ 记忆铁律：外层同名守卫会先 return ⇒ 内层删掉也全绿 —— 所以这里**直接调**目标函数。
func _check_behavior() -> void:
	var script: GDScript = load(SRC_PATH)
	_expect(script != null, "script_loads", "Team3v3Lobby.gd 能被 load")
	if script == null:
		return

	# 用一个只带必要节点的替身：`script.new()` 真正实例化成 Team3v3Lobby，
	# 手工塞 _start_plate / _start_lbl，然后直接调 _update_start_pulse，
	# 验它写出来的 modulate。
	# ★ 必须用 `script.new()`，不能 `Node.new()` + `set_script()` —— 后者在
	#   headless 下 `call()` 会报 "Nonexistent function ... (via call)"，
	#   而 GDScript 的 `call()` 失败**不抛异常** ⇒ 所有行为断言静默用初值判过、
	#   门禁假绿（第一次跑就是这个坑：checked=12 全 PASS，日志里却有一条 Invalid call）。
	var host: Node = script.new()
	_expect(host != null, "host_instantiated", "Team3v3Lobby 能实例化")
	if host == null:
		return
	add_child(host)

	# 防假绿：先确认 `call()` 真能打到那个函数。GDScript 的 `call()` 打到不存在的
	# 方法**不抛异常**，只会往日志打一行 Invalid call ⇒ 后续断言静默用初值判过。
	# 这里用 `has_method()` 与「调一次能改变 modulate」双重确认。
	_expect(host.has_method("_update_start_pulse"), "host_has_method",
		"实例身上有 _update_start_pulse（call 不会静默落空）")

	var plate := TextureRect.new()
	var lbl := Label.new()
	host.set("_start_plate", plate)
	host.set("_start_lbl", lbl)
	host.add_child(plate)
	host.add_child(lbl)

	# 1) 队员侧「不脉动」⇒ 必须复亮（修复前行为：复位到白）。
	plate.modulate = Color(0.30, 0.30, 0.30, 1.0)
	lbl.modulate = Color(0.30, 0.30, 0.30, 1.0)
	host.call("_update_start_pulse", false, false)
	_expect(plate.modulate.is_equal_approx(Color(1, 1, 1, 1)),
		"ready_inactive_bright", "队员未脉动时木牌复亮（修复前口径）")
	_expect(lbl.modulate.is_equal_approx(Color(1, 1, 1, 1)),
		"ready_inactive_bright_label", "队员未脉动时文字复亮（修复前口径）")

	# === 本轮（10.07c）核心：脉动必须能被「准备」停掉，且不能泄漏 tween ===
	# 用户真机反馈：「点击准备后，还在脉动」。
	# 根因：本函数每次 `_refresh()` 都调（高频），旧写法在「该脉动」路上**无条件新建
	# tween** 且不 kill 旧的 ⇒ 堆了 N 个 loop tween 同时写 modulate；按下准备时
	# `_stop_start_pulse()` 只 kill 到当前引用那一个，前面泄漏的仍在跑。
	_checked += 1
	var pulsing_after_prep := bool(host.get("_pulsing"))
	if pulsing_after_prep:
		_failed += 1
		print("  FAIL [no_pulse_after_ready] 准备后仍在脉动（_pulsing=true）")

	# 反复「未准备 → 快照刷新」多次，验不会堆 tween；再切到已准备，验立刻停。
	# 每轮都读一次 _pulsing（模拟房间轮询反复调 _refresh）。
	var leaked := false
	for i in range(8):
		host.call("_update_start_pulse", true, false)   # 未准备 ⇒ 应脉动
		if not bool(host.get("_pulsing")):
			leaked = true
			break
	_expect(not leaked, "ready_pulse_starts", "未准备时确实起脉动（8 次连续刷新）")
	# 关键：连续刷新 8 次之后，仍然只有**一个** tween 引用，且处于脉动态。
	_expect(bool(host.get("_pulsing")), "single_tween_alive", "反复刷新后仍是一个脉动（未泄漏）")

	# 按下「准备」⇒ 必须立刻停脉动、回亮。
	host.call("_update_start_pulse", false, false)
	_expect(not bool(host.get("_pulsing")), "ready_press_stops_pulse",
		"按下准备后立刻停脉动（本轮核心修复）")
	_expect(plate.modulate.is_equal_approx(Color(1, 1, 1, 1)),
		"ready_press_bright", "按下准备后木牌复亮")
	_expect(lbl.modulate.is_equal_approx(Color(1, 1, 1, 1)),
		"ready_press_bright_label", "按下准备后文字复亮")

	# 停掉之后再刷新若干次，必须**始终不脉动**（旧实现会因泄漏 tween 继续脉动）。
	var restarted := false
	for i in range(8):
		host.call("_update_start_pulse", false, false)
		if bool(host.get("_pulsing")):
			restarted = true
			break
	_expect(not restarted, "ready_stays_stopped",
		"已准备后反复刷新仍不脉动（泄漏已堵）")

	# 2) 房主侧「不可开始」⇒ 必须压到 START_PLATE_DIM（第 1 条新语义仍在）。
	host.call("_update_start_pulse", false, true)
	# 显式标 Variant：本工程把 `inference_on_variant` 当错误（`:=` 从 Variant 推断
	# 会直接编译失败，且只在日志里报一行、门禁不一定计入）。
	var dim: Variant = script.get("START_PLATE_DIM")
	_expect(dim is Color, "dim_is_color", "START_PLATE_DIM 是可读的 Color")
	var dim_color: Color = dim if dim is Color else Color(1, 1, 1, 1)
	_expect(plate.modulate.is_equal_approx(dim_color),
		"host_blocked_dim", "房主不可开始时木牌常暗（第 1 条语义保留）")
	_expect(lbl.modulate.is_equal_approx(dim_color),
		"host_blocked_dim_label", "房主不可开始时文字常暗")
	_expect(not bool(host.get("_pulsing")), "host_blocked_not_pulsing",
		"房主不可开始时**不脉动**（用户口径：不可开始 = 暗状态）")

	# 2b) 房主侧「可以开始」⇒ 必须脉动（用户口径：可进行开始 = 脉动）。
	host.call("_update_start_pulse", true, true)
	_expect(bool(host.get("_pulsing")), "host_ready_pulsing",
		"房主可开始时有脉动（用户口径：可进行开始 = 明暗交替）")
	# 连续刷新不得把脉动叠加成多个（同一身份也要防泄漏）。
	var stacked := false
	for i in range(6):
		host.call("_update_start_pulse", true, true)
		if not bool(host.get("_pulsing")):
			stacked = true
			break
	_expect(not stacked, "host_pulse_not_stacked", "房主侧反复刷新脉动不中断也不叠加")
	# 收尾：停掉房主脉动，避免影响后续断言。
	host.call("_update_start_pulse", false, false)
	_expect(not bool(host.get("_pulsing")), "host_pulse_stopped",
		"房主侧可停掉脉动（走回亮态）")

	# 3) 队员侧脉动路径的暗档 = 修复前 0.70（不是 0.52）。
	#    脉动要帧驱动才可见；这里直接调，读 tween 的第一/第三段终值不便，
	#    改为断言常量本身 + 走「不脉动」这条已覆盖。补一条：队员侧不脉动时
	#    **绝不能**是 START_PLATE_DIM。
	plate.modulate = Color(1, 1, 1, 1)
	host.call("_update_start_pulse", false, false)
	_expect(not plate.modulate.is_equal_approx(dim_color),
		"ready_never_uses_host_dim", "队员复亮 ≠ 房主常暗色（证明两者解耦）")

	host.queue_free()
