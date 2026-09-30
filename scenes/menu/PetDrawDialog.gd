extends Control

# 稀有宠物奖池的交互预览。奖池、概率和服务端交易未开放时绝不扣币或发奖。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const SHOP_ART := preload("res://assets/ui/shop/shop_hero_bg.png")
const Currency := preload("res://scripts/account/Currency.gd")

var _pity_progress := -1
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
	var scene := TextureRect.new()
	scene.texture = SHOP_ART
	scene.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scene.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.add_child(scene)
	var right := PanelContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_M))
	content.add_child(right)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", Tokens.GAP_S)
	right.add_child(_body)
	_notice = Label.new()
	_notice.text = _t("奖池筹备中；当前不会扣除钻石。", "Pool in preparation; no gems can be spent yet.")
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
	_heading(_t("下一位伙伴，等待揭晓", "Your next companion awaits"))
	var intro := _line(_t("两只稀有宠物正在设计中，正式奖池开放后可在此抽取。",
		"Two rare pets are being designed. Summoning opens with the completed pool."))
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
	var line := _line(_t("未获得新宠物：返还 100 游戏币", "No new pet: receive 100 coins"))
	_body.add_child(line)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(spacer)
	var draw: Button = ACTION_BUTTON.instantiate()
	draw.text = _t("抽取一次  ·  75 钻石", "Draw once  ·  75 gems")
	draw.theme_type_variation = Theming.VARIATION_PRIMARY
	draw.custom_minimum_size.y = Tokens.TOUCH_MIN
	draw.pressed.connect(func() -> void:
		_notice.text = _t("奖池尚未开放，没有扣除钻石，也没有发放奖励。",
			"The pool is not open. No gems were spent and no reward was granted.")
		_notice.add_theme_color_override("font_color", Tokens.CYAN))
	_body.add_child(draw)


func _show_pool() -> void:
	_pity_label = null
	_heading(_t("稀有宠物奖池", "Rare pet pool"))
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	_body.add_child(row)
	for number in [1, 2]:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(195, 180)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", Tokens.panel_box(
			Tokens.SURFACE_RAISED, Tokens.GOLD_PRESSED, Tokens.GAP_M))
		row.add_child(card)
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		card.add_child(col)
		var mark := _line("✦  ?  ✦")
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mark.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
		mark.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
		col.add_child(mark)
		var name := _line(_t("神秘伙伴 %d" % number, "Mystery pet %d" % number))
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(name)
	var note := _line(_t("宠物外观、效果和抽中概率将在奖池开放前公布。",
		"Pet art, effects and draw odds will be published before the pool opens."))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(note)


func _show_rules() -> void:
	_pity_label = null
	_heading(_t("抽取规则", "Draw rules"))
	for text_pair in [
		[_t("每次抽取消耗 75 钻石。", "Each draw costs 75 gems.")],
		[_t("最多 10 抽获得一只尚未拥有的新宠物。", "A new unowned pet is guaranteed within 10 draws.")],
		[_t("没有抽中新宠物时，获得 100 游戏币。", "If no new pet drops, receive 100 coins.")],
		[_t("剩余保底抽数会由服务器记录，奖池开放后在召唤页显示。",
			"Remaining draws will be tracked by the server and shown on the summon page.")],
		[_t("具体概率将在正式开放前公布。", "Exact odds will be published before release.")],
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
