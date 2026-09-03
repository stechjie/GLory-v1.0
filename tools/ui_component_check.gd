extends Node

# Glory UI 基础组件的门禁（V3 P0-07 / P1-01 / P1-02 / P1-03）。
#
# 这个检查存在的意义不是「组件写好了」，而是把复审里三个具体故障做成可回归的断言：
#   1. 关掉弹窗后树上留着看不见的 MOUSE_FILTER_STOP 控件 -> 之后点什么都没反应；
#   2. 连点确认按钮把不可逆操作执行两遍；
#   3. 按钮低于 48 dp、禁用态和普通态长得一样，玩家分不清能不能点。
# 每条都用真节点跑，不看源码里写没写。
#
# 另有一条是纯源码断言：业务目录里不允许再出现 AcceptDialog.new()。那是 V3 P1-03
# 的验收口径，只有它能防止「组件建好了但没人用」。

const CheckHarness := preload("res://tools/CheckHarness.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const SettingsScene := preload("res://scenes/menu/SettingsScreen.tscn")
const SettingsScreenScript := preload("res://scenes/menu/SettingsScreen.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Dialog := preload("res://ui/components/GloryConfirmDialog.gd")

const CHECK_NAME := "ui_component"

# 业务代码里禁止出现的弹窗写法。tools/ 和 ui/ 自身不算业务代码。
const BANNED_PATTERNS := [
	"AcceptDialog.new(",
	"ConfirmationDialog.new(",
]
const BUSINESS_DIRS := ["res://scenes", "res://scripts", "res://effects"]

var _h: CheckHarness
var _stop_baseline: Array = []


func _ready() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_tokens()
	_check_theme()
	_check_theme_state_coverage()
	_check_busy_state_is_distinct()
	await _check_minimum_touch_size()
	_check_reduced_motion_setting()
	await _check_settings_state_is_not_colour_only()
	_check_no_legacy_dialogs()
	await _check_modal_stack()
	await _check_dialog_contract()
	await _check_dialog_service()
	_h.finish(get_tree())


# --- 令牌 ---------------------------------------------------------------------

func _check_tokens() -> void:
	# 触控下限。复审时教程确认框的按钮是 140×40，40 < 48 是它点不准的直接原因。
	_h.expect(Tokens.TOUCH_MIN >= 48.0, "touch_min_too_small",
		"TOUCH_MIN=%.1f，手机触控目标不得小于 48" % Tokens.TOUCH_MIN)
	_h.expect(Tokens.BUTTON_HEIGHT >= Tokens.TOUCH_MIN, "button_below_touch_min",
		"BUTTON_HEIGHT=%.1f 小于 TOUCH_MIN=%.1f" % [Tokens.BUTTON_HEIGHT, Tokens.TOUCH_MIN])

	for pair in [["FONT_TITLE", Tokens.FONT_TITLE], ["FONT_BODY", Tokens.FONT_BODY],
			["FONT_BUTTON", Tokens.FONT_BUTTON], ["FONT_CAPTION", Tokens.FONT_CAPTION]]:
		_h.expect(int(pair[1]) >= Tokens.FONT_MIN_READABLE, "font_below_readable",
			"%s=%d 低于可读下限 %d" % [str(pair[0]), int(pair[1]), Tokens.FONT_MIN_READABLE])

	# V3 P1-02 明确要求 80–88%：低于 80 分不清模态，高于 88 背景全黑失去上下文。
	_h.expect(Tokens.BACKDROP.a >= 0.80 and Tokens.BACKDROP.a <= 0.88, "backdrop_alpha_out_of_range",
		"BACKDROP.a=%.2f，应在 0.80–0.88" % Tokens.BACKDROP.a)

	# 正文必须在卡片底色上读得清。4.5:1 是 WCAG AA 的正文门槛。
	var ratio := _contrast(Tokens.TEXT_PRIMARY, Tokens.SURFACE)
	_h.expect(ratio >= 4.5, "text_contrast_low",
		"TEXT_PRIMARY 对 SURFACE 对比度 %.2f:1，低于 4.5:1" % ratio)
	var gold_ratio := _contrast(Tokens.TEXT_ON_GOLD, Tokens.GOLD)
	_h.expect(gold_ratio >= 4.5, "gold_button_contrast_low",
		"金色按钮文字对比度 %.2f:1，低于 4.5:1" % gold_ratio)

	# 危险色必须和主操作色分得开，否则「确认」和「删档」看起来一样。
	var hue_gap: float = absf(Tokens.GOLD.h - Tokens.DANGER.h)
	_h.expect(minf(hue_gap, 1.0 - hue_gap) > 0.05, "danger_hue_too_close",
		"DANGER 与 GOLD 色相过近，玩家无法区分主操作与危险操作")


# --- 主题 ---------------------------------------------------------------------

func _check_theme() -> void:
	var theme := Theming.build()
	_h.expect(theme != null, "theme_build_failed", "GloryTheme.build() 返回空")
	if theme == null:
		return

	var types := ["Button", Theming.VARIATION_PRIMARY, Theming.VARIATION_DANGER,
		Theming.VARIATION_GHOST]
	for type_name in types:
		var boxes: Dictionary = {}
		for state in Theming.REQUIRED_BUTTON_STATES:
			var box := theme.get_stylebox(state, type_name)
			if not _h.expect(box != null, "stylebox_missing",
					"%s 缺少 %s 状态的 StyleBox" % [type_name, state]):
				continue
			boxes[state] = box

		# 六态可区分是 P1-04 的核心：normal / hover / pressed 三者若共用同一个
		# StyleBox，玩家按下去没有任何视觉变化 —— 这正是「点了没反应」的观感来源。
		_expect_distinct(type_name, boxes, "normal", "hover")
		_expect_distinct(type_name, boxes, "normal", "pressed")
		_expect_distinct(type_name, boxes, "normal", "disabled")

	# 其余控件类型至少要被主题覆盖到，否则页面迁过来会露出 Godot 默认外观。
	for spec in [["PanelContainer", "panel"], ["Panel", "panel"],
			["ProgressBar", "background"], ["ProgressBar", "fill"], ["LineEdit", "normal"]]:
		_h.expect(theme.get_stylebox(str(spec[1]), str(spec[0])) != null, "theme_type_uncovered",
			"主题未覆盖 %s/%s" % [str(spec[0]), str(spec[1])])


func _expect_distinct(type_name: String, boxes: Dictionary, a: String, b: String) -> void:
	if not (boxes.has(a) and boxes.has(b)):
		return
	var box_a := boxes[a] as StyleBoxFlat
	var box_b := boxes[b] as StyleBoxFlat
	if box_a == null or box_b == null:
		return
	var same_bg := box_a.bg_color.is_equal_approx(box_b.bg_color)
	var same_border := box_a.border_color.is_equal_approx(box_b.border_color)
	_h.expect(not (same_bg and same_border), "button_state_indistinct",
		"%s 的 %s 与 %s 状态底色和描边完全相同，玩家看不出差别" % [type_name, a, b])


# --- ModalStack ----------------------------------------------------------------

func _check_modal_stack() -> void:
	_stop_baseline = ModalStack.find_invisible_stop_controls()
	_h.expect(ModalStack.depth() == 0, "modal_stack_dirty_start",
		"检查开始时模态栈不为空：depth=%d" % ModalStack.depth())

	# 嵌套 3 层，只有栈顶吃输入。
	var ids: Array[String] = []
	for i in 3:
		var content := _dummy_content("Layer%d" % i)
		var id := ModalStack.push(content, {"id": "check_modal_%d" % i, "owner": self})
		_h.expect(not id.is_empty(), "modal_push_failed", "第 %d 层 push 失败" % i)
		ids.append(id)
	await get_tree().process_frame

	_h.expect(ModalStack.depth() == 3, "modal_depth_wrong",
		"push 三层后 depth=%d" % ModalStack.depth())
	var stop_count := 0
	for entry in ModalStack.dump_modal_stack():
		# 「拿到了 id 但弹窗根本没显示」是最难查的一类：调用方以为成功了。
		# 所以在树上这件事必须单独断言，不能只看 depth。
		_h.expect(bool(entry.get("in_tree", false)), "modal_not_in_tree",
			"模态 %s 在栈上但不在场景树里，玩家看不到它" % str(entry.get("id", "")))
		if str(entry.get("backdrop_filter", "")) == "STOP":
			stop_count += 1
			_h.expect(bool(entry.get("is_top", false)), "non_top_backdrop_stops",
				"非栈顶模态 %s 的 backdrop 仍是 STOP" % str(entry.get("id", "")))
	_h.expect(stop_count == 1, "stop_backdrop_count_wrong",
		"应恰好有 1 个 STOP backdrop，实际 %d" % stop_count)

	# 同 id 重复 push 必须被拒 —— 这是「连点开出两个框」的根因防线。
	var dup := ModalStack.push(_dummy_content("Dup"), {"id": "check_modal_0", "owner": self})
	_h.expect(dup.is_empty(), "duplicate_modal_id_accepted", "同 id 重复 push 未被拒绝")

	# 层号必须严格递增，否则后开的框可能被压在先开的下面。
	var last_layer := -1
	var ok_layers := true
	for entry in ModalStack.dump_modal_stack():
		var idx := int(entry.get("index", 0))
		if idx <= last_layer:
			ok_layers = false
		last_layer = idx
	_h.expect(ok_layers, "modal_layer_not_monotonic", "模态层号未严格递增")

	# close_top 只关一层。
	ModalStack.close_top("check")
	await get_tree().process_frame
	_h.expect(ModalStack.depth() == 2, "close_top_wrong_depth",
		"close_top 后 depth=%d，应为 2" % ModalStack.depth())

	# owner 收口：一次清空该 owner 的全部模态。
	var closed := ModalStack.close_all_for_owner(self, "check")
	await get_tree().process_frame
	_h.expect(closed == 2, "close_all_for_owner_wrong_count",
		"close_all_for_owner 关了 %d 个，应为 2" % closed)
	_h.expect(ModalStack.depth() == 0, "modal_stack_not_empty",
		"owner 清空后 depth=%d" % ModalStack.depth())

	await get_tree().process_frame
	_assert_no_leaked_stop("modal_stack")


# 泄漏是这套东西要防的头号故障，所以每个阶段结束都查一次。
func _assert_no_leaked_stop(stage: String) -> void:
	var leaked := ModalStack.find_invisible_stop_controls()
	var added: Array = []
	for path in leaked:
		if not _stop_baseline.has(path):
			added.append(path)
	_h.expect(added.is_empty(), "invisible_stop_leaked",
		"%s 阶段后树上多了 %d 个不可见的 STOP 控件（会吃掉后续点击）：%s" % [
			stage, added.size(), ", ".join(added.slice(0, 5))])


# --- 确认框合同 ----------------------------------------------------------------

func _check_dialog_contract() -> void:
	var results: Array = []
	var dialog: Control = load("res://ui/components/GloryConfirmDialog.tscn").instantiate()
	dialog.resolved.connect(func(result: String, rid: String) -> void:
		results.append({"result": result, "rid": rid}))
	var modal_id := ModalStack.push(dialog, {"id": "check_dialog", "owner": self})
	# 用长正文：既能验「没塌成 0 高」，也能验「超长时被压到上限而不是撑爆卡片」。
	dialog.configure({
		"title": "标题",
		"body": ("与服务器的连接在等待队友阶段中断了。可以重试一次；如果仍然失败，"
			+ "请检查网络后返回备战页重新开始。本局阵容已经保存，不会丢失。"
			+ "错误码 NET_TIMEOUT_60S，反馈时请一并提供。").repeat(4),
		"intent": Dialog.Intent.DANGER,
		"request_id": "req_1",
	})
	# _fit_body_scroll 是 deferred 的，之后还要一帧让容器布局生效。
	for _f in 3:
		await get_tree().process_frame

	var confirm_btn := dialog.find_child("ConfirmButton", true, false) as Button
	var cancel_btn := dialog.find_child("CancelButton", true, false) as Button
	_h.expect(confirm_btn != null, "dialog_missing_confirm", "确认框没有 ConfirmButton")
	_h.expect(cancel_btn != null, "dialog_missing_cancel", "DANGER 意图应有取消按钮")

	# 按钮组必须居中。这是产品明确要的排布，而 V3 文档只写了「主操作在右」
	# （指组内顺序），照字面读很容易被改成整组靠右，所以这里用几何位置锁死。
	var row := dialog.find_child("DialogButtons", true, false) as HBoxContainer
	var card := dialog.find_child("DialogCard", true, false) as Control
	_h.expect(row != null, "dialog_missing_button_row", "确认框没有 DialogButtons")
	if row != null:
		_h.expect(row.alignment == BoxContainer.ALIGNMENT_CENTER, "buttons_not_centered",
			"按钮组 alignment=%d，应为居中" % row.alignment)
	# 量按钮自身的包围范围，不是量 HBoxContainer：容器无论怎么对齐都占满整宽，
	# 量它等于永远居中，这条断言就白写了。
	if row != null and card != null and confirm_btn != null:
		var left := confirm_btn.global_position.x
		var right := confirm_btn.global_position.x + confirm_btn.size.x
		if cancel_btn != null:
			left = minf(left, cancel_btn.global_position.x)
			right = maxf(right, cancel_btn.global_position.x + cancel_btn.size.x)
		var group_center := (left + right) * 0.5
		var card_center := card.global_position.x + card.size.x * 0.5
		_h.expect(absf(group_center - card_center) <= 2.0, "buttons_off_center",
			"按钮组中心 %.1f 与卡片中心 %.1f 相差 %.1f px" % [
				group_center, card_center, absf(group_center - card_center)])
		# 组内顺序不变：取消在左，主操作在右。
		if cancel_btn != null and confirm_btn != null:
			_h.expect(cancel_btn.global_position.x < confirm_btn.global_position.x,
				"confirm_not_on_right", "主操作按钮不在取消按钮右侧")

	# 正文必须真的占到高度。第一版把正文塞进 ScrollContainer 却没给它最小高度，
	# 结果容器塌成 0 高、整段正文不可见 —— 而当时所有断言都是绿的。
	# 所以「文字在不在屏幕上」得自己是一条断言，不能靠肉眼看图发现。
	var body := dialog.find_child("DialogBody", true, false) as Label
	var body_scroll := dialog.find_child("DialogBodyScroll", true, false) as Control
	_h.expect(body != null, "dialog_missing_body", "确认框没有 DialogBody")
	if body != null and body_scroll != null:
		_h.expect(not body.text.is_empty(), "dialog_body_empty", "正文文本为空")
		_h.expect(body_scroll.size.y > 0.0, "dialog_body_collapsed",
			"正文区高度为 %.1f，正文不可见" % body_scroll.size.y)
		_h.expect(body.is_visible_in_tree(), "dialog_body_hidden", "正文 Label 不可见")
		# 长文只能滚，不能把卡片撑到超出上限、把按钮顶出屏幕。
		_h.expect(body_scroll.size.y <= Tokens.DIALOG_MAX_BODY_HEIGHT + 1.0,
			"dialog_body_overflow", "正文区高 %.1f 超过上限 %.1f" % [
				body_scroll.size.y, Tokens.DIALOG_MAX_BODY_HEIGHT])

	if confirm_btn != null:
		_h.expect(confirm_btn.custom_minimum_size.y >= Tokens.TOUCH_MIN, "dialog_button_too_short",
			"确认按钮高 %.1f，低于触控下限 %.1f" % [
				confirm_btn.custom_minimum_size.y, Tokens.TOUCH_MIN])
		_h.expect(confirm_btn.theme_type_variation == Theming.VARIATION_DANGER,
			"danger_button_not_red", "DANGER 意图的主按钮没有用危险变体")

		# 连点 10 次只应结算一次。这条直接对应「危险动作不能因连点触发两次」。
		for _i in 10:
			confirm_btn.emit_signal("pressed")
		_h.expect(results.size() == 1, "dialog_resolved_more_than_once",
			"连点 10 次确认，resolved 发了 %d 次" % results.size())
		if results.size() > 0:
			_h.expect(str(results[0].get("result", "")) == Dialog.RESULT_CONFIRMED,
				"dialog_wrong_result", "结果应为 confirmed，实际 %s" % str(results[0].get("result", "")))
			_h.expect(str(results[0].get("rid", "")) == "req_1", "dialog_request_id_lost",
				"request_id 未原样带回")

	ModalStack.pop(modal_id, "check")
	await get_tree().process_frame

	# INFO 意图只有一个按钮：主菜单「敬请期待」这类提示不该出现「取消」。
	var info_dialog: Control = load("res://ui/components/GloryConfirmDialog.tscn").instantiate()
	var info_modal := ModalStack.push(info_dialog, {"id": "check_dialog_info", "owner": self})
	info_dialog.configure({"body": "这个功能还在开发中。", "intent": Dialog.Intent.INFO,
		"request_id": "req_2"})
	for _f in 3:
		await get_tree().process_frame
	_h.expect(info_dialog.find_child("CancelButton", true, false) == null,
		"info_dialog_has_cancel", "INFO 意图不应有取消按钮")
	# 短正文也要有高度，且不该被撑到上限 —— 卡片应该贴着内容走。
	var info_scroll := info_dialog.find_child("DialogBodyScroll", true, false) as Control
	if info_scroll != null:
		_h.expect(info_scroll.size.y > 0.0, "info_body_collapsed",
			"INFO 正文区高度为 %.1f" % info_scroll.size.y)
		_h.expect(info_scroll.size.y < Tokens.DIALOG_MAX_BODY_HEIGHT, "info_body_padded",
			"短正文却占满了上限高度 %.1f，卡片没有贴合内容" % info_scroll.size.y)
	ModalStack.pop(info_modal, "check")
	await get_tree().process_frame
	_assert_no_leaked_stop("dialog_contract")


# --- DialogService --------------------------------------------------------------

func _check_dialog_service() -> void:
	var calls: Array = []
	var on_result := func(result: String, rid: String) -> void:
		calls.append({"result": result, "rid": rid})

	var rid := DialogService.confirm({
		"request_id": "svc_1", "owner": self, "body": "确定？", "on_result": on_result})
	await get_tree().process_frame
	_h.expect(rid == "svc_1", "service_request_id_wrong", "confirm 返回的 request_id 不对：%s" % rid)
	_h.expect(DialogService.open_count() == 1, "service_open_count_wrong",
		"open_count=%d，应为 1" % DialogService.open_count())

	# 同 request_id 再请求一次不应开出第二个框。
	DialogService.confirm({
		"request_id": "svc_1", "owner": self, "body": "确定？", "on_result": on_result})
	await get_tree().process_frame
	_h.expect(DialogService.open_count() == 1, "service_duplicate_opened",
		"重复 request_id 开出了第二个框：open_count=%d" % DialogService.open_count())
	_h.expect(ModalStack.depth() == 1, "service_duplicate_modal",
		"重复 request_id 在模态栈上留下多层：depth=%d" % ModalStack.depth())

	DialogService.close("svc_1")
	await get_tree().process_frame
	_h.expect(calls.size() == 1, "service_callback_count_wrong",
		"on_result 被调用 %d 次，应为 1" % calls.size())
	if calls.size() == 1:
		_h.expect(str(calls[0].get("result", "")) == Dialog.RESULT_DISMISSED,
			"service_close_result_wrong", "主动关闭应返回 dismissed，实际 %s"
				% str(calls[0].get("result", "")))
		_h.expect(str(calls[0].get("rid", "")) == "svc_1",
			"service_close_request_id_lost", "主动关闭回调丢失 request_id")
	_h.expect(DialogService.open_count() == 0, "service_not_cleared",
		"关闭后 open_count=%d" % DialogService.open_count())
	_h.expect(ModalStack.depth() == 0, "service_modal_left",
		"关闭后模态栈仍有 %d 层" % ModalStack.depth())
	await get_tree().process_frame
	_assert_no_leaked_stop("dialog_service")


# --- 迁移验收（V3 P1-03）---------------------------------------------------------

func _check_no_legacy_dialogs() -> void:
	var offenders: Array[String] = []
	for dir_path in BUSINESS_DIRS:
		_scan_gd(dir_path, offenders)
	_h.item(1)
	if not offenders.is_empty():
		_h.fail("legacy_dialog_call_site",
			"业务代码仍在直接 new 系统弹窗（应改走 DialogService）：%s" % ", ".join(offenders))


func _scan_gd(dir_path: String, offenders: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := "%s/%s" % [dir_path, name]
		if dir.current_is_dir():
			# 审计备份目录留在仓库里做证据，不参与门禁。
			if not name.begins_with(".") and not name.contains("_prechange_backup_"):
				_scan_gd(full, offenders)
		elif name.ends_with(".gd"):
			var text := FileAccess.get_file_as_string(full)
			for pattern in BANNED_PATTERNS:
				if text.contains(pattern):
					offenders.append("%s (%s)" % [full, pattern])
		name = dir.get_next()
	dir.list_dir_end()


# --- 工具 ---------------------------------------------------------------------

func _dummy_content(node_name: String) -> Control:
	var c := Control.new()
	c.name = node_name
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _contrast(fg: Color, bg: Color) -> float:
	var l1 := _relative_luminance(fg)
	var l2 := _relative_luminance(bg)
	var hi := maxf(l1, l2)
	var lo := minf(l1, l2)
	return (hi + 0.05) / (lo + 0.05)


func _relative_luminance(c: Color) -> float:
	return 0.2126 * _linearize(c.r) + 0.7152 * _linearize(c.g) + 0.0722 * _linearize(c.b)


func _linearize(channel: float) -> float:
	if channel <= 0.03928:
		return channel / 12.92
	return pow((channel + 0.055) / 1.055, 2.4)


# V3 P1-01：主题覆盖表逐条核对。
#
# 漏一个状态就会在那个状态下露出 Godot 默认外观 —— 深色界面里突然冒出一块浅灰，
# 而且只在 hover / 只读 / 禁用这些不常走的分支上出现，人工点不到。
# 表写在 GloryTheme 里（生产侧），这里只负责核对，避免门禁自带一份会漂移的副本。
func _check_theme_state_coverage() -> void:
	var theme := Theming.build()
	if theme == null:
		return
	var missing: Array[String] = []
	var total := 0
	for type_name in Theming.REQUIRED_STYLEBOX_COVERAGE.keys():
		for state in Theming.REQUIRED_STYLEBOX_COVERAGE[type_name] as Array:
			total += 1
			# has_stylebox 而不是 get_stylebox()!=null：后者在缺失时会回落到默认，
			# 断言就永远通不了红。
			if not theme.has_stylebox(str(state), str(type_name)):
				missing.append("%s/%s" % [type_name, state])
	_h.expect(total >= 30, "coverage_table_too_small",
		"覆盖表只有 %d 条，可能被删空了 —— 空表上「没有缺失」恒真" % total)
	_h.expect(missing.is_empty(), "theme_state_uncovered",
		"主题没有覆盖这些 (类型/状态)，该状态下会露出 Godot 默认外观：%s" % str(missing))


# V3 P1-01：忙碌态必须与禁用态可分辨。
#
# 禁用说的是「现在不能点」，忙碌说的是「你点到了，正在做」。两者共用一套外观时，
# 玩家分不出「我按空了」和「它在跑」—— 那正是连点的成因。
func _check_busy_state_is_distinct() -> void:
	var theme := Theming.build()
	if theme == null:
		return
	for state in Theming.REQUIRED_BUTTON_STATES:
		_h.expect(theme.has_stylebox(str(state), Theming.VARIATION_BUSY),
			"busy_state_missing", "忙碌变体缺少 %s 状态" % state)
	var busy := theme.get_stylebox("normal", Theming.VARIATION_BUSY) as StyleBoxFlat
	var disabled := theme.get_stylebox("disabled", "Button") as StyleBoxFlat
	var normal := theme.get_stylebox("normal", "Button") as StyleBoxFlat
	if busy == null or disabled == null or normal == null:
		return
	_h.expect(not (busy.bg_color.is_equal_approx(disabled.bg_color)
			and busy.border_color.is_equal_approx(disabled.border_color)),
		"busy_looks_disabled",
		"忙碌态与禁用态外观完全相同 —— 玩家分不出「按空了」和「在跑」")
	_h.expect(not (busy.bg_color.is_equal_approx(normal.bg_color)
			and busy.border_color.is_equal_approx(normal.border_color)),
		"busy_looks_idle", "忙碌态与常态外观完全相同 —— 按下去没有任何变化")


# V3 P1-02：移动端最小触控尺寸。
#
# 量的是**主题作用之后**控件的最小尺寸，不是 token 常量本身：TOUCH_MIN 写成 48
# 而按钮实际只有 42 高，是这条要求最常见的失败方式 —— 常量看着对，手指点不中。
func _check_minimum_touch_size() -> void:
	var theme := Theming.build()
	if theme == null:
		return
	var probes := {
		"Button": Button.new(),
		Theming.VARIATION_PRIMARY: Button.new(),
		Theming.VARIATION_DANGER: Button.new(),
		Theming.VARIATION_GHOST: Button.new(),
		Theming.VARIATION_BUSY: Button.new(),
		"CheckButton": CheckButton.new(),
		"LineEdit": LineEdit.new(),
	}
	var host := Control.new()
	host.theme = theme
	add_child(host)
	var undersized: Array[String] = []
	for type_name in probes.keys():
		var control: Control = probes[type_name]
		if control is Button:
			(control as Button).text = "确认"
			if type_name != "Button" and type_name != "CheckButton":
				control.theme_type_variation = str(type_name)
		elif control is LineEdit:
			(control as LineEdit).text = "0000"
		host.add_child(control)
	await get_tree().process_frame
	for type_name in probes.keys():
		var control: Control = probes[type_name]
		var min_size := control.get_combined_minimum_size()
		if min_size.y < Tokens.TOUCH_MIN:
			undersized.append("%s 高 %.1f < %.1f" % [type_name, min_size.y, Tokens.TOUCH_MIN])
	_h.expect(undersized.is_empty(), "control_below_touch_minimum",
		"这些控件在主题作用后仍低于最小触控高度，手指点不中：%s" % str(undersized))
	host.queue_free()
	await get_tree().process_frame


# V3 P1-09：降低动态效果要能在**设置页**里开关，且状态不能只靠颜色。
func _check_reduced_motion_setting() -> void:
	# 两处常量必须字面一致。PlayerProfile 不 preload GloryTokens（autoload 反过来
	# 依赖 UI 层会把依赖方向倒过来），所以那一处是抄的 —— 抄的东西要有人核对。
	_h.expect(PlayerProfile.REDUCED_MOTION_SETTING == Tokens.REDUCED_MOTION_SETTING,
		"reduced_motion_setting_key_drifted",
		"PlayerProfile 与 GloryTokens 的 reduced motion 设置名不一致：%s vs %s"
			% [PlayerProfile.REDUCED_MOTION_SETTING, Tokens.REDUCED_MOTION_SETTING])

	var before: bool = PlayerProfile.get_presentation_toggle("reduced_motion")
	var setting_before = ProjectSettings.get_setting(Tokens.REDUCED_MOTION_SETTING, false)

	PlayerProfile.set_presentation_toggle("reduced_motion", true)
	_h.expect(PlayerProfile.get_presentation_toggle("reduced_motion"),
		"reduced_motion_not_persisted", "打开降低动态效果之后 profile 没记住")
	# 玩家在设置页打开之后，读侧必须**立刻**看到 —— 不能等下次启动。
	_h.expect(bool(ProjectSettings.get_setting(Tokens.REDUCED_MOTION_SETTING, false)),
		"reduced_motion_not_applied",
		"设置页开了但 ProjectSettings 没跟上 —— 动画还会照跑")
	_h.expect(Tokens.reduced_motion(), "reduced_motion_reader_disagrees",
		"GloryTokens.reduced_motion() 读不到玩家的选择")
	_h.expect(is_equal_approx(Tokens.motion(0.5), 0.0), "reduced_motion_does_not_zero_durations",
		"降低动态效果打开时 Tokens.motion() 没有归零")

	PlayerProfile.set_presentation_toggle("reduced_motion", false)
	_h.expect(not Tokens.reduced_motion(), "reduced_motion_stuck_on",
		"关掉降低动态效果之后读侧仍然认为是开的")

	# 还原测试前的状态。这条门禁写的是真实 profile。
	PlayerProfile.set_presentation_toggle("reduced_motion", before)
	ProjectSettings.set_setting(Tokens.REDUCED_MOTION_SETTING, setting_before)
	_h.expect(PlayerProfile.get_presentation_toggle("reduced_motion") == before,
		"reduced_motion_not_restored", "测试结束后没有还原玩家原来的设置")


# V3 P1-09：设置页的「当前选中」不能只靠颜色。
#
# 色觉障碍、强光下的手机屏幕、以及任何截图转灰度的场合，只有 modulate 的界面都
# 读不出自己选的是哪一项 —— 而语言和画质恰好都是「选错了要重新找回来」的设置。
func _check_settings_state_is_not_colour_only() -> void:
	var screen := SettingsScene.instantiate()
	add_child(screen)
	await get_tree().process_frame

	var zh_before := str(screen._btn_zh.text)
	var en_before := str(screen._btn_en.text)
	_h.expect(zh_before != "中文" or en_before != "English",
		"language_selection_is_colour_only",
		"语言按钮的文本没有任何选中标记，只有 modulate —— 灰度下读不出选的是哪个")
	var marked_before := zh_before.contains(SettingsScreenScript.SELECTED_MARK)

	LocaleManager.set_locale("en" if LocaleManager.get_locale() == "zh" else "zh")
	screen._refresh_lang_buttons()
	await get_tree().process_frame
	_h.expect(zh_before.contains(SettingsScreenScript.SELECTED_MARK)
			!= str(screen._btn_zh.text).contains(SettingsScreenScript.SELECTED_MARK),
		"language_mark_does_not_follow_selection",
		"切换语言之后中文按钮的选中标记没有跟着变")
	# 标记只能有一份，反复刷新不能越拼越长。
	#
	# 查的是**画质**按钮而不是语言按钮：语言那两个每次传的是字面量（"中文"），
	# 重刷多少次都不会累加；画质按钮传的是 btn.text —— 读自己再拼一次，
	# 那才是真正会越拼越长的地方。断言要指着能坏的那一处。
	for _i in 5:
		screen._refresh_quality_buttons()
	var worst := 0
	for btn_any in screen._quality_btns:
		var q_btn: Button = btn_any
		worst = maxi(worst, str(q_btn.text).count(SettingsScreenScript.SELECTED_MARK))
	_h.expect(worst <= 1, "selection_mark_accumulates",
		"反复刷新之后画质按钮的选中标记被重复拼接了 %d 次" % worst)

	# 开关同理：CheckButton 的滑块在低对比度屏上不明显，要有开/关文字。
	var guides: CheckButton = screen._board_guides_btn
	var text_on := ""
	var text_off := ""
	PlayerProfile.set_board_readability_enabled(true)
	screen._refresh_board_guides_button()
	text_on = str(guides.text)
	PlayerProfile.set_board_readability_enabled(false)
	screen._refresh_board_guides_button()
	text_off = str(guides.text)
	_h.expect(text_on != text_off, "toggle_state_is_colour_only",
		"开关的文本在开与关时完全相同 —— 状态只靠颜色和滑块")
	PlayerProfile.set_board_readability_enabled(true)

	if marked_before:
		LocaleManager.set_locale("zh")
	screen.queue_free()
	await get_tree().process_frame
