extends Control

# 独立钻石购买窗口。平台内购尚未接入，档位只展示数量，不提供虚假定价或到账。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const Currency := preload("res://scripts/account/Currency.gd")

var _balance := -1
var _balance_label: Label


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	if not has_meta("ui_capture_fixture"):
		_load_balance()


func _load_balance() -> void:
	var result: Dictionary = await AccountManager.fetch_wallet()
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 == 2:
		_balance = int((result.get("body", {}) as Dictionary).get("diamond", 0))
		_balance_label.text = Currency.comma(_balance)


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
	_balance_label.text = "—" if _balance < 0 else Currency.comma(_balance)
	_balance_label.custom_minimum_size.x = 88
	_balance_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	_balance_label.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	header.add_child(_balance_label)
	var close: Button = ACTION_BUTTON.instantiate()
	close.text = "✕"
	close.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	close.pressed.connect(queue_free)
	header.add_child(close)
	var subtitle := Label.new()
	subtitle.text = _t("选择钻石档位", "Choose a diamond bundle")
	subtitle.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	subtitle.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	content.add_child(subtitle)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	content.add_child(row)
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/diamond_products.json"))
	if data is Dictionary:
		for raw in (data as Dictionary).get("products", []):
			row.add_child(_product_card(raw as Dictionary))
	var foot := Label.new()
	foot.text = _t("平台购买尚未开放。开放后显示当地价格，由服务器确认到账。",
		"Platform purchases are coming soon. Local prices and verified delivery will appear here.")
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	foot.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	foot.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	content.add_child(foot)


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
	var unit := Label.new()
	unit.text = _t("钻石", "Diamonds")
	unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	unit.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	unit.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	col.add_child(unit)
	var button: Button = ACTION_BUTTON.instantiate()
	button.text = _t("即将开放", "Coming soon")
	button.disabled = true
	# 宽度跟卡片走（卡片 195）。GloryActionButton 自带 280 的最小宽：只改高度的话五张卡
	# 会被撑到约 1520 宽，比设计的 1130 宽出一截，手机横屏两头钻进灵动岛 / 圆角。
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	col.add_child(button)
	return card


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		queue_free()
		get_viewport().set_input_as_handled()


func _t(zh: String, en: String) -> String:
	return en if LocaleManager.get_locale().begins_with("en") else zh
