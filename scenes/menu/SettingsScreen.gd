extends Control

signal back_requested

var _btn_zh: Button
var _btn_en: Button
var _quality_btns: Array[Button] = []
var _board_guides_btn: CheckButton
var _presentation_btns: Dictionary = {}

func _ready() -> void:
	_build()
	LocaleManager.locale_changed.connect(_on_locale_changed)

func _build() -> void:
	for child in get_children():
		child.queue_free()

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.09)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.add_theme_constant_override("separation", 16)
	center.add_child(panel)

	var title := Label.new()
	title.text = tr("settings_title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.96, 0.96, 0.92))
	panel.add_child(title)

	var sep := HSeparator.new()
	panel.add_child(sep)

	var lang_label := Label.new()
	lang_label.text = tr("settings_language")
	lang_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lang_label.add_theme_color_override("font_color", Color(0.86, 0.9, 0.9))
	panel.add_child(lang_label)

	var lang_row := HBoxContainer.new()
	lang_row.alignment = BoxContainer.ALIGNMENT_CENTER
	lang_row.add_theme_constant_override("separation", 12)
	panel.add_child(lang_row)

	_btn_zh = Button.new()
	_btn_zh.text = "中文"
	_btn_zh.custom_minimum_size = Vector2(140, 48)
	_btn_zh.pressed.connect(func(): LocaleManager.set_locale("zh"))
	lang_row.add_child(_btn_zh)

	_btn_en = Button.new()
	_btn_en.text = "English"
	_btn_en.custom_minimum_size = Vector2(140, 48)
	_btn_en.pressed.connect(func(): LocaleManager.set_locale("en"))
	lang_row.add_child(_btn_en)

	_refresh_lang_buttons()

	var sep_q := HSeparator.new()
	panel.add_child(sep_q)

	# 画质档。自动判定按总内存分（<4GB -> 流畅），但玩家选了就永远优先，
	# 自动判定不再覆盖 —— 低端机上默认保守，愿意的人可以自己往上调。
	var quality_label := Label.new()
	quality_label.text = tr("settings_quality")
	quality_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	quality_label.add_theme_color_override("font_color", Color(0.86, 0.9, 0.9))
	panel.add_child(quality_label)

	var quality_row := HBoxContainer.new()
	quality_row.alignment = BoxContainer.ALIGNMENT_CENTER
	quality_row.add_theme_constant_override("separation", 10)
	panel.add_child(quality_row)

	_quality_btns.clear()
	var options := [
		[VFXQualityBudget.Tier.LOW, "settings_quality_low"],
		[VFXQualityBudget.Tier.MEDIUM, "settings_quality_medium"],
		[VFXQualityBudget.Tier.HIGH, "settings_quality_high"],
	]
	for opt in options:
		var tier_value: int = opt[0]
		var btn := Button.new()
		btn.text = tr(str(opt[1]))
		btn.custom_minimum_size = Vector2(96, 48)
		btn.pressed.connect(func():
			VFXManager.set_quality_pref(tier_value)
			_refresh_quality_buttons())
		quality_row.add_child(btn)
		_quality_btns.append(btn)
	_refresh_quality_buttons()

	var sep_guides := HSeparator.new()
	panel.add_child(sep_guides)

	_board_guides_btn = CheckButton.new()
	_board_guides_btn.text = tr("settings_board_guides")
	_board_guides_btn.custom_minimum_size = Vector2(280, 46)
	_board_guides_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_board_guides_btn.button_pressed = PlayerProfile.board_readability_enabled
	_board_guides_btn.toggled.connect(func(enabled: bool):
		PlayerProfile.set_board_readability_enabled(enabled)
		_refresh_board_guides_button())
	panel.add_child(_board_guides_btn)
	_refresh_board_guides_button()

	# V2 P1-05 第 4 条：屏震 / 闪光 / hit-stop 三个无障碍开关。
	# 三项默认开启 —— 它们是演出效果，默认关掉等于让绝大多数玩家看到更差的版本。
	var sep_access := HSeparator.new()
	panel.add_child(sep_access)
	for spec in [
		{"key": "screen_shake", "label": "settings_screen_shake"},
		{"key": "flash_effects", "label": "settings_flash_effects"},
		{"key": "hit_stop", "label": "settings_hit_stop"},
	]:
		var spec_dict: Dictionary = spec
		var key := str(spec_dict["key"])
		var btn := CheckButton.new()
		btn.text = tr(str(spec_dict["label"]))
		btn.custom_minimum_size = Vector2(280, 46)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.button_pressed = PlayerProfile.get_presentation_toggle(key)
		btn.toggled.connect(func(enabled: bool):
			PlayerProfile.set_presentation_toggle(key, enabled)
			_refresh_presentation_button(key))
		panel.add_child(btn)
		_presentation_btns[key] = btn
		_refresh_presentation_button(key)

	var sep2 := HSeparator.new()
	panel.add_child(sep2)

	var back_btn := Button.new()
	back_btn.text = tr("settings_back")
	back_btn.custom_minimum_size = Vector2(160, 40)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.pressed.connect(func(): back_requested.emit())
	panel.add_child(back_btn)

func _refresh_quality_buttons() -> void:
	var current := VFXManager.get_quality_tier()
	for i in _quality_btns.size():
		var btn := _quality_btns[i]
		if is_instance_valid(btn):
			btn.modulate = Color(1.0, 0.85, 0.3) if i == current else Color(1, 1, 1)

func _refresh_presentation_button(key: String) -> void:
	var btn_value = _presentation_btns.get(key)
	if not (btn_value is CheckButton) or not is_instance_valid(btn_value):
		return
	var btn := btn_value as CheckButton
	var on: bool = PlayerProfile.get_presentation_toggle(key)
	btn.button_pressed = on
	btn.modulate = Color(1.0, 0.88, 0.48) if on else Color(0.76, 0.78, 0.78)


func _refresh_board_guides_button() -> void:
	if not is_instance_valid(_board_guides_btn):
		return
	_board_guides_btn.button_pressed = PlayerProfile.board_readability_enabled
	_board_guides_btn.modulate = Color(1.0, 0.88, 0.48) if PlayerProfile.board_readability_enabled else Color(0.76, 0.78, 0.78)

func _refresh_lang_buttons() -> void:
	if not is_instance_valid(_btn_zh) or not is_instance_valid(_btn_en):
		return
	var locale := LocaleManager.get_locale()
	_btn_zh.modulate = Color(1.0, 0.85, 0.3) if locale == "zh" else Color(1, 1, 1)
	_btn_en.modulate = Color(1.0, 0.85, 0.3) if locale == "en" else Color(1, 1, 1)

func _on_locale_changed(_locale: String) -> void:
	_refresh_lang_buttons()
