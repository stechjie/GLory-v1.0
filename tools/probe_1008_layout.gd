extends Node

# 10.08 第 4 条辅助探针：量出「准备头像（两行）」与「羁绊/宝藏栏」的实测 rect，
# 判断头像加高后是否真的压到了下面那一栏（决定要不要下移羁绊栏）。
# 另外量出左上角头像下方还有哪些控件（腾位置的对象到底是谁）。

const OUT_PATH := "user://probe_1008_layout.txt"


func _ready() -> void:
	var lines: Array[String] = []
	get_viewport().size = Vector2i(1266, 600)
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if packed == null:
		lines.append("ERR scene load failed")
		_flush(lines)
		return
	NetworkService.team_active = true
	GameState.reset_run()
	GameState.tutorial_mode = false
	var prep := packed.instantiate()
	add_child(prep)
	for i in 4:
		await get_tree().process_frame

	lines.append("viewport=%s" % str(get_viewport().get_visible_rect().size))

	var ri: Control = prep.get("_ready_indicator")
	if ri != null:
		lines.append("ready_indicator rect=%s children=%d" % [str(ri.get_global_rect()), ri.get_child_count()])
		for c in ri.get_children():
			if c is Control:
				lines.append("  row %s rect=%s n=%d" % [c.name, str((c as Control).get_global_rect()), c.get_child_count()])

	var synergy: Object = prep.get("_synergy")
	if synergy != null:
		var lp: Control = synergy.get("_left_panel")
		if lp != null:
			lines.append("synergy._left_panel rect=%s children=%d" % [str(lp.get_global_rect()), lp.get_child_count()])
			for c in lp.get_children():
				if c is Control:
					lines.append("  SY %s(%s) rect=%s vis=%s" % [
						c.name, c.get_class(), str((c as Control).get_global_rect()), str((c as Control).visible)])

	# 左上角区域所有可见、接输入的控件（按 rect 排序），看头像下面紧跟着谁。
	lines.append("--- 左半屏可见控件（y<400, x<520）---")
	var stack: Array[Node] = []
	_collect(prep, stack)
	for n in stack:
		var c := n as Control
		if c == null or not c.visible:
			continue
		var r := c.get_global_rect()
		if r.size.x <= 1.0 or r.size.y <= 1.0:
			continue
		if r.position.x >= 520.0 or r.position.y >= 400.0:
			continue
		lines.append("  %s(%s) rect=%s mf=%d z=%d" % [
			c.name, c.get_class(), str(r), c.mouse_filter, c.z_index])

	_flush(lines)


func _collect(n: Node, out: Array[Node]) -> void:
	if n is Control:
		out.append(n)
	for c in n.get_children():
		_collect(c, out)


func _flush(lines: Array[String]) -> void:
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		for l in lines:
			f.store_line(l)
		f.close()
	print("PROBE_1008_LAYOUT report=%s written=%s lines=%d" % [OUT_PATH, str(f != null), lines.size()])
	get_tree().quit()
