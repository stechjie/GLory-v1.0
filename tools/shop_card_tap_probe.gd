extends Node

# 10.07 第 4 条（手机端商店第 4 格「小灵」点不着）诊断 + 修复验证
# （非 headless，真窗口 + 真 push_input 鼠标事件）。
#
# 诊断结论（修复前实测）：四张卡的命中矩形/遮挡层**完全一致**，
# 「第 4 格格外不灵」不是几何问题，而是「轻点被吞」的比例在阈值附近。
# 旧阈值 16px 太窄 ⇒ 手机手抖十几像素就被判成拖拽、那次松手不发 `pressed`。
#
# 修复：`PrepDragButton.DRAG_START_DISTANCE` 16 -> 28（详见该文件注释）。
# 本探针在修复后应显示：四张卡在 0/14/20/27px 手抖下都 got=true，
# 只有真正拖拽（≥28px）才不起点选。
#
# 运行（必须**非** headless）：
#   Godot_v4.7.2-stable_win64_console.exe --path . --resolution 1600x759 tools/shop_card_tap_probe.tscn

const REPORT := "user://shop_card_tap_probe.txt"

var _prep: Node
var _lines: Array = []
var _hits: Array = []   # 每次 _on_card_selected 的 index


func _ready() -> void:
	GameState.reset_run()
	var packed := load("res://scenes/prep/PrepScreen.tscn") as PackedScene
	if packed == null:
		_out("FATAL scene_load_failed")
		_flush()
		get_tree().quit(1)
		return
	_prep = packed.instantiate()
	add_child(_prep)
	for i in 6:
		await get_tree().process_frame

	var shop: Variant = _prep.get("_shop")
	if shop == null:
		_out("FATAL shop_null")
		_flush()
		get_tree().quit(1)
		return
	var panel: Control = shop.get("panel")
	if not panel.visible:
		shop.call("toggle_picker")
		for i in 4:
			await get_tree().process_frame
	_out("viewport=%s panel.visible=%s" % [str(get_viewport().get_visible_rect().size), str(panel.visible)])

	var buttons: Array = shop.get("buttons")
	_out("buttons=%d" % buttons.size())

	# 记录真实选中回调
	shop.card_selected.connect(func(idx: int) -> void: _hits.append(idx))

	for i in buttons.size():
		await _probe_card(i, buttons[i], shop)

	_flush()
	get_tree().quit(0)


# 对一张卡做：中心轻点(0px) / 中心多档手抖 / 两侧与边缘。
#
# ★ 10.07 第 4 条把 DRAG_START_DISTANCE 从 16 提到 28 —— 本探针的分界点必须
#   同步挪到 28 两侧，否则「手抖 20px 仍算点击」这条新承诺就没人验。
#   旧口径下 18px 起拖（got=false）；新口径下 18 与 27 都应 got=true。
func _probe_card(i: int, card: Control, shop: Variant) -> void:
	var gr := card.get_global_rect()
	_out("=== card[%d] rect=%s" % [i, str(gr)])
	var cases := [
		{"k": "center_tap0", "pos": gr.get_center(), "d": 0},
		{"k": "center_tap14", "pos": gr.get_center(), "d": 14},
		{"k": "center_tap20", "pos": gr.get_center(), "d": 20},
		{"k": "center_tap27", "pos": gr.get_center(), "d": 27},
		{"k": "center_tap28", "pos": gr.get_center(), "d": 28},
		{"k": "q_left_tap0", "pos": Vector2(gr.position.x + gr.size.x * 0.25, gr.get_center().y), "d": 0},
		{"k": "q_right_tap0", "pos": Vector2(gr.position.x + gr.size.x * 0.75, gr.get_center().y), "d": 0},
		{"k": "edge_right_tap0", "pos": Vector2(gr.end.x - 3.0, gr.get_center().y), "d": 0},
		{"k": "top_tap0", "pos": Vector2(gr.get_center().x, gr.position.y + 6.0), "d": 0},
	]
	for c in cases:
		# 先清掉选中态，保证「有没有触发」可判
		shop.set("selected", -1)
		var before := _hits.size()
		var pos: Vector2 = c["pos"]
		_tap(pos, int(c["d"]))
		for f in 2:
			await get_tree().process_frame
		var got := _hits.size() > before
		_out("  %-16s pos=(%.0f,%.0f) d=%d -> selected=%d got=%s" % [
			str(c["k"]), pos.x, pos.y, int(c["d"]), int(shop.get("selected")), str(got)])


func _tap(global_pos: Vector2, dist: int) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = global_pos
	get_viewport().push_input(down)
	if dist > 0:
		var mv := InputEventMouseMotion.new()
		mv.position = global_pos + Vector2(dist, 0)
		get_viewport().push_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = global_pos + Vector2(dist, 0)
	get_viewport().push_input(up)


func _out(s: String) -> void:
	_lines.append(s)
	print(s)


func _flush() -> void:
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f == null:
		print("report_open_failed")
		return
	for l in _lines:
		f.store_line(l)
	f.close()
	print("report=%s written=true lines=%d" % [REPORT, _lines.size()])
