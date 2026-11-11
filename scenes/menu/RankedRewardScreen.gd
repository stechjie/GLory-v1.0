extends Control

# The battle server decides the outcome. The account server decides the exact reward.
# This page never grants coins; it only displays the committed receipt.
signal confirmed
signal details_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const RankedTiers := preload("res://scenes/menu/RankedTiers.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
# 11.11 羊皮纸风：石台背景 + 羊皮纸面板 + 标题缎带（胜利横幅图到了再换）。
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const UiJuice := preload("res://ui/theme/UiJuice.gd")
const WIN_COLOR := Color("8a4b12")
const LOSE_COLOR := Color("5f5246")
const DRAW_COLOR := Color("3f5f6a")
const RANK_EMBLEM := preload("res://assets/ui/ranked/tier_4_crown.png")
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
var _banner: TextureRect
var _coin_icon: TextureRect


func _ready() -> void:
	theme = Kit.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_result = _local_result()
	_build()
	_reveal()
	if data.has("preview_receipt"):
		_apply_receipt(data.get("preview_receipt", {}))
	else:
		_poll_receipt()


func _coins_only() -> bool:
	return str(data.get("mode", "ranked")) in ["casual", "casual_normal"]

func _local_result() -> String:
	var outcome := int(data.get("outcome", 2))
	if outcome == 2:
		return "draw"
	return "win" if outcome == int(data.get("local_team", 0)) else "lose"


func _build() -> void:
	Kit.backdrop(self, "rooms_arena", 0.32)

	var scroll := TouchScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var frame := PanelContainer.new()
	_frame = frame
	frame.custom_minimum_size = Vector2(680, 0)
	frame.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(64, 40, 64, 31)))
	center.add_child(frame)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 7)
	frame.add_child(column)

	var eyebrow := _label(_t("休闲对局 · 金币结算", "CASUAL · COIN REWARD") if _coins_only() else _t("荣耀排位 · 对局结算", "GLORY RANKED · MATCH RESULT"), 16,
		Kit.INK_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	column.add_child(eyebrow)
	# 结果写在标题缎带上（胜利 / 平局 / 失败横幅出图后按结果换图）
	# 胜利 / 失败 / 平局三张横幅（第二批图），字色跟着横幅走
	_banner = Kit.result_banner(_result, _result_title(), 104.0, 40)
	_title = _banner.get_node("TitleText") as Label
	column.add_child(_banner)
	var subtitle := _label(_t("属于你的本场荣耀", "YOUR MATCH SUMMARY"), 16,
		Kit.INK_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	column.add_child(subtitle)

	var emblem_area := Control.new()
	emblem_area.custom_minimum_size = Vector2(152, 126)
	var rank_column := column
	if _coins_only():
		column.add_child(emblem_area)
	else:
		var rank_row := HBoxContainer.new()
		rank_row.add_theme_constant_override("separation", 16)
		column.add_child(rank_row)
		rank_row.add_child(emblem_area)
		rank_column = VBoxContainer.new()
		rank_column.alignment = BoxContainer.ALIGNMENT_CENTER
		rank_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rank_column.add_theme_constant_override("separation", 7)
		rank_row.add_child(rank_column)
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
	emblem.texture = Currency.icon("coin") if _coins_only() else RANK_EMBLEM
	emblem.custom_minimum_size = Vector2(152, 126)
	emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emblem_center.add_child(emblem)
	_tier_label = _label(_t("正在确认段位…", "Verifying rank…"), 20,
		WIN_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	_tier_label.visible = not _coins_only()
	rank_column.add_child(_tier_label)

	var score_panel := PanelContainer.new()
	score_panel.add_theme_stylebox_override("panel", Kit.box("slot", Vector4(20, 12, 20, 12)))
	score_panel.visible = not _coins_only()
	rank_column.add_child(score_panel)
	var score_column := VBoxContainer.new()
	score_column.add_theme_constant_override("separation", 6)
	score_panel.add_child(score_column)
	_score = _label(_t("排位积分 · 正在确认", "RANK SCORE · VERIFYING"), 21,
		Kit.INK, HORIZONTAL_ALIGNMENT_CENTER)
	_score.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	score_column.add_child(_score)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 10)
	_progress.show_percentage = false
	_progress.max_value = 100
	_progress.value = 0
	# 槽和填充色走 Kit.theme()（深棕槽 + 金色）
	score_column.add_child(_progress)

	var reward_panel := PanelContainer.new()
	reward_panel.add_theme_stylebox_override("panel", Kit.box("slot", Vector4(22, 14, 22, 14)))
	column.add_child(reward_panel)
	var reward_column := VBoxContainer.new()
	reward_column.add_theme_constant_override("separation", 4)
	reward_panel.add_child(reward_column)
	reward_column.add_child(_label(_t("本场游戏币奖励", "MATCH COIN REWARD"), 17,
		Kit.INK_SOFT, HORIZONTAL_ALIGNMENT_CENTER))
	var amount_row := HBoxContainer.new()
	amount_row.alignment = BoxContainer.ALIGNMENT_CENTER
	amount_row.add_theme_constant_override("separation", 12)
	reward_column.add_child(amount_row)
	var coin := TextureRect.new()
	_coin_icon = coin
	coin.texture = Currency.icon("coin")
	coin.custom_minimum_size = Vector2(44, 44)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	amount_row.add_child(coin)
	_amount = _label("—", 34, WIN_COLOR)
	amount_row.add_child(_amount)
	_receipt_status = _label(_t("正在确认到账…", "Verifying your reward…"), 15,
		Kit.INK_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	_receipt_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reward_column.add_child(_receipt_status)
	_balance = _label("", 14, Kit.INK_SOFT, HORIZONTAL_ALIGNMENT_CENTER)
	reward_column.add_child(_balance)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 16)
	column.add_child(actions)
	# 10.10 bug 第 14 条：排位对局结束的结算页**去掉「确认并返回大厅」**，
	# 只留「查看详细战况」—— actions 是 ALIGNMENT_CENTER，单独一个按钮即居中。
	#
	# ⚠ 不能无条件删掉「确认」：没有详细战况时（show_details=false）这张页面
	#   就一个出口都没有，玩家被卡死在结算页。所以「确认」只在**拿不到详细战况**
	#   时兜底显示；正常情况下出口是 查看详细战况 → 结算面板的「返回队伍 / 返回主菜单」。
	var has_details := bool(data.get("show_details", false)) and not _coins_only()
	_details = ACTION_BUTTON.instantiate()
	_details.text = _t("查看详细战况", "Match details")
	_details.custom_minimum_size = Vector2(220, 52)
	_details.visible = has_details
	_details.disabled = true
	_details.pressed.connect(func() -> void: details_requested.emit())
	Kit.style_plate(_details, true)
	actions.add_child(_details)
	_confirm = ACTION_BUTTON.instantiate()
	_confirm.text = _t("继续", "Continue") if _coins_only() else _t("确认并返回大厅", "Confirm and return")
	_confirm.custom_minimum_size = Vector2(260, 52)
	_confirm.disabled = true
	_confirm.visible = not has_details
	_confirm.pressed.connect(func() -> void: confirmed.emit())
	Kit.style_plate(_confirm, true)
	actions.add_child(_confirm)
	_retry = ACTION_BUTTON.instantiate()
	_retry.text = _t("重试查询", "Retry")
	_retry.custom_minimum_size = Vector2(160, 44)
	_retry.visible = false
	_retry.pressed.connect(_poll_receipt)
	Kit.style_plate(_retry, false)
	actions.add_child(_retry)


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
	Kit.bold_label(label)
	return label


func _reveal() -> void:
	if Tokens.reduced_motion():
		return
	_frame.modulate.a = 0.0
	# 面板弹出；标题缎带稍后从大到小「砸」下来（赢了砸得更有力）
	UiJuice.pop_in([_frame], 0.0, 0.0, 0.88)
	_banner.pivot_offset = _banner.custom_minimum_size * 0.5
	_banner.scale = Vector2.ONE * (1.6 if _result == "win" else 1.2)
	_banner.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_interval(0.18)
	tween.tween_property(_banner, "modulate:a", 1.0, 0.12)
	tween.parallel().tween_property(_banner, "scale", Vector2.ONE, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


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
	Kit.set_result_banner(_banner, _result)
	_amount.text = "+%d" % coins
	_receipt_status.text = _t("已加入账户钱包", "Added to your account wallet")
	_receipt_status.add_theme_color_override("font_color", WIN_COLOR)
	if not _coins_only():
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
		create_tween().tween_property(_amount, "scale", Vector2.ONE, Tokens.motion(0.35)).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		if coins > 0:
			_fly_coins.call_deferred(mini(coins, 10))


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
	_receipt_status.add_theme_color_override("font_color", Kit.INK_SOFT)
	_confirm.disabled = false
	_details.disabled = false
	_retry.visible = true


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh


# 金币从徽章那里一颗颗飞进奖励栏的金币图标，落下时图标弹一下。纯表现，不碰数字。
func _fly_coins(count: int) -> void:
	if _emblem == null or _coin_icon == null or not is_inside_tree():
		return
	var from := _emblem.get_global_rect().get_center()
	var to := _coin_icon.get_global_rect().get_center()
	for i in count:
		var c := TextureRect.new()
		c.texture = Currency.icon("coin")
		c.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		c.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		c.size = Vector2(34, 34)
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.top_level = true
		add_child(c)
		var start := from + Vector2(randf_range(-40, 40), randf_range(-24, 24)) - c.size * 0.5
		c.global_position = start
		c.modulate.a = 0.0
		var mid := start.lerp(to - c.size * 0.5, 0.5) + Vector2(randf_range(-60, 60), -70)
		var tw := c.create_tween()
		tw.tween_interval(0.06 * i)
		tw.tween_property(c, "modulate:a", 1.0, 0.08)
		tw.tween_method(func(t: float) -> void:
			# 二次贝塞尔：先往上抛再落进图标
			var a := start.lerp(mid, t)
			var b := mid.lerp(to - c.size * 0.5, t)
			c.global_position = a.lerp(b, t), 0.0, 1.0, 0.45).set_ease(Tween.EASE_IN)
		tw.tween_callback(func() -> void:
			_coin_icon.pivot_offset = _coin_icon.size * 0.5
			var bump := _coin_icon.create_tween()
			bump.tween_property(_coin_icon, "scale", Vector2.ONE * 1.25, 0.06)
			bump.tween_property(_coin_icon, "scale", Vector2.ONE, 0.14))
		tw.tween_callback(c.queue_free)
