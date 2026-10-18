extends Control
# Read-only account level overview, opened from the profile screen.
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
const PROFILE_BG_TEX := preload("res://assets/ui/profile/hall_of_glory.png")
const UnitCollection := preload("res://scripts/account/UnitCollection.gd")

signal dismissed()

var _headline: Label
var _progress: ProgressBar
var _list: VBoxContainer


func _ready() -> void:
	theme = Theming.get_theme()
	_build()
	_load()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := TextureRect.new()
	background.texture = PROFILE_BG_TEX
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var veil := ColorRect.new()
	veil.color = Color(0.008, 0.016, 0.031, 0.55)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(veil)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 56)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := Label.new()
	title.text = _text("等级与奖励", "Levels & Rewards")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	header.add_child(title)
	var close := ACTION_BUTTON.instantiate() as Button
	close.text = _text("返回", "Back")
	close.custom_minimum_size = Vector2(130, Tokens.TOUCH_MIN)
	close.pressed.connect(func() -> void: dismissed.emit())
	header.add_child(close)
	_headline = Label.new()
	_headline.text = _text("正在读取等级…", "Loading level…")
	_headline.add_theme_font_size_override("font_size", 22)
	_headline.add_theme_color_override("font_color", Tokens.GOLD)
	column.add_child(_headline)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 20
	_progress.show_percentage = false
	column.add_child(_progress)
	var scroll := TouchScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)


func _load() -> void:
	var response: Dictionary = await AccountManager.fetch_progression()
	if not is_inside_tree():
		return
	if int(response.get("code", 0)) != 200:
		_headline.text = _text("等级暂时无法读取", "Level is temporarily unavailable")
		return
	var state: Dictionary = response.get("body", {})
	var level := int(state.get("level", 1))
	var xp := int(state.get("xp", 0))
	var next_xp = state.get("next_xp", null)
	_headline.text = _text("等级 %d · 总经验 %d" % [level, xp],
		"Level %d · %d total XP" % [level, xp])
	if next_xp == null:
		_progress.visible = false
		_headline.text += _text(" · 已满级", " · Max level")
	else:
		_progress.min_value = int(state.get("level_xp", 0))
		_progress.max_value = maxi(1, int(next_xp))
		_progress.value = xp
	for child in _list.get_children():
		child.queue_free()
	var start := PanelContainer.new()
	start.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, 10))
	_list.add_child(start)
	var starter := Label.new()
	starter.text = _text("Lv 1  ·  人族全套棋子，可立即进行休闲对局",
		"Lv 1  ·  Full Human roster, ready for Casual")
	starter.add_theme_font_size_override("font_size", 18)
	start.add_child(starter)
	for entry in state.get("rewards", []):
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		_add_reward(entry as Dictionary, level)


func _add_reward(reward: Dictionary, current: int) -> void:
	var level := int(reward.get("level", 0))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE if level <= current else Tokens.SURFACE_RAISED,
		Tokens.GOLD_EDGE if level == current else Tokens.PREP_EDGE, 10))
	_list.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	card.add_child(row)
	var marker := Label.new()
	marker.text = "Lv %d" % level
	marker.custom_minimum_size.x = 88
	marker.add_theme_font_size_override("font_size", 20)
	marker.add_theme_color_override("font_color", Tokens.GOLD if level <= current else Tokens.TEXT_SECONDARY)
	row.add_child(marker)
	var detail := Label.new()
	detail.text = reward_text(reward)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_font_size_override("font_size", 17)
	detail.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(detail)
	var status := Label.new()
	status.text = _text("已获得", "Earned") if level <= current else _text("待解锁", "Locked")
	status.add_theme_color_override("font_color", Tokens.GOLD if level <= current else Tokens.TEXT_SECONDARY)
	row.add_child(status)


static func reward_text(reward: Dictionary) -> String:
	var en := TranslationServer.get_locale().begins_with("en")
	var units: Array = reward.get("units", [])
	if not units.is_empty():
		var names: Array[String] = []
		for unit_id in units:
			var unit := UnitCollection.unit_def(str(unit_id))
			names.append(str(unit.get("name_en", unit_id)) if en else str(unit.get("name", unit_id)))
		return ", ".join(names)
	if int(reward.get("diamond", 0)) > 0:
		return ("Free diamonds × %d" if en else "免费钻石 × %d") % int(reward["diamond"])
	return ("Coins × %d" if en else "游戏币 × %d") % int(reward.get("coin", 0))


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
