extends Control

# 出售体验卡（背包「出售」按钮打开）。可以选数量，也可以「全部出售」。
# 单价按天数：1/3/7 天 = 100/200/300 游戏币。给多少以服务器回执为准。
#
# 用法同 RaceTrialDialog：configure(card) 之后 ModalStack.push(dialog, {"id": MODAL_ID, ...})。

signal sold(result: Dictionary)

const MODAL_ID := "trial_sell"
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Card := preload("res://ui/components/TrialCardKit.gd")
const Currency := preload("res://scripts/account/Currency.gd")
const SfxService := preload("res://ui/services/SfxService.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")

var _card: Dictionary = {}
var _count := 1
var _busy := false
var _pending_op := ""
var _count_label: Label
var _total_label: Label
var _status: Label
var _confirm: Button
var _minus: Button
var _plus: Button


func configure(card: Dictionary) -> void:
	_card = card
	_count = 1


func _max() -> int:
	return maxi(1, int(_card.get("count", 1)))


func _unit_price() -> int:
	return int(_card.get("sell_price", Card.PRICE.get(int(_card.get("days", 1)), 0)))


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 0)
	panel.add_theme_stylebox_override("panel", Kit.box("panel", Vector4(60, 44, 60, 36)))
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(box)

	var title := Label.new()
	title.text = Card.t("出售体验卡", "Sell trial card")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Color("8a4b12"))
	box.add_child(title)

	var tile_holder := CenterContainer.new()
	tile_holder.add_child(Card.tile(_card, Vector2(120, 120)))
	box.add_child(tile_holder)

	var name_label := Label.new()
	name_label.text = Card.card_title(str(_card.get("kind", "")), str(_card.get("target", "")),
		int(_card.get("days", 1)))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_BUTTON)
	name_label.add_theme_color_override("font_color", Kit.INK)
	box.add_child(name_label)

	var unit := Label.new()
	unit.text = Card.t("单价 %s 游戏币 · 拥有 %d 张", "%s coins each · you have %d") % [
		Currency.comma(_unit_price()), _max()]
	unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	unit.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	unit.add_theme_color_override("font_color", Kit.INK_SOFT)
	box.add_child(unit)

	var stepper := HBoxContainer.new()
	stepper.alignment = BoxContainer.ALIGNMENT_CENTER
	stepper.add_theme_constant_override("separation", Tokens.GAP_M)
	box.add_child(stepper)
	_minus = _small_button("−", func() -> void: _set_count(_count - 1))
	stepper.add_child(_minus)
	_count_label = Label.new()
	_count_label.custom_minimum_size = Vector2(70, 0)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count_label.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	_count_label.add_theme_color_override("font_color", Kit.INK)
	stepper.add_child(_count_label)
	_plus = _small_button("+", func() -> void: _set_count(_count + 1))
	stepper.add_child(_plus)
	var all := _small_button(Card.t("全部", "All"), func() -> void: _set_count(_max()))
	all.custom_minimum_size.x = 96
	stepper.add_child(all)

	_total_label = Label.new()
	_total_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_total_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_total_label.add_theme_color_override("font_color", Color("8a4b12"))
	box.add_child(_total_label)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", Tokens.FONT_CAPTION)
	_status.add_theme_color_override("font_color", Color("a3271a"))
	_status.visible = false
	box.add_child(_status)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", Tokens.GAP_L)
	box.add_child(row)
	var cancel: Button = ACTION_BUTTON.instantiate()
	cancel.text = Card.t("取消", "Cancel")
	cancel.custom_minimum_size = Vector2(160, Tokens.BUTTON_HEIGHT)
	cancel.theme_type_variation = Theming.VARIATION_GHOST
	cancel.pressed.connect(_close)
	row.add_child(cancel)
	_confirm = ACTION_BUTTON.instantiate()
	_confirm.custom_minimum_size = Vector2(160, Tokens.BUTTON_HEIGHT)
	_confirm.theme_type_variation = Theming.VARIATION_PRIMARY
	_confirm.pressed.connect(_sell)
	row.add_child(_confirm)
	_set_count(1)


func _small_button(text: String, cb: Callable) -> Button:
	var b: Button = ACTION_BUTTON.instantiate()
	b.text = text
	b.custom_minimum_size = Vector2(Tokens.TOUCH_MIN, Tokens.TOUCH_MIN)
	Kit.style_plate(b, false)
	b.pressed.connect(cb)
	return b


func _set_count(value: int) -> void:
	var next := clampi(value, 1, _max())
	if next != _count:
		# 数量变了就是另一笔：换新操作号（重试只针对同一笔）。
		_pending_op = ""
	_count = next
	_count_label.text = str(_count)
	_total_label.text = Card.t("出售 %d 张，获得 %s 游戏币", "Sell %d for %s coins") % [
		_count, Currency.comma(_count * _unit_price())]
	_minus.disabled = _busy or _count <= 1
	_plus.disabled = _busy or _count >= _max()
	_confirm.text = Card.t("出售", "Sell")
	_confirm.disabled = _busy


func _sell() -> void:
	if _busy:
		return
	_busy = true
	_set_count(_count)
	if _pending_op.is_empty():
		_pending_op = AccountManager.new_client_order_id()
	var result: Dictionary = await AccountManager.sell_trial_card(_pending_op,
		str(_card.get("target", "")), int(_card.get("days", 1)), _count)
	if not is_inside_tree():
		return
	_busy = false
	var code := int(result.get("code", 0))
	if code / 100 != 2:
		if code != 0 and code < 500:
			_pending_op = ""
		_status.text = str(result.get("error", Card.t("出售失败", "Could not sell")))
		_status.visible = true
		_set_count(_count)
		return
	var body: Dictionary = result.get("body", {})
	if not bool(body.get("replayed", false)):
		SfxService.play(SfxService.CUE_UI_CURRENCY_GAIN)
	GloryToast.show_text(Card.t("已出售，获得 %s 游戏币", "Sold for %s coins") % Currency.comma(
		int(body.get("coin_delta", 0))))
	sold.emit(body)
	_close()


func _close() -> void:
	ModalStack.pop(MODAL_ID)
