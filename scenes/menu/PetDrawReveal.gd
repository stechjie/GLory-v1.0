extends Control

# Transparent result and pet-detail overlay; no reward is decided here.
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Currency := preload("res://scripts/account/Currency.gd")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const PetService := preload("res://scripts/pets/PetService.gd")
const SfxService := preload("res://ui/services/SfxService.gd")

signal summon_requested
signal dismissed

var _phase := ""
var _panel: PanelContainer
var _content: VBoxContainer


func _ready() -> void:
	size = Vector2(1600, 720)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_panel = PanelContainer.new()
	_panel.position = Vector2(500, 111)
	_panel.size = Vector2(600, 490)
	_panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SUMMON_INFO_GLASS, Tokens.GOLD_EDGE, 16))
	add_child(_panel)
	_content = VBoxContainer.new()
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	_content.add_theme_constant_override("separation", 9)
	_panel.add_child(_content)


func show_reward(pet_id: String, coin_reward: int, replayed: bool) -> void:
	_phase = "reward"
	_clear()
	var pet := not pet_id.is_empty()
	_add_label(_t("召唤成功", "Summon complete") if pet else
		_t("获得奖励", "Reward received"), 30)
	if pet:
		var art := PetPreview.build_illustration(pet_id, Vector2(245, 205))
		art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_content.add_child(art)
		_pop(art)
		SfxService.play(SfxService.CUE_MERC_SUMMON)
		_add_label(_t("获得新宠物：%s" % PetService.display_name(pet_id),
			"New pet: %s" % PetService.display_name(pet_id)), 24)
	else:
		var coins := Control.new()
		coins.custom_minimum_size = Vector2(390, 185)
		coins.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_content.add_child(coins)
		for i in 4:
			var icon := TextureRect.new()
			icon.texture = Currency.icon("coin")
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.position = Vector2(160 + i * 8, 154)
			icon.size = Vector2(75, 75)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			coins.add_child(icon)
			if not Tokens.reduced_motion():
				var rise := create_tween().set_parallel(true)
				rise.tween_property(icon, "position", Vector2(54 + i * 75, 58 + (i % 2) * 21), 0.43 + i * 0.07).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
				rise.tween_property(icon, "rotation", -0.13 + 0.09 * i, 0.43 + i * 0.07)
		SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN)
		_add_label(_t("获得 %d 金币" % coin_reward, "Received %d coins" % coin_reward), 26)
	if replayed:
		_add_label(_t("已恢复本次抽取，没有再次扣钻", "Draw restored without another charge"), 16)
	_add_button(_t("确认", "Confirm"), _dismiss)


func show_pet_info(pet_id: String, _owned: bool) -> void:
	_phase = "info"
	_clear()
	_add_label(PetService.display_name(pet_id), 30)
	var english := LocaleManager.get_locale().begins_with("en")
	_panel.position = Vector2(490, 70 if english else 80)
	_panel.size = Vector2(620, 625 if english else 560)
	var art := PetPreview.build_illustration(pet_id, Vector2(210, 140 if english else 150))
	art.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_content.add_child(art)
	var reading_plate := PanelContainer.new()
	reading_plate.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SUMMON_READ_PLATE, Tokens.SUMMON_PLATE_EDGE, 12))
	reading_plate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(reading_plate)
	var detail := RichTextLabel.new()
	detail.bbcode_enabled = true
	detail.scroll_active = true
	detail.custom_minimum_size = Vector2(0, 285 if english else 220)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_font_size_override("normal_font_size", 18)
	detail.add_theme_color_override("default_color", Tokens.SUMMON_DETAIL_INK)
	detail.add_theme_constant_override("line_separation", 4)
	detail.text = _skill_markup(PetService.skill_detail_text(pet_id))
	reading_plate.add_child(detail)
	_add_button(_t("确认", "Confirm"), _dismiss)


func _skill_markup(raw: String) -> String:
	var text := raw
	if LocaleManager.get_locale().begins_with("en"):
		text = text.replace(". ", ".\n")
		text = text.replace("Tier 1", "[b][color=#205c3d]Tier 1[/color][/b]")
	else:
		text = text.replace("。", "。\n")
		text = text.replace("1 阶", "[b][color=#205c3d]1 阶[/color][/b]")
	text = text.replace("+5%", "[b][color=#205c3d]+5%[/color][/b]")
	return text.strip_edges()


func show_error(message: String, can_retry: bool) -> void:
	_phase = "error"
	_clear()
	SfxService.play(SfxService.CUE_UI_REJECT)
	_add_label(_t("召唤结果尚未确认", "Summon result unconfirmed"), 29)
	var detail := _add_label(message, 19)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if can_retry:
		_add_label(_t("重试同一抽不会重复扣钻", "Retrying this draw will not charge twice"), 16)
		_add_button(_t("重试同一抽", "Retry same draw"), _retry)
	_add_button(_t("返回", "Back"), _dismiss)


func _retry() -> void:
	_dismiss()
	summon_requested.emit()


func _clear() -> void:
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()


func _add_label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Tokens.SUMMON_DETAIL_INK)
	
	label.add_theme_constant_override("outline_size", 0)
	_content.add_child(label)
	return label


func _add_button(value: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(220, 51)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.add_theme_stylebox_override("normal", Tokens.panel_box(Tokens.SUMMON_GLASS, Tokens.GOLD_EDGE, 8))
	button.add_theme_stylebox_override("hover", Tokens.panel_box(Tokens.SUMMON_GLASS_HOVER, Tokens.GOLD_HOVER, 8))
	button.add_theme_stylebox_override("pressed", Tokens.panel_box(Tokens.SUMMON_GLASS, Tokens.GOLD_PRESSED, 8))
	button.add_theme_color_override("font_color", Tokens.SUMMON_DETAIL_INK)
	button.add_theme_color_override("font_hover_color", Tokens.SUMMON_DETAIL_INK)
	button.add_theme_constant_override("outline_size", 0)
	button.add_theme_font_size_override("font_size", 20)
	button.pressed.connect(callback)
	_content.add_child(button)


func _pop(art: Control) -> void:
	if Tokens.reduced_motion():
		return
	art.pivot_offset = Vector2(122, 102)
	art.scale = Vector2(0.5, 0.5)
	art.modulate.a = 0.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(art, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(art, "modulate:a", 1.0, 0.26)


func _dismiss() -> void:
	dismissed.emit()
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_dismiss()
		get_viewport().set_input_as_handled()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
