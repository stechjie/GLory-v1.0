extends Node

# D2 的安全网：把 PrepScreen 实例化后的完整节点树与仓库里的基线逐行比对。
#
# 为什么需要它：`_build_rest` 原本是个 638 行的 UI 构建函数，而 PrepUI 的注释里
# 明确记着**树顺序影响输入拾取**——
#   「它默认 STOP 且树顺序在 board_frame 之后（拾取优先），把右列点击全吃了」
# 也就是说，拆分构建函数时哪怕只是把两段的先后换一下，右列棋格就可能点不动，
# 而 board_4x4_smoke 未必抓得到（它测的是 _can_drop_on_board 的逻辑判定，
# 不是真实点击拾取）。
#
# ⚠️ 这个工具的第一版是**假绿**，记在这里当教训：
#     它只导出树、断言「节点数 > 50」，然后把文件写到 user://，
#     **从来没有比对过任何东西**。`checked=305` 只是节点计数喂给 _h.item()。
#     于是 D2 第八到十一步里「节点树 305 节点无变化」这句话，
#     工具一次都没有真正验证过 —— 靠的是人去 diff 两个 user:// 文件，
#     而那一步很容易被省掉，事实上也确实被省掉了。
#     发现方式：故意把 make_cell_caption() 的 z_index 改成 11、visible 改成 true，
#     工具照样 PASS。事后 diff 两份导出文件，96 行差异明明白白。
#
#     教训与 4.5 同类：**一条检查必须能因为产品变了而变红**。
#     只统计不比对的「检查」，读起来和真检查一模一样。
#
# 现在的行为：与 `tools/prep_tree_baseline.txt` 逐行比对，
# 报第一处差异的行号、期望值与实际值，并统计新增/缺失的节点。
#
# 快照包含：节点路径、类名、在父节点中的次序（由行序体现）、
# 以及影响拾取与层叠的关键属性（z_index / visible / mouse_filter）。
# **不含位置与尺寸**：它们依赖窗口大小与布局时序，headless 下不稳定，
# 记进来会把快照变成噪声源。
#
# 运行：
#   Godot ... tools/prep_tree_snapshot.tscn
# 刻意重建基线（改动确实应该改变树时）：
#   Godot ... tools/prep_tree_snapshot.tscn -- --update

const CheckHarness := preload("res://tools/CheckHarness.gd")

const CHECK_NAME := "prep_tree_snapshot"
const BASELINE := "res://tools/prep_tree_baseline.txt"
const DUMP_OUT := "user://prep_tree_actual.txt"

var _h: CheckHarness
var _update := false
var _lines: Array[String] = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_parse_args()

	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if not _h.expect(packed != null, "scene_load_failed", "PrepScreen.tscn 无法加载"):
		_h.finish(get_tree())
		return
	var prep := packed.instantiate()
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame

	_dump(prep, "")
	if not _h.expect(_lines.size() > 50, "tree_too_small",
			"只导出了 %d 个节点，构建可能没跑完" % _lines.size()):
		_h.finish(get_tree())
		return

	# 实际结果总是写出来，比对失败时方便人工 diff。
	var out := FileAccess.open(DUMP_OUT, FileAccess.WRITE)
	if out != null:
		out.store_string("\n".join(_lines))
		out.close()

	if _update:
		_write_baseline()
		_h.finish(get_tree())
		return

	_compare()
	_h.finish(get_tree())


func _write_baseline() -> void:
	var f := FileAccess.open(BASELINE, FileAccess.WRITE)
	if f == null:
		_h.fail("baseline_write_failed", "无法写入 %s" % BASELINE)
		return
	# 按仓库惯例写 CRLF：tools/ 下都是 CRLF，基线写成 LF 会让 git diff 每次显示全文改动。
	# 比对时逐行 strip_edges()，所以换行符本身不影响判定。
	f.store_string("\r\n".join(_lines) + "\r\n")
	f.close()
	print("[%s] 已重建基线 %s（%d 个节点）" % [CHECK_NAME, BASELINE, _lines.size()])
	print("[%s] ⚠️ 重建基线等于宣布「树本来就该变」。请确认差异是预期的，并写进 docs/CHECKS.md。" % CHECK_NAME)


func _compare() -> void:
	var f := FileAccess.open(BASELINE, FileAccess.READ)
	if f == null:
		# 基线缺失必须是**硬失败**。当成「首次运行，自动建基线」处理，
		# 就等于任何人删掉基线都能让这条检查永远绿。
		_h.fail("baseline_missing",
			"基线文件 %s 不存在。刻意重建请显式跑 -- --update" % BASELINE)
		return
	var text := f.get_as_text()
	f.close()
	var want := text.strip_edges().split("\n")
	var got := _lines

	_h.item(got.size())
	_h.expect(got.size() == want.size(), "node_count_changed",
		"节点数 %d，基线是 %d（差 %+d）" % [got.size(), want.size(), got.size() - want.size()])

	# 先做**集合比对**再做顺序比对。
	# 只做逐行比对的话，在中间插入一个节点会让后面每一行都错位 ——
	# 实测新增 1 个节点报出「302 行不同」，噪声淹没了真正的信息。
	# 集合比对回答「多了谁、少了谁」，顺序比对回答「谁挪了位置」，两者要分开说。
	var want_set := {}
	for l in want:
		want_set[str(l).strip_edges()] = true
	var got_set := {}
	for l in got:
		got_set[str(l).strip_edges()] = true
	var added: Array = []
	for l in got:
		if not want_set.has(str(l).strip_edges()):
			added.append(str(l))
	var missing: Array = []
	for l in want:
		if not got_set.has(str(l).strip_edges()):
			missing.append(str(l))
	for l in added.slice(0, 8):
		_h.fail("node_added", "多出节点：%s" % str(l))
	for l in missing.slice(0, 8):
		_h.fail("node_missing", "缺失节点：%s" % str(l))
	if added.size() > 8:
		_h.fail("node_added_more", "另有 %d 个新增节点未列出" % (added.size() - 8))
	if missing.size() > 8:
		_h.fail("node_missing_more", "另有 %d 个缺失节点未列出" % (missing.size() - 8))

	# 顺序比对：把两边共有的行按原顺序取出来比，这样「插入一个新节点」
	# 不会把后面全判成错位，真正的挪位才会被报出来。
	var got_common: Array = []
	for l in got:
		if want_set.has(str(l).strip_edges()):
			got_common.append(str(l).strip_edges())
	var want_common: Array = []
	for l in want:
		if got_set.has(str(l).strip_edges()):
			want_common.append(str(l).strip_edges())
	var common_limit := mini(got_common.size(), want_common.size())
	var order_diffs := 0
	for i in common_limit:
		if got_common[i] == want_common[i]:
			continue
		order_diffs += 1
		if order_diffs == 1:
			_h.fail("node_order_changed",
				"共有节点的第 %d 个位置次序变了
         基线: %s
         实际: %s" % [
					i + 1, want_common[i], got_common[i]])
	if order_diffs > 1:
		_h.fail("node_order_changed_more", "另有 %d 处次序不同" % (order_diffs - 1))
	if added.is_empty() and missing.is_empty() and order_diffs == 0 and got.size() == want.size():
		print("[%s] 与基线一致（%d 个节点）" % [CHECK_NAME, got.size()])
	return

	# 逐行比对，报第一处差异 —— 只说「不一致」没法定位，
	# 和 determinism_check 要求给出首个不同 tick 是同一个道理。
	var limit := mini(got.size(), want.size())
	var diffs := 0
	for i in limit:
		if str(got[i]).strip_edges() == str(want[i]).strip_edges():
			continue
		diffs += 1
		if diffs == 1:
			_h.fail("tree_changed",
				"第 %d 行起与基线不同\n         基线: %s\n         实际: %s" % [
					i + 1, str(want[i]), str(got[i])])
	if diffs > 1:
		_h.fail("tree_changed_more", "共 %d 行与基线不同（完整结果见 %s）" % [diffs, DUMP_OUT])

	# 行数不同时，把多出来/少掉的那几行也点名。
	if got.size() > want.size():
		for i in range(want.size(), mini(got.size(), want.size() + 5)):
			_h.fail("node_added", "多出节点：%s" % str(got[i]))
	elif want.size() > got.size():
		for i in range(got.size(), mini(want.size(), got.size() + 5)):
			_h.fail("node_missing", "缺失节点：%s" % str(want[i]))

	if diffs == 0 and got.size() == want.size():
		print("[%s] 与基线逐行一致（%d 个节点）" % [CHECK_NAME, got.size()])


# 只记影响「长什么样 / 能不能点」的属性。位置尺寸不记：它们依赖窗口大小与布局时序，
# 在 headless 下不稳定，会把快照变成噪声源。
func _dump(node: Node, path: String) -> void:
	var here := path + "/" + node.name
	var extra := ""
	if node is CanvasItem:
		var ci := node as CanvasItem
		extra += " z=%d vis=%s" % [ci.z_index, str(ci.visible)]
	if node is Control:
		var c := node as Control
		extra += " mouse=%d" % int(c.mouse_filter)
	_lines.append("%s [%s]%s" % [here, node.get_class(), extra])
	for i in node.get_child_count():
		_dump(node.get_child(i), here)


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a) == "--update":
			_update = true
