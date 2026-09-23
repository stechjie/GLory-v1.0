extends Node
# 行为级回归探针：战斗场景「队友」按钮点不开（9.21 截图反馈）。
#
# ★ 根因（已复现）：BattleArena._build() 里第一个 add_child 的全屏底板 arena_wrap
#   是 Control，默认 mouse_filter=STOP。BattleScreen._ready() 里**先**加的语音/队友按钮
#   （z_index=100）与它重叠时，Godot 的 GUI 命中测试**按树序取后者**（z_index 不参与裁决），
#   于是点击被 arena_wrap 吃掉 → 「队友」点不开、语音切不了档。
#
# 本探针做三件事：
#   A. 源码断言：BattleArena.gd 的 arena_wrap 必须显式设 MOUSE_FILTER_IGNORE
#      （并在 add_child 之前）。
#   B. 行为复刻：按**修复前**的结构（arena_wrap=STOP，后加）造一遍 → 点击必须被吃掉；
#      再按**修复后**的结构（arena_wrap=IGNORE）造一遍 → 点击必须成功。
#      两个方向都断言，避免「永远绿」的纸老虎。
#   C. 子节点不受影响：arena_wrap 设 IGNORE 后，它**内部**的控件仍必须能收到点击
#      （单位命中区就是 _arena 的子节点）。

const VoiceControls := preload("res://ui/components/VoiceControls.gd")
const VOICE_BTN_SIZE := Vector2(120, 36)

var _fails: Array[String] = []


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 720))
	get_tree().root.size = Vector2i(1600, 720)
	await get_tree().process_frame
	await get_tree().process_frame

	_check_source()
	await _check_behavior(false, "pre_fix_click_eaten")
	await _check_behavior(true, "post_fix_click_works")
	await _check_children_still_receive()

	var status := "PASS" if _fails.is_empty() else "FAIL"
	print("CHECK_RESULT name=voice_battle_hit status=%s checked=%d failures=%d allowed=0 stale=0"
		% [status, 0, _fails.size()])
	for f in _fails:
		print("[voice_battle_hit]   FAIL ", f)
	get_tree().quit(0 if _fails.is_empty() else 1)


func _check_source() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd")
	_p(not src.is_empty(), "arena_readable", "读不到 BattleArena.gd")
	# 三块全屏纯装饰底板都必须 IGNORE，且都必须在 add_child 之前。
	# 它们是 _build() 里最早加的兄弟，会压住 _ready() 里先建的语音/队友按钮。
	for spec in [
		["arena_wrap", "var arena_wrap := Control.new()", "add_child(arena_wrap)"],
		["screen_bg", "var screen_bg := ColorRect.new()", "add_child(screen_bg)"],
		["arena_tint", "var arena_tint := ColorRect.new()", "arena_wrap.add_child(arena_tint)"],
	]:
		var name := str(spec[0])
		var declare := str(spec[1])
		var add := str(spec[2])
		var ignore := "%s.mouse_filter = Control.MOUSE_FILTER_IGNORE" % name
		_p(src.contains(declare) and src.contains(add), name + "_present",
			"找不到 %s 的建与加" % name)
		var at_ignore := src.find(ignore)
		var at_add := src.find(add)
		_p(at_ignore >= 0, name + "_ignores_mouse",
			"%s 没设 MOUSE_FILTER_IGNORE —— 全屏底板会吃掉语音/队友/单位点击" % name)
		_p(at_ignore >= 0 and at_add >= 0 and at_ignore < at_add, name + "_ignore_before_add",
			"%s 的 IGNORE 必须写在 add_child 之前（否则中间有窗口期）" % name)
	# 单位命中区还在 _arena 内部，不能被一起关掉
	var renderer := FileAccess.get_file_as_string("res://scenes/battle/BattleRenderer.gd")
	_p(renderer.contains("_arena.add_child(node)"), "units_still_under_arena",
		"单位命中区不再挂在 _arena 下 —— 本的 IGNORE 修复前提变了，需重新评估")


# 复刻 BattleScreen 的兄弟顺序：先加按钮（z=100），后加 arena_wrap。
# arena_ignore=false → 修复前（STOP）；true → 修复后（IGNORE）。
func _check_behavior(arena_ignore: bool, code: String) -> void:
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_tree().root.add_child(host)
	await get_tree().process_frame

	var vc := VoiceControls.new()
	vc.build(host, VOICE_BTN_SIZE, VOICE_BTN_SIZE, 14, {"panel_context": "battle"})
	var top := 100.0
	for button in [vc.voice_button, vc.members_button]:
		var control := button as Button
		control.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		control.offset_left = -16.0 - VOICE_BTN_SIZE.x
		control.offset_right = -16.0
		control.offset_top = top
		control.offset_bottom = top + VOICE_BTN_SIZE.y
		control.z_index = 100
		host.add_child(control)
		top += 42.0
	await get_tree().process_frame

	# 后加的全屏底板（复刻 arena_wrap）
	var arena := Control.new()
	arena.name = "ArenaWrap"
	arena.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arena.clip_contents = true
	if arena_ignore:
		arena.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		arena.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(arena)
	await get_tree().process_frame
	await get_tree().process_frame

	var members: Button = vc.members_button
	var center: Vector2 = members.global_position + members.size * 0.5
	var fired := [false]
	members.pressed.connect(func(): fired[0] = true)
	_tap(center)
	await get_tree().process_frame
	await get_tree().process_frame

	print("PROBE [%s] arena_ignore=%s center=%s pressed=%s modal=%d" % [
		code, str(arena_ignore), str(center), str(fired[0]), ModalStack.depth()])
	if arena_ignore:
		_p(fired[0], code, "arena_wrap 设 IGNORE 后「队友」按钮仍点不动")
		_p(ModalStack.depth() >= 1, code + "_panel", "arena_wrap 设 IGNORE 后语音面板没进栈")
	else:
		_p(not fired[0], code, "arena_wrap 设 STOP 时按钮竟点得动 —— 复现前提不成立（探针失效）")

	ModalStack.close_all()
	vc.teardown()
	host.queue_free()
	await get_tree().process_frame


# arena_wrap 设 IGNORE 后，它**内部**的控件必须仍能收到点击（单位命中区就在里面）。
func _check_children_still_receive() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_tree().root.add_child(root)
	await get_tree().process_frame

	var arena := Control.new()
	arena.name = "ArenaWrapIgnored"
	arena.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	arena.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(arena)
	await get_tree().process_frame

	var unit := Control.new()
	unit.name = "FakeUnitHit"
	unit.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	unit.position = Vector2(200, 200)
	unit.size = Vector2(100, 100)
	unit.mouse_filter = Control.MOUSE_FILTER_STOP
	arena.add_child(unit)
	await get_tree().process_frame

	var got := [false]
	unit.gui_input.connect(func(_e): got[0] = true)
	_tap(Vector2(250, 250))
	await get_tree().process_frame
	await get_tree().process_frame
	print("PROBE child_under_ignored_parent received=%s" % str(got[0]))
	_p(got[0], "children_receive_under_ignored_parent",
		"arena_wrap 设 IGNORE 后，它内部的单位命中区收不到点击 —— 会把单位点击一起关掉")

	root.queue_free()
	await get_tree().process_frame


func _tap(at: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	get_viewport().push_input(press, true)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	get_viewport().push_input(release, true)


func _p(cond: bool, code: String, msg: String) -> void:
	if cond:
		print("PROBE ok %s" % code)
	else:
		_fails.append("[%s] %s" % [code, msg])
		print("PROBE FAIL %s :: %s" % [code, msg])
