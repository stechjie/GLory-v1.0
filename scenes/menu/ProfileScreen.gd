extends Control
# 玩家资料页。入口是主菜单左上角那个名牌。
#
# 设计与取舍见 docs/玩家资料系统设计.md。三条在改这个文件之前必须知道的：
#
# 1. **一个页面两种模式。** SELF 可编辑、含占位区块；PUBLIC 只读、
#    **不渲染占位区块** —— 自己看到「以后有段位」是预期管理，
#    陌生人看到一整页「敬请期待」得到的信息是「这游戏没做完」。
#
# 2. **隐藏字段在 PUBLIC 模式下根本不会到达客户端。** 后端按可见性裁剪，
#    JSON 里连键都没有。所以这里不判可见性，也判不了 —— 不要加那种代码。
#
# 3. **昵称永远和好友码一起显示。** player_name 不唯一（database/001 的设计），
#    只显示昵称的地方就是冒充成立的地方。显示名只从
#    AccountManager.display_name 出，不许有第二个拼法。

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Catalog := preload("res://scripts/account/AvatarCatalog.gd")
const AvatarPicker := preload("res://scenes/menu/AvatarPickerPanel.gd")
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")

signal back_requested

enum Mode { SELF, PUBLIC }

const PICKER_MODAL_ID := "profile_avatar_picker"
# 与主菜单房间面板同档：都是页面级面板。
const PICKER_PRIORITY := 40

const GENDER_VALUES := ["male", "female", "other"]
# 按预期玩家分布排。加一个地区是往这里加一行 —— 不打算维护完整的 ISO 249 项，
# 那个列表在手机上滚起来也没法用。
const REGIONS := [
	["MY", "马来西亚", "Malaysia"],
	["SG", "新加坡", "Singapore"],
	["CN", "中国大陆", "China"],
	["HK", "中国香港", "Hong Kong"],
	["TW", "中国台湾", "Taiwan"],
	["TH", "泰国", "Thailand"],
	["VN", "越南", "Vietnam"],
	["ID", "印尼", "Indonesia"],
	["PH", "菲律宾", "Philippines"],
	["JP", "日本", "Japan"],
	["KR", "韩国", "Korea"],
	["AU", "澳大利亚", "Australia"],
	["GB", "英国", "United Kingdom"],
	["US", "美国", "United States"],
]
# 与 database/002 的 birth_day_in_month 约束一致（004 只加列，不碰这条）。
# 2 月给 29 —— 闰日生日是真实存在的。tools/profile_check 钉着两边一致。
const DAYS_IN_MONTH := [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

var _mode: int = Mode.SELF
var _target_code := ""
var _data: Dictionary = {}
var _busy := false

var _body: VBoxContainer
var _status: Label
var _avatar_rect: TextureRect
var _name_label: Label
var _days_label: Label
var _pet_label: Label
var _name_edit: LineEdit
var _name_hint: Label
var _gender_pick: OptionButton
var _month_pick: OptionButton
var _day_pick: OptionButton
var _birth_private: CheckBox
var _region_pick: OptionButton
var _signature_edit: LineEdit
var _save_btn: Button


# 加进树之前调。不调就是「看自己」。
#
# 刻意做成两个具名方法而不是 configure(mode) —— 调用方（Main.gd）要传 Mode.SELF
# 就得 preload 本脚本，而那会把 Tokens / Theming / AvatarCatalog / AvatarPicker /
# 主菜单背景图的整张依赖图拉进 Main 的加载路径。Main.gd 的 _load_screen 上面
# 那段注释量过这笔账：界面依赖图压在启动路径上要多花约 1.5 秒。
func configure_self() -> void:
	_mode = Mode.SELF
	_target_code = ""


func configure_public(friend_code: String) -> void:
	_mode = Mode.PUBLIC
	_target_code = friend_code


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_load()


func _exit_tree() -> void:
	# 页面被关掉时把选择器一起收走，否则它会留在 ModalStack 上盖住主菜单。
	if ModalStack.has(PICKER_MODAL_ID):
		ModalStack.pop(PICKER_MODAL_ID)


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

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 这一页只往下长，横向滚只会让手指划错方向。同 SettingsScreen。
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

	_body = VBoxContainer.new()
	_body.custom_minimum_size = Vector2(460, 0)
	_body.add_theme_constant_override("separation", Tokens.GAP_M)
	center.add_child(_body)

	_body.add_child(_header())
	_body.add_child(_identity_card())

	if _mode == Mode.SELF:
		_body.add_child(_name_section())
		_body.add_child(_bio_section())
		_body.add_child(_placeholder_block(
			_text("战绩", "Record"),
			[_text("等级", "Level"), _text("段位", "Rank"), _text("场次 / 胜率", "Matches / Winrate")]))
		_body.add_child(_placeholder_block(
			_text("收藏", "Collection"),
			[_text("图鉴进度", "Codex"), _text("拥有宠物", "Pets"), _text("拥有皮肤", "Skins")]))
		_body.add_child(_bind_account_slot())
	else:
		_body.add_child(_public_bio_block())
		_body.add_child(_report_button())

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_body.add_child(_status)


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back := Button.new()
	back.text = _text("← 返回", "← Back")
	back.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)

	var title := Label.new()
	title.text = _text("我的资料", "My Profile") if _mode == Mode.SELF \
		else _text("玩家资料", "Player Profile")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(title)

	# 与返回键等宽的空位，让标题真的居中。
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(96, 0)
	row.add_child(spacer)
	return row


func _identity_card() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(row)

	_avatar_rect = TextureRect.new()
	_avatar_rect.custom_minimum_size = Vector2(112, 112)
	_avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if _mode == Mode.SELF:
		var avatar_btn := Button.new()
		avatar_btn.custom_minimum_size = Vector2(112, 112)
		avatar_btn.focus_mode = Control.FOCUS_NONE
		avatar_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		avatar_btn.tooltip_text = _text("换头像", "Change avatar")
		var box := Tokens.flat_box(Tokens.SURFACE_RAISED, Tokens.GOLD_EDGE, 2)
		for state in ["normal", "hover", "pressed"]:
			avatar_btn.add_theme_stylebox_override(state, box)
		avatar_btn.pressed.connect(_open_avatar_picker)
		_avatar_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		avatar_btn.add_child(_avatar_rect)
		row.add_child(avatar_btn)
	else:
		row.add_child(_avatar_rect)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	row.add_child(column)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY + 4)
	_name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	column.add_child(_name_label)

	_days_label = Label.new()
	_days_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(_days_label)

	_pet_label = Label.new()
	_pet_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(_pet_label)
	return panel


# --- SELF：昵称 ---------------------------------------------------------------


func _name_section() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)
	column.add_child(_section_title(_text("昵称", "Nickname")))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	column.add_child(row)

	_name_edit = LineEdit.new()
	# 与 database/001 的 player_name_length 一致。前端挡住比让后端回 400 好。
	_name_edit.max_length = 24
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	row.add_child(_name_edit)

	var save := Button.new()
	save.text = _text("改名", "Rename")
	save.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	save.pressed.connect(_on_rename_pressed)
	row.add_child(save)

	_name_hint = Label.new()
	_name_hint.add_theme_font_size_override("font_size", Tokens.FONT_BODY - 3)
	_name_hint.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
	_name_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_name_hint)
	return panel


# --- SELF：资料 ---------------------------------------------------------------


func _bio_section() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)
	column.add_child(_section_title(_text("资料", "About")))

	# 性别。「不显示」是选项里的最后一项，但它落到的是**可见性开关**，
	# 不是性别字段的值 —— 002 里那个 'undisclosed' 值新 UI 一律不写，
	# 同一件事有两种表示法迟早会不一致。
	_gender_pick = OptionButton.new()
	_gender_pick.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_gender_pick.add_item(_text("男", "Male"))
	_gender_pick.add_item(_text("女", "Female"))
	_gender_pick.add_item(_text("其他", "Other"))
	_gender_pick.add_item(_text("不显示", "Hidden"))
	column.add_child(_labeled(_text("性别", "Gender"), _gender_pick))

	# 生日。**只能设置一次** —— 设过之后两个下拉变只读。
	var birth_row := HBoxContainer.new()
	birth_row.add_theme_constant_override("separation", Tokens.GAP_S)
	_month_pick = OptionButton.new()
	_month_pick.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_month_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_month_pick.add_item(_text("月份", "Month"), 0)
	for m in range(1, 13):
		_month_pick.add_item(_text("%d 月" % m, "%d" % m), m)
	_month_pick.item_selected.connect(func(_i: int) -> void: _rebuild_days())
	birth_row.add_child(_month_pick)

	_day_pick = OptionButton.new()
	_day_pick.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_day_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	birth_row.add_child(_day_pick)
	_rebuild_days()
	column.add_child(_labeled(_text("生日", "Birthday"), birth_row))

	_birth_private = CheckBox.new()
	_birth_private.text = _text("生日不公开", "Hide birthday")
	_birth_private.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	column.add_child(_birth_private)

	_region_pick = OptionButton.new()
	_region_pick.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	for region in REGIONS:
		_region_pick.add_item(_text(str(region[1]), str(region[2])))
	_region_pick.add_item(_text("不显示", "Hidden"))
	column.add_child(_labeled(_text("地区", "Region"), _region_pick))

	_signature_edit = LineEdit.new()
	# 与 004 的 signature_length 一致。签名**没有可见性开关**：
	# 它是表达，清空即隐藏。见设计文档第三节。
	_signature_edit.max_length = 60
	_signature_edit.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_signature_edit.placeholder_text = _text("说点什么…（清空即不显示）", "Say something…")
	column.add_child(_labeled(_text("签名", "Signature"), _signature_edit))

	_save_btn = Button.new()
	_save_btn.text = _text("保存资料", "Save")
	_save_btn.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_save_btn.pressed.connect(_on_save_bio_pressed)
	column.add_child(_save_btn)
	return panel


# --- PUBLIC ------------------------------------------------------------------


func _public_bio_block() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())
	panel.name = "PublicBio"
	var column := VBoxContainer.new()
	column.name = "Rows"
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)
	return panel


func _report_button() -> Control:
	var button := Button.new()
	button.text = _text("举报该玩家", "Report player")
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	# 举报入口是**发布必需项**（Google Play UGC 政策 / App Store 1.2）——
	# 有玩家可见的自定义昵称与签名，就必须有地方举报。后端受理流程不在本批，
	# 所以这里先只收下并告诉玩家收到了；接上之后把这个分支换掉。
	button.pressed.connect(func() -> void:
		DialogService.info({
			"title": _text("已记录", "Received"),
			"body": _text(
				"举报已记录。处理流程还在建设中，暂时不会有回执。",
				"Report noted. The review pipeline is still being built."),
		}))
	return button


# --- 占位与入口位 -------------------------------------------------------------


func _placeholder_block(title: String, rows: Array) -> Control:
	# ⚠️ **只在 SELF 模式出现。** 见文件顶部第 1 条。
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box())
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)
	column.add_child(_section_title(title))
	for row in rows:
		var line := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = str(row)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
		line.add_child(name_label)
		var value := Label.new()
		value.text = _text("敬请期待", "Coming soon")
		value.add_theme_color_override("font_color", Tokens.TEXT_DISABLED)
		line.add_child(value)
		column.add_child(line)
	return panel


func _bind_account_slot() -> Control:
	# 位置先留。功能（Google / Apple 登录）是下一批 —— 但这一页恰恰是第一个
	# 让玩家产生「我不想丢」的东西，所以入口该从第一天就在这儿。
	var button := Button.new()
	button.text = _text("绑定账号，防止换设备丢失（敬请期待）", "Link account (coming soon)")
	button.disabled = true
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	return button


# --- 数据 ---------------------------------------------------------------------


func _load() -> void:
	_set_status(_text("加载中…", "Loading…"))
	var result: Dictionary
	if _mode == Mode.SELF:
		result = await AccountManager.fetch_my_profile()
	else:
		result = await AccountManager.fetch_public_profile(_target_code)
	# await 期间玩家可能已经退出这一页。
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		_set_status(_failure_text(result))
		return
	_data = result.get("body", {})
	_set_status("")
	_refresh()


func _refresh() -> void:
	var name_text := _field("player_name")
	var code := _field("friend_code")
	# 唯一的显示名拼法。见文件顶部第 3 条。
	_name_label.text = AccountManager.display_name(name_text, code)
	_avatar_rect.texture = Catalog.texture_for(_field("avatar"))

	var days := _field_int("days_since_created", 1)
	_days_label.text = _text("第 %d 天" % days, "Day %d" % days)

	_pet_label.text = _text("出战宠物：%s", "Pet: %s") % _pet_display(_field("showcase_pet"))

	if _mode == Mode.SELF:
		_refresh_self()
	else:
		_refresh_public()


func _refresh_self() -> void:
	_name_edit.text = _field("player_name")
	var ready_at := _field("rename_available_at")
	if ready_at.is_empty():
		_name_hint.text = _text("首次改名免费。之后每 7 天一次。",
			"First rename is free. After that, once every 7 days.")
	else:
		_name_hint.text = _text("下次可改名：%s", "Next rename: %s") % ready_at.left(10)

	var gender_index := GENDER_VALUES.find(_field("gender"))
	if _field("gender_visibility", "public") == "private":
		_gender_pick.select(GENDER_VALUES.size())  # 「不显示」
	elif gender_index >= 0:
		_gender_pick.select(gender_index)
	else:
		_gender_pick.select(GENDER_VALUES.size())

	var month := _field_int("birth_month")
	var day := _field_int("birth_day")
	if month > 0:
		_month_pick.select(_month_pick.get_item_index(month))
		_rebuild_days()
		_day_pick.select(_day_pick.get_item_index(day))
		# 只能设一次：设过就锁死。后端也拦着，这里是为了让玩家看得见规则。
		_month_pick.disabled = true
		_day_pick.disabled = true
		_birth_private.text = _text("生日不公开（生日已设定，不可更改）",
			"Hide birthday (birthday is locked)")
	_birth_private.button_pressed = _field("birth_visibility", "public") == "private"

	if _field("region_visibility", "public") == "private":
		_region_pick.select(REGIONS.size())
	else:
		var region := _field("region")
		var found := -1
		for i in REGIONS.size():
			if str(REGIONS[i][0]) == region:
				found = i
				break
		_region_pick.select(found if found >= 0 else REGIONS.size())

	_signature_edit.text = _field("signature")


func _refresh_public() -> void:
	var panel := _find_child_by_name(_body, "PublicBio")
	if panel == null:
		return
	var column := panel.get_node_or_null("Rows") as VBoxContainer
	if column == null:
		return
	for child in column.get_children():
		child.queue_free()

	# ⚠️ 这里**只画收到了什么**。隐藏的字段后端根本没发过来，
	# 所以「没填」和「隐藏」在这一层完全一样 —— 那是刻意的隐私性质。
	var signature := _field("signature")
	if not signature.is_empty():
		column.add_child(_read_only_row(_text("签名", "Signature"), signature))
	if _data.has("gender"):
		var index := GENDER_VALUES.find(_field("gender"))
		var labels := [_text("男", "Male"), _text("女", "Female"), _text("其他", "Other")]
		if index >= 0:
			column.add_child(_read_only_row(_text("性别", "Gender"), str(labels[index])))
	if _data.has("birth_month"):
		var text := _text("%d 月 %d 日", "%d/%d") % [
			_field_int("birth_month", 1), _field_int("birth_day", 1)]
		column.add_child(_read_only_row(_text("生日", "Birthday"), text))
	if _data.has("region"):
		column.add_child(
			_read_only_row(_text("地区", "Region"), _region_label(_field("region"))))
	if column.get_child_count() == 0:
		column.add_child(_read_only_row(
			_text("资料", "About"), _text("这位玩家没有公开资料", "Nothing shared")))


# --- 操作 ---------------------------------------------------------------------


func _on_rename_pressed() -> void:
	if _busy:
		return
	var wanted := _name_edit.text.strip_edges()
	if wanted == _field("player_name"):
		_set_status(_text("昵称没有变化", "Nickname unchanged"))
		return
	_begin_submit()
	_finish_submit(await AccountManager.update_profile({"player_name": wanted}))


func _on_save_bio_pressed() -> void:
	if _busy:
		return
	var payload := _bio_payload()
	# 生日只能设一次，所以第一次设置要二次确认 —— 手滑填错会永久顶着错生日，
	# 而那必然产生客服工单。已经设过的不再问（后端会保留原值）。
	var first_time := _field_int("birth_month") == 0 and int(payload.get("birth_month", 0)) > 0
	if first_time:
		DialogService.confirm({
			"title": _text("确认生日", "Confirm birthday"),
			"body": _text(
				"生日设置后**不可更改**。确认是 %d 月 %d 日吗？",
				"Your birthday cannot be changed later. Confirm %d/%d?"
			) % [int(payload["birth_month"]), int(payload["birth_day"])],
			"confirm_text": _text("确认", "Confirm"),
			"on_result": func(result: String) -> void:
				if result == "confirm":
					_save_bio(payload),
		})
		return
	await _save_bio(payload)


func _save_bio(payload: Dictionary) -> void:
	_begin_submit()
	_finish_submit(await AccountManager.update_bio(payload))


func _save_avatar(value: String) -> void:
	_begin_submit()
	_finish_submit(await AccountManager.update_profile({"avatar": value}))


func _bio_payload() -> Dictionary:
	var gender_index := _gender_pick.selected
	var hide_gender := gender_index >= GENDER_VALUES.size()
	# 选「不显示」时**保留原来的值**，只把可见性关掉 —— 否则玩家关一次显示
	# 就把自己填过的内容抹了，再打开时是空的。
	var gender: Variant = _field("gender") if hide_gender else GENDER_VALUES[gender_index]
	if typeof(gender) == TYPE_STRING and str(gender).is_empty():
		gender = null

	var region_index := _region_pick.selected
	var hide_region := region_index >= REGIONS.size()
	var region: Variant = _field("region") if hide_region else str(REGIONS[region_index][0])
	if typeof(region) == TYPE_STRING and str(region).is_empty():
		region = null

	var month := _month_pick.get_selected_id()
	var day := _day_pick.get_selected_id()
	var has_birth := month > 0 and day > 0

	return {
		"gender": gender,
		"birth_month": month if has_birth else null,
		"birth_day": day if has_birth else null,
		"region": region,
		"signature": _signature_edit.text,
		"gender_visibility": "private" if hide_gender else "public",
		"birth_visibility": "private" if _birth_private.button_pressed else "public",
		"region_visibility": "private" if hide_region else "public",
	}


# ⚠️ **不要合并成 _submit(AccountManager.update_xxx(...))。**
# GDScript 不允许把一个协程调用当作值传进函数 —— 那是解析期错误，
# 而资料页是运行时 load 的，解析错误在玩家点开之前不会有任何征兆。
# 所以是 begin / finish 两半，await 由调用方自己写出来。
func _begin_submit() -> void:
	_busy = true
	_set_status(_text("保存中…", "Saving…"))


func _finish_submit(result: Dictionary) -> void:
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		_set_status(_failure_text(result))
		return
	_data = result.get("body", {})
	_set_status(_text("已保存", "Saved"))
	_refresh()


func _open_avatar_picker() -> void:
	if ModalStack.has(PICKER_MODAL_ID):
		return
	var picker := AvatarPicker.new() as Control
	picker.call("configure", _field("avatar"))
	picker.connect("picked", func(value: String) -> void:
		ModalStack.pop(PICKER_MODAL_ID)
		_save_avatar(value))
	picker.connect("dismissed", func() -> void: ModalStack.pop(PICKER_MODAL_ID))
	ModalStack.push(picker, {
		"id": PICKER_MODAL_ID,
		"owner": self,
		"priority": PICKER_PRIORITY,
		"dismiss_on_backdrop": true,
	})


# --- 小工具 -------------------------------------------------------------------


# ⚠️ **JSON 的 null 在 GDScript 里是 null 变体，而 str(null) 得到字面量 "<null>"。**
#
# 后端有一批字段是可空的（rename_available_at / signature / gender / region /
# showcase_pet），直接写 str(_data.get(key, "")) 的话，**没设过的玩家会在界面上
# 看到 "<null>"** —— 签名栏里写着 <null>、出战宠物是 <null>。
# 预览截图第一版就是这样。所有读 _data 的地方一律走这两个函数。
func _field(key: String, fallback: String = "") -> String:
	var value: Variant = _data.get(key, null)
	if value == null:
		return fallback
	return str(value)


func _field_int(key: String, fallback: int = 0) -> int:
	var value: Variant = _data.get(key, null)
	if value == null:
		return fallback
	return int(value)


# 宠物在数据里是 id（pet_rabbit），玩家不该看到 id。
func _pet_display(pet_id: String) -> String:
	if pet_id.is_empty():
		return "—"
	var table: Variant = DataRegistry.get_table("pets")
	if typeof(table) == TYPE_DICTIONARY:
		var english := TranslationServer.get_locale().begins_with("en")
		for entry in (table as Dictionary).get("pets", []):
			var row := entry as Dictionary
			if str(row.get("id", "")) == pet_id:
				return str(row.get("name_en" if english else "name", pet_id))
	# 查不到就退回 id：一个认不出来的宠物不该让整页画不出来。
	return pet_id


func _rebuild_days() -> void:
	var month := _month_pick.get_selected_id()
	var previous := _day_pick.get_selected_id()
	_day_pick.clear()
	_day_pick.add_item(_text("日期", "Day"), 0)
	# 按月份卡实际天数，挡住 2/31 这类 —— 与 002 的 birth_day_in_month 一致。
	# 不卡的话玩家能选出一个必然被后端拒绝的日子。
	var limit := 31 if month <= 0 else int(DAYS_IN_MONTH[month - 1])
	for d in range(1, limit + 1):
		_day_pick.add_item(_text("%d 日" % d, "%d" % d), d)
	var index := _day_pick.get_item_index(previous)
	if index >= 0:
		_day_pick.select(index)


func _labeled(label_text: String, control: Control) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY - 2)
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	row.add_child(label)
	row.add_child(control)
	return row


func _read_only_row(label_text: String, value_text: String) -> Control:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	row.add_child(label)
	var value := Label.new()
	value.text = value_text
	value.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	row.add_child(value)
	return row


func _section_title(text_value: String) -> Control:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	label.add_theme_color_override("font_color", Tokens.GOLD)
	return label


func _region_label(code: String) -> String:
	for region in REGIONS:
		if str(region[0]) == code:
			return _text(str(region[1]), str(region[2]))
	return code


func _find_child_by_name(root: Node, wanted: String) -> Node:
	for child in root.get_children():
		if child.name == wanted:
			return child
	return null


func _failure_text(result: Dictionary) -> String:
	var code := int(result.get("code", 0))
	if code == 0:
		return _text("连不上服务器，稍后再试", "Can't reach the server, try again later")
	# 后端的 detail 已经脱敏（backend 那边有测试钉着不含 token），可以直接显示。
	return str(result.get("error", "HTTP %d" % code))


func _set_status(text_value: String) -> void:
	if _status != null and is_instance_valid(_status):
		_status.text = text_value


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
