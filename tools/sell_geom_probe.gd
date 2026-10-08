extends Control

# 10.08c 出售区探针（多分辨率）。
#
# 为什么必须多分辨率：10.08b 那次把红区改成「运行时按布局重算左缘」，在基准
# 1600×720 下看起来正常，但用户用的是手机 —— 画布尺寸一变，那条换算会把红区
# 撑成巨框，压掉商店刷新按钮、挡住待命区。所以这里每个分辨率都测一遍。
#
# 判据（每条都必须成立）：
#   ① 红区保持原尺寸：高 150（request #9 要求「恢复成原来大小」）
#   ② 红区不压住商店内外的任何可见控件（尤其 refresh_button）
#   ③ 刷新按钮可见
#   ④ 命中范围要覆盖商店弹窗 + 钱袋/金图标（要在商店 UI/金图标处能卖）
#   ⑤ 棋盘中心不算可出售（否则正常拖动会被误卖）

const PrepScene := preload("res://scenes/prep/PrepScreen.tscn")

const SIZES := [Vector2i(1600, 720), Vector2i(1280, 720), Vector2i(2340, 1080)]

var _results: Array[Dictionary] = []
var _tag: String = ""

func _ready() -> void:
	for s in SIZES:
		await _measure(s)
	_finish()

func _measure(size: Vector2i) -> void:
	_tag = "%dx%d" % [size.x, size.y]
	get_viewport().size = size
	var prep: Control = PrepScene.instantiate()
	add_child(prep)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var shop = prep._shop if "_shop" in prep else null
	if shop == null:
		_note("shop_missing", true, "拿不到 _shop")
		_free(prep)
		return
	var overlay = shop.sell_overlay
	if overlay == null or not is_instance_valid(overlay):
		_note("overlay_missing", true, "拿不到 sell_overlay")
		_free(prep)
		return

	overlay.visible = true
	# 必须走真正的开店入口，side_controls 的显隐才同步（_refresh_picker）。
	if shop.has_method("toggle_picker") and not shop.picker_open:
		shop.toggle_picker()
	await get_tree().process_frame
	await get_tree().process_frame

	var orect: Rect2 = overlay.get_global_rect()
	print("[sell.%s] overlay=%s" % [_tag, str(orect)])

	_note("overlay_size_restored", absf(orect.size.y - 150.0) >= 2.0,
		"红区高度必须恢复为原尺寸 150，实测 %.1f" % orect.size.y)

	if shop.panel != null and is_instance_valid(shop.panel) and shop.panel.visible:
		var prect: Rect2 = shop.panel.get_global_rect()
		print("[sell.%s] panel=%s" % [_tag, str(prect)])
		_note("overlay_inside_popup_bottom", orect.position.y < prect.position.y - 1.0,
			"红区不得越过商店弹窗上缘（红区 top=%.1f 弹窗 top=%.1f）"
				% [orect.position.y, prect.position.y])

	# 侧挂控件逐个判相交 —— side_controls 本身是横跨全屏的容器，拿它的 rect 判必然相交。
	var covered: Array[String] = []
	var purse_center := Vector2.INF
	if shop.side_controls != null and is_instance_valid(shop.side_controls):
		for ch in shop.side_controls.get_children():
			if ch is Control:
				var kid := ch as Control
				if kid.visible and kid.get_global_rect().intersects(orect):
					covered.append(String(kid.name))
				if purse_center == Vector2.INF and kid.position.x < 400.0:
					purse_center = kid.get_global_rect().get_center()
	_note("overlay_not_covering_side_controls", not covered.is_empty(),
		"红区不得压住侧挂控件（钱袋/刷新），实测压住 %d 个：%s"
			% [covered.size(), str(covered)])

	if shop.refresh_button != null and is_instance_valid(shop.refresh_button):
		var rb := shop.refresh_button as Control
		print("[sell.%s] refresh=%s visible=%s" % [_tag, str(rb.get_global_rect()), str(rb.visible)])
		_note("refresh_button_visible", not rb.visible,
			"商店打开后刷新按钮必须可见（visible=%s）" % str(rb.visible))
		_note("refresh_button_not_covered", rb.get_global_rect().intersects(orect),
			"刷新按钮不得被红区压住（按钮=%s 红区=%s）"
				% [str(rb.get_global_rect()), str(orect)])
	else:
		_note("refresh_button_visible", true, "拿不到 shop.refresh_button")

	# 功能判据：PrepScreen 继承 PrepBoardController，实例本身就是控制器。
	if shop.panel != null and is_instance_valid(shop.panel) and shop.panel.visible:
		var pc: Vector2 = shop.panel.get_global_rect().get_center()
		var hit_panel: bool = prep._point_in_sell_coverage(pc)
		print("[sell.%s] coverage@panel %s -> %s" % [_tag, str(pc.round()), str(hit_panel)])
		_note("coverage_hits_shop_panel", not hit_panel,
			"商店弹窗中心必须能卖（命中=%s）" % str(hit_panel))
	if purse_center != Vector2.INF:
		var hit_purse: bool = prep._point_in_sell_coverage(purse_center)
		print("[sell.%s] coverage@purse %s -> %s" % [_tag, str(purse_center.round()), str(hit_purse)])
		_note("coverage_hits_gold_purse", not hit_purse,
			"钱袋/金图标中心必须能卖（命中=%s）" % str(hit_purse))
	var board_pt := Vector2(get_viewport_rect().size.x * 0.5, get_viewport_rect().size.y * 0.36)
	var hit_board: bool = prep._point_in_sell_coverage(board_pt)
	_note("coverage_ignores_board", hit_board,
		"棋盘中心不得算可出售（命中=%s @ %s）—— 否则正常拖动会被误卖"
			% [str(hit_board), str(board_pt.round())])

	_free(prep)

func _free(prep: Node) -> void:
	remove_child(prep)
	prep.queue_free()
	await get_tree().process_frame

func _note(code: String, bad: bool, msg: String) -> void:
	_results.append({"code": _tag + "/" + code, "bad": bad, "msg": msg})

func _finish() -> void:
	var bad_count := 0
	print("[SELL] checked=%d" % _results.size())
	for r in _results:
		var failed: bool = bool(r["bad"])
		bad_count += 1 if failed else 0
		var label: String = "FAIL" if failed else "ok"
		print("  [SELL]   %s [%s] %s" % [label, str(r["code"]), str(r["msg"])])
	print("[SELL] failures=%d" % bad_count)
	get_tree().quit()
