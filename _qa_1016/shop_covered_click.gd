extends Node
# ============================================================================
# 2026-10-15 问题 1 门禁：被商店弹窗盖住的 UI 不得再吃点击。
#
# 【反馈原文】
#   「对局中打开商店后，在里面进行购买棋子操作，在商店UI位置会点击到商店UI
#     然后退出商店界面。修复要求：对于已经被遮盖的UI不应该被触发，像这种商店
#     已经打开了，遮盖住了商店UI，那在商店UI的位置不应该能够再被点击到。」
#
# 【要钉住什么】
#   1. 商店开着时，底部「商店」木牌**被弹窗整个盖住**（几何前提，先断言，
#      否则下面的判定没有意义）。
#   2. 在木牌所在的屏幕位置点击 → 商店必须**仍然开着**。
#      （修复前：这一下会穿透到木牌，把商店关掉 = 反馈里的现象。）
#   3. 光标停在木牌位置时，GUI 拾取到的控件**不是**那块被盖住的木牌。
#   4. 反向：弹窗打开后，它自己那一层要能吃掉点击 —— 卡面点选 / 采购热区 /
#      刷新键都还得照常工作，否则「挡住下层」就变成了「整块失活」。
#   5. 反向：点在弹窗**外面**仍然要能收起商店（9.13 起就有的行为，不能一起废掉）。
#
# 【跑法】
#   Godot_v4.7.2-stable_win64_console.exe --headless --path <工程根> \
#       _qa_1016/shop_covered_click.tscn
#   退出码 0 = PASS，1 = FAIL。
#
# ⚠ 必须**带窗口尺寸**跑：木牌几何依赖 viewport 宽度（基准 1600×720，
#   stretch=canvas_items + aspect=expand，画布宽度随设备宽高比在 1280~1600 间变）。
#   本门禁自己把窗口设成 1600×720，不依赖命令行 --resolution。

const CheckHarness := preload("res://_qa_1016/CheckHarness.gd")
const CHECK_NAME := "shop_covered_click"

const VIEW := Vector2i(1600, 720)
const PREP_SCENE := "res://scenes/prep/PrepScreen.tscn"

var _h: CheckHarness
var _prep: Node
var _shop: Variant


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	get_window().size = VIEW
	await _settle(4)

	GameState.reset_run()
	var packed := load(PREP_SCENE) as PackedScene
	if not _h.expect(packed != null, "prep_scene_load_failed", "%s 加载不出来" % PREP_SCENE):
		_h.finish(get_tree())
		return
	_prep = packed.instantiate()
	if not _h.expect(_prep != null, "prep_instantiate_failed", "PrepScreen 实例化失败"):
		_h.finish(get_tree())
		return
	add_child(_prep)
	await _settle(10)

	_shop = _prep.get("_shop")
	if not _h.expect(_shop != null, "shop_missing",
			"PrepScreen 上取不到 _shop（面板被改名或没建起来）"):
		_h.finish(get_tree())
		return

	_diagnose()
	await _case_covered_bar()
	await _case_popup_still_interactive()
	await _case_outside_click_still_closes()
	await _case_all_resolutions()

	_h.finish(get_tree())


# ── 诊断（只进日志，不影响退出码） ─────────────────────────────────────────────

func _diagnose() -> void:
	var panel: Control = _shop.get("panel")
	var bar: Control = _shop.get("open_button")
	var side: Control = _shop.get("side_controls")
	if panel == null or bar == null:
		return
	_h.note("panel.mouse_filter=%d z=%d  bar.mouse_filter=%d z=%d  side.z=%d"
		% [panel.mouse_filter, panel.z_index, bar.mouse_filter, bar.z_index,
			side.z_index if side != null else -999])
	_h.note("panel path = %s" % str(_prep.get_path_to(panel)))
	_h.note("bar   path = %s" % str(_prep.get_path_to(bar)))
	# 找到共同祖先（PrepUI / center_host / host 三者中的最低公共点），打印它的直接子节点次序。
	# 拾取是按树的逆序走子节点的，所以「弹窗所在的分支」是否排在「木牌所在的分支」之后，
	# 决定了谁先被命中。
	var panel_branch := _branch_under(panel, _prep)
	var bar_branch := _branch_under(bar, _prep)
	var kids: Array = []
	for c in _prep.get_children():
		var tag := ""
		if c == panel_branch:
			tag += "<-panel"
		if c == bar_branch:
			tag += "<-bar"
		kids.append("%s(z=%d)%s" % [c.name, (c as CanvasItem).z_index if c is CanvasItem else -999, tag])
	_h.note("PrepUI.children(in order) = %s" % str(kids))
	_h.note("panel branch under PrepUI = %s ; bar branch = %s"
		% [str(panel_branch.name if panel_branch != null else "<none>"),
			str(bar_branch.name if bar_branch != null else "<none>")])


func _branch_under(node: Node, root: Node) -> Node:
	var cur := node
	while cur != null and cur.get_parent() != root:
		cur = cur.get_parent()
	return cur


# ── 主判定：被盖住的「商店」木牌不得被点击 ──────────────────────────────────────

func _case_covered_bar() -> void:
	await _open()
	if not _h.expect(bool(_shop.get("picker_open")), "shop_not_open",
			"起点不成立：toggle_picker() 之后商店没打开"):
		return

	var panel: Control = _shop.get("panel")
	var bar: Control = _shop.get("open_button")
	if not _h.expect(panel != null and is_instance_valid(panel) and bar != null
			and is_instance_valid(bar), "shop_nodes_missing",
			"商店面板 panel / 底部木牌 open_button 取不到"):
		return
	if not _h.expect(panel.visible and bar.visible, "shop_nodes_invisible",
			"商店开着，但面板或木牌的 visible 不对（panel=%s bar=%s）"
				% [str(panel.visible), str(bar.visible)]):
		return

	var panel_rect := panel.get_global_rect()
	var bar_rect := bar.get_global_rect()
	_h.note("panel=%s  bar=%s" % [str(panel_rect), str(bar_rect)])

	# 几何前提：木牌几乎整个落在弹窗矩形里，探针点取两者交集的中心。
	# 用覆盖率而不是 encloses：实测底边有 2px 露在判定框外（弹窗背景 920×280 仍然盖住它），
	# 写 encloses 会因为这条 2px 的缝常年红。
	var covered := _overlap(panel_rect, bar_rect)
	var bar_area := maxf(1.0, bar_rect.size.x * bar_rect.size.y)
	_h.expect(covered / bar_area >= 0.9, "bar_not_covered",
		"前提不成立：底部「商店」木牌 %s 只被商店弹窗 %s 盖住 %.1f%%"
			% [str(bar_rect), str(panel_rect), 100.0 * covered / bar_area])
	var probe := panel_rect.intersection(bar_rect).get_center()
	_h.expect(panel_rect.has_point(probe), "probe_point_outside_panel",
		"取到的探针点 %s 不在弹窗 %s 里，这条判定会失去意义" % [str(probe), str(panel_rect)])

	# ① 拾取：光标停在木牌位置，GUI 拾取到的必须是**弹窗那一支**。
	var window_point := _canvas_to_window(probe)
	_move(window_point)
	await _settle(2)
	var hovered := get_viewport().gui_get_hovered_control()
	_h.expect(hovered != bar, "hover_leaks_to_covered_bar",
		"光标停在商店弹窗内部（木牌位置 %s），GUI 拾取到的却是被盖住的木牌" % str(probe))
	_h.expect(hovered == panel or (hovered != null and panel.is_ancestor_of(hovered)),
		"pick_not_absorbed_by_popup",
		"光标停在商店弹窗内部 %s，拾取到的却是 %s —— 既不是弹窗也不是它的子节点，"
			% [str(probe), str(hovered)]
		+ "说明还有别的分支排在被盖住的弹窗后面")

	# ② 点击：这一下不得把商店关掉。
	_tap(window_point)
	await _settle(4)
	_h.expect(bool(_shop.get("picker_open")), "covered_bar_receives_click",
		"在商店弹窗内部点了木牌所在的屏幕位置 %s，商店被关掉了 —— "
			% str(probe)
		+ "被弹窗盖住的 UI 抢到了这次点击（2026-10-15 问题 1）")


# ── 反向：弹窗自己那一层要能吃掉点击，卡面/采购/刷新不能被一起废掉 ──────────────

func _case_popup_still_interactive() -> void:
	await _open()
	if not bool(_shop.get("picker_open")):
		_h.fail("popup_case_not_open", "前置不成立：商店没打开，无法验证弹窗交互")
		return

	# ① 卡面点选：真实点击第 1 张卡的中心，选中态必须落到 0。
	var cards: Array = _shop.get("buttons")
	if not _h.expect(cards.size() > 0, "shop_cards_missing", "商店一张卡都没建出来"):
		return
	var card := cards[0] as Control
	if card == null or not is_instance_valid(card):
		_h.fail("shop_card_invalid", "第 1 张商店卡不是有效 Control")
		return
	_shop.set("selected", -1)
	await _settle(2)
	_tap(_canvas_to_window(card.get_global_rect().get_center()))
	await _settle(3)
	_h.expect(int(_shop.get("selected")) == 0, "card_tap_broken",
		"商店开着时点第 1 张卡中心，选中态是 %d（应为 0）—— 弹窗把点击吃过头了"
			% int(_shop.get("selected")))

	# ② 采购热区（钱袋 A，挂在弹窗矩形**外面**的外挂层）仍须可拾取。
	var buy: Control = _shop.get("buy_button")
	if buy != null and is_instance_valid(buy) and buy.is_visible_in_tree():
		var buy_point := buy.get_global_rect().get_center()
		_move(_canvas_to_window(buy_point))
		await _settle(2)
		var buy_hovered := get_viewport().gui_get_hovered_control()
		_h.expect(_is_in_side_controls(buy_hovered), "buy_zone_unreachable",
			"光标停在采购热区 %s 上，拾取到的却是 %s —— 外挂层（钱袋A/刷新）被挡住了"
				% [str(buy_point), str(buy_hovered)])
	else:
		_h.fail("buy_button_missing", "取不到 buy_button，采购热区判据无法执行")

	# ③ 刷新键同理。
	var refresh: Control = _shop.get("refresh_button")
	if refresh != null and is_instance_valid(refresh) and refresh.is_visible_in_tree():
		var refresh_point := refresh.get_global_rect().get_center()
		_move(_canvas_to_window(refresh_point))
		await _settle(2)
		var refresh_hovered := get_viewport().gui_get_hovered_control()
		_h.expect(_is_in_side_controls(refresh_hovered), "refresh_unreachable",
			"光标停在刷新键 %s 上，拾取到的却是 %s —— 外挂层被挡住了"
				% [str(refresh_point), str(refresh_hovered)])
	else:
		_h.fail("refresh_button_missing", "取不到 refresh_button，刷新键判据无法执行")

	# ④ 采购热区点下去不得顺手把商店关掉（9.13 起用白名单保证的行为）。
	var buy2: Control = _shop.get("buy_button")
	if buy2 != null and is_instance_valid(buy2):
		_tap(_canvas_to_window(buy2.get_global_rect().get_center()))
		await _settle(3)
		_h.expect(bool(_shop.get("picker_open")), "buy_tap_closes_shop",
			"点了采购热区之后商店被关掉了 —— 白名单（click_on_shop_side）失效")


# ── 反向：点弹窗外面仍要收起商店 ───────────────────────────────────────────────

func _case_outside_click_still_closes() -> void:
	await _open()
	if not bool(_shop.get("picker_open")):
		_h.fail("outside_case_not_open", "前置不成立：商店没打开")
		return
	var panel: Control = _shop.get("panel")
	if panel == null or not is_instance_valid(panel):
		_h.fail("outside_panel_missing", "取不到 panel")
		return
	var panel_rect := panel.get_global_rect()
	# 弹窗正上方 30px、同一列的空白处：既在弹窗之外，也不在木牌/外挂层上。
	var outside := Vector2(panel_rect.get_center().x, panel_rect.position.y - 30.0)
	_h.expect(not panel_rect.has_point(outside), "outside_point_inside_panel",
		"选的点 %s 居然在弹窗里，这条判据不成立" % str(outside))
	_tap(_canvas_to_window(outside))
	await _settle(4)
	_h.expect(not bool(_shop.get("picker_open")), "outside_click_no_longer_closes",
		"点在商店弹窗之外（%s）没能收起商店 —— 把「遮挡不吃点击」修成了「哪都关不掉」"
			% str(outside))


# ── 三种画布宽度都验一遍（stretch=canvas_items + expand，窄屏画布更窄） ─────────

func _case_all_resolutions() -> void:
	var restore := get_window().size
	for size in [Vector2i(1280, 720), Vector2i(1440, 720), Vector2i(1600, 720)]:
		get_window().size = size as Vector2i
		await _settle(4)
		await _open()
		var panel: Control = _shop.get("panel")
		var bar: Control = _shop.get("open_button")
		if panel == null or not is_instance_valid(panel) or bar == null or not is_instance_valid(bar):
			_h.fail("resolution_nodes_missing", "%s：面板/木牌取不到" % str(size))
			continue
		var canvas := get_viewport().get_visible_rect().size
		var bar_rect := bar.get_global_rect()
		var panel_rect := panel.get_global_rect()
		_h.expect(bool(_shop.get("picker_open")), "resolution_shop_not_open",
			"%s（画布 %.0fx%.0f）：商店没打开" % [str(size), canvas.x, canvas.y])
		var cov := _overlap(panel_rect, bar_rect) / maxf(1.0, bar_rect.size.x * bar_rect.size.y)
		_h.expect(cov >= 0.9, "resolution_bar_not_covered",
			"%s（画布 %.0fx%.0f）：木牌 %s 只被弹窗 %s 盖住 %.1f%%"
				% [str(size), canvas.x, canvas.y, str(bar_rect), str(panel_rect), 100.0 * cov])
		_tap(_canvas_to_window(panel_rect.intersection(bar_rect).get_center()))
		await _settle(4)
		_h.expect(bool(_shop.get("picker_open")), "resolution_covered_bar_click",
			"%s（画布 %.0fx%.0f）：点被盖住的木牌位置，商店被关掉了"
				% [str(size), canvas.x, canvas.y])
	get_window().size = restore
	await _settle(3)


# ── 辅助 ───────────────────────────────────────────────────────────────────────

func _open() -> void:
	if bool(_shop.get("picker_open")):
		_shop.call("close_picker")
		await _settle(3)
	_shop.call("toggle_picker")      # 走真实入口，不直接改 picker_open
	await _settle(4)


func _is_in_side_controls(node: Control) -> bool:
	var side: Control = _shop.get("side_controls")
	if node == null or side == null or not is_instance_valid(side):
		return false
	return side == node or side.is_ancestor_of(node)


# 两个矩形的交面积（px²）。无交返回 0。
func _overlap(a: Rect2, b: Rect2) -> float:
	var hit := a.intersection(b)
	if hit.size.x <= 0.0 or hit.size.y <= 0.0:
		return 0.0
	return hit.size.x * hit.size.y


func _canvas_to_window(pos: Vector2) -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return pos
	var canvas := vp.get_visible_rect().size
	var win := Vector2(vp.size)
	if canvas.x <= 0.0 or canvas.y <= 0.0:
		return pos
	return Vector2(pos.x * win.x / canvas.x, pos.y * win.y / canvas.y)


func _move(win_pos: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = win_pos
	m.global_position = win_pos
	get_viewport().push_input(m)


func _tap(win_pos: Vector2) -> void:
	var d := InputEventMouseButton.new()
	d.button_index = MOUSE_BUTTON_LEFT
	d.pressed = true
	d.position = win_pos
	d.global_position = win_pos
	get_viewport().push_input(d)
	var u := InputEventMouseButton.new()
	u.button_index = MOUSE_BUTTON_LEFT
	u.pressed = false
	u.position = win_pos
	u.global_position = win_pos
	get_viewport().push_input(u)


func _settle(frames: int = 2) -> void:
	for i in frames:
		await get_tree().process_frame
