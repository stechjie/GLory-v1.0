extends Control

signal claimed(go_prep: bool)
signal revealed()

const Currency := preload("res://scripts/account/Currency.gd")
const UnitCollection := preload("res://scripts/account/UnitCollection.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
# 11.11 羊皮纸风：浅色羊皮纸上的字色（原来是给深色面板配的浅色字）
const GOLD := Color("8a4b12")
const CREAM := Color("4a2c14")
const MUTED := Color("7a5634")
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const UiJuice := preload("res://ui/theme/UiJuice.gd")
const CHEST_CLOSED := preload("res://assets/ui/parchment_kit/chest_closed.png")
const CHEST_OPEN := preload("res://assets/ui/parchment_kit/chest_open.png")


class BurstEffect extends Control:
	var elapsed := 1.0
	var lifetime := 0.7
	var origin := Vector2.ZERO
	var strength := 1.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(false)

	func play_at(point: Vector2, power: float = 1.0) -> void:
		origin = point
		strength = power
		elapsed = 0.0
		set_process(true)
		queue_redraw()

	func _process(delta: float) -> void:
		elapsed += delta
		queue_redraw()
		if elapsed >= lifetime:
			set_process(false)

	func _draw() -> void:
		if elapsed >= lifetime:
			return
		var phase := elapsed / lifetime
		var fade := pow(1.0 - phase, 2.0)
		var radius := (24.0 + phase * 205.0) * strength
		draw_circle(origin, (64.0 - phase * 38.0) * strength,
			Color(1.0, 0.87, 0.45, 0.42 * fade))
		draw_arc(origin, radius, 0.0, TAU, 56,
			Color(1.0, 0.91, 0.57, 0.9 * fade), 7.0 * strength, true)
		for index in range(16):
			var angle := TAU * float(index) / 16.0 + 0.12
			var direction := Vector2.from_angle(angle)
			var inner := origin + direction * radius * 0.42
			var outer := origin + direction * radius * (0.9 + float(index % 3) * 0.11)
			draw_line(inner, outer, Color(1.0, 0.85, 0.44, 0.72 * fade),
				(2.0 if index % 2 == 0 else 1.0) * strength, true)
			draw_circle(outer, (3.0 + float(index % 3)) * strength,
				Color(1.0, 0.97, 0.71, fade))

var _levels: Array = []
var _rewards: Array = []
var _prep_prompt := false
var _compact := false
var _revealed := false
var _cards: Array[Button] = []
var _burst: BurstEffect
var _reward_scroll: ScrollContainer
var _reveal_center: CenterContainer
var _reveal_button: Button
var _grant_note: Label
var _action_buttons: HBoxContainer
# 揭晓前摆在中间的宝箱；揭晓时在原地开箱、冒光、淡出（纯表现层，见 _open_chest）
var _chest: TextureRect


func tutorial_reveal_target() -> Control:
	return _reveal_button


func tutorial_claim_target() -> Control:
	if _action_buttons == null or _action_buttons.get_child_count() == 0:
		return null
	return _action_buttons.get_child(0) as Control


func configure(levels: Array, rewards: Array) -> void:
	_levels = levels.duplicate()
	_rewards = rewards.duplicate(true)
	for raw in _rewards:
		if typeof(raw) == TYPE_DICTIONARY and bool(raw.get("prep_prompt", false)):
			_prep_prompt = true


func _ready() -> void:
	_compact = get_viewport_rect().size.y < 800
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var entries := _flatten_rewards()
	var columns := mini(3, maxi(1, entries.size()))
	var panel_width := mini(960, maxi(760 if _prep_prompt else 720,
		columns * 250 + 90))
	var frame := PanelContainer.new()
	frame.custom_minimum_size.x = panel_width
	frame.add_theme_stylebox_override("panel", Kit.box("panel",
		Vector4(64, 40, 64, 30) if _compact else Vector4(70, 48, 70, 36)))
	center.add_child(frame)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	frame.add_child(column)
	var ornament := _label("✦    ✧    ✦", 24, GOLD)
	ornament.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(ornament)
	var heading := Kit.title_banner(_t("等级提升", "LEVEL UP"), 70.0, 28)
	column.add_child(heading)
	var reached := 1
	for raw in _levels:
		reached = maxi(reached, int(raw))
	var level := _label("Lv %d" % reached, 62, CREAM)
	level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(level)
	column.add_child(Kit.separator(24.0))
	var subtitle_text := _t("获得 %d 件奖励" % entries.size(),
		"%d NEW REWARDS" % entries.size())
	if entries.size() > 3:
		subtitle_text += _t(" · 向下滑动查看全部", " · SCROLL FOR MORE")
	var subtitle := _label(subtitle_text, 20, MUTED)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(subtitle)
	var stage := Control.new()
	stage.custom_minimum_size.y = (242 if _compact else 282) if entries.size() <= 3 else (
		300 if _compact else 360)
	column.add_child(stage)
	_reward_scroll = ScrollContainer.new()
	_reward_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reward_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_reward_scroll.visible = false
	stage.add_child(_reward_scroll)
	var rewards_center := CenterContainer.new()
	rewards_center.custom_minimum_size.x = panel_width - 52
	rewards_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reward_scroll.add_child(rewards_center)
	var rewards_grid := GridContainer.new()
	rewards_grid.columns = columns
	rewards_grid.add_theme_constant_override("h_separation", 14)
	rewards_grid.add_theme_constant_override("v_separation", 12)
	rewards_center.add_child(rewards_grid)
	for entry in entries:
		var card := _reward_card(entry)
		rewards_grid.add_child(card)
		_cards.append(card)
	_burst = BurstEffect.new()
	_burst.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(_burst)
	_reveal_center = CenterContainer.new()
	_reveal_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_reveal_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(_reveal_center)
	var reveal_column := VBoxContainer.new()
	reveal_column.alignment = BoxContainer.ALIGNMENT_CENTER
	reveal_column.add_theme_constant_override("separation", 15)
	_reveal_center.add_child(reveal_column)
	# 关着的宝箱，轻轻上下浮动，提示「点我」
	var chest_holder := Control.new()
	chest_holder.custom_minimum_size = Vector2(170, 120 if _compact else 146)
	chest_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reveal_column.add_child(chest_holder)
	_chest = TextureRect.new()
	_chest.texture = CHEST_CLOSED
	_chest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_chest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_chest.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_chest.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chest_holder.add_child(_chest)
	var bob := _chest.create_tween().set_loops()
	bob.tween_property(_chest, "position:y", -6.0, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	bob.tween_property(_chest, "position:y", 0.0, 0.9).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_reveal_button = _button(_t("点击揭晓奖励", "REVEAL REWARDS"), true)
	_reveal_button.custom_minimum_size = Vector2(300, 72)
	_reveal_button.pressed.connect(_reveal_rewards)
	reveal_column.add_child(_reveal_button)
	var reveal_hint := _label(_t("奖励已到账，点亮你的成长时刻",
		"Already granted · Reveal your rewards"), 17, MUTED)
	reveal_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reveal_column.add_child(reveal_hint)
	_grant_note = _label(_t("奖励已自动存入账号", "Rewards added to your account"), 17, MUTED)
	_grant_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_grant_note)
	if _prep_prompt:
		var hint := _label(_t("神族已集齐并自动加入备战阵容，去看看吧！",
			"Divine roster complete and added to Prep. Take a look!"), 18, GOLD)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		column.add_child(hint)
	_action_buttons = HBoxContainer.new()
	_action_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_action_buttons.add_theme_constant_override("separation", 13)
	_action_buttons.visible = false
	column.add_child(_action_buttons)
	if _prep_prompt:
		var later := _button(_t("稍后再看", "LATER"), false)
		later.pressed.connect(func() -> void: claimed.emit(false))
		_action_buttons.add_child(later)
		var prep := _button(_t("前往备战", "GO TO PREP"), true)
		prep.pressed.connect(func() -> void: claimed.emit(true))
		_action_buttons.add_child(prep)
	else:
		var claim := _button(_t("收下奖励", "CONTINUE"), true)
		claim.pressed.connect(func() -> void: claimed.emit(false))
		_action_buttons.add_child(claim)
	_reveal_button.grab_focus.call_deferred()
	UiJuice.pop_in([frame], 0.0, 0.0, 0.88)


func _reveal_rewards() -> void:
	if _revealed:
		return
	_revealed = true
	# 揭晓区（宝箱 + 按钮）不立刻整块藏起来：按钮和提示先藏，宝箱在原地开完再收（_open_chest）
	_reveal_button.hide()
	_open_chest()
	_reward_scroll.show()
	_action_buttons.show()
	_burst.play_at(_burst.size * 0.5)
	SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN)
	_animate_reward_cards()
	revealed.emit()


# 开箱：宝箱从揭晓区搬到 stage 上方（揭晓区马上要隐藏），抖两下 → 换成打开的图 →
# 弹一下 + 冒光 → 淡出。状态切换（显示奖励 / 按钮、发 revealed）在 _reveal_rewards 里立刻完成，
# 这里只是叠在上面的表现，教学引导和检查脚本不用等它。
func _open_chest() -> void:
	if _chest == null or not is_instance_valid(_chest):
		_reveal_center.hide()
		return
	var chest := _chest
	chest.pivot_offset = chest.size * 0.5
	var tw := chest.create_tween()
	for i in 2:
		tw.tween_property(chest, "rotation", deg_to_rad(-7.0), 0.06)
		tw.tween_property(chest, "rotation", deg_to_rad(7.0), 0.08)
	tw.tween_property(chest, "rotation", 0.0, 0.05)
	tw.tween_callback(func() -> void:
		chest.texture = CHEST_OPEN
		chest.scale = Vector2.ONE * 1.18)
	tw.tween_property(chest, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.2)
	tw.tween_property(_reveal_center, "modulate:a", 0.0, 0.25)
	tw.tween_callback(func() -> void:
		_reveal_center.hide()
		_reveal_center.modulate.a = 1.0)


func _animate_reward_cards() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	for index in range(_cards.size()):
		var card := _cards[index]
		card.pivot_offset = card.size * 0.5
		card.scale = Vector2(0.72, 0.72)
		card.modulate.a = 0.0
		var delay := 0.38 + minf(float(index) * 0.09, 0.54)
		create_tween().tween_property(card, "modulate:a", 1.0, 0.24).set_delay(delay)
		create_tween().tween_property(card, "scale", Vector2.ONE, 0.4).set_delay(delay).set_trans(
			Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if not _action_buttons.get_children().is_empty():
		(_action_buttons.get_children()[0] as Button).grab_focus.call_deferred()


func _on_reward_card_pressed(card: Button) -> void:
	if not _revealed:
		return
	card.pivot_offset = card.size * 0.5
	card.scale = Vector2(0.94, 0.94)
	create_tween().tween_property(card, "scale", Vector2.ONE, 0.26).set_trans(
		Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_burst.play_at(card.get_global_rect().get_center() - _burst.global_position, 0.55)
	SfxService.play(SfxService.CUE_UI_CONFIRM)


func _flatten_rewards() -> Array:
	var out: Array = []
	for raw in _rewards:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var reward: Dictionary = raw
		var level := int(reward.get("level", 0))
		for unit_id in reward.get("units", []):
			var definition := UnitCollection.unit_def(str(unit_id))
			out.append({"level": level, "kind": "unit", "id": str(unit_id),
				"name": str(definition.get("name_en", unit_id)) if _english()
					else str(definition.get("name", unit_id))})
		if int(reward.get("coin", 0)) > 0:
			out.append({"level": level, "kind": "coin", "amount": int(reward["coin"])})
		if int(reward.get("diamond", 0)) > 0:
			out.append({"level": level, "kind": "diamond", "amount": int(reward["diamond"])})
	return out


func _reward_card(entry: Dictionary) -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(235, 228 if _compact else 264)
	var pad := Vector4(16, 20, 16, 16)
	card.add_theme_stylebox_override("normal", Kit.box("card", pad))
	card.add_theme_stylebox_override("hover", Kit.box("card", pad, Color(1.06, 1.04, 0.98)))
	card.add_theme_stylebox_override("pressed", Kit.box("card", pad, Color(0.92, 0.88, 0.82)))
	card.add_theme_stylebox_override("focus", Kit.box("card", pad, Color(1.0, 0.93, 0.76)))
	card.pressed.connect(_on_reward_card_pressed.bind(card))
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 5)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(column)
	# Button 不给子节点排版：内容列要自己铺满卡片（内缩一圈让开金框），图标和字才会居中
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 14)
	var kind := str(entry.get("kind", ""))
	var heading := _t("神族棋子", "DIVINE PIECE") if kind == "unit" else (
		_t("游戏币", "COINS") if kind == "coin" else _t("免费钻石", "DIAMONDS"))
	var tag := _label("Lv %d · %s" % [int(entry.get("level", 0)), heading], 16, GOLD)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(tag)
	var art_frame := PanelContainer.new()
	art_frame.custom_minimum_size = Vector2(128, 128) if _compact else Vector2(154, 154)
	art_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	art_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_frame.add_theme_stylebox_override("panel", Kit.box("slot", Vector4(10, 10, 10, 10)))
	column.add_child(art_frame)
	if kind == "unit":
		var portrait_path := "res://assets/ui/unit_portraits/%s.png" % str(entry.get("id", ""))
		if ResourceLoader.exists(portrait_path):
			var portrait := TextureRect.new()
			portrait.texture = load(portrait_path)
			portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
			art_frame.add_child(portrait)
	else:
		# 11.11：原来是文字符号「G」「◆」，换成全游戏统一的金币 / 钻石图标（Currency.icon）
		var symbol := TextureRect.new()
		symbol.texture = Currency.icon("diamond" if kind == "diamond" else "coin")
		symbol.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		symbol.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		symbol.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art_frame.add_child(symbol)
	var name := str(entry.get("name", "")) if kind == "unit" else "× %d" % int(entry.get("amount", 0))
	var value := _label(name, 23, CREAM)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(value)
	return card


func _button(title: String, primary: bool) -> Button:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size = Vector2(252, 64)
	Kit.style_plate(button, primary)
	button.add_theme_font_size_override("font_size", 24)
	return button


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
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
