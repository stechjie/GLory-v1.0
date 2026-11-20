extends Control

# 种族体验卡购买弹窗（商城「棋子」页「还差 X 游戏币」下面那颗按钮打开）。
#
#   体验暗族
#   1天   100金   [购买]
#   3天   200金   [已购买 · 下周一重置]
#   7天   300金   [购买]
#
# 规则在服务器（backend/app/trial.py）：每个账号、每个种族、每周 1/3/7 天各一次；买到的卡进背包。
# 买完换成「已购买」：[立刻使用] [关闭]。立刻使用 = 直接用这张卡，不用再去背包。
#
# 用法：
#   var dialog := RaceTrialDialog.new()
#   dialog.configure(race)
#   ModalStack.push(dialog, {"id": "race_trial", "owner": self, "dismiss_on_backdrop": true})
# 关闭由它自己 pop（id 固定为 MODAL_ID）。

signal wallet_changed(coin: int)
signal trial_used(race: String, expires_at: String)

const MODAL_ID := "race_trial"
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Card := preload("res://ui/components/TrialCardKit.gd")
const Currency := preload("res://scripts/account/Currency.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const SfxService := preload("res://ui/services/SfxService.gd")

var _race := ""
var _coin := -1
var _bought: Array = []
var _resets_at := ""
var _busy := false
# 每种天数一个待重试的操作号：断网后再点同一行，用的还是这个号，服务器只扣一次钱。
var _pending_ops: Dictionary = {}
var _box: VBoxContainer
var _status: Label


func configure(race: String) -> void:
	_race = race


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(560, 0)
	card.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(60, 44, 60, 36)))
	center.add_child(card)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", Tokens.GAP_M)
	card.add_child(_box)
	_render_loading()
	# 截图工具（tools/shop_bag_ui_capture.gd）进树后自己灌数据再画，不发网络请求。
	if has_meta("ui_capture_fixture"):
		return
	_load()


func _load() -> void:
	var offer: Dictionary = await AccountManager.fetch_race_trial(_race)
	var wallet: Dictionary = await AccountManager.fetch_wallet()
	if not is_inside_tree():
		return
	if int(wallet.get("code", 0)) / 100 == 2:
		_coin = int((wallet.get("body", {}) as Dictionary).get("coin", -1))
	if int(offer.get("code", 0)) / 100 != 2:
		_render_error(str(offer.get("error", Card.t("读取失败", "Could not load"))))
		return
	var body: Dictionary = offer.get("body", {})
	_bought = (body.get("bought", []) as Array).duplicate()
	_resets_at = str(body.get("resets_at", ""))
	_render_offer()


# --- 画面 ---------------------------------------------------------------------

func _clear() -> void:
	for child in _box.get_children():
		_box.remove_child(child)
		child.queue_free()


func _title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	label.add_theme_color_override("font_color", Color("8a4b12"))
	_box.add_child(label)


func _line(text: String, color: Color = Kit.INK, font_size := 0) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size if font_size > 0 else Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", color)
	_box.add_child(label)
	return label


func _button(text: String, primary: bool, cb: Callable) -> Button:
	var b: Button = ACTION_BUTTON.instantiate()
	b.text = text
	b.custom_minimum_size = Vector2(180, Tokens.BUTTON_HEIGHT)
	b.theme_type_variation = Theming.VARIATION_PRIMARY if primary else Theming.VARIATION_GHOST
	b.pressed.connect(cb)
	return b


func _button_row(buttons: Array) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", Tokens.GAP_L)
	for b in buttons:
		row.add_child(b)
	_box.add_child(row)


func _render_loading() -> void:
	_clear()
	_title(Card.t("体验%s", "Try %s") % Card.target_name("race", _race))
	_line(Card.t("正在读取…", "Loading…"), Kit.INK_SOFT)
	_button_row([_button(Card.t("关闭", "Close"), false, _close)])


func _render_error(message: String) -> void:
	_clear()
	_title(Card.t("体验%s", "Try %s") % Card.target_name("race", _race))
	_line(message, Color("a3271a"))
	_button_row([_button(Card.t("重试", "Retry"), true, func() -> void:
			_render_loading()
			_load()),
		_button(Card.t("关闭", "Close"), false, _close)])


func _render_offer() -> void:
	_clear()
	_title(Card.t("体验%s", "Try %s") % Card.target_name("race", _race))
	_line(Card.t("体验期间可以带这一族出战。买到的体验卡放进背包，点「使用」才开始计时。\n每个种族每周 1 / 3 / 7 天各能买一次，每周一 0 点（北京时间）重置。",
		"Take this race into battle while the trial lasts. Cards go to your Bag and start when used.\nEach length can be bought once per race per week; resets Monday 00:00 (UTC+8)."),
		Kit.INK_SOFT, Tokens.FONT_CAPTION)
	if _coin >= 0:
		_line(Card.t("游戏币：%s", "Coins: %s") % Currency.comma(_coin), Kit.INK, Tokens.FONT_CAPTION)
	for days in Card.DAYS:
		_box.add_child(_offer_row(int(days)))
	_status = _line("", Color("a3271a"), Tokens.FONT_CAPTION)
	_status.visible = false
	_button_row([_button(Card.t("关闭", "Close"), false, _close)])


func _offer_row(days: int) -> Control:
	var price := int(Card.PRICE.get(days, 0))
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel",
		Kit.box("list_row", Vector4(24, 6, 24, 6), Card.DAY_TINT.get(days, Color.WHITE)))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", Tokens.GAP_M)
	row.add_child(line)
	line.add_child(Card.icon("race", _race, Vector2(44, 44)))
	var name_label := Label.new()
	name_label.text = Card.days_text(days)
	name_label.custom_minimum_size.x = 80
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	name_label.add_theme_color_override("font_color", Kit.INK)
	line.add_child(name_label)
	var coin_icon := TextureRect.new()
	coin_icon.texture = Currency.icon("coin")
	coin_icon.custom_minimum_size = Vector2(28, 28)
	coin_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	line.add_child(coin_icon)
	var price_label := Label.new()
	price_label.text = Currency.comma(price)
	price_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	price_label.add_theme_color_override("font_color", Kit.INK)
	line.add_child(price_label)
	var buy: Button = ACTION_BUTTON.instantiate()
	buy.custom_minimum_size = Vector2(200, Tokens.TOUCH_MIN)
	if _bought.has(days) or _bought.has(float(days)):
		buy.text = Card.t("已购买 · 下周一重置", "Bought · resets Mon")
		buy.disabled = true
		Kit.style_plate(buy, false)
	elif _coin >= 0 and _coin < price:
		buy.text = Card.t("游戏币不足", "Not enough coins")
		buy.disabled = true
		Kit.style_plate(buy, false)
	else:
		buy.text = Card.t("购买", "Buy")
		buy.disabled = _busy
		Kit.style_plate(buy, true)
		buy.pressed.connect(_buy.bind(days))
	line.add_child(buy)
	return row


func _render_bought(days: int) -> void:
	_clear()
	_title(Card.t("已购买", "Purchased"))
	_box.add_child(_centered(Card.tile({"kind": "race", "target": _race, "days": days, "count": 1},
		Vector2(132, 132))))
	_line(Card.t("%s已放入背包。", "%s is in your Bag.") % Card.card_title("race", _race, days))
	_status = _line("", Color("a3271a"), Tokens.FONT_CAPTION)
	_status.visible = false
	_button_row([
		_button(Card.t("关闭", "Close"), false, _close),
		_button(Card.t("立刻使用", "Use now"), true, _use_now.bind(days)),
	])


func _centered(node: Control) -> Control:
	var holder := CenterContainer.new()
	holder.add_child(node)
	return holder


func _show_status(text: String) -> void:
	if _status != null:
		_status.text = text
		_status.visible = not text.is_empty()


# --- 动作 ---------------------------------------------------------------------

func _buy(days: int) -> void:
	if _busy:
		return
	_busy = true
	_render_offer()
	if not _pending_ops.has(days):
		_pending_ops[days] = AccountManager.new_client_order_id()
	var result: Dictionary = await AccountManager.buy_race_trial(str(_pending_ops[days]), _race, days)
	if not is_inside_tree():
		return
	_busy = false
	var code := int(result.get("code", 0))
	if code / 100 != 2:
		# 断网 / 5xx：留着操作号，再点一次是重试同一笔；业务拒绝：换新号。
		if code != 0 and code < 500:
			_pending_ops.erase(days)
		if str(result.get("reason", "")) == "weekly_limit" and not _bought.has(days):
			_bought.append(days)
		_render_offer()
		_show_status(str(result.get("error", Card.t("购买失败", "Purchase failed"))))
		return
	_pending_ops.erase(days)
	var body: Dictionary = result.get("body", {})
	_coin = int(body.get("coin", _coin))
	if not _bought.has(days):
		_bought.append(days)
	if not bool(body.get("replayed", false)):
		SfxService.play(SfxService.CUE_UI_CURRENCY_SPEND)
	wallet_changed.emit(_coin)
	_render_bought(days)


func _use_now(days: int) -> void:
	if _busy:
		return
	_busy = true
	var key := "use_%d" % days
	if not _pending_ops.has(key):
		_pending_ops[key] = AccountManager.new_client_order_id()
	var result: Dictionary = await AccountManager.use_trial_card(str(_pending_ops[key]), _race, days)
	if not is_inside_tree():
		return
	_busy = false
	var code := int(result.get("code", 0))
	if code / 100 != 2:
		if code != 0 and code < 500:
			_pending_ops.erase(key)
		_show_status(str(result.get("error", Card.t("使用失败，可以稍后在背包里使用", "Could not use it — try again from your Bag"))))
		return
	_pending_ops.erase(key)
	var expires := str((result.get("body", {}) as Dictionary).get("expires_at", ""))
	# 服务器在不满 4 族时会把这一族自动带上出战（同集齐解锁），拉一次让备战页一致。
	PlayerProfile.refresh_races()
	GloryToast.show_text(Card.t("%s体验已生效，%s", "%s trial is active — %s") % [
		Card.target_name("race", _race), Card.time_left(expires)])
	trial_used.emit(_race, expires)
	_close()


func _close() -> void:
	ModalStack.pop(MODAL_ID)
