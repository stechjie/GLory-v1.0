extends Node

# 10.08 第 9 条侦察探针：拖棋子到出售区时，落在「商店 UI」或「金图标」位置卖不掉。
# 只做几何测量：把 sell_overlay 的 global_rect 与商店弹窗 / side_controls 里
# 各控件的 global_rect 打出来，判断「这些位置是否被红区盖住」。

const OUT_PATH := "user://probe_1008_sellzone.txt"
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"


func _ready() -> void:
	var lines: Array[String] = []
	var packed := load(PREP_SCENE) as PackedScene
	if packed == null:
		lines.append("ERR scene load failed")
		_flush(lines)
		return
	var screen := packed.instantiate()
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var vp := get_viewport().get_visible_rect().size
	lines.append("viewport=%s" % str(vp))

	var shop: Object = screen.get("_shop")
	if shop == null:
		lines.append("ERR _shop null")
		_flush(lines)
		return

	# 打开商店，让 side_controls / panel 都可见
	if not bool(shop.get("picker_open")):
		shop.toggle_picker()
	await get_tree().process_frame
	await get_tree().process_frame

	# 进入拖拽态（棋盘棋子），红区应显示
	var payload := {"kind": "board", "index": 0}
	screen._on_drag_started(payload)
	await get_tree().process_frame
	await get_tree().process_frame

	var overlay: Control = shop.get("sell_overlay")
	lines.append("picker_open=%s" % str(shop.get("picker_open")))
	if overlay == null:
		lines.append("ERR sell_overlay null")
	else:
		lines.append("sell_overlay.visible=%s z=%d rect=%s" % [
			str(overlay.visible), overlay.z_index, str(overlay.get_global_rect())])

	var panel: Control = shop.get("panel")
	if panel != null:
		lines.append("shop_panel.visible=%s z=%d rect=%s" % [
			str(panel.visible), panel.z_index, str(panel.get_global_rect())])

	var side: Control = shop.get("side_controls")
	if side != null:
		lines.append("side_controls.visible=%s z=%d rect=%s" % [
			str(side.visible), side.z_index, str(side.get_global_rect())])
		lines.append("side_controls.mouse_filter=%d" % side.mouse_filter)
		for c in side.get_children():
			if c is Control:
				var cc := c as Control
				lines.append("  SIDE %s vis=%s mf=%d rect=%s" % [
					cc.name, str(cc.visible), cc.mouse_filter, str(cc.get_global_rect())])

	# 关键点：金图标（gold_area 是第一象限左下那个 138x141 的 Control）
	var gold_rect := Rect2()
	lines.append("--- gold_area 定位 ---")
	for c in side.get_children():
		if c is Control:
			var cc := c as Control
			if cc.get_child_count() >= 5:
				gold_rect = cc.get_global_rect()
				lines.append("  gold_area rect=%s mf=%d children=%d" % [
					str(gold_rect), cc.mouse_filter, cc.get_child_count()])

	# 网格采样：把商店弹窗 y 范围切成 6 条扫描线，每条上取若干 x，看哪些点「没有红区」
	if overlay != null and panel != null:
		lines.append("--- 扫描：商店弹窗区域 ---")
		var pr := panel.get_global_rect()
		var orc := overlay.get_global_rect()
		lines.append("sellzone_y=[%.1f,%.1f] shoppanel_y=[%.1f,%.1f]" % [
			orc.position.y, orc.end.y, pr.position.y, pr.end.y])
		for k in 6:
			var y := pr.position.y + pr.size.y * (float(k) + 0.5) / 6.0
			var misses: Array[String] = []
			for j in 9:
				var x := pr.position.x + pr.size.x * (float(j) + 0.5) / 9.0
				var pt := Vector2(x, y)
				if not orc.has_point(pt):
					misses.append("%d" % j)
			lines.append("  y=%.1f 红区未覆盖的列=%s (%d/9)" % [y, str(misses), misses.size()])
		# 金图标采样
		if gold_rect.size.x > 0:
			lines.append("--- 扫描：金图标 ---")
			for k in 3:
				var y2 := gold_rect.position.y + gold_rect.size.y * (float(k) + 0.5) / 3.0
				var miss2 := 0
				for j in 3:
					var x2 := gold_rect.position.x + gold_rect.size.x * (float(j) + 0.5) / 3.0
					if not orc.has_point(Vector2(x2, y2)):
						miss2 += 1
				lines.append("  y=%.1f 红区未覆盖 %d/3" % [y2, miss2])

	# 用真实命中测试：找鼠标点下最上层能接拖放的控件
	if overlay != null:
		var test_points: Array[Vector2] = [gold_rect.get_center()]
		if panel != null:
			test_points.append(panel.get_global_rect().get_center())
		test_points.append(overlay.get_global_rect().get_center())
		for tp in test_points:
			if tp.x < 0 or tp.y < 0:
				continue
			lines.append("hit_test at %s -> %s" % [str(tp), _describe_hit(screen, tp)])

	_flush(lines)


func _describe_hit(root: Node, pt: Vector2) -> String:
	# 自顶向下遍历绘制顺序（近似：逆序深度优先），找第一个可见且非 IGNORE 的 Control
	var stack: Array[Node] = []
	_collect(root, stack)
	var best := ""
	for i in range(stack.size() - 1, -1, -1):
		var n := stack[i] as Control
		if n == null:
			continue
		if not n.visible:
			continue
		if n.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			continue
		if not n.get_global_rect().has_point(pt):
			continue
		var eff := _eff_z(n)
		best = "%s(%s) mf=%d effz=%d" % [n.name, n.get_class(), n.mouse_filter, eff]
		break
	return best


func _eff_z(n: Control) -> int:
	var z := n.z_index
	var p := n.get_parent()
	while p is Control:
		z += (p as Control).z_index
		p = p.get_parent()
	return z


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
	print("PROBE_1008_SELLZONE report=%s written=%s lines=%d" % [OUT_PATH, str(f != null), lines.size()])
	get_tree().quit()
