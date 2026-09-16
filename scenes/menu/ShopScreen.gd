extends Control

# 商城界面（docs/商城系统设计.md）。入口：主菜单右侧「商店」。
#
# 网格铺商品卡片，卡片上是模型预览 + 名字 + 价格。已拥有的置灰、写「已拥有」、点不动。
# 点可买的 -> 确认框 -> POST /v1/shop/orders -> 回执刷新余额与拥有列表。
#
# ## 三条纪律
#
# 1. **客户端只发意图。** 请求体里只有 client_order_id 和 item_id，没有价格、
#    没有「我有多少钱」。卡片上那个价格只是显示用的，服务端另算一遍
#    （docs/P1经济账本RFC.md 第六节）。
#
# 2. **client_order_id 生成一次，整笔重试期间复用。** 换一个新的就是新订单，
#    会再扣一次钱。所以它存在 _pending_order_id 里，成功或明确失败之后才清。
#
# 3. **「不在目录里 = 免费」。** 拥有列表里没有某个内容**不代表**玩家没有它 ——
#    现有 20 张头像都不在归属表里却人人可用。这一页只显示服务端目录里的东西，
#    所以这里不会踩到；但别把这页的判断逻辑抄去做「有没有资格用」。

signal back_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")
# 新按钮一律实例化组件，不写 Button.new()：procedural_ui_ratchet 按文件只许降。
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")
const TEX_GOLD := preload("res://assets/ui/main_menu_live/gold.png")
const TEX_DIAMOND := preload("res://assets/ui/main_menu_live/diamond.png")
const PetPreview := preload("res://scripts/pets/PetPreview.gd")
const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")

const CARD_SIZE := Vector2(220, 300)
const PREVIEW_SIZE := Vector2(180, 150)
const COLUMNS := 4

var _busy := false
var _loading := true
var _items: Array = []
var _owned: Dictionary = {}     # 内容 id -> true
var _diamond := 0
var _coin := 0
var _notice := ""
var _notice_bad := false

# 正在进行的那笔购买的幂等键。**重试必须复用它**，见文件头第 2 条。
var _pending_order_id := ""
var _pending_item_id := ""

var _grid: GridContainer
var _notice_label: Label
var _diamond_label: Label
var _coin_label: Label
var _empty_label: Label


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_render()
	_reload()


# --- 骨架 ---------------------------------------------------------------------

func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = MENU_BG_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var dim := ColorRect.new()
	dim.color = Tokens.BACKDROP
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, Tokens.PAD)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", Tokens.GAP_M)
	margin.add_child(root)
	root.add_child(_header())

	_notice_label = Label.new()
	_notice_label.name = "Notice"
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_notice_label.visible = false
	root.add_child(_notice_label)

	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override(
		"panel", Tokens.panel_box(Tokens.SURFACE, Tokens.BORDER, Tokens.GAP_M))
	root.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var holder := VBoxContainer.new()
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_theme_constant_override("separation", Tokens.GAP_M)
	scroll.add_child(holder)

	_empty_label = Label.new()
	_empty_label.name = "Empty"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_empty_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	holder.add_child(_empty_label)

	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", Tokens.GAP_M)
	_grid.add_theme_constant_override("v_separation", Tokens.GAP_M)
	holder.add_child(_grid)


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back: Button = ACTION_BUTTON.instantiate()
	back.name = "Back"
	back.text = _t("← 返回", "← Back")
	back.custom_minimum_size = Vector2(160, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)

	var title := Label.new()
	title.text = _t("商城", "Shop")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(title)

	# 余额。与主菜单右上角是同一组图标 —— 两处显示同一个数，图不一样会让人以为是两种钱。
	var purse := HBoxContainer.new()
	purse.add_theme_constant_override("separation", Tokens.GAP_S)
	purse.custom_minimum_size = Vector2(320, Tokens.TOUCH_MIN)
	purse.alignment = BoxContainer.ALIGNMENT_END
	_coin_label = _purse_entry(purse, TEX_GOLD)
	_diamond_label = _purse_entry(purse, TEX_DIAMOND)
	row.add_child(purse)
	return row


func _purse_entry(parent: HBoxContainer, tex: Texture2D) -> Label:
	var icon := TextureRect.new()
	icon.texture = tex
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(36, 36)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(icon)

	var label := Label.new()
	label.text = "—"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(96, 0)
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	parent.add_child(label)
	return label


# --- 拉数据 -------------------------------------------------------------------

# 目录、余额、拥有列表一起拉。**三个都到齐才重画** ——
# 先画目录再补拥有状态的话，已买的商品会先亮一下「可购买」，玩家会去点。
func _reload() -> void:
	_loading = true
	_render()
	var catalog: Dictionary = await AccountManager.fetch_shop()
	var wallet: Dictionary = await AccountManager.fetch_wallet()
	var owned: Dictionary = await AccountManager.fetch_entitlements()
	if not is_inside_tree():
		return
	_loading = false

	if int(catalog.get("code", 0)) / 100 != 2:
		_set_notice(str(catalog.get("error", _t("商城打不开", "The shop failed to load"))), true)
		_render()
		return
	_items = ((catalog.get("body", {}) as Dictionary).get("items", []) as Array)

	# 余额和拥有列表失败不算致命：目录还能看，只是买不了。
	# 直接整页报错的话，一次网络抖动就把整个商城变成错误页。
	if int(wallet.get("code", 0)) / 100 == 2:
		var w: Dictionary = wallet.get("body", {})
		_diamond = int(w.get("diamond", 0))
		_coin = int(w.get("coin", 0))
	if int(owned.get("code", 0)) / 100 == 2:
		_owned.clear()
		for id in ((owned.get("body", {}) as Dictionary).get("items", []) as Array):
			_owned[str(id)] = true
	_render()


# --- 渲染 ---------------------------------------------------------------------

func _render() -> void:
	if _grid == null:
		return
	_diamond_label.text = "—" if _loading else _comma(_diamond)
	_coin_label.text = "—" if _loading else _comma(_coin)

	_notice_label.visible = not _notice.is_empty()
	_notice_label.text = _notice
	_notice_label.add_theme_color_override(
		"font_color", Tokens.DANGER if _notice_bad else Tokens.GOLD)

	for child in _grid.get_children():
		child.queue_free()

	if _loading:
		_empty_label.text = _t("正在载入…", "Loading…")
		_empty_label.visible = true
		return
	if _items.is_empty():
		_empty_label.text = _t("商城暂时没有上架的东西", "Nothing is on sale right now")
		_empty_label.visible = true
		return
	_empty_label.visible = false
	for raw in _items:
		_grid.add_child(_card(raw as Dictionary))


func _card(item: Dictionary) -> Control:
	var grants := str(item.get("grants", ""))
	var owned := bool(_owned.get(grants, false))
	var price := int(item.get("price", 0))
	var currency := str(item.get("currency", "diamond"))
	var affordable := _balance_of(currency) >= price

	var panel := PanelContainer.new()
	panel.custom_minimum_size = CARD_SIZE
	panel.add_theme_stylebox_override(
		"panel", Tokens.panel_box(Tokens.SURFACE_RAISED, Tokens.BORDER, Tokens.GAP_S))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(box)
	box.add_child(_preview(item, owned))

	var name_label := Label.new()
	name_label.text = _item_name(item)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	name_label.add_theme_color_override(
		"font_color", Tokens.TEXT_DISABLED if owned else Tokens.TEXT_PRIMARY)
	box.add_child(name_label)

	var price_row := HBoxContainer.new()
	price_row.alignment = BoxContainer.ALIGNMENT_CENTER
	price_row.add_theme_constant_override("separation", Tokens.GAP_S)
	box.add_child(price_row)
	if not owned:
		var icon := TextureRect.new()
		icon.texture = TEX_DIAMOND if currency == "diamond" else TEX_GOLD
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(28, 28)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		price_row.add_child(icon)
		var price_label := Label.new()
		price_label.text = _comma(price)
		price_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
		# 买不起就把价格标红。按钮上只写「余额不足」不够 —— 玩家要看到差多少。
		price_label.add_theme_color_override(
			"font_color", Tokens.TEXT_PRIMARY if affordable else Tokens.DANGER)
		price_row.add_child(price_label)

	var button: Button = ACTION_BUTTON.instantiate()
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	if owned:
		button.text = _t("已拥有", "Owned")
		button.disabled = true
	elif not affordable:
		button.text = _t("余额不足", "Not enough")
		button.disabled = true
	else:
		button.text = _t("购买", "Buy")
		button.pressed.connect(func() -> void: _confirm_buy(item))
	box.add_child(button)
	return panel


# 卡片上的图。宠物只有 3D 模型（pets.json 的 icon 是空的），头像 / 头像框是 2D 图。
func _preview(item: Dictionary, owned: bool) -> Control:
	var kind := str(item.get("kind", ""))
	var grants := str(item.get("grants", ""))
	if kind == "pet":
		return PetPreview.build(grants, PREVIEW_SIZE, owned)
	var tex := AvatarCatalog.texture_for(grants)
	if tex == null:
		return PetPreview.placeholder(PREVIEW_SIZE, owned)
	var rect := TextureRect.new()
	rect.texture = tex
	rect.custom_minimum_size = PREVIEW_SIZE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if owned:
		rect.modulate = Color(0.45, 0.45, 0.45)
	return rect


# --- 购买 ---------------------------------------------------------------------

func _confirm_buy(item: Dictionary) -> void:
	if _busy:
		return
	var price := int(item.get("price", 0))
	var currency_name := _t("钻石", "diamonds") if str(item.get("currency", "")) == "diamond" \
		else _t("金币", "coins")
	DialogService.confirm({
		"title": _t("确认购买", "Confirm purchase"),
		# 中英语序不同，各自格式化 —— 硬凑成一个模板会让参数顺序随语言变，
		# 那是「改文案顺手改错参数」的经典入口。
		"body": ("Buy \"%s\" for %d %s?" % [_item_name(item), price, currency_name]
			if _english()
			else "花 %d %s 购买「%s」？" % [price, currency_name, _item_name(item)]),
		"confirm_text": _t("购买", "Buy"),
		"owner": self,
		"on_result": func(result: String, _request_id: String) -> void:
			if result == ConfirmDialog.RESULT_CONFIRMED:
				await _buy(item),
	})


func _buy(item: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	var item_id := str(item.get("id", ""))
	# 🔴 同一件商品重试时复用上一次的幂等键。换新的等于开一张新订单 ——
	# 上一笔如果其实成功了（只是回执丢在路上），玩家就被扣了两次钱。
	if _pending_order_id.is_empty() or _pending_item_id != item_id:
		_pending_order_id = AccountManager.new_client_order_id()
		_pending_item_id = item_id
	var result: Dictionary = await AccountManager.place_shop_order(_pending_order_id, item_id)
	_busy = false
	if not is_inside_tree():
		return

	var code := int(result.get("code", 0))
	if code / 100 == 2:
		_pending_order_id = ""
		_pending_item_id = ""
		var receipt: Dictionary = (result.get("body", {}) as Dictionary).get("receipt", {})
		_diamond = int(receipt.get("diamond", _diamond))
		_coin = int(receipt.get("coin", _coin))
		_owned[str(receipt.get("granted", ""))] = true
		# replayed = 服务端重放了一张旧回执（上一次其实成功了）。不另说一句的话，
		# 玩家会以为这次又扣了一笔。
		# 买的是宠物就把归属缓存刷一遍 —— 备战页与出战宠物都读 PlayerProfile，
		# 不刷的话玩家买完回去发现新宠物不在那儿。
		if str(item.get("kind", "")) == "pet":
			await PlayerProfile.refresh_pets()
		if bool(receipt.get("replayed", false)):
			_set_notice(_t("这件你刚才已经买到了，没有重复扣费",
				"You already bought this a moment ago — you were not charged twice"), false)
		else:
			_set_notice(_t("购买成功", "Purchased"), false)
		_render()
		return

	# 409 / 402 这些是「明确的失败」，服务端一定没扣钱，可以把幂等键丢掉。
	# 但 0（根本没发出去 / 没收到响应）和 5xx **必须留着** —— 那笔可能已经成交了，
	# 换个新 id 重试就会变成第二笔订单。
	if code != 0 and code < 500:
		_pending_order_id = ""
		_pending_item_id = ""
	var message := str(result.get("error", _t("购买失败", "Purchase failed")))
	if code == 402:
		message = _t("余额不足", "Not enough balance")
	elif code == 0 or code >= 500:
		message = "%s（%s）" % [message,
			_t("再点一次「购买」会接着这一笔，不会重复扣费",
				"Tapping Buy again resumes this order — you will not be charged twice")]
	_set_notice(message, true)
	# 余额和拥有状态可能已经变了（比如在另一台设备上买过），重新拉一次。
	await _reload()


# --- 小工具 -------------------------------------------------------------------

func _balance_of(currency: String) -> int:
	return _diamond if currency == "diamond" else _coin


func _item_name(item: Dictionary) -> String:
	var key := "name_en" if _english() else "name"
	return str(item.get(key, item.get("name", item.get("id", ""))))


func _set_notice(text: String, bad: bool) -> void:
	_notice = text
	_notice_bad = bad


# 千分位。写死的那个 "89,450" 就是这个格式，接真实数据后要保持一致。
func _comma(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if value < 0 else "") + out


func _english() -> bool:
	return LocaleManager.get_locale().begins_with("en")


func _t(zh: String, en: String) -> String:
	return en if _english() else zh
