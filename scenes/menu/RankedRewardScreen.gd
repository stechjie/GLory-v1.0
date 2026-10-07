extends Control

# The battle server decides the outcome. The account server decides the exact reward.
# This page never grants coins; it only displays the committed receipt.
signal confirmed
signal details_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const RankedTiers := preload("res://scenes/menu/RankedTiers.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const BACKGROUND := preload("res://assets/ui/main_menu_live/background.png")
const RANK_EMBLEM := preload("res://assets/ui/ranked/reward_crest.png")
const Currency := preload("res://scripts/account/Currency.gd")
const WARM_GLOW := preload("res://assets/ui/main_menu_live/glow_warm.png")

const POLL_ATTEMPTS := 12
const POLL_INTERVAL := 1.25
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")

var data: Dictionary = {}
var _result := "win"
var _title: Label
var _tier_label: Label
var _emblem: TextureRect
var _amount: Label
var _receipt_status: Label
var _score: Label
var _balance: Label
var _progress: ProgressBar
var _confirm: Button
var _details: Button
var _retry: Button
var _frame: Control
var _polling := false


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result = _local_result()
	_build()
	_reveal()
	if data.has("preview_receipt"):
		_apply_receipt(data.get("preview_receipt", {}))
	else:
		_poll_receipt()


func _local_result() -> String:
	var outcome := int(data.get("outcome", 2))
	if outcome == 2:
		return "draw"
	return "win" if outcome == int(data.get("local_team", 0)) else "lose"


func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = BACKGROUND
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var shade := ColorRect.new()
	shade.color = Color(Tokens.BG_DEEP.r, Tokens.BG_DEEP.g, Tokens.BG_DEEP.b, 0.88)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var scroll := TouchScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.custom_minimum_size = Vector2(0, 690)
	scroll.add_child(center)
	var frame := PanelContainer.new()
	_frame = frame
	frame.custom_minimum_size = Vector2(680, 0)
	frame.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.INK_PANEL, Tokens.GOLD_EDGE, 24))
	center.add_child(frame)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	frame.add_child(column)

	var eyebrow := _label(_t("荣耀排位 · 对局结算", "GLORY RANKED · MATCH RESULT"), 16,
		Tokens.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	column.add_child(eyebrow)
	var title_color := Tokens.GOLD_HOVER if _result == "win" else (
		Tokens.CYAN if _result == "draw" else Tokens.TEXT_PRIMARY)
	var title := _label(_result_title(), 54, title_color, HORIZONTAL_ALIGNMENT_CENTER)
	title.name = "ResultTitle"
	_title = title
	column.add_child(title)
	var subtitle := _label(_t("属于你的本场荣耀", "YOUR MATCH SUMMARY"), 16,
		Tokens.TEXT_SECONDARY, HORIZONTAL_ALIGNMENT_CENTER)
	column.add_child(subtitle)

	var emblem_area := Control.new()
	emblem_area.custom_minimum_size = Vector2(0, 174)
	column.add_child(emblem_area)
	var glow := TextureRect.new()
	glow.texture = WARM_GLOW
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glow.modulate.a = 0.65 if _result == "win" else 0.30
	emblem_area.add_child(glow)
	var emblem_center := CenterContainer.new()
	emblem_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	emblem_area.add_child(emblem_center)
	var emblem := TextureRect.new()
	_emblem = emblem
	emblem.texture = RANK_EMBLEM
	emblem.custom_minimum_size = Vector2(190, 174)
	emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emblem_center.add_child(emblem)
	_tier_label = _label(_t("正在确认段位…", "Verifying rank…"), 20,
		Tokens.GOLD_HOVER, HORIZONTAL_ALIGNMENT_CENTER)
	column.add_child(_tier_label)

	var score_panel := PanelContainer.new()
	score_panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE, Tokens.BORDER, 14))
	column.add_child(score_panel)
	var score_column := VBoxContainer.new()
	score_column.add_theme_constant_override("separation", 6)
	score_panel.add_child(score_column)
	_score = _label(_t("排位积分 · 正在确认", "RANK SCORE · VERIFYING"), 21,
		Tokens.TEXT_PRIMARY, HORIZONTAL_ALIGNMENT_CENTER)
	score_column.add_child(_score)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 10)
	_progress.show_percentage = false
	_progress.max_value = 100
	_progress.value = 0
	_progress.add_theme_stylebox_override("background", Tokens.flat_box(
		Tokens.BG_DEEP, Tokens.BORDER, 0, 5))
	_progress.add_theme_stylebox_override("fill", Tokens.flat_box(
		Tokens.GOLD, Tokens.GOLD_EDGE, 0, 5))
	score_column.add_child(_progress)

	var reward_panel := PanelContainer.new()
	reward_panel.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SURFACE_RAISED, Tokens.GOLD_PRESSED, 18))
	column.add_child(reward_panel)
	var reward_column := VBoxContainer.new()
	reward_column.add_theme_constant_override("separation", 4)
	reward_panel.add_child(reward_column)
	reward_column.add_child(_label(_t("本场游戏币奖励", "MATCH COIN REWARD"), 17,
		Tokens.TEXT_SECONDARY, HORIZONTAL_ALIGNMENT_CENTER))
	var amount_row := HBoxContainer.new()
	amount_row.alignment = BoxContainer.ALIGNMENT_CENTER
	amount_row.add_theme_constant_override("separation", 12)
	reward_column.add_child(amount_row)
	var coin := TextureRect.new()
	coin.texture = Currency.icon("coin")
	coin.custom_minimum_size = Vector2(56, 56)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	amount_row.add_child(coin)
	_amount = _label("—", 42, Tokens.GOLD_HOVER)
	amount_row.add_child(_amount)
	_receipt_status = _label(_t("正在确认到账…", "Verifying your reward…"), 15,
		Tokens.CYAN, HORIZONTAL_ALIGNMENT_CENTER)
	reward_column.add_child(_receipt_status)
	_balance = _label("", 14, Tokens.TEXT_SECONDARY, HORIZONTAL_ALIGNMENT_CENTER)
	reward_column.add_child(_balance)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 16)
	column.add_child(actions)
	_details = ACTION_BUTTON.instantiate()
	_details.text = _t("查看详细战况", "Match details")
	_details.custom_minimum_size = Vector2(220, 52)
	_details.visible = bool(data.get("show_details", false))
	_details.disabled = true
	_details.pressed.connect(func() -> void: details_requested.emit())
	actions.add_child(_details)
	_confirm = ACTION_BUTTON.instantiate()
	_confirm.text = _t("确认并返回大厅", "Confirm and return")
	_confirm.custom_minimum_size = Vector2(260, 52)
	_confirm.disabled = true
	_confirm.pressed.connect(func() -> void: confirmed.emit())
	actions.add_child(_confirm)
	_retry = ACTION_BUTTON.instantiate()
	_retry.text = _t("重试查询", "Retry")
	_retry.custom_minimum_size = Vector2(160, 44)
	_retry.visible = false
	_retry.pressed.connect(_poll_receipt)
	column.add_child(_retry)


func _result_title() -> String:
	match _result:
		"win": return _t("胜利", "VICTORY")
		"draw": return _t("平局", "DRAW")
		_: return _t("虽败犹荣", "DEFEAT")


func _label(value: String, font_size: int, color: Color,
	align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = align
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _reveal() -> void:
	if Tokens.reduced_motion():
		return
	_frame.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(_frame, "modulate:a", 1.0, Tokens.motion(0.45))


func _poll_receipt() -> void:
	if _polling:
		return
	var match_uid := str(data.get("match_uid", ""))
	if match_uid.is_empty():
		_set_delayed()
		return
	_polling = true
	_retry.visible = false
	_receipt_status.text = _t("正在确认到账…", "Verifying your reward…")
	for attempt in POLL_ATTEMPTS:
		var response: Dictionary = await AccountManager.fetch_ranked_reward(match_uid)
		if not is_inside_tree():
			return
		if int(response.get("code", 0)) == 200:
			var body: Dictionary = response.get("body", {})
			if str(body.get("status", "")) == "settled":
				_polling = false
				_apply_receipt(body)
				return
		if attempt < POLL_ATTEMPTS - 1:
			await get_tree().create_timer(POLL_INTERVAL).timeout
			if not is_inside_tree():
				return
	_polling = false
	_set_delayed()


func _apply_receipt(receipt: Dictionary) -> void:
	if str(receipt.get("status", "")) != "settled":
		_set_delayed()
		return
	var coins := maxi(0, int(receipt.get("coin", 0)))
	_result = str(receipt.get("result", _result))
	_title.text = _result_title()
	_title.add_theme_color_override("font_color", Tokens.GOLD_HOVER if _result == "win" else (
		Tokens.CYAN if _result == "draw" else Tokens.TEXT_PRIMARY))
	_amount.text = "+%d" % coins
	_receipt_status.text = _t("已加入账户钱包", "Added to your account wallet")
	_receipt_status.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	var before := int(receipt.get("score_before", 0))
	var after := int(receipt.get("score_after", 0))
	var delta := after - before
	_score.text = _t("排位积分  %d → %d   (%+d)", "Rank score  %d → %d   (%+d)") % [before, after, delta]
	var tier_before := clampi(int(receipt.get("tier_before", 0)), 0, RankedTiers.BADGES.size() - 1)
	var tier_after := clampi(int(receipt.get("tier_after", 0)), 0, RankedTiers.BADGES.size() - 1)
	var span := int(receipt.get("tier_span", 0))
	_progress.value = 100.0 if span <= 0 else 100.0 * float(receipt.get("tier_progress", 0)) / float(span)
	_show_rank(tier_before, tier_after)
	_balance.text = _t("当前游戏币  %d", "Account coins  %d") % int(receipt.get("coin_balance_after", 0))
	_confirm.disabled = false
	_details.disabled = false
	_retry.visible = false
	if not Tokens.reduced_motion():
		_amount.pivot_offset = _amount.size * 0.5
		_amount.scale = Vector2(0.72, 0.72)
		create_tween().tween_property(_amount, "scale", Vector2.ONE, Tokens.motion(0.35))


func _show_rank(before: int, after: int) -> void:
	var rank_name := RankedTiers.name_of(after, LocaleManager.get_locale().begins_with("en"))
	if before == after or Tokens.reduced_motion():
		_emblem.texture = RankedTiers.badge_of(after)
		_tier_label.text = rank_name
		return
	_emblem.texture = RankedTiers.badge_of(before)
	_tier_label.text = (_t("晋级 · %s", "PROMOTED · %s") if after > before else
		_t("降至 · %s", "RANK DOWN · %s")) % rank_name
	var tween := create_tween()
	tween.tween_property(_emblem, "modulate:a", 0.0, Tokens.motion(0.20))
	tween.tween_callback(func() -> void: _emblem.texture = RankedTiers.badge_of(after))
	tween.tween_property(_emblem, "modulate:a", 1.0, Tokens.motion(0.30))


func _set_delayed() -> void:
	_receipt_status.text = _t("结算暂未确认，可稍后在钱包查看", "Settlement delayed; check your wallet later")
	_receipt_status.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_confirm.disabled = false
	_details.disabled = false
	_retry.visible = true


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
