extends Node

# 守「教学引导指向的控件名」与备战界面实际成员的一致性。
#
# 起因是一个真实事故：D2 把商店/棋盘的成员收进 ShopPanel / BoardPanel 内部类之后，
# `scripts/tutorial/TutorialMode.gd` 里 15 处 `_prep.get("_selected_shop")` 这类
# **字符串取属性**全部失效。而 `Object.get()` 取不到只是返回 null、不报错，于是：
#
#   E _shop_entry_control: Invalid call. Nonexistent 'bool' constructor.
#     TutorialMode.gd:551 -> _target_control() -> update_overlay() -> sync() -> attach()
#     -> PrepScreen._ready() -> Main._show_prep()
#
# 也就是**进教学第一关就崩**，而编译零错误、board_4x4_smoke 62 项全绿 ——
# 因为那些检查直接实例化 PrepScreen，走不到 TutorialMode 这条路。
#
# 本检查做的事很简单但正好补上这个洞：把 TutorialMode.gd 里所有
# `_prep.get("X")` 的 X 抠出来，逐个断言 PrepScreen 上真的有这个属性。
# 字符串里的标识符编译器管不到，只能靠这种检查守。
#
# 运行：
#   Godot_v4.7-stable_win64_console.exe --headless --path . tools/tutorial_target_check.tscn

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "tutorial_target"
const TUTORIAL_PATH := "res://scripts/tutorial/TutorialMode.gd"

var _h: CheckHarness


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)

	var raw := FileAccess.get_file_as_string(TUTORIAL_PATH)
	if not _h.expect(not raw.is_empty(), "source_unreadable",
			"读不到 %s" % TUTORIAL_PATH):
		_h.finish(get_tree())
		return
	# 注释里会出现"旧写法长这样"的示例，扫描前先剥掉，否则会把示例当成真实调用。
	var source := _strip_comments(raw)

	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	var prep := packed.instantiate()
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame

	var direct := _collect(source, "_prep\\.get\\(\"([A-Za-z_][A-Za-z0-9_]*)\"\\)")
	_h.expect(not direct.is_empty(), "no_direct_targets",
		"一个 _prep.get(\"…\") 都没抠到 —— 正则或文件结构变了，这个检查已经失效")
	for name in direct:
		_h.expect(_has_property(prep, name), "missing_prep_member",
			"TutorialMode 取 _prep.get(\"%s\")，但 PrepScreen 上没有这个属性（会静默返回 null）" % name)

	# 走辅助函数的那批：_prep_shop_field("x") / _prep_board_field("x")
	_check_cluster(prep, source, "_prep_shop_field", "_shop")
	# 棋盘状态已随 D2 搬进 BoardHud 节点，持有者从 _board 变成 _board_hud。
	_check_cluster(prep, source, "_prep_board_field", "_board_hud")

	print("[%s] 直接取用 %d 个属性" % [CHECK_NAME, direct.size()])
	_h.finish(get_tree())


func _check_cluster(prep: Node, source: String, helper: String, holder_name: String) -> void:
	var names := _collect(source, helper + "\\(\"([A-Za-z_][A-Za-z0-9_]*)\"\\)")
	if names.is_empty():
		return
	var holder: Variant = prep.get(holder_name)
	if not _h.expect(holder != null, "cluster_missing",
			"PrepScreen 上没有 %s —— %s() 全部会返回 null" % [holder_name, helper]):
		return
	for name in names:
		_h.expect(_has_property(holder, name), "missing_cluster_member",
			"TutorialMode 取 %s(\"%s\")，但 %s 上没有这个属性" % [helper, name, holder_name])
	print("[%s] %s 取用 %d 个字段" % [CHECK_NAME, holder_name, names.size()])


# 只剥「整行注释」和「行尾注释」。GDScript 的字符串里可以有 #，
# 但本检查关心的调用都不含 #，所以按第一个 # 截断足够，且不会误伤。
func _strip_comments(text: String) -> String:
	var out: Array[String] = []
	for line in text.split("\n"):
		var hash_at := line.find("#")
		out.append(line if hash_at < 0 else line.substr(0, hash_at))
	return "\n".join(out)


func _collect(source: String, pattern: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.create_from_string(pattern)
	if re == null or not re.is_valid():
		_h.fail("regex_invalid", "正则 %s 编译失败，这一路全部漏检" % pattern)
		return out
	for m in re.search_all(source):
		var name := m.get_string(1)
		if not out.has(name):
			out.append(name)
	out.sort()
	return out


# get_property_list() 才是可靠判据：get() 对不存在的属性返回 null，
# 而合法属性本身也可能是 null（未构建的节点引用），两者用返回值区分不开。
func _has_property(obj: Object, name: String) -> bool:
	for prop in obj.get_property_list():
		if str(prop.get("name", "")) == name:
			return true
	return false
