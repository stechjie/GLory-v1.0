extends Control

signal back_requested

var _btn_zh: Button
var _btn_en: Button

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

	var sep2 := HSeparator.new()
	panel.add_child(sep2)

	var back_btn := Button.new()
	back_btn.text = tr("settings_back")
	back_btn.custom_minimum_size = Vector2(160, 40)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.pressed.connect(func(): back_requested.emit())
	panel.add_child(back_btn)

func _refresh_lang_buttons() -> void:
	if not is_instance_valid(_btn_zh) or not is_instance_valid(_btn_en):
		return
	var locale := LocaleManager.get_locale()
	_btn_zh.modulate = Color(1.0, 0.85, 0.3) if locale == "zh" else Color(1, 1, 1)
	_btn_en.modulate = Color(1.0, 0.85, 0.3) if locale == "en" else Color(1, 1, 1)

func _on_locale_changed(_locale: String) -> void:
	_refresh_lang_buttons()
