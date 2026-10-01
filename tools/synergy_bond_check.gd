extends Node

# 第 12 点（10.01 反馈）：备战「种族」界面点种族卡片 → 弹该族羁绊**效果**说明。
#
# 用户要求：参考对局里的羁绊达成，**保留效果部分**，但**去掉**「已解锁 / 未解锁 /
# 还差几人 / 当前数量」——那是**战场达成条件**的说明；字体和颜色深浅要一致。
#
# 所以这里守两条线：
#   * 新函数 format_synergy_effects 只出「名字 + 效果」，一个状态词都不许有；
#   * 老函数 format_synergy_detail **必须保持原样**（tools/prep_text_coverage_check
#     断言它必须含「当前数量：%d/7」「未解锁」「还差 1 人」）。那是战场口径，
#     为了让新弹窗好看去改它，等于把战场那块的判据弄坏。

const H := preload("res://tools/CheckHarness.gd")
const PanelScript := preload("res://scenes/prep/panels/SynergyPanel.gd")
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")
const RacePick := preload("res://scripts/units/RacePick.gd")
const PetScreenScript := preload("res://scenes/menu/PetScreen.gd")
const CHECK_NAME := "synergy_bond"
const PET_SRC := "res://scenes/menu/PetScreen.gd"
const PET_SCENE := "res://scenes/menu/PetScreen.tscn"

const RACES := ["god", "dark", "undead", "human"]

# 用户点名要去掉的状态词（中英各一套）。
const BANNED := ["已解锁", "未解锁", "还差", "当前数量", "On board", "Locked", "Need "]

var h


func _ready() -> void:
	h = H.new(CHECK_NAME)
	_section_content()
	_section_regression()
	_section_wiring()
	_section_discrimination()
	await _section_dialog()
	await _section_real_click()
	h.finish(get_tree())


# ── A. 效果文本的内容 ───────────────────────────────────────────────────────

func _section_content() -> void:
	for race in RACES:
		var body: String = PanelScript.format_synergy_effects(race)
		h.expect(not body.is_empty(), "content_%s_nonempty" % race,
			"%s 族的效果文本不能为空" % race)
		for banned in BANNED:
			h.expect(not body.contains(banned), "content_%s_bans_%s" % [race, _slug(banned)],
				"%s 族效果里不该出现「%s」——那是战场达成条件" % [race, banned])
		# 纯文本：弹窗正文是 Label，不吃 BBCode（带了标记会原样显示出来）。
		h.expect(not body.contains("[b]") and not body.contains("[color=") and not body.contains("[/"),
			"content_%s_plain_text" % race,
			"%s 族效果是纯文本（弹窗正文 Label 不吃 BBCode）" % race)

		var entries: Array = PanelScript._race_entries(race)
		h.expect(entries.size() >= 1, "content_%s_has_entries" % race,
			"%s 族至少有一条羁绊效果" % race)
		var all_names := true
		var all_details := true
		for item in entries:
			if not body.contains(str(item.get("name", ""))):
				all_names = false
			if not body.contains(str(item.get("detail", ""))):
				all_details = false
		h.expect(all_names, "content_%s_all_names" % race,
			"%s 族每一条效果名都在文本里" % race)
		h.expect(all_details, "content_%s_all_details" % race,
			"%s 族每一条效果正文都在文本里" % race)


# ── B. 战场版不许被顺手改掉 ─────────────────────────────────────────────────

func _section_regression() -> void:
	var panel = PanelScript.new()
	var detail: String = panel.format_synergy_detail("god", 3)
	h.expect(detail.contains("当前数量") or detail.contains("On board"),
		"regression_detail_keeps_count",
		"format_synergy_detail 仍然保留数量行（战场口径）")
	h.expect(detail.contains("已解锁") or detail.contains("Active")
			or detail.contains("未解锁") or detail.contains("Locked"),
		"regression_detail_keeps_status",
		"format_synergy_detail 仍然保留已解锁/未解锁状态")
	h.expect(detail.contains("[b]"), "regression_detail_keeps_bbcode",
		"format_synergy_detail 的 BBCode 没被顺手改成纯文本")

	var effects: String = PanelScript.format_synergy_effects("god")
	h.expect(effects != detail, "regression_two_outputs_differ",
		"效果版与战场版必须是两份不同的文本（否则等于没去掉状态行）")
	h.expect(detail.length() > effects.length(), "regression_detail_is_longer",
		"战场版比效果版长（多出数量行与每条的解锁状态）")
	panel.free()


# ── C. 接线：点卡片 -> 弹窗 ─────────────────────────────────────────────────

func _section_wiring() -> void:
	var src := FileAccess.get_file_as_string(PET_SRC)
	if not h.expect(not src.is_empty(), "wiring_src_readable", "PetScreen.gd 可读"):
		return
	h.expect(src.contains('preload("res://scenes/prep/panels/SynergyPanel.gd")'),
		"wiring_preload_panel", "PetScreen 静态 preload 了 SynergyPanel")

	var pressed := func_body(src, "func _on_race_card_pressed(")
	h.expect(not pressed.is_empty(), "wiring_pressed_found", "_on_race_card_pressed 可定位")
	h.expect(pressed.contains("_show_race_bond(race)"), "wiring_click_shows_bond",
		"点种族卡片时会弹羁绊效果")
	# 原有的选/取消语义不许被动掉（另一个门禁 race_pick_check 依赖它）。
	h.expect(pressed.contains("_race_draft.erase(race)"), "wiring_keeps_deselect",
		"原有的取消选择语义还在")
	h.expect(pressed.contains("_refresh_races()"), "wiring_keeps_refresh",
		"原有的刷新还在")

	var show := func_body(src, "func _show_race_bond(")
	h.expect(not show.is_empty(), "wiring_show_found", "_show_race_bond 可定位")
	h.expect(show.contains("DialogService.info("), "wiring_uses_dialog_service",
		"弹窗走 DialogService.info")
	h.expect(show.contains("format_synergy_effects"), "wiring_uses_effects_text",
		"正文取自 format_synergy_effects")
	h.expect(not show.contains("format_synergy_detail"), "wiring_not_detail_text",
		"正文不许用战场版格式（那会带上已解锁/还差几人）")


# ── D. 判别力自检 ───────────────────────────────────────────────────────────

func _section_discrimination() -> void:
	# 文本必须随种族变，否则就是写死的一个常量。
	var a: String = PanelScript.format_synergy_effects("god")
	var b: String = PanelScript.format_synergy_effects("dark")
	h.expect(a != b, "disc_races_differ", "不同种族的效果文本必须不同")
	# 标题与种族名同源。
	h.expect(PanelScript.format_synergy_title("god").contains(PanelScript.race_name("god")),
		"disc_title_uses_race_name", "标题里含种族名")
	h.expect(PanelScript.format_synergy_title("dark") != PanelScript.format_synergy_title("god"),
		"disc_titles_differ", "不同种族的标题不同")
	# 未知种族给空串，不许崩也不许编内容出来。
	h.expect(PanelScript.format_synergy_effects("__nope__").is_empty(),
		"disc_unknown_race_empty", "未知种族返回空串")
	# 条目之间用空行分隔（弹窗里读起来才分块）。
	h.expect(a.contains("\n\n"), "disc_blocks_separated", "多条效果之间有空行分隔")


# ── E. 真的弹一次 ───────────────────────────────────────────────────────────

func _section_dialog() -> void:
	await get_tree().process_frame
	# owner 给一个**已入树**的节点（同 modal_lifecycle_check 的写法）：
	# ModalStack 会把 dialog 挂上去；否则 dialog 还没入树就被 grab_focus，
	# 场景退出时会吐一条 "Condition !is_inside_tree()" 的 ERROR 噪音。
	var owner_node := Node.new()
	owner_node.name = "BondOwner"
	add_child(owner_node)

	var body: String = PanelScript.format_synergy_effects("god")
	var before := DialogService.open_count()
	var rid := DialogService.info({
		"title": PanelScript.format_synergy_title("god"),
		"body": body,
		"owner": owner_node,
	})
	await get_tree().process_frame
	h.expect(DialogService.open_count() == before + 1, "dialog_opens",
		"羁绊效果能真的弹出来（走真实 DialogService -> ModalStack 通路）")
	if not rid.is_empty():
		DialogService.close(rid)
	await get_tree().process_frame
	h.expect(DialogService.open_count() == before, "dialog_closes",
		"弹窗能收掉，不留悬挂模态")
	owner_node.queue_free()
	await get_tree().process_frame


# ── F. 真机形状：真的开这一页、真的发鼠标事件 ──────────────────────────────
#
# ★★ 为什么非要有这一段：A~D 全是**源码文本**断言 —— 只证明「代码里写了」，
#    证明不了「点了会发生」。上一轮就栽在这儿：门禁 PASS 70/0，用户真机点种族什么都没弹。
#    真机的形状是**按钮被 disabled**（四族全出战 = 整页锁定）：禁用的 Button 根本不发
#    pressed，而 `pressed.emit()`（race_pick_check 的写法）会绕过这道检查照把回调调起来 ——
#    所以这一段的点击必须是**真实鼠标事件**，不许用 emit_signal / 直接调函数顶替。

func _section_real_click() -> void:
	var packed := load(PET_SCENE) as PackedScene
	if not h.expect(packed != null, "real_scene_loads", "PetScreen.tscn 能加载"):
		return
	var saved_starter: bool = PlayerProfile.needs_starter_pick
	# 首次三选一那关会把页签整排藏起来，这里要看的是正常的备战页。
	PlayerProfile.needs_starter_pick = false
	var screen: PetScreenScript = packed.instantiate() as PetScreenScript
	if not h.expect(screen != null, "real_scene_typed",
			"PetScreen 没能实例化成备战页脚本（多半是 PetScreen.gd 编译失败）"):
		PlayerProfile.needs_starter_pick = saved_starter
		return
	add_child(screen)
	await _settle()

	# 1) 切到「种族」页：也走真实点击（顺带证明页签本身没坏）。
	var tab_btn: Button = screen._tab_buttons.get(PetScreenScript.Tab.RACES)
	h.expect(tab_btn != null and tab_btn.text == tr("prep_tab_races"), "real_tab_button",
		"按 enum 取到的「种族」页签是「%s」，实际拿到「%s」" % [
			tr("prep_tab_races"), "" if tab_btn == null else tab_btn.text])
	if tab_btn != null:
		await _click(tab_btn)
	await _settle()
	h.expect(screen._race_box.visible, "real_race_tab_shown",
		"真点了「种族」页签，种族页没出来 —— 后面就没得点了")
	h.expect(not screen._pet_box.visible, "real_pet_tab_hidden",
		"切到种族页后宠物页还开着（两页叠在一起）")

	# 2) 逐个种族：卡片按钮要**看得见、按得动**，真点下去要弹出**这一族自己**的羁绊文本。
	var races := RacePick.all_races()
	h.expect(races.size() > 0, "real_races_nonempty", "种族表非空")
	var clickable := 0
	for race in races:
		var parts: Dictionary = screen._race_cards.get(race, {})
		var btn: Button = parts.get("button")
		if not h.expect(btn != null, "real_%s_button" % race, "%s 卡片上没有按钮" % race):
			continue
		if not h.expect(btn.visible, "real_%s_visible" % race, "%s 卡片的按钮不可见" % race):
			continue
		# ★ 这一条就是真机上死掉的那条：disabled 的按钮永远不发 pressed，
		#   而它在源码里完全看不出来（文本断言照样绿）。
		if not h.expect(not btn.disabled, "real_%s_clickable" % race,
				"%s 卡片的按钮被禁用了 —— 这种按钮真机上永远不会发 pressed，羁绊弹窗弹不出来" % race):
			continue
		clickable += 1
		await _click_one_race(race, btn)
	await _settle()
	screen.queue_free()
	await get_tree().process_frame
	PlayerProfile.needs_starter_pick = saved_starter
	print("[%s] 真机形状：%d/%d 个种族的卡片点得动" % [CHECK_NAME, clickable, races.size()])


func _click_one_race(race: String, btn: Button) -> void:
	var before := DialogService.open_count()
	await _click(btn)
	await _settle()
	var after := DialogService.open_count()
	if not h.expect(after == before + 1, "real_%s_click_opens" % race,
			"真点了 %s 的卡片，没有弹出框（点之前 %d 个，点之后 %d 个）" % [race, before, after]):
		_close_modals()
		return
	# 弹出来的必须是**这一族**的羁绊 —— 弹一个别族的框同样是坏的。
	var body := _dialog_body_text()
	var entries: Array = PanelScript._race_entries(race)
	var first_name := "" if entries.is_empty() else str((entries[0] as Dictionary).get("name", ""))
	h.expect(not first_name.is_empty() and body.contains(first_name),
		"real_%s_body_is_own_race" % race,
		"弹的不是 %s 自己的羁绊：框里找不到「%s」（正文前 40 字：%s）" % [
			race, first_name, body.substr(0, 40)])
	# 「去掉已解锁/未解锁/还差几人」也要在**真弹出来的那一份**上复核，不能只看函数返回值。
	for banned in BANNED:
		h.expect(not body.contains(banned), "real_%s_body_bans_%s" % [race, _slug(banned)],
			"真弹出来的 %s 正文里出现了「%s」—— 那是战场达成条件" % [race, banned])
	_close_modals()


# ── 真机形状的辅助 ──────────────────────────────────────────────────────────

func _settle() -> void:
	for _i in 5:
		await get_tree().process_frame


# 真实鼠标事件。**不要**换成 btn.pressed.emit()：
# emit_signal 绕过 BaseButton 对 disabled 的判断，会让上面那条判据变成假的。
func _click(ctrl: Control) -> void:
	var vp := get_viewport()
	var at := ctrl.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	vp.push_input(motion, true)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		vp.push_input(ev, true)
	await get_tree().process_frame


func _dialog_body_text() -> String:
	var label := get_tree().root.find_child("DialogBody", true, false) as Label
	return "" if label == null else label.text


func _close_modals() -> void:
	# DialogService 没有公开的「全关」；ModalStack 有，而它会回调 DialogService
	# 把 _pending 一起清掉。这里只是不给后面的用例留下悬挂模态。
	ModalStack.close_all()


# ── 辅助 ────────────────────────────────────────────────────────────────────

func func_body(src: String, header: String) -> String:
	var at := src.find(header)
	if at < 0:
		return ""
	var rest := src.substr(at)
	var nxt := rest.find("\nfunc ", 1)
	return rest if nxt < 0 else rest.substr(0, nxt)


func _slug(text: String) -> String:
	return text.strip_edges().to_lower().replace(" ", "_").replace("/", "_")
