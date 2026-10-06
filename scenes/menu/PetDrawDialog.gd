extends Control

# 钻石宠物召唤。抽取结果、余额和保底次数全部来自账号服务器。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const Currency := preload("res://scripts/account/Currency.gd")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")

signal draw_finished

var _pity_progress := -1
var _available: Array = []
var _owned: Array = []
var _diamond := -1
var _busy := false
var _pending_draw_id := ""
var _draw_button: Button
var _view := "summon"
var _body: VBoxContainer
var _notice: Label
var _pity_label: Label
var _view_buttons: Dictionary = {}


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_show_view("summon")
	_load_state()


# 以后由服务端奖池状态调用；-1 表示尚无可验证的抽取记录。
func set_pity_progress(draws_since_new_pet: int) -> void:
	_pity_progress = draws_since_new_pet
	if _pity_label != null:
		_update_pity_label()


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Tokens.BACKDROP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var shell := PanelContainer.new()
	shell.custom_minimum_size = Vector2(1060, 555)
	shell.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.BG_DEEP, Tokens.GOLD_EDGE, Tokens.GAP_L))
	center.add_child(shell)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", Tokens.GAP_S)
	shell.add_child(root)
	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = _t("稀有伙伴召唤", "Rare companion summon")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	header.add_child(title)
	var close: Button = ACTION_BUTTON.instantiate()
	close.text = "✕"
	close.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	close.pressed.connect(queue_free)
	header.add_child(close)
	var sub := Label.new()
	sub.text = _t("75 钻石抽取一次 · 10 抽内保底获得一只未拥有的新宠物",
		"75 gems per draw · a new unowned pet within 10 draws")
	sub.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	sub.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	root.add_child(sub)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", Tokens.GAP_S)
	root.add_child(tabs)
	for tab in [
		{"id": "summon", "zh": "召唤", "en": "Summon"},
		{"id": "pool", "zh": "奖池", "en": "Pool"},
		{"id": "rules", "zh": "规则", "en": "Rules"},
	]:
		var button: Button = ACTION_BUTTON.instantiate()
		button.text = _t(str(tab.zh), str(tab.en))
		button.custom_minimum_size = Vector2(142, Tokens.TOUCH_MIN)
		var id := str(tab.id)
		button.pressed.connect(func() -> void: _show_view(id))
		tabs.add_child(button)
		_view_buttons[id] = button
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", Tokens.GAP_M)
	root.add_child(content)
	var art := PanelContainer.new()
	art.custom_minimum_size = Vector2(350, 310)
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.GOLD_PRESSED, 2))
	content.add_child(art)
	var portraits := HBoxContainer.new()
	portraits.alignment = BoxContainer.ALIGNMENT_CENTER
	portraits.add_theme_constant_override("separation", Tokens.GAP_S)
	art.add_child(portraits)
	for pet_id in ["pet_squirrel", "pet_tiger"]:
		portraits.add_child(PetPreview.build_illustration(pet_id, Vector2(160, 290)))
	var right := PanelContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_M))
	content.add_child(right)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", Tokens.GAP_S)
	right.add_child(_body)
	_notice = Label.new()
	_notice.text = _t("正在读取奖池与钱包…", "Loading pool and wallet…")
	_notice.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_notice.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	root.add_child(_notice)


func _show_view(view_id: String) -> void:
	_view = view_id
	for key in _view_buttons:
		(_view_buttons[key] as Button).theme_type_variation = (
			Theming.VARIATION_PRIMARY if key == view_id else Theming.VARIATION_GHOST)
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	match view_id:
		"pool":
			_show_pool()
		"rules":
			_show_rules()
		_:
			_show_summon()


func _show_summon() -> void:
	_heading(_t("召唤松鼠或老虎", "Summon Squirrel or Tiger"))
	var intro := _line(_t("每抽 10% 获得一只未拥有的奖池宠物；第 10 抽必得。",
		"10% chance for an unowned pool pet; guaranteed on draw 10."))
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(intro)
	_pity_label = _line("")
	_pity_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	_pity_label.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	_body.add_child(_pity_label)
	_update_pity_label()
	var track := HBoxContainer.new()
	track.add_theme_constant_override("separation", 3)
	_body.add_child(track)
	for i in 10:
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(38, 16)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_stylebox_override("panel", Tokens.panel_box(
			Tokens.SURFACE_RAISED, Tokens.GOLD_PRESSED if i == 9 else Tokens.BORDER, 0))
		track.add_child(cell)
	_body.add_child(_line(_t("未抽中宠物时获得 100 账号金币。",
		"No pet? Receive 100 account coins.")))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(spacer)
	_draw_button = ACTION_BUTTON.instantiate()
	_draw_button.theme_type_variation = Theming.VARIATION_PRIMARY
	_draw_button.custom_minimum_size.y = Tokens.TOUCH_MIN
	_draw_button.pressed.connect(_draw)
	_body.add_child(_draw_button)
	_update_draw_button()


func _update_draw_button() -> void:
	if _draw_button == null or not is_instance_valid(_draw_button):
		return
	_draw_button.disabled = _busy or _pity_progress < 0 or _available.is_empty() or _diamond < 75
	if _available.is_empty() and _pity_progress >= 0:
		_draw_button.text = _t("奖池已收集完毕", "Pool complete")
	elif _diamond >= 0 and _diamond < 75:
		_draw_button.text = _t("钻石不足", "Not enough gems")
	else:
		_draw_button.text = _t("抽取一次 · 75 钻石", "Draw once · 75 gems")


func _load_state() -> void:
	var pool: Dictionary = await AccountManager.fetch_pet_draw_state()
	var wallet: Dictionary = await AccountManager.fetch_wallet()
	if not is_inside_tree():
		return
	if int(pool.get("code", 0)) / 100 != 2:
		_notice.text = str(pool.get("error", _t("奖池读取失败", "Could not load pool")))
		return
	var body: Dictionary = pool.get("body", {})
	_available = body.get("available", [])
	_owned = body.get("owned", [])
	set_pity_progress(int(body.get("misses", 0)))
	if int(wallet.get("code", 0)) / 100 == 2:
		_diamond = int((wallet.get("body", {}) as Dictionary).get("diamond", -1))
	_notice.text = _t("当前钻石：%s" % Currency.comma(_diamond),
		"Gems: %s" % Currency.comma(_diamond))
	_update_draw_button()
	if _view == "pool":
		_show_view("pool")


func _draw() -> void:
	if _busy or _available.is_empty() or _diamond < 75:
		return
	_busy = true
	_update_draw_button()
	if _pending_draw_id.is_empty():
		_pending_draw_id = AccountManager.new_client_order_id()
	var result: Dictionary = await AccountManager.draw_pet(_pending_draw_id)
	_busy = false
	if not is_inside_tree():
		return
	var code := int(result.get("code", 0))
	if code / 100 == 2:
		_pending_draw_id = ""
		var receipt: Dictionary = result.get("body", {})
		var replayed := bool(receipt.get("replayed", false))
		_diamond = int(receipt.get("diamond", _diamond))
		set_pity_progress(int(receipt.get("misses", _pity_progress)))
		var pet_id := str(receipt.get("pet_id", ""))
		if pet_id.is_empty():
			_notice.text = _t("获得 100 账号金币 · 剩余 %d 抽保底 · 钻石 %d" %
				[10 - _pity_progress, _diamond],
				"100 coins · %d draws to guarantee · %d gems" %
				[10 - _pity_progress, _diamond])
		else:
			_available.erase(pet_id)
			_owned.append(pet_id)
			_notice.text = _t("获得新宠物：%s！" % _pet_name(pet_id),
				"New pet: %s!" % _pet_name(pet_id))
			await PlayerProfile.refresh_pets()
		if replayed:
			_notice.text = _t("这一抽已完成，没有重复扣钻。", "This draw was already completed; no gems were charged again.") + " " + _notice.text
		draw_finished.emit()
		if _view == "pool":
			_show_view("pool")
	else:
		if code != 0 and code < 500:
			_pending_draw_id = ""
		_notice.text = str(result.get("error", _t("抽取失败", "Draw failed")))
		if code == 0 or code >= 500:
			_notice.text += _t("；重试会继续同一抽", "; retry resumes the same draw")
	_update_draw_button()


func _pet_name(pet_id: String) -> String:
	match pet_id:
		"pet_squirrel":
			return _t("松鼠", "Squirrel")
		"pet_tiger":
			return _t("老虎", "Tiger")
	return pet_id


func _show_pool() -> void:
	_pity_label = null
	_draw_button = null
	_heading(_t("稀有宠物奖池", "Rare pet pool"))
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	_body.add_child(row)
	for pet_id in ["pet_squirrel", "pet_tiger"]:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(195, 180)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", Tokens.panel_box(
			Tokens.SURFACE_RAISED, Tokens.GOLD_PRESSED, Tokens.GAP_M))
		row.add_child(card)
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		card.add_child(col)
		col.add_child(PetPreview.build_illustration(pet_id, Vector2(190, 165)))
		var name := _line(_pet_name(pet_id))
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(name)
		var status := _line(_t("已拥有", "Owned") if _owned.has(pet_id) else
			_t("未拥有", "Not owned"))
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(status)
	var note := _line(_t("抽中宠物时，从未拥有的宠物中等概率选择。全部拥有后停止抽取。",
		"Pet drops are shared equally among unowned pets. Drawing stops when both are owned."))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(note)


func _show_rules() -> void:
	_pity_label = null
	_heading(_t("抽取规则", "Draw rules"))
	for text_pair in [
		[_t("每次抽取消耗 75 钻石。", "Each draw costs 75 gems.")],
		[_t("最多 10 抽获得一只尚未拥有的新宠物。", "A new unowned pet is guaranteed within 10 draws.")],
		[_t("没有抽中新宠物时，获得 100 游戏币。", "If no new pet drops, receive 100 coins.")],
		[_t("保底次数由服务器按账号记录，获得宠物后重置。",
			"Pity is tracked per account and resets after a pet drop.")],
		[_t("普通抽取宠物概率 10%，第 10 抽保底。", "Pet chance is 10%, guaranteed on draw 10.")],
	]:
		var label := _line("•  " + str(text_pair[0]))
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(label)


func _update_pity_label() -> void:
	if _pity_label == null:
		return
	_pity_label.text = (_t("保底剩余 — 抽 / 10 抽", "Pity remaining — / 10 draws")
		if _pity_progress < 0 else
		_t("保底剩余 %d 抽 / 10 抽" % maxi(1, 10 - _pity_progress),
			"Pity remaining %d / 10 draws" % maxi(1, 10 - _pity_progress)))


func _heading(value: String) -> void:
	var label := _line(value)
	label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	label.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	_body.add_child(label)


func _line(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	return label


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		queue_free()
		get_viewport().set_input_as_handled()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
