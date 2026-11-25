extends Control

# Forest summon view. The altar animation never determines a reward.
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Currency := preload("res://scripts/account/Currency.gd")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const PetDrawReveal := preload("res://scenes/menu/PetDrawReveal.gd")
const PetSummonFx := preload("res://scenes/menu/PetSummonFx.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const MusicService := preload("res://ui/services/MusicService.gd")
# 打开弹窗前在放的那首（关窗时接回去）。
var _music_before := ""
const FOREST := preload("res://assets/ui/page_backgrounds/pets_courtyard.png")
# 11.11 重做成「宠物蛋孵化」：草窝上一颗蛋，召唤时蛋晃、出裂纹，结果到了破壳发光再弹出结果框。
# 动画纯表现，奖励只看服务器回执（同原来的能量球）。羊皮纸部件见 ui/theme/ParchmentKit.gd。
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const EGG_DIR := "res://assets/ui/parchment_kit/"
const EGG_RECT := Rect2(712, 168, 176, 211)
const NEST_RECT := Rect2(640, 318, 320, 151)
# 左栏的奖池宠物卡（11-25 起三只）。
const POOL_PETS := ["pet_squirrel", "pet_tiger", "pet_monkey"]
const PET_CARD_SIZE := Vector2(260, 158)
const PET_ART_SIZE := Vector2(210, 113)

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
var _egg: TextureRect
var _crack: TextureRect
var _shell_top: TextureRect
var _shell_bottom: TextureRect
var _egg_glow: TextureRect
var _wobble: Tween


func _ready() -> void:
	theme = Kit.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_fit_canvas()
	_load_state()
	# 11.16：抽宠物独立 BGM；关掉弹窗接回底下那页的歌、原来的位置。
	_music_before = MusicService.enter_overlay(MusicService.PET_DRAW_MUSIC)


func _exit_tree() -> void:
	MusicService.leave_overlay(MusicService.PET_DRAW_MUSIC, _music_before)


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
	_fx.show_orb = false
	_rect(_fx, 0, 0, 1600, 720)
	_canvas.add_child(_fx)
	_build_egg()
	var title := Kit.title_banner(_t("森林伙伴召唤", "Companion Summon"), 76.0, 22)
	title.position = Vector2(800 - title.custom_minimum_size.x * 0.5, 4)
	title.size = title.custom_minimum_size
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
	var close := Kit.close_button(_close, 52.0)
	_rect(close, 1530, 15, 52, 52)
	_canvas.add_child(close)
	_summon = _button(_t("召唤 · 75 钻石", "Summon · 75 gems"), Vector2(300, 72))
	Kit.style_plate(_summon, true)
	_summon.add_theme_font_size_override("font_size", 27)
	_rect(_summon, 650, 486, 300, 72)
	_summon.pressed.connect(_begin_draw)
	_canvas.add_child(_summon)
	_plate(_canvas, Rect2(80, 159, 355, 44),
		_t("召唤伙伴 · 点击查看技能", "Companions · tap for skills"), 16)
	# 奖池里的宠物，顺序与 backend/app/pet_draw.py 的 PET_IDS 一致（backend/tests/test_pet_draw.py 钉着）。
	# 11-25 加了猴子：三张卡竖排在左栏，卡高 170 -> 158、间距 11 -> 10，最后一张底边对齐规则框底（702）。
	for i in POOL_PETS.size():
		_pet_card(str(POOL_PETS[i]), 80, 208 + i * (PET_CARD_SIZE.y + 10))
	_plate(_canvas, Rect2(1205, 176, 245, 44), _t("森林能量", "Forest energy"), 17)
	_energy_label = _label("", 18)
	_energy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rect(_energy_label, 1220, 558, 320, 40)
	_canvas.add_child(_energy_label)
	_rules = PanelContainer.new()
	_rules.add_theme_stylebox_override("panel", Kit.box("card", Vector4(44, 32, 44, 25)))
	_rect(_rules, 461, 567, 678, 135)
	_canvas.add_child(_rules)
	# 11-20 体验卡：没抽中时三选一（backend/app/trial.py 的 MISS_OUTCOMES / DAY_WEIGHTS，
	# backend/tests/test_pet_draw.py 钉着两边一致）。字号 16 -> 14：多了一行，规则框高度不变。
	var rule_text := _label(_t(
		"规则  ·  每抽消耗 75 钻石，普通抽中宠物概率 10%，第 10 抽必得未拥有宠物。提前抽中继续积累能量，保底命中才清零。\n未中宠物时：只得 100 金币 60% / 只得宠物体验卡 30% / 两样都得 10%；体验卡天数 1天 60%、3天 30%、7天 10%（卡放进背包）。",
		"Rules · 75 gems per draw. 10% pet chance; draw 10 guarantees an unowned pet. Early pets keep energy; only the guarantee resets it.\nNo pet: 100 coins only 60% / pet trial card only 30% / both 10%; card length 1d 60%, 3d 30%, 7d 10% (cards go to your Bag)."), 14)
	rule_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rule_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rule_text.add_theme_color_override("font_color", Tokens.SUMMON_DETAIL_INK)
	rule_text.add_theme_constant_override("outline_size", 0)
	_rules.add_child(rule_text)
	_notice = _label(_t("正在读取奖池…", "Loading summon pool…"), 17)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_rect(_notice, 520, 461, 560, 25)
	_canvas.add_child(_notice)
	_retry = _button(_t("重试读取", "Retry loading"), Vector2(170, 50))
	_rect(_retry, 965, 497, 170, 50)
	Kit.style_plate(_retry, false)
	_retry.pressed.connect(_load_state)
	_canvas.add_child(_retry)
	_refresh_ui()


func _pet_card(pet_id: String, x: float, y: float) -> void:
	var card := _button("", PET_CARD_SIZE)
	card.name = "Card_%s" % pet_id
	_rect(card, x, y, PET_CARD_SIZE.x, PET_CARD_SIZE.y)
	card.accessibility_name = _t("查看%s介绍", "View %s details") % PetService.display_name(pet_id)
	card.pressed.connect(_show_pet_info.bind(pet_id))
	_canvas.add_child(card)
	var art := PetPreview.build_illustration(pet_id, PET_ART_SIZE)
	_rect(art, 25, 2, PET_ART_SIZE.x, PET_ART_SIZE.y)
	card.add_child(art)
	_plate(card, Rect2(7, PET_ART_SIZE.y - 2, 246, 42), PetService.display_name(pet_id), 17)
	var owned_plate := Kit.gold_badge(_t("已拥有", "Owned"))
	owned_plate.position = Vector2(14, 19)
	card.add_child(owned_plate)
	_portraits[pet_id] = {"art": art, "owned": owned_plate, "button": card}


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
		(portrait.owned as Control).visible = owned
		(portrait.button as Button).add_theme_stylebox_override("normal", Kit.box("card", Vector4(8, 8, 8, 8),
			Color(0.78, 0.74, 0.68) if owned else Color.WHITE))
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
	_egg_wobble()
	_notice.text = _t("蛋在晃动…", "The egg is stirring…")
	if _pending_draw_id.is_empty():
		_pending_draw_id = AccountManager.new_client_order_id()
	var started := Time.get_ticks_msec()
	var result: Dictionary = await AccountManager.draw_pet(_pending_draw_id)
	if not is_inside_tree():
		return
	# 蛋至少晃 1.4 秒再出结果（纯表现）
	var remaining := Tokens.motion(1.4) - float(Time.get_ticks_msec() - started) / 1000.0
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
		_egg_reset()
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
	await _egg_hatch()
	if not is_inside_tree():
		return
	_open_reveal()
	_reveal.call("show_reward", pet_id, coin_reward, replayed,
		str(receipt.get("trial_target", "")), int(receipt.get("trial_days", 0)))
	_refresh_ui()
	draw_finished.emit()


func _show_pet_info(pet_id: String) -> void:
	if _busy or _reveal != null:
		return
	_open_reveal()
	_reveal.call("show_pet_info", pet_id, _owned.has(pet_id), PlayerProfile.active_pet == pet_id)
	_refresh_ui()


func _use_pool_pet(pet_id: String, action: Button) -> void:
	if _busy or not _owned.has(pet_id) or PlayerProfile.active_pet == pet_id:
		return
	_busy = true
	action.disabled = true
	if not PlayerProfile.is_owned(pet_id):
		await PlayerProfile.refresh_pets()
	if not is_inside_tree() or is_queued_for_deletion():
		return
	var ok := PlayerProfile.active_pet == pet_id
	if not ok:
		ok = await PlayerProfile.set_active(pet_id)
	if not is_inside_tree() or is_queued_for_deletion():
		return
	_busy = false
	if is_instance_valid(action) and not action.is_queued_for_deletion():
		action.text = _t("使用中", "In use") if ok else _t("使用", "Use")
		action.disabled = ok
	if not ok:
		preload("res://ui/components/GloryToast.gd").show_text(_t("宠物出战设置失败，请重试", "Could not equip pet. Please try again."))
	_refresh_ui()


func _open_reveal() -> void:
	_reveal = PetDrawReveal.new()
	_reveal.connect("summon_requested", _commit_draw)
	_reveal.connect("pet_use_requested", _use_pool_pet)
	_reveal.connect("dismissed", _on_reveal_dismissed)
	_canvas.add_child(_reveal)
	_rect(_reveal, 0, 0, 1600, 720)


func _on_reveal_dismissed() -> void:
	_reveal = null
	_egg_reset()
	_refresh_ui()


# --- 宠物蛋 -------------------------------------------------------------------

func _egg_tex(name: String) -> TextureRect:
	var r := TextureRect.new()
	r.texture = load(EGG_DIR + name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _build_egg() -> void:
	# 破壳那一下的光：径向渐变，平时透明
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.97, 0.75, 1.0))
	grad.set_color(1, Color(1.0, 0.85, 0.4, 0.0))
	var glow_tex := GradientTexture2D.new()
	glow_tex.fill = GradientTexture2D.FILL_RADIAL
	glow_tex.fill_from = Vector2(0.5, 0.5)
	glow_tex.fill_to = Vector2(1.0, 0.5)
	glow_tex.gradient = grad
	_egg_glow = TextureRect.new()
	_egg_glow.texture = glow_tex
	_egg_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_egg_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect(_egg_glow, EGG_RECT.get_center().x - 220, EGG_RECT.get_center().y - 220, 440, 440)
	_egg_glow.pivot_offset = Vector2(220, 220)
	_egg_glow.modulate.a = 0.0
	_canvas.add_child(_egg_glow)
	var nest := _egg_tex("egg_nest.png")
	_rect(nest, NEST_RECT.position.x, NEST_RECT.position.y, NEST_RECT.size.x, NEST_RECT.size.y)
	_canvas.add_child(nest)
	_egg = _egg_tex("egg_closed.png")
	_crack = _egg_tex("egg_crack.png")
	_shell_bottom = _egg_tex("egg_shell_bottom.png")
	_shell_top = _egg_tex("egg_shell_top.png")
	for r in [_egg, _shell_bottom, _shell_top]:
		_rect(r, EGG_RECT.position.x, EGG_RECT.position.y, EGG_RECT.size.x, EGG_RECT.size.y)
		r.pivot_offset = Vector2(EGG_RECT.size.x * 0.5, EGG_RECT.size.y * 0.92)
		_canvas.add_child(r)
	# 裂纹贴在蛋上，跟着蛋一起晃
	_crack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_egg.add_child(_crack)
	_egg_reset()


func _egg_idle() -> void:
	if _wobble != null and _wobble.is_valid():
		_wobble.kill()
	# 平时每隔几秒轻轻歪一下，告诉玩家「里面有东西」
	_wobble = _egg.create_tween().set_loops()
	_wobble.tween_interval(2.4)
	_wobble.tween_property(_egg, "rotation", deg_to_rad(-4.0), 0.12)
	_wobble.tween_property(_egg, "rotation", deg_to_rad(4.0), 0.16)
	_wobble.tween_property(_egg, "rotation", 0.0, 0.12)


func _egg_wobble() -> void:
	if _wobble != null and _wobble.is_valid():
		_wobble.kill()
	_wobble = _egg.create_tween()
	for i in 6:
		var amp := 5.0 + float(i) * 2.2
		_wobble.tween_property(_egg, "rotation", deg_to_rad(-amp), 0.07)
		_wobble.tween_property(_egg, "rotation", deg_to_rad(amp), 0.09)
		if i == 2:
			_wobble.tween_callback(func() -> void: _crack.visible = true)
	_wobble.tween_property(_egg, "rotation", 0.0, 0.06)
	_wobble.set_loops()


func _egg_hatch() -> void:
	if _wobble != null and _wobble.is_valid():
		_wobble.kill()
	if Tokens.reduced_motion():
		return
	_egg.visible = false
	_shell_top.visible = true
	_shell_bottom.visible = true
	_shell_top.position = EGG_RECT.position
	var tw := create_tween()
	tw.tween_property(_egg_glow, "modulate:a", 1.0, 0.12)
	tw.parallel().tween_property(_egg_glow, "scale", Vector2.ONE * 1.25, 0.4).from(Vector2.ONE * 0.4)
	tw.parallel().tween_property(_shell_top, "position", EGG_RECT.position + Vector2(-30, -110), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_shell_top, "rotation", deg_to_rad(-28.0), 0.45)
	tw.parallel().tween_property(_shell_top, "modulate:a", 0.0, 0.45).set_delay(0.15)
	tw.tween_property(_egg_glow, "modulate:a", 0.0, 0.3)
	await tw.finished


func _egg_reset() -> void:
	if _egg == null:
		return
	_egg.visible = true
	_egg.rotation = 0.0
	_crack.visible = false
	_shell_top.visible = false
	_shell_bottom.visible = false
	_shell_top.modulate.a = 1.0
	_shell_top.rotation = 0.0
	_egg_glow.modulate.a = 0.0
	if not Tokens.reduced_motion() and is_inside_tree():
		_egg.scale = Vector2.ONE * 0.6
		create_tween().tween_property(_egg, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_egg_idle()


func _close() -> void:
	if not _busy and _reveal == null:
		queue_free()


func _rect(node: Control, x: float, y: float, w: float, h: float) -> void:
	node.position = Vector2(x, y)
	node.size = Vector2(w, h)


func _plate(parent: Control, bounds: Rect2, text: String, font_size: int) -> void:
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", Kit.box("plate", Vector4(28, 12, 28, 8)))
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var caption := _label(text, font_size)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.add_theme_color_override("font_color", Kit.INK)
	caption.add_theme_constant_override("outline_size", 0)
	plate.add_child(caption)
	_rect(plate, bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y)
	parent.add_child(plate)


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
	Kit.style_plate(button, false)
	button.add_theme_font_size_override("font_size", 20)
	return button


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
