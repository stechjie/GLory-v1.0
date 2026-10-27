extends Control

# 钻石宝库：充值（docs/充值系统设计.md 第二、九节）。界面是 lenoliew 09-30 做的那版，档位改成问服务器。
#
# 数字都不是这里算的：钻石数、首充、余额问账号服务器（GET /v1/iap/catalog），当地价格问 Google
# （BillingBridge.prices）。查不到价格的档不给购买按钮，不自己编一个价格。
#
# 买一档：建单 → 弹 Google 付款页 → 把付款凭证交给服务器 → 服务器答复 credited / pending / cancelled。
# 到没到账只看服务器的 status。🔴 503、断网、超时一律显示「处理中」，不显示失败：
# 钱多半已经扣了，只是这一趟没核实完，下次启动会再交一次（AccountManager.recover_purchases）。

signal balance_changed(diamond: int)

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const Currency := preload("res://scripts/account/Currency.gd")
const BillingBridge := preload("res://scripts/account/BillingBridge.gd")

# 「处理中」之后每隔几秒问一次服务器这张单入账没有，问几次。
const POLL_ORDER_SEC := 3.0
const POLL_ORDER_TIMES := 10

# 截图工具（tools/shop_bag_ui_capture.gd）的假档位：不联网也能画出卡片。只在 ui_capture_fixture 时用。
const FIXTURE_PRODUCTS := [
	{"id": "diamond_pack_1", "diamond": 50, "bonus": 0, "first_bonus": true},
	{"id": "diamond_pack_2", "diamond": 200, "bonus": 20, "first_bonus": true},
	{"id": "diamond_pack_3", "diamond": 500, "bonus": 60, "first_bonus": false},
]
const FIXTURE_PRICES := {"diamond_pack_1": "RM 4.90", "diamond_pack_2": "RM 19.90", "diamond_pack_3": "RM 49.90"}

var _balance := -1
var _balance_label: Label
var _row: HBoxContainer
var _foot: Label
var _platform := ""
var _products: Array = []
var _prices: Dictionary = {}
var _busy := false
# 游客提醒只问一次：点过「继续」这次打开窗口期间就不再拦。
var _guest_ok := false
var _guest_panel: Control = null


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	if has_meta("ui_capture_fixture"):
		_products = FIXTURE_PRODUCTS.duplicate(true)
		_prices = FIXTURE_PRICES.duplicate()
		_render()
		return
	_load()


func _load() -> void:
	_platform = BillingBridge.platform()
	if _platform.is_empty():
		_set_foot(_t("这台设备暂时还不能充值。", "Top-ups are not available on this device yet."))
		_load_balance_only()
		return
	if _platform == "google" and not BillingBridge.installed_from_play():
		# 直发的 APK 用不了 Play 结算（docs/充值系统设计.md 第十节）。
		_set_foot(_t("请从 Google Play 下载正式版后再充值。", "Install the game from Google Play to buy diamonds."))
		_load_balance_only()
		return
	if not await _load_catalog():
		return
	var ids: Array = []
	for product in _products:
		ids.append(str((product as Dictionary).get("id", "")))
	_prices = await BillingBridge.prices(get_tree(), ids)
	if not is_inside_tree():
		return
	_render()
	if _prices.is_empty():
		_set_foot(_t("读不到 Google Play 的价格，请稍后再试。", "Could not load prices from Google Play. Try again later."))


# 拉档位与余额。失败时把原因写在页脚，返回 false。
func _load_catalog() -> bool:
	_set_foot(_t("正在读取档位…", "Loading bundles…"))
	var result: Dictionary = await AccountManager.fetch_iap_catalog(_platform)
	if not is_inside_tree():
		return false
	if int(result.get("code", 0)) / 100 != 2:
		_set_foot(_t("读取档位失败，请稍后再试。", "Could not load bundles. Try again later."))
		return false
	var body: Dictionary = result.get("body", {})
	_set_balance(int(body.get("diamond", 0)))
	if not bool(body.get("open", false)):
		_set_foot(_t("充值暂未开放。", "Top-ups are not open yet."))
		return false
	_products = body.get("products", [])
	_set_foot(_t("钻石由服务器确认后到账。", "Diamonds are added once the server confirms the payment."))
	return true


func _load_balance_only() -> void:
	var result: Dictionary = await AccountManager.fetch_wallet()
	if is_inside_tree() and int(result.get("code", 0)) / 100 == 2:
		_set_balance(int((result.get("body", {}) as Dictionary).get("diamond", 0)))


func _set_balance(value: int) -> void:
	_balance = value
	if _balance_label == null:
		return
	_balance_label.text = Currency.comma(value) if value >= 0 else "-" + Currency.comma(-value)
	# 欠账时是负数（docs/充值系统设计.md 第七节），标红。
	_balance_label.add_theme_color_override("font_color", Tokens.GOLD_HOVER if value >= 0 else Tokens.DANGER)


func _set_foot(text: String) -> void:
	if _foot != null:
		_foot.text = text


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Tokens.SHOP_MODAL_DIM
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	# 遮罩铺满全屏，弹窗本身在安全区里居中（ui/services/SafeArea.gd）。
	SafeArea.track(center)
	var shell := PanelContainer.new()
	shell.custom_minimum_size = Vector2(1130, 445)
	shell.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SHOP_MODAL, Tokens.SHOP_EDGE_ACTIVE, Tokens.GAP_L))
	center.add_child(shell)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", Tokens.GAP_M)
	shell.add_child(content)
	var header := HBoxContainer.new()
	content.add_child(header)
	var title := Label.new()
	title.text = _t("钻石宝库", "Diamond vault")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	header.add_child(title)
	var wallet_icon := TextureRect.new()
	wallet_icon.texture = Currency.icon("diamond")
	wallet_icon.custom_minimum_size = Vector2(30, 30)
	wallet_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wallet_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(wallet_icon)
	_balance_label = Label.new()
	_balance_label.custom_minimum_size.x = 88
	_balance_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	header.add_child(_balance_label)
	if _balance >= 0:
		_set_balance(_balance)
	else:
		_balance_label.text = "—"
		_balance_label.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	var close: Button = ACTION_BUTTON.instantiate()
	close.text = "✕"
	close.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	close.pressed.connect(queue_free)
	header.add_child(close)
	var subtitle := Label.new()
	subtitle.text = _t("选择钻石档位 · 每档第一次购买双倍", "Choose a bundle · first purchase of each bundle is doubled")
	subtitle.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	subtitle.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	content.add_child(subtitle)
	_row = HBoxContainer.new()
	_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_row.add_theme_constant_override("separation", Tokens.GAP_S)
	content.add_child(_row)
	_foot = Label.new()
	_foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_foot.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_foot.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	content.add_child(_foot)


func _render() -> void:
	for child in _row.get_children():
		child.queue_free()
	for raw in _products:
		_row.add_child(_product_card(raw as Dictionary))


func _product_card(product: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(195, 225)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", Tokens.panel_box(
		Tokens.SHOP_DIAMOND_CARD, Tokens.SHOP_EDGE, Tokens.GAP_S))
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", Tokens.GAP_S)
	card.add_child(col)
	var icon := TextureRect.new()
	icon.texture = Currency.icon("diamond")
	icon.custom_minimum_size.y = 60
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	col.add_child(icon)
	var amount := Label.new()
	amount.text = Currency.comma(int(product.get("diamond", 0)))
	amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	amount.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	amount.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	col.add_child(amount)
	var extra := Label.new()
	extra.text = bonus_text(product, LocaleManager.get_locale().begins_with("en"))
	extra.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	extra.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	extra.add_theme_color_override("font_color",
		Tokens.GOLD_HOVER if bool(product.get("first_bonus", false)) else Tokens.TEXT_SECONDARY)
	col.add_child(extra)
	var button: Button = ACTION_BUTTON.instantiate()
	var id := str(product.get("id", ""))
	var price := str(_prices.get(id, ""))
	button.text = price if not price.is_empty() else _t("暂不可买", "Unavailable")
	button.disabled = price.is_empty() or _busy
	button.set_meta("product_id", id)
	# 宽度跟卡片走（卡片 195）。GloryActionButton 自带 280 的最小宽：只改高度的话卡片
	# 会被撑宽，比设计的 1130 宽出一截，手机横屏两头钻进灵动岛 / 圆角。
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	button.pressed.connect(func() -> void: _on_buy(product))
	col.add_child(button)
	return card


# 卡片上基础量下面那一行。首充 = 再给一份基础量，代替平时加送（docs/充值系统设计.md 第二节）。
static func bonus_text(product: Dictionary, english: bool) -> String:
	var base := int(product.get("diamond", 0))
	var bonus := int(product.get("bonus", 0))
	if bool(product.get("first_bonus", false)):
		return ("First purchase ×2 · +%s" if english else "首充双倍 · 再送 %s") % Currency.comma(base)
	if bonus > 0:
		return ("+%s bonus" if english else "加送 %s") % Currency.comma(bonus)
	return ""


func _set_buttons_enabled(enabled: bool) -> void:
	for card in _row.get_children():
		for node in card.find_children("*", "Button", true, false):
			var id := str(node.get_meta("product_id", ""))
			(node as Button).disabled = not enabled or str(_prices.get(id, "")).is_empty()


func _on_buy(product: Dictionary) -> void:
	if _busy:
		return
	if AccountManager.is_guest() and not _guest_ok:
		_ask_guest(product)
		return
	await _buy(product)


# 游客号付款前提醒一次（docs/充值系统设计.md 第一节「游客能充」）。
func _ask_guest(product: Dictionary) -> void:
	if _guest_panel != null:
		return
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SHOP_MODAL, Tokens.SHOP_EDGE_ACTIVE, Tokens.GAP_L))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(620, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(col)
	var text := Label.new()
	text.text = guest_warning_text(LocaleManager.get_locale().begins_with("en"))
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size.x = 580
	col.add_child(text)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", Tokens.GAP_M)
	col.add_child(buttons)
	var go: Button = ACTION_BUTTON.instantiate()
	go.text = _t("继续购买", "Continue")
	go.pressed.connect(func() -> void:
		_guest_ok = true
		_close_guest_panel()
		_buy(product))
	buttons.add_child(go)
	var back: Button = ACTION_BUTTON.instantiate()
	back.text = _t("先不买", "Not now")
	back.pressed.connect(_close_guest_panel)
	buttons.add_child(back)
	_guest_panel = panel
	add_child(panel)


static func guest_warning_text(english: bool) -> String:
	if english:
		return "You are playing as a guest. If you uninstall the game or change phones, this account and its diamonds cannot be recovered. Link Google on the profile page first to keep them."
	return "你现在是游客号。卸载游戏或换手机后，这个号和里面的钻石都找不回来。建议先在资料页绑定 Google。"


func _close_guest_panel() -> void:
	if _guest_panel != null:
		_guest_panel.queue_free()
		_guest_panel = null


func _buy(product: Dictionary) -> void:
	var id := str(product.get("id", ""))
	_busy = true
	_set_buttons_enabled(false)
	_set_foot(_t("正在下单…", "Placing order…"))
	var created: Dictionary = await AccountManager.create_iap_order(
		AccountManager.new_client_order_id(), _platform, id)
	if not is_inside_tree():
		return
	if int(created.get("code", 0)) / 100 != 2:
		_done(str(created.get("error", _t("下单失败，请稍后再试", "Could not place the order. Try again later."))))
		return
	var order: Dictionary = created.get("body", {})
	var order_id := str(order.get("order_id", ""))
	_set_foot(_t("请在 Google 付款页完成付款", "Complete the payment on the Google Play sheet"))
	var paid: Dictionary = await BillingBridge.purchase(
		get_tree(), id, str(order.get("obfuscated_account_id", "")), order_id)
	if not is_inside_tree():
		return
	match str(paid.get("state", "")):
		"purchased":
			_set_foot(_t("付款成功，正在确认…", "Payment done, confirming…"))
			var confirmed: Dictionary = await AccountManager.confirm_google_purchase(order_id, str(paid["token"]))
			if not is_inside_tree():
				return
			await _show_outcome(confirmed, order_id)
		"pending":
			_done(_t("付款处理中，完成后钻石会自动到账。", "Payment pending. Diamonds will be added once it completes."))
		"cancelled":
			_done(_t("已取消。", "Cancelled."))
		"already_owned":
			# 这一档有一笔付了还没处理完的：先把它交了，再让玩家看余额。
			await AccountManager.recover_purchases()
			if is_inside_tree():
				_done(_t("上一笔付款已重新提交，钻石会自动到账。", "Your previous payment was resubmitted. Diamonds will be added shortly."))
				_load_balance_only()
		"busy":
			_done(_t("已经有一个付款页开着。", "A payment is already in progress."))
		"timeout":
			_done(processing_text(LocaleManager.get_locale().begins_with("en")))
		_:
			_done(_t("付款没有完成，请稍后再试。", "The payment did not go through. Try again later."))


# 服务器对 confirm 的答复 → 给玩家看的话。拿出来做纯函数，门禁（tools/iap_check）直接测。
#   kind = credited / processing / cancelled / failed
static func outcome_of(code: int, body: Dictionary, error: String, english: bool) -> Dictionary:
	if code / 100 == 2:
		match str(body.get("status", "")):
			"credited":
				return {"kind": "credited", "text": ("+%s diamonds added." if english else "已到账：+%s 钻石。")
					% Currency.comma(int(body.get("credited", 0)))}
			"cancelled", "refunded":
				if str(body.get("note", "")) == "test_daily_limit":
					return {"kind": "cancelled", "text": "Test purchase limit reached for today; this one was not added."
						if english else "测试单已到今日上限，这一笔没有到账。"}
				return {"kind": "cancelled", "text": "This payment was cancelled." if english else "这笔付款已取消。"}
			_:
				return {"kind": "processing", "text": processing_text(english)}
	# 🔴 0（断网、超时）和 5xx（平台连不上、服务器没配好）都是「处理中」：钱可能已经扣了。
	if code == 0 or code >= 500:
		return {"kind": "processing", "text": processing_text(english)}
	return {"kind": "failed", "text": error if not error.is_empty() else ("Something went wrong." if english else "出错了，请稍后再试。")}


static func processing_text(english: bool) -> String:
	return "Processing. Diamonds will be added automatically." if english else "处理中，钻石会自动到账。"


func _show_outcome(result: Dictionary, order_id: String) -> void:
	var body: Dictionary = result.get("body", {}) if result.get("body") is Dictionary else {}
	var outcome := outcome_of(int(result.get("code", 0)), body, str(result.get("error", "")),
		LocaleManager.get_locale().begins_with("en"))
	if body.has("diamond"):
		_set_balance(int(body["diamond"]))
		balance_changed.emit(_balance)
	_done(str(outcome["text"]))
	match str(outcome["kind"]):
		"credited":
			# 首充标记要跟着变：重新拉一次档位（价格不用再问 Google）。
			if await _load_catalog():
				_render()
				_set_foot(str(outcome["text"]))
		"processing":
			await _poll_order(order_id)


# 「处理中」时隔几秒问一次服务器：后台（Google 实时通知）入了账就把余额刷新。
func _poll_order(order_id: String) -> void:
	for _i in POLL_ORDER_TIMES:
		await get_tree().create_timer(POLL_ORDER_SEC).timeout
		if not is_inside_tree():
			return
		var result: Dictionary = await AccountManager.fetch_iap_order(order_id)
		if not is_inside_tree():
			return
		var body: Dictionary = result.get("body", {}) if result.get("body") is Dictionary else {}
		if int(result.get("code", 0)) / 100 == 2 and str(body.get("status", "")) != "pending":
			await _show_outcome(result, order_id)
			return


func _done(text: String) -> void:
	_busy = false
	_set_buttons_enabled(true)
	_set_foot(text)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		queue_free()
		get_viewport().set_input_as_handled()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
