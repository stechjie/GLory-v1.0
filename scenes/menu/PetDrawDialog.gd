extends Control

# Forest summon view. The altar animation never determines a reward.
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Currency := preload("res://scripts/account/Currency.gd")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const PetDrawReveal := preload("res://scenes/menu/PetDrawReveal.gd")
const PetSummonFx := preload("res://scenes/menu/PetSummonFx.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const FOREST := preload("res://assets/ui/pets/pet_summon_altar_bg.png")

signal draw_finished

var _energy := -1
var _available: Array = []
var _owned: Array = []
var _diamond := -1
var _busy := false
var _loading := false
var _pending_draw_id := ""
var _canvas: Control
var _fx: Control
var _summon: Button
var _retry: Button
var _balance: Label
var _notice: Label
var _energy_label: Label
var _rules: PanelContainer
var _portraits: Dictionary = {}
var _reveal: Control


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_fit_canvas()
	_load_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _canvas != null:
		_fit_canvas()


func _fit_canvas() -> void:
	var factor := minf(size.x / 1600.0, size.y / 720.0)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = (size - Vector2(1600, 720) * factor) * 0.5


func _build() -> void:
	var forest := TextureRect.new()
	forest.texture = FOREST
	forest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	forest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	forest.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	forest.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(forest)
	_canvas = Control.new()
	_canvas.size = Vector2(1600, 720)
	_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_canvas)
	_fx = PetSummonFx.new()
	_rect(_fx, 0, 0, 1600, 720)
	_canvas.add_child(_fx)
	var title := _label(_t("森林伙伴召唤", "Forest companion summon"), 31)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(title, 610, 10, 380, 48)
	_canvas.add_child(title)
	var balance_row := HBoxContainer.new()
	balance_row.alignment = BoxContainer.ALIGNMENT_END
	balance_row.add_theme_constant_override("separation", 7)
	_rect(balance_row, 1265, 21, 250, 36)
	_canvas.add_child(balance_row)
	var diamond_icon := TextureRect.new()
	diamond_icon.texture = Currency.icon("diamond")
	diamond_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	diamond_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	diamond_icon.custom_minimum_size = Vector2(32, 32)
	diamond_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	balance_row.add_child(diamond_icon)
	_balance = _label("", 20)
	_balance.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	balance_row.add_child(_balance)
	var close := _button("✕", Vector2(52, 52))
	_rect(close, 1530, 15, 52, 52)
	close.pressed.connect(_close)
	_canvas.add_child(close)
	_summon = _button(_t("召唤 · 75 钻石", "Summon · 75 gems"), Vector2(300, 72))
	_summon.add_theme_font_size_override("font_size", 27)
	_rect(_summon, 650, 85, 300, 72)
	_summon.pressed.connect(_begin_draw)
	_canvas.add_child(_summon)
	var pets_heading := _label(_t("召唤伙伴 · 点击查看技能", "Companions · tap for skills"), 18)
	_rect(pets_heading, 80, 169, 355, 34)
	_canvas.add_child(pets_heading)
	_pet_card("pet_squirrel", 80, 210)
	_pet_card("pet_tiger", 80, 391)
	var energy_title := _label(_t("森林能量", "Forest energy"), 24)
	energy_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(energy_title, 1250, 180, 260, 40)
	_canvas.add_child(energy_title)
	_energy_label = _label("", 18)
	_energy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(_energy_label, 1220, 558, 320, 40)
	_canvas.add_child(_energy_label)
	_rules = PanelContainer.new()
	_rules.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SUMMON_GLASS, Tokens.GOLD_EDGE, 12))
	_rect(_rules, 475, 573, 650, 119)
	_canvas.add_child(_rules)
	var rule_text := _label(_t(
		"规则  ·  每抽消耗 75 钻石，普通抽中宠物概率 10%，第 10 抽必得未拥有宠物。\n未中宠物获得 100 金币；提前抽中继续积累能量，保底命中才清零。",
		"Rules · 75 gems per draw. 10% pet chance; draw 10 guarantees an unowned pet.\nNo pet: 100 coins. Early pets keep energy; only the guarantee resets it."), 17)
	rule_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rule_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rule_text.add_theme_color_override("font_color", Tokens.SUMMON_DETAIL_INK)
	rule_text.add_theme_constant_override("outline_size", 0)
	_rules.add_child(rule_text)
	_notice = _label(_t("正在读取奖池…", "Loading summon pool…"), 17)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(_notice, 540, 511, 520, 43)
	_canvas.add_child(_notice)
	_retry = _button(_t("重试读取", "Retry loading"), Vector2(170, 50))
	_rect(_retry, 715, 462, 170, 50)
	_retry.pressed.connect(_load_state)
	_canvas.add_child(_retry)
	_refresh_ui()


func _pet_card(pet_id: String, x: float, y: float) -> void:
	var card := _button("", Vector2(260, 170))
	card.name = "Card_%s" % pet_id
	_rect(card, x, y, 260, 170)
	card.tooltip_text = _t("点击查看宠物介绍", "Tap for pet details")
	card.pressed.connect(_show_pet_info.bind(pet_id))
	_canvas.add_child(card)
	var art := PetPreview.build_illustration(pet_id, Vector2(210, 125))
	_rect(art, 25, 2, 210, 125)
	card.add_child(art)
	var name := _label(_t("松鼠", "Squirrel") if pet_id == "pet_squirrel" else
		_t("老虎", "Tiger"), 22)
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(name, 0, 128, 260, 35)
	card.add_child(name)
	var owned := _label(_t("已拥有", "Owned"), 19)
	owned.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(owned, 0, 64, 260, 35)
	card.add_child(owned)
	_portraits[pet_id] = {"art": art, "owned": owned, "button": card}


func _load_state() -> void:
	if _loading:
		return
	_loading = true
	_refresh_ui()
	var pool: Dictionary = await AccountManager.fetch_pet_draw_state()
	if not is_inside_tree():
		return
	if int(pool.get("code", 0)) / 100 != 2:
		_loading = false
		_notice.text = _t("奖池暂不可用：%s" % str(pool.get("error", "HTTP 500")),
			"Pool unavailable: %s" % str(pool.get("error", "HTTP 500")))
		_refresh_ui()
		return
	var wallet: Dictionary = await AccountManager.fetch_wallet()
	if not is_inside_tree():
		return
	var body: Dictionary = pool.get("body", {})
	_available = body.get("available", [])
	_owned = body.get("owned", [])
	_energy = int(body.get("energy", body.get("misses", 0)))
	if int(wallet.get("code", 0)) / 100 != 2:
		_loading = false
		_diamond = -1
		_notice.text = _t("余额读取失败，请重试", "Could not load balance; please retry")
		_refresh_ui()
		return
	_diamond = int((wallet.get("body", {}) as Dictionary).get("diamond", -1))
	_loading = false
	_notice.text = _t("点击召唤，唤醒森林祭坛", "Tap summon to awaken the forest altar")
	_refresh_ui()


func _refresh_ui() -> void:
	if _summon == null:
		return
	_summon.visible = _reveal == null
	_rules.visible = _reveal == null
	_notice.visible = _reveal == null
	_fx.visible = _reveal == null
	_retry.visible = _energy < 0 or _diamond < 0
	_retry.disabled = _loading
	_summon.disabled = _busy or _loading or _reveal != null or _energy < 0 or _diamond < 75 or _available.is_empty()
	if _available.is_empty() and _energy >= 0:
		_summon.text = _t("宠物已收集完毕", "All pets collected")
	elif _diamond >= 0 and _diamond < 75:
		_summon.text = _t("钻石不足", "Not enough gems")
	else:
		_summon.text = _t("召唤 · 75 钻石", "Summon · 75 gems")
	_balance.text = Currency.comma(_diamond) if _diamond >= 0 else ""
	_energy_label.text = _t("能量  %d / 10" % _energy,
		"Energy  %d / 10" % _energy) if _energy >= 0 else _t("能量  — / 10", "Energy  — / 10")
	_fx.call("set_energy", maxi(0, _energy))
	for pet_id in _portraits:
		var portrait: Dictionary = _portraits[pet_id]
		var owned := _owned.has(pet_id)
		(portrait.art as Control).modulate = Color(0.38, 0.38, 0.38) if owned else Color.WHITE
		(portrait.owned as Label).visible = owned
		(portrait.button as Button).add_theme_stylebox_override("normal", Tokens.panel_box(
			Tokens.SUMMON_GLASS, Tokens.MIST_GHOST_EDGE if owned else Tokens.GOLD_EDGE, 4))
	if _available.is_empty() and _energy >= 0:
		_notice.text = _t("当前宠物已集齐，能量保留给后续新宠物", "All current pets owned; energy is saved")


func _begin_draw() -> void:
	if _busy or _reveal != null or _available.is_empty() or _diamond < 75:
		return
	_commit_draw()


func _commit_draw() -> void:
	if _busy:
		return
	_busy = true
	_refresh_ui()
	_fx.call("start_summon")
	_notice.text = _t("能量聚合中…", "Gathering energy…")
	if _pending_draw_id.is_empty():
		_pending_draw_id = AccountManager.new_client_order_id()
	var started := Time.get_ticks_msec()
	var result: Dictionary = await AccountManager.draw_pet(_pending_draw_id)
	if not is_inside_tree():
		return
	var remaining := Tokens.motion(0.82) - float(Time.get_ticks_msec() - started) / 1000.0
	if remaining > 0.0:
		await get_tree().create_timer(remaining).timeout
	if not is_inside_tree():
		return
	_busy = false
	var code := int(result.get("code", 0))
	if code / 100 != 2:
		var can_retry := code == 0 or code >= 500
		if not can_retry:
			_pending_draw_id = ""
		_notice.text = str(result.get("error", _t("召唤失败", "Summon failed")))
		_open_reveal()
		_reveal.call("show_error", _notice.text, can_retry)
		_refresh_ui()
		return
	_pending_draw_id = ""
	var receipt: Dictionary = result.get("body", {})
	var replayed := bool(receipt.get("replayed", false))
	_diamond = int(receipt.get("diamond", _diamond))
	_energy = int(receipt.get("energy", receipt.get("misses", _energy)))
	var pet_id := str(receipt.get("pet_id", ""))
	var coin_reward := int(receipt.get("coin_reward", 0))
	if not replayed:
		SfxService.play(SfxService.CUE_UI_CURRENCY_SPEND)
	if not pet_id.is_empty():
		_available.erase(pet_id)
		if not _owned.has(pet_id):
			_owned.append(pet_id)
	_notice.text = ""
	_open_reveal()
	_reveal.call("show_reward", pet_id, coin_reward, replayed)
	_refresh_ui()
	draw_finished.emit()


func _show_pet_info(pet_id: String) -> void:
	if _busy or _reveal != null:
		return
	_open_reveal()
	_reveal.call("show_pet_info", pet_id, _owned.has(pet_id))
	_refresh_ui()


func _open_reveal() -> void:
	_reveal = PetDrawReveal.new()
	_reveal.connect("summon_requested", _commit_draw)
	_reveal.connect("dismissed", _on_reveal_dismissed)
	_canvas.add_child(_reveal)
	_rect(_reveal, 0, 0, 1600, 720)


func _on_reveal_dismissed() -> void:
	_reveal = null
	_refresh_ui()


func _close() -> void:
	if not _busy and _reveal == null:
		queue_free()


func _rect(node: Control, x: float, y: float, w: float, h: float) -> void:
	node.position = Vector2(x, y)
	node.size = Vector2(w, h)


func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Tokens.SUMMON_TEXT)
	label.add_theme_color_override("font_outline_color", Tokens.SUMMON_TEXT_EDGE)
	label.add_theme_constant_override("outline_size", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _button(value: String, minimum: Vector2) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = minimum
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_stylebox_override("normal", Tokens.panel_box(Tokens.SUMMON_GLASS, Tokens.GOLD_EDGE, 4))
	button.add_theme_stylebox_override("hover", Tokens.panel_box(Tokens.SUMMON_GLASS_HOVER, Tokens.GOLD_HOVER, 4))
	button.add_theme_stylebox_override("pressed", Tokens.panel_box(Tokens.SUMMON_GLASS, Tokens.GOLD_PRESSED, 4))
	button.add_theme_stylebox_override("disabled", Tokens.panel_box(Tokens.SUMMON_GLASS, Tokens.MIST_GHOST_EDGE, 4))
	button.add_theme_color_override("font_color", Tokens.SUMMON_TEXT)
	button.add_theme_color_override("font_hover_color", Tokens.SUMMON_TEXT)
	button.add_theme_color_override("font_disabled_color", Tokens.TEXT_DISABLED)
	button.add_theme_color_override("font_outline_color", Tokens.SUMMON_TEXT_EDGE)
	button.add_theme_constant_override("outline_size", 2)
	button.add_theme_font_size_override("font_size", 20)
	return button


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
