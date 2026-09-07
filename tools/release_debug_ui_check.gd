extends Node

# V3 P1-07 门禁：Release 包不能暴露调试专用 UI。
#
# 具体缺陷（本轮实测发现，不是猜的）：Team3v3Lobby 的「自测开始」按钮此前只按
# `not _online()` 显隐，没有查 `OS.is_debug_build()`。这条按钮打开的是
# `officetest/OfficeTestScreen.tscn` —— 而这个目录在 export_presets.cfg 的
# `exclude_filter` 里，**根本不进 Android Release 包**。Release 玩家离线时能看见
# 并点这颗按钮，点下去 `Main._show_selftest()` 里 `load(...)` 拿到 null，
# 对 null 调 `.instantiate()` 直接崩溃。
#
# headless 跑的是 debug 模板，无法在同一进程伪装 Release。这里守源码合同：
# 两处显隐统一走 selftest_available()，而该入口必须同时检查 Debug 和 PackedScene
# 的真实资源能力。这样普通 Debug APK 即使排除了 officetest/ 也不会显示死按钮；
# Release 的二进制显隐仍需真实导出复核。
#
# 官方约定的三个调试入口一起查：自测按钮、F3 排布调试网格、officetest 场景本身
# 的判空兜底。逐条限定到函数体，不整文件 contains —— 本轮已经三次栽在
# 「整文件 contains 被自己写的注释满足」上。

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "release_debug_ui"
const LOBBY_SRC_PATH := "res://scenes/menu/Team3v3Lobby.gd"
const MAIN_SRC_PATH := "res://scenes/main/Main.gd"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	var lobby_src := FileAccess.get_file_as_string(LOBBY_SRC_PATH)
	var main_src := FileAccess.get_file_as_string(MAIN_SRC_PATH)
	_check_selftest_button_gated(lobby_src)
	_check_selftest_capability(lobby_src)
	_check_f3_overlay_gated(lobby_src)
	_check_selftest_handler_defends_missing_scene(main_src)
	_check_officetest_excluded_from_export()
	_h.finish(get_tree())


# 按函数切开源码，返回 {函数名: 函数体}。限定到函数体是这条门禁反复验证过
# 有效的做法：整文件 contains 会被自己写的注释满足。
func _split_funcs(src: String) -> Dictionary:
	var out := {}
	var lines := src.split("\n")
	var name := ""
	var buf := PackedStringArray()
	for raw in lines:
		var line := raw.trim_suffix("\r")
		if line.begins_with("func "):
			if name != "":
				out[name] = "\n".join(buf)
			var open_paren := line.find("(")
			name = line.substr(5, open_paren - 5) if open_paren > 5 else line.substr(5)
			buf = PackedStringArray()
			continue
		if name != "":
			buf.append(line)
	if name != "":
		out[name] = "\n".join(buf)
	return out


func _check_selftest_button_gated(lobby_src: String) -> void:
	var funcs := _split_funcs(lobby_src)
	# 两处赋值：_ready() 里的初始化、_refresh_lobby_state() 类的刷新回调。
	# 两处都必须查，漏一处等于联机切换回离线时按钮又冒出来。
	var sites: Array[String] = []
	for fname in funcs.keys():
		var body: String = funcs[fname]
		for raw in body.split("\n"):
			var line := str(raw).strip_edges()
			if line.begins_with("_selftest_btn.visible = "):
				sites.append("%s: %s" % [fname, line])
	_h.expect(sites.size() >= 2, "selftest_visibility_sites_missing",
		"只找到 %d 处 _selftest_btn.visible 赋值（预期 ≥2）—— 门禁可能已经查不到了"
			% sites.size())
	var ungated: Array[String] = []
	for site in sites:
		if not site.contains("selftest_available()"):
			ungated.append(site)
	_h.expect(ungated.is_empty(), "selftest_button_visible_in_release",
		("这些地方没有统一走 selftest_available() 能力判断，"
			+ "场景未打包时仍可能显示一个死入口：%s")
			% str(ungated))


func _check_selftest_capability(lobby_src: String) -> void:
	var funcs := _split_funcs(lobby_src)
	var body: String = funcs.get("selftest_available", "")
	_h.expect(body.contains("OS.is_debug_build()")
			and body.contains("ResourceLoader.exists(SELFTEST_SCENE_PATH"),
		"selftest_capability_incomplete",
		"selftest_available() 必须同时验证 Debug 构建和场景真实存在")


func _check_f3_overlay_gated(lobby_src: String) -> void:
	var funcs := _split_funcs(lobby_src)
	var body: String = funcs.get("_unhandled_key_input", "")
	if not _h.expect(not body.is_empty(), "f3_handler_missing",
			"Team3v3Lobby 没有 _unhandled_key_input —— F3 排布调试的接入点不见了"):
		return
	var guard_at := body.find("if not OS.is_debug_build():")
	var key_check_at := body.find("key.keycode != KEY_F3")
	_h.expect(guard_at >= 0 and key_check_at > guard_at, "f3_overlay_not_gated",
		("F3 排布调试网格没有在处理按键之前先判 OS.is_debug_build() —— "
			+ "桌面 Release 版真实键盘能触发内部调试线"))


func _check_selftest_handler_defends_missing_scene(main_src: String) -> void:
	var funcs := _split_funcs(main_src)
	var body: String = funcs.get("_show_selftest", "")
	if not _h.expect(not body.is_empty(), "show_selftest_missing",
			"Main 没有 _show_selftest() —— 门禁的取值方式失效了"):
		return
	_h.expect(body.contains("as PackedScene") and body.contains("if packed == null:"),
		"show_selftest_no_null_guard",
		("_show_selftest() 直接对 load() 的结果调 instantiate()，"
			+ "没有判空 —— officetest 不在 Release 包里，这条路会崩溃"))
	_h.expect(not body.contains(").instantiate()") or body.find("if packed == null:")
			< body.find(").instantiate()"),
		"show_selftest_null_guard_out_of_order",
		"判空必须排在 instantiate() 之前，否则崩溃已经发生了才检查")


# officetest/ 必须仍在 Android 导出的排除清单里。这条不是这批加的，
# 但它是上面几条断言成立的前提 —— 前提本身漂移了，上面的「崩溃」判断就是错的，
# 所以钉在这里防止两边脱节。
func _check_officetest_excluded_from_export() -> void:
	var cfg := FileAccess.get_file_as_string("res://export_presets.cfg")
	_h.expect(cfg.contains("officetest/*"), "officetest_no_longer_excluded",
		("export_presets.cfg 不再排除 officetest/* —— "
			+ "如果这是有意为之，上面几条「Release 会崩溃」的断言前提已经不成立，"
			+ "要么撤回本次的 is_debug_build 改动、要么保留导出排除"))
