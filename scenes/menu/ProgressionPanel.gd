extends Control

signal dismissed()

const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
const PROFILE_BG_TEX := preload("res://assets/ui/profile/hall_of_glory.png")
const UnitCollection := preload("res://scripts/account/UnitCollection.gd")
const GOLD := Color("edca79")
const CREAM := Color("f8f0dc")
const MUTED := Color("b9c3c0")
const DARK := Color("14252b")

var _headline: Label
var _next: Label
var _xp_text: Label
var _progress: ProgressBar
var _track: HBoxContainer
var _track_scroll: ScrollContainer
var _detail: HBoxContainer
var _cards: Dictionary = {}
var _rewards: Dictionary = {}
var _current_level := 1
var _selected_level := 2
# 10.19 教程反馈第 4 条：教学引导要指向面板右上角的「返回」。
var _close_btn: Button


func tutorial_back_target() -> Control:
	return _close_btn


# 10.20 教程反馈第 4 条补：除了「返回」，「已获得的奖励」也要一起打亮。
# 返回奖励栏（滚动容器）本身：1 级「人族全套棋子」、2 级「神侍」都在这一排里，
# 已获得的卡带金框和「已获得」字样，比单独点某一级更完整。
func tutorial_reward_target() -> Control:
	return _track_scroll
var _compact := false


func _ready() -> void:
	_compact = get_viewport_rect().size.y < 800
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
	veil.color = Color(0.012, 0.030, 0.040, 0.76)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(veil)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 32 if _compact else 52)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16 if _compact else 29)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9 if _compact else 14)
	margin.add_child(column)
	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 50 if _compact else 58
	column.add_child(header)
	var title := _label(_t("成长之路", "PATH OF GROWTH"), 33, CREAM)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := ACTION_BUTTON.instantiate() as Button
	close.text = _t("返回", "Back")
	close.custom_minimum_size = Vector2(150, 50 if _compact else 58)
	close.pressed.connect(func() -> void: dismissed.emit())
	header.add_child(close)
	_close_btn = close
	var hero := PanelContainer.new()
	hero.custom_minimum_size.y = 145 if _compact else 175
	hero.add_theme_stylebox_override("panel", _box(Color("162d32"), GOLD, 18, 2,
		16 if _compact else 23))
	column.add_child(hero)
	var hero_row := HBoxContainer.new()
	hero_row.add_theme_constant_override("separation", 25)
	hero.add_child(hero_row)
	var emblem := PanelContainer.new()
	emblem.custom_minimum_size = Vector2(102, 102) if _compact else Vector2(137, 137)
	emblem.add_theme_stylebox_override("panel", _box(Color("304b46"), GOLD, 68, 4, 8))
	hero_row.add_child(emblem)
	_headline = _label("Lv 1", 36 if _compact else 43, GOLD)
	_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_headline.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	emblem.add_child(_headline)
	var hero_copy := VBoxContainer.new()
	hero_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero_copy.alignment = BoxContainer.ALIGNMENT_CENTER
	hero_copy.add_theme_constant_override("separation", 9)
	hero_row.add_child(hero_copy)
	hero_copy.add_child(_label(_t("当前等级", "CURRENT LEVEL"), 18, MUTED))
	_next = _label(_t("正在读取成长进度…", "Loading progress…"), 25, CREAM)
	hero_copy.add_child(_next)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 20
	_progress.show_percentage = false
	_progress.add_theme_stylebox_override("background", _box(Color("0b171c"), Color("5c726d"), 9, 1, 0))
	_progress.add_theme_stylebox_override("fill", _box(GOLD, GOLD, 9, 0, 0))
	hero_copy.add_child(_progress)
	_xp_text = _label("0 / 60 XP", 17, MUTED)
	hero_copy.add_child(_xp_text)
	var section := HBoxContainer.new()
	section.custom_minimum_size.y = 34 if _compact else 40
	column.add_child(section)
	var section_title := _label(_t("等级奖励", "LEVEL REWARDS"), 25, GOLD)
	section_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	section.add_child(section_title)
	section.add_child(_label(_t("选择等级查看奖励", "Select a level to preview its reward"), 17, MUTED))
	_track_scroll = TouchScrollContainer.new()
	_track_scroll.custom_minimum_size.y = 195 if _compact else 242
	_track_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_track_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_track_scroll)
	_track = HBoxContainer.new()
	_track.add_theme_constant_override("separation", 12)
	_track_scroll.add_child(_track)
	var detail_panel := PanelContainer.new()
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.custom_minimum_size.y = 150 if _compact else 170
	detail_panel.add_theme_stylebox_override("panel", _box(Color("13252c"), Color("9c865a"), 15, 2, 21))
	column.add_child(detail_panel)
	_detail = HBoxContainer.new()
	_detail.add_theme_constant_override("separation", 24)
	detail_panel.add_child(_detail)


func _load() -> void:
	var response: Dictionary = await AccountManager.fetch_progression()
	if not is_inside_tree():
		return
	if int(response.get("code", 0)) != 200:
		_next.text = _t("等级暂时无法读取", "Level is temporarily unavailable")
		return
	_show_state(response.get("body", {}))


func _show_state(state: Dictionary) -> void:
	_current_level = int(state.get("level", 1))
	_selected_level = mini(_current_level + 1, 20)
	_headline.text = "Lv %d" % _current_level
	var xp := int(state.get("xp", 0))
	var next_xp = state.get("next_xp", null)
	if next_xp == null:
		_next.text = _t("等级已满 · 荣耀之路达成", "Maximum level reached")
		_progress.value = 100
		_xp_text.text = _t("已满级", "MAX LEVEL")
	else:
		_next.text = _t("距离 Lv %d 还差 %d 经验" % [_current_level + 1, maxi(0, int(next_xp) - xp)],
			"%d XP to Level %d" % [maxi(0, int(next_xp) - xp), _current_level + 1])
		_progress.min_value = int(state.get("level_xp", 0))
		_progress.max_value = maxi(int(next_xp), _progress.min_value + 1)
		_progress.value = xp
		_xp_text.text = "%d / %d XP" % [xp, int(next_xp)]
	_rewards.clear()
	_rewards[1] = {"level": 1, "units": [], "coin": 0, "diamond": 0}
	for raw in state.get("rewards", []):
		if typeof(raw) == TYPE_DICTIONARY:
			_rewards[int(raw.get("level", 0))] = raw
	for child in _track.get_children():
		_track.remove_child(child)
		child.queue_free()
	_cards.clear()
	for level in range(1, 21):
		var card := _make_card(level)
		_track.add_child(card)
		_cards[level] = card
	_select_level(_selected_level)
	# Jump near the next reward on an established account, while preserving Lv 1 at the start.
	_track_scroll.set_deferred("scroll_horizontal", maxi(0, (_selected_level - 2) * 188))


func _make_card(level: int) -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(176, 185 if _compact else 220)
	card.text = ""
	card.pressed.connect(_select_level.bind(level))
	var body := VBoxContainer.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 10
	body.offset_right = -10
	body.offset_top = 9
	body.offset_bottom = -9
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_theme_constant_override("separation", 5)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(body)
	var number := _label("Lv %d" % level, 21, GOLD if level <= _current_level else MUTED)
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(number)
	var art := _reward_art(_rewards.get(level, {}), 56 if _compact else 74)
	art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	body.add_child(art)
	var name := _label(_summary(level), 17, CREAM)
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name.custom_minimum_size.y = 35 if _compact else 42
	body.add_child(name)
	var state := _t("已获得", "EARNED") if level <= _current_level else _t("待解锁", "LOCKED")
	var status := _label(state, 15, GOLD if level <= _current_level else MUTED)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(status)
	return card


func _select_level(level: int) -> void:
	_selected_level = level
	for raw in _cards:
		var index := int(raw)
		var selected := index == level
		var obtained := index <= _current_level
		var card: Button = _cards[index]
		var fill := Color("30494a") if selected else (Color("23383a") if obtained else DARK)
		var edge := GOLD if selected else (Color("937d55") if obtained else Color("657875"))
		card.add_theme_stylebox_override("normal", _box(fill, edge, 13, 3 if selected else 1, 8))
		card.add_theme_stylebox_override("hover", _box(fill.lightened(0.10), GOLD, 13, 2, 8))
		card.add_theme_stylebox_override("pressed", _box(fill.darkened(0.08), GOLD, 13, 2, 8))
		card.add_theme_stylebox_override("focus", _box(fill, GOLD, 13, 3, 8))
	_render_detail(level)


func _render_detail(level: int) -> void:
	for child in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()
	var reward: Dictionary = _rewards.get(level, {})
	var art := _detail_reward_art(reward)
	_detail.add_child(art)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 6)
	_detail.add_child(info)
	info.add_child(_label(_t("第 %d 级奖励" % level, "LEVEL %d REWARD" % level), 19, GOLD))
	info.add_child(_label(_summary(level), 30, CREAM))
	var description := ""
	if level == 1:
		description = _t("人族全套棋子已解锁，可以立即开始青苗对局。",
			"Full Human roster unlocked. Play Seedling now.")
	elif level == 10:
		description = _t("神族棋子集齐后自动加入备战阵容。",
			"The complete Divine roster joins your Prep loadout automatically.")
	elif (reward.get("units", []) as Array).size() > 1:
		description = reward_text(reward) + _t(" · 升级后自动发放", " · Granted on level up")
	else:
		description = _t("升级后自动发放到账号，无需手动领取。",
			"Automatically added to your account on level up.")
	var note := _label(description, 17, MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_child(note)
	var status := _label(_t("✓ 已获得", "✓ EARNED") if level <= _current_level else
		_t("达到 Lv %d 解锁" % level, "UNLOCK AT LV %d" % level), 19,
		GOLD if level <= _current_level else MUTED)
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail.add_child(status)


func _detail_reward_art(reward: Dictionary) -> Control:
	var units: Array = reward.get("units", [])
	if units.size() <= 1:
		return _reward_art(reward, 100 if _compact else 130)
	var portraits := HBoxContainer.new()
	portraits.add_theme_constant_override("separation", 12)
	for unit_id in units:
		var portrait := VBoxContainer.new()
		portrait.add_theme_constant_override("separation", 4)
		portraits.add_child(portrait)
		var single_reward := {"units": [unit_id]}
		portrait.add_child(_reward_art(single_reward, 82 if _compact else 98))
		var definition := UnitCollection.unit_def(str(unit_id))
		var name := str(definition.get("name_en", unit_id)) if _english() else str(definition.get("name", unit_id))
		var caption := _label(name, 16, CREAM)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		portrait.add_child(caption)
	return portraits


func _reward_art(reward: Dictionary, dimension: int) -> Control:
	var holder := PanelContainer.new()
	holder.custom_minimum_size = Vector2(dimension + 20, dimension + 20)
	holder.add_theme_stylebox_override("panel", _box(Color("263d41"), GOLD, 12, 2, 7))
	var level := int(reward.get("level", 0))
	var units: Array = reward.get("units", [])
	var path := ""
	if level == 1:
		path = "res://assets/ui/race_logos/human.png"
	elif not units.is_empty():
		path = "res://assets/ui/unit_portraits/%s.png" % str(units[0])
	if not path.is_empty() and ResourceLoader.exists(path):
		var image := TextureRect.new()
		image.texture = load(path)
		image.custom_minimum_size = Vector2(dimension, dimension)
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		holder.add_child(image)
	else:
		var glyph := "◆" if int(reward.get("diamond", 0)) > 0 else "G"
		var symbol := _label(glyph, dimension / 2, GOLD)
		symbol.custom_minimum_size = Vector2(dimension, dimension)
		symbol.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		symbol.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		holder.add_child(symbol)
	return holder


func _summary(level: int) -> String:
	if level == 1:
		return _t("人族全套棋子", "Human roster")
	var reward: Dictionary = _rewards.get(level, {})
	var units: Array = reward.get("units", [])
	if not units.is_empty():
		if units.size() > 1:
			return _t("神族棋子 × %d" % units.size(), "Divine pieces × %d" % units.size())
		var definition := UnitCollection.unit_def(str(units[0]))
		return str(definition.get("name_en", units[0])) if _english() else str(definition.get("name", units[0]))
	return reward_text(reward)


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


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _box(fill: Color, edge: Color, radius: int, border: int, pad: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = edge
	box.set_border_width_all(border)
	box.set_corner_radius_all(radius)
	box.set_content_margin_all(pad)
	return box


func _english() -> bool:
	return TranslationServer.get_locale().begins_with("en")


func _t(zh: String, en: String) -> String:
	return en if _english() else zh
