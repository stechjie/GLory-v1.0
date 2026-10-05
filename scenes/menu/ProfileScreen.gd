extends Control
# 玩家资料页。入口是主菜单左上角那个名牌。

const SfxService := preload("res://ui/services/SfxService.gd")
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
const FramePicker := preload("res://scenes/menu/FramePickerPanel.gd")
const TouchChoice := preload("res://ui/components/TouchChoiceButton.gd")
# 引用常量而不是写字符串字面量。第一版这里写的是 "confirm"，而真值是 "confirmed"
# —— 判断永远为假，玩家第一次设生日点了确认什么都不会发生，且不报任何错。
# 仓库里 TutorialMode 就是引用常量的（SkipDialog.RESULT_CONFIRMED）。
const ConfirmDialog := preload("res://ui/components/GloryConfirmDialog.gd")
const MatchHistory := preload("res://scenes/menu/MatchHistoryPanel.gd")
const ReportDialog := preload("res://ui/components/ReportDialog.gd")
const ACTION_BUTTON := preload("res://ui/components/GloryActionButton.tscn")
const PROFILE_BG_TEX := preload("res://assets/ui/profile/hall_of_glory.png")
const RankedTiers := preload("res://scenes/menu/RankedTiers.gd")

signal back_requested

enum Mode { SELF, PUBLIC }

const PICKER_MODAL_ID := "profile_avatar_picker"
const FRAME_PICKER_MODAL_ID := "profile_frame_picker"
const HISTORY_MODAL_ID := "profile_match_history"

# 资料页专用的默认框素材：`main_menu_live/profile_avatar.png` 把内圆抠透明后的副本。
# **刻意不写进 data/avatars.json** —— 那一行是「资料页 + 大厅名牌」共用的，
# 改了会连带改掉大厅的画法。只在本文件里用，见 `_profile_frame_texture`。
const FRAME_DEFAULT_ID := "frame_default"
const FRAME_DEFAULT_HOLLOW_PATH := "res://assets/ui/shop/headframes/frame_default.png"
# 懒加载缓存（对齐 AvatarCatalog 的做法：只有资料页用得到的东西不占启动预算）。
var _frame_default_hollow: Texture2D

# 「战绩」块里三个要异步填的值标签（_load_ranked）。
var _rank_value: Label
var _rank_badge: TextureRect
var _record_value: Label
var _credit_value: Label
var _rank_progress: ProgressBar
var _rank_progress_label: Label
var _next_rank_label: Label
var _wins_value: Label
var _win_rate_value: Label
var _tier_icons: Array[TextureRect] = []
var _overview_panel: Control
var _settings_panel: Control
var _overview_tab: Button
var _settings_tab: Button
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
# 从哪儿点进来看的（举报时告诉服务器该复制哪一种证据，见 backend/app/reports.py）：
# 好友列表 / 最近同房 = profile，世界频道 = world。
var _report_context := "profile"
var _data: Dictionary = {}
var _busy := false

var _body: VBoxContainer
var _public_rows: VBoxContainer
var _status: Label
var _avatar_rect: TextureRect
var _frame_rect: TextureRect
var _name_label: Label
var _days_label: Label
var _pet_label: Label
var _name_edit: LineEdit
var _name_hint: Label
var _gender_pick: OptionButton
var _month_pick: TouchChoice
var _day_pick: TouchChoice
var _birth_private: CheckBox
var _region_pick: OptionButton
var _signature_edit: LineEdit
var _save_btn: Button
var _delete_code_edit: LineEdit
var _delete_btn: Button


# 加进树之前调。不调就是「看自己」。
#
# 刻意做成两个具名方法而不是 configure(mode) —— 调用方（Main.gd）要传 Mode.SELF
# 就得 preload 本脚本，而那会把 Tokens / Theming / AvatarCatalog / AvatarPicker /
# 主菜单背景图的整张依赖图拉进 Main 的加载路径。Main.gd 的 _load_screen 上面
# 那段注释量过这笔账：界面依赖图压在启动路径上要多花约 1.5 秒。
func configure_self() -> void:
	_mode = Mode.SELF
	_target_code = ""


func configure_public(friend_code: String, report_context: String = "profile") -> void:
	_mode = Mode.PUBLIC
	_target_code = friend_code
	_report_context = report_context


func _ready() -> void:
	theme = Theming.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_load()


func _exit_tree() -> void:
	# 页面被关掉时把浮层一起收走，否则它会留在 ModalStack 上盖住主菜单。
	if ModalStack.has(PICKER_MODAL_ID):
		ModalStack.pop(PICKER_MODAL_ID)
	if ModalStack.has(FRAME_PICKER_MODAL_ID):
		ModalStack.pop(FRAME_PICKER_MODAL_ID)
	if ModalStack.has(HISTORY_MODAL_ID):
		ModalStack.pop(HISTORY_MODAL_ID)


# --- 骨架 ---------------------------------------------------------------------


func _build() -> void:
	var bg := TextureRect.new()
	bg.texture = PROFILE_BG_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var dim := ColorRect.new()
	# A moderate veil keeps text readable while the profile art remains visible.
	dim.color = Color(0.008, 0.016, 0.031, 0.38)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	# 游戏是 **1600x720 横屏**（project.godot 的 viewport）。
	# 第一版做成了竖着长的单列，在真实画布上必须往下滚 —— 横屏游戏里
	# 需要滚动的资料页是错的。现在是三栏，一屏放得下。
	#
	# ScrollContainer 仍然留着，但它是**兜底**不是主要布局：更窄的机型
	# （或以后往栏里加东西）时还能滚，正常比例下根本不会出现滚动条。
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", Tokens.GAP_M)
	center.add_child(_body)

	_body.add_child(_header())

	if _mode == Mode.SELF:
		var tabs := HBoxContainer.new()
		tabs.alignment = BoxContainer.ALIGNMENT_CENTER
		tabs.add_theme_constant_override("separation", Tokens.GAP_S)
		_body.add_child(tabs)
		_overview_tab = ACTION_BUTTON.instantiate() as Button
		_overview_tab.text = _text("总览", "Overview")
		_overview_tab.custom_minimum_size = Vector2(190, Tokens.TOUCH_MIN)
		_overview_tab.pressed.connect(func() -> void: _select_profile_tab(false))
		tabs.add_child(_overview_tab)
		var history_tab := ACTION_BUTTON.instantiate() as Button
		history_tab.text = _text("对局记录", "Match History")
		history_tab.custom_minimum_size = Vector2(190, Tokens.TOUCH_MIN)
		history_tab.pressed.connect(_open_match_history)
		tabs.add_child(history_tab)
		_settings_tab = ACTION_BUTTON.instantiate() as Button
		_settings_tab.text = _text("资料设置", "Profile Settings")
		_settings_tab.custom_minimum_size = Vector2(190, Tokens.TOUCH_MIN)
		_settings_tab.pressed.connect(func() -> void: _select_profile_tab(true))
		tabs.add_child(_settings_tab)

		_overview_panel = HBoxContainer.new()
		_overview_panel.add_theme_constant_override("separation", Tokens.GAP_M)
		_body.add_child(_overview_panel)
		_overview_panel.add_child(_column(400, [_identity_card()]))
		_overview_panel.add_child(_column(780, [_record_block()]))

		_settings_panel = HBoxContainer.new()
		_settings_panel.add_theme_constant_override("separation", Tokens.GAP_M)
		_settings_panel.alignment = BoxContainer.ALIGNMENT_CENTER
		_body.add_child(_settings_panel)
		_settings_panel.add_child(_column(400, [_name_section(), _bind_account_slot()]))
		_settings_panel.add_child(_column(440, [_bio_section()]))
		_settings_panel.add_child(_column(340, [_danger_zone()]))
		_select_profile_tab(false)
	else:
		var columns := HBoxContainer.new()
		columns.add_theme_constant_override("separation", Tokens.GAP_M)
		columns.alignment = BoxContainer.ALIGNMENT_CENTER
		_body.add_child(columns)
		columns.add_child(_column(400, [_identity_card()]))
		columns.add_child(_column(440, [_public_bio_block(), _friend_request_button()]))
		var report_row := HBoxContainer.new()
		report_row.alignment = BoxContainer.ALIGNMENT_END
		report_row.add_child(_report_button())
		_body.add_child(report_row)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 26)
	_status.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	_body.add_child(_status)


func _select_profile_tab(settings: bool) -> void:
	_overview_panel.visible = not settings
	_settings_panel.visible = settings
	for button in [_overview_tab, _settings_tab]:
		var active: bool = (button == _settings_tab) == settings
		if active:
			button.add_theme_stylebox_override("normal", Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.GOLD_EDGE))
			button.add_theme_stylebox_override("hover", Tokens.button_box(Tokens.SURFACE_RAISED, Tokens.GOLD_EDGE))
			button.add_theme_color_override("font_color", Tokens.GOLD)
			button.add_theme_color_override("font_hover_color", Tokens.GOLD)
		else:
			button.remove_theme_stylebox_override("normal")
			button.remove_theme_stylebox_override("hover")
			button.remove_theme_color_override("font_color")
			button.remove_theme_color_override("font_hover_color")


# 一栏。定宽是刻意的：三栏各自内容长度差很多，让它们自己去抢宽度
# 会导致换个语言（英文更长）就重排成另一个样子。
func _column(width: float, panels: Array) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(width, 0)
	column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	column.add_theme_constant_override("separation", Tokens.GAP_M)
	for panel in panels:
		column.add_child(panel as Control)
	return column


func _header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_M)

	var back := Button.new()
	back.text = _text("← 返回", "← Back")
	back.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	back.pressed.connect(func() -> void: back_requested.emit())
	row.add_child(back)

	var title := Label.new()
	title.text = _text("玩家主页", "Player Profile") if _mode == Mode.SELF \
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
	if _mode == Mode.SELF:
		panel.add_theme_stylebox_override("panel", Tokens.panel_box(Color.TRANSPARENT, Color.TRANSPARENT, Tokens.GAP_M))
		panel.custom_minimum_size = Vector2(400, 430)
	else:
		panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_M))

	var content: BoxContainer
	if _mode == Mode.SELF:
		content = VBoxContainer.new()
		content.alignment = BoxContainer.ALIGNMENT_CENTER
	else:
		content = HBoxContainer.new()
	content.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(content)

	_avatar_rect = TextureRect.new()
	_avatar_rect.custom_minimum_size = Vector2.ZERO
	_avatar_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var avatar_stage := Control.new()
	var avatar_size := 176 if _mode == Mode.SELF else 112
	avatar_stage.custom_minimum_size = Vector2(avatar_size, avatar_size)
	avatar_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	avatar_stage.add_child(_avatar_rect)
	_frame_rect = TextureRect.new()
	_frame_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_frame_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	avatar_stage.add_child(_frame_rect)

	if _mode == Mode.SELF:
		var avatar_btn := Button.new()
		avatar_btn.custom_minimum_size = Vector2(avatar_size, avatar_size)
		avatar_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		avatar_btn.focus_mode = Control.FOCUS_NONE
		avatar_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		avatar_btn.tooltip_text = _text("换头像", "Change avatar")
		var clear_box := Tokens.flat_box(Color.TRANSPARENT, Color.TRANSPARENT, 0)
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			avatar_btn.add_theme_stylebox_override(state, clear_box)
		avatar_btn.pressed.connect(_open_avatar_picker)
		avatar_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		avatar_btn.add_child(avatar_stage)
		content.add_child(avatar_btn)
	else:
		content.add_child(avatar_stage)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	content.add_child(column)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY + (9 if _mode == Mode.SELF else 4))
	_name_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	if _mode == Mode.SELF:
		_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_name_label)

	_days_label = Label.new()
	_days_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	if _mode == Mode.SELF:
		_days_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_days_label)

	_pet_label = Label.new()
	_pet_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	if _mode == Mode.SELF:
		_pet_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_pet_label)
	if _mode == Mode.SELF:
		var frame_button: Button = ACTION_BUTTON.instantiate()
		frame_button.text = _text("更换头像框", "Change frame")
		frame_button.custom_minimum_size = Vector2(150, Tokens.TOUCH_MIN)
		frame_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		frame_button.pressed.connect(_open_frame_picker)
		column.add_child(frame_button)
	return panel


# --- SELF：昵称 ---------------------------------------------------------------


func _name_section() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_M))

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
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_M))

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
	_month_pick = TouchChoice.new()
	_month_pick.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_month_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_month_pick.add_item(_text("月份", "Month"), 0)
	for m in range(1, 13):
		_month_pick.add_item(_text("%d 月" % m, "%d" % m), m)
	_month_pick.item_selected.connect(func(_i: int) -> void: _rebuild_days())
	birth_row.add_child(_month_pick)

	_day_pick = TouchChoice.new()
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
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_M))
	_public_rows = VBoxContainer.new()
	_public_rows.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(_public_rows)
	return panel


func _report_button() -> Control:
	var button := Button.new()
	button.text = _text("举报该玩家", "Report player")
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	# 举报入口是**发布必需项**（Google Play UGC 政策 / App Store 1.2）——
	# 有玩家可见的自定义昵称与签名，就必须有地方举报。2026-09-27 接上后端（backend/app/reports.py）：
	# 证据由服务器复制，处理在网页后台「举报」页。
	button.pressed.connect(func() -> void:
		ReportDialog.new().present(self, _target_code,
			AccountManager.display_name(_field("player_name"), _target_code), _report_context))
	return button

var _friend_action: Button
var _block_action: Button

func _update_friend_actions() -> void:
	if _friend_action == null:
		return
	var relation := str(_data.get("relation", "none"))
	_friend_action.text = _text("删除好友", "Remove friend") if relation == "friends" else _text("添加朋友请求", "Send friend request")
	# ⚠️ **不要**因为 relation == "blocked" 就把这两个按钮置灰（9.11 测试报告）。
	#
	# 服务端刻意不区分拉黑方向：`friends.relation_to()` 对「我拉黑了他」和
	# 「他拉黑了我」都只回 `blocked`（见那边注释：把"对方拉黑了我"说破，等于给
	# 骚扰者一个探测器）。而**按钮变灰恰恰就是把方向说破的最直接方式** ——
	# 被拉黑的人一进资料页看到两个按钮全不可用，就"推理"出了自己被拉黑。
	#
	# 所以按钮一律照常可用，让**动作**去回答：
	#   * 添加朋友请求 -> 服务端回通用失败「无法向该玩家发送好友请求」
	#     （我拉黑过对方时回的是「你已拉黑对方。先解除拉黑才能加好友」，
	#      那是我自己做的事，明说无妨）；
	#   * 拉入黑名单   -> 正常执行：对方先拉黑了我，我仍然可以拉黑他。
	# 只有"看自己"（relation == "self"）这两个动作才真的没有意义。
	_friend_action.disabled = relation == "self"
	var blocked_by_me := bool(_data.get("blocked_by_me", false))
	_block_action.text = _text("解除黑名单", "Unblock player") if blocked_by_me else _text("拉入黑名单", "Block player")
	# 文案只取决于**我自己的**黑名单（blocked_by_me），因此"解除黑名单"不会泄露
	# 对方的选择；对方拉黑我时这里仍是「拉入黑名单」，且可用。
	_block_action.disabled = relation == "self"

func _on_block_action() -> void:
	if not bool(_data.get("blocked_by_me", false)):
		_confirm_friend_action(true)
		return
	_block_action.disabled = true
	var response: Dictionary = await _send_unblock()
	if not is_inside_tree():
		return
	if int(response.get("code", 0)) >= 200 and int(response.get("code", 0)) < 300:
		_data["relation"] = "none"
		_data["blocked_by_me"] = false
		_set_status(_text("已解除黑名单，可重新发送好友请求", "Unblocked. You can send a friend request again."))
	else:
		_set_status(str(response.get("error", _text("解除失败，请重试", "Unable to unblock. Please retry."))))
	_update_friend_actions()

func _send_unblock() -> Dictionary:
	return await AccountManager.unblock_player(_target_code)

func _confirm_friend_action(blocking: bool) -> void:
	DialogService.confirm({"owner": self, "intent": ConfirmDialog.Intent.DANGER,
		"body": _text("拉黑将同时解除好友关系，并阻止对方发送好友请求。", "Blocking removes the friendship and prevents requests.") if blocking else _text("删除后，你也会从对方好友列表中消失。", "Removing also removes you from their friend list."),
		"confirm_text": _text("拉黑", "Block") if blocking else _text("删除", "Remove"),
		"on_result": func(result: String, _request_id: String) -> void:
			if result != ConfirmDialog.RESULT_CONFIRMED:
				return
			_friend_action.disabled = true
			_block_action.disabled = true
			var response: Dictionary = await _send_friend_change(blocking)
			if not is_inside_tree():
				return
			if int(response.get("code", 0)) >= 200 and int(response.get("code", 0)) < 300:
				_data["relation"] = "blocked" if blocking else "none"
				_data["blocked_by_me"] = blocking
				_set_status(_text("已拉黑", "Blocked") if blocking else _text("已删除好友", "Friend removed"))
			else:
				_set_status(str(response.get("error", "操作失败")))
			_update_friend_actions()})

func _send_friend_change(blocking: bool) -> Dictionary:
	return await AccountManager.block_player(_target_code) if blocking else await AccountManager.remove_friend(_target_code)

# 与 _send_unblock / _send_friend_change 同一套接缝：出网请求单独一个方法，
# 检查（tools/friends08_check.gd）才能把"服务端拒绝"这条路径驱动起来 ——
# 否则「被对方拉黑时点加好友要给通用失败提示」就只能靠手测。
func _send_friend_request() -> Dictionary:
	return await AccountManager.send_friend_request(_target_code)

func _friend_request_button() -> Control:
	var column := VBoxContainer.new()
	var button := Button.new()
	_friend_action = button
	button.text = _text("添加朋友请求", "Send friend request")
	button.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	button.pressed.connect(func() -> void:
		if str(_data.get("relation", "")) == "friends":
			_confirm_friend_action(false)
			return
		button.disabled = true
		var result: Dictionary = await _send_friend_request()
		if not is_inside_tree():
			return
		button.disabled = false
		if int(result.get("code", 0)) >= 200 and int(result.get("code", 0)) < 300:
			var accepted := str((result.get("body", {}) as Dictionary).get("result", "")) == "accepted"
			_data["relation"] = "friends" if accepted else "pending_out"
			_update_friend_actions()
			_set_status(_text("已成为好友", "You are now friends") if accepted else _text("已发送好友请求", "Friend request sent"))
		else:
			_set_status(str(result.get("error", _text("请求失败", "Request failed")))))
	column.add_child(button)
	_block_action = Button.new()
	_block_action.text = _text("拉入黑名单", "Block player")
	_block_action.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_block_action.pressed.connect(_on_block_action)
	column.add_child(_block_action)
	return column


# --- 占位与入口位 -------------------------------------------------------------


# Names and emblems live together in RankedTiers; score conversion stays server-owned.


# 「战绩」块。**半真半占位** —— 这是它与 _placeholder_block 的区别。
#
# 段位 / 场次 / 信誉分是真数据（第 5 步）；「等级」系统仍然不存在，照旧「敬请期待」。
# 对局历史是个真入口（第 2 步）。
#
# ⚠️ **这里预取一次 /v1/me/ranked。** 第 2 步时我刻意不预取历史（那是一整页
# 二十局的数据，为角落一行汇总让所有人多等一趟不划算）；段位不一样 ——
# 它**就是这个块存在的理由**，而且响应只有十来个数字。
#
# 同 _placeholder_block：**只在 SELF 模式出现**。PUBLIC 看不到别人的段位 ——
# 后端只有 /v1/me/ranked，压根没有「看别人段位」这个接口。
# 信誉分更是只给自己看（docs/排位系统设计.md 第四节：公开等于发一个新的骂人理由）。
func _record_block() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Color.TRANSPARENT, Color.TRANSPARENT, Tokens.GAP_M))
	panel.custom_minimum_size = Vector2(780, 430)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_M)
	panel.add_child(column)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	heading.add_child(_section_title(_text("本赛季排位", "Season Ranked")))
	var heading_spacer := Control.new()
	heading_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(heading_spacer)
	_credit_value = Label.new()
	_credit_value.text = _text("信誉分 —", "Credit —")
	_credit_value.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	heading.add_child(_credit_value)

	var rank_row := HBoxContainer.new()
	rank_row.add_theme_constant_override("separation", Tokens.GAP_M)
	column.add_child(rank_row)
	_rank_badge = TextureRect.new()
	_rank_badge.name = "RankBadge"
	_rank_badge.custom_minimum_size = Vector2(192, 192)
	_rank_badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rank_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_rank_badge.visible = false
	rank_row.add_child(_rank_badge)
	var rank_text := VBoxContainer.new()
	rank_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rank_text.alignment = BoxContainer.ALIGNMENT_CENTER
	rank_text.add_theme_constant_override("separation", Tokens.GAP_S)
	rank_row.add_child(rank_text)
	var eyebrow := Label.new()
	eyebrow.text = _text("当前段位", "Current rank")
	eyebrow.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	rank_text.add_child(eyebrow)
	_rank_value = Label.new()
	_rank_value.text = "—"
	_rank_value.add_theme_font_size_override("font_size", 34)
	_rank_value.add_theme_color_override("font_color", Tokens.GOLD)
	rank_text.add_child(_rank_value)
	_rank_progress_label = Label.new()
	_rank_progress_label.text = _text("正在读取排位进度…", "Loading rank progress…")
	_rank_progress_label.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	rank_text.add_child(_rank_progress_label)
	_rank_progress = ProgressBar.new()
	_rank_progress.custom_minimum_size = Vector2(0, 18)
	_rank_progress.show_percentage = false
	_rank_progress.max_value = 100
	rank_text.add_child(_rank_progress)
	_next_rank_label = Label.new()
	_next_rank_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	rank_text.add_child(_next_rank_label)

	var tier_path := HBoxContainer.new()
	tier_path.alignment = BoxContainer.ALIGNMENT_CENTER
	tier_path.add_theme_constant_override("separation", Tokens.GAP_M)
	column.add_child(tier_path)
	for tier in RankedTiers.BADGES.size():
		var tier_icon := TextureRect.new()
		tier_icon.texture = RankedTiers.badge_of(tier)
		tier_icon.custom_minimum_size = Vector2(60, 60)
		tier_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tier_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tier_icon.modulate.a = 0.38
		tier_icon.tooltip_text = RankedTiers.name_of(tier, _is_en())
		tier_path.add_child(tier_icon)
		_tier_icons.append(tier_icon)

	column.add_child(HSeparator.new())
	var stats := HBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	stats.add_theme_constant_override("separation", 64)
	column.add_child(stats)
	_record_value = _rank_stat(stats, _text("排位场次", "Matches"))
	_wins_value = _rank_stat(stats, _text("胜场", "Wins"))
	_win_rate_value = _rank_stat(stats, _text("胜率", "Win rate"))
	_load_ranked()

	var open := ACTION_BUTTON.instantiate() as Button
	open.text = _text("查看最近对局", "Recent Matches")
	open.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	open.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	open.pressed.connect(_open_match_history)
	column.add_child(open)
	return panel


func _rank_stat(parent: HBoxContainer, caption: String) -> Label:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	parent.add_child(box)
	var value := Label.new()
	value.text = "—"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 27)
	value.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	box.add_child(value)
	var name_label := Label.new()
	name_label.text = caption
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	box.add_child(name_label)
	return value


# 战绩块里的一行。返回右边那个值标签，供 _load_ranked 填。
func _record_line(column: VBoxContainer, name_text: String, value_text: String,
		dim: bool = false) -> Label:
	var line := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = name_text
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	line.add_child(name_label)
	var value := Label.new()
	value.text = value_text
	value.add_theme_color_override("font_color",
		Tokens.TEXT_DISABLED if dim else Tokens.TEXT_PRIMARY)
	line.add_child(value)
	column.add_child(line)
	return value


# 拉一次排位数据。失败就留「—」——
# **不要显示 0**：0 分是一个看起来正常的错值，玩家会以为自己掉段了。
# 同主菜单名牌那两个货币位的做法（MainMenu 里那段注释）。
func _load_ranked() -> void:
	var result: Dictionary = await AccountManager.fetch_ranked()
	if not is_inside_tree() or int(result.get("code", 0)) != 200:
		return
	var body: Dictionary = result.get("body", {})
	var tier := clampi(int(body.get("tier", 0)), 0, RankedTiers.BADGES.size() - 1)
	var games := int(body.get("games", 0))
	var score := int(body.get("score", 0))
	var progress := int(body.get("tier_progress", 0))
	var span := int(body.get("tier_span", 0))
	if games <= 0:
		_rank_value.text = _text("尚未排位", "Unranked")
		_rank_badge.visible = false
		_rank_progress.visible = false
		_rank_progress_label.text = _text("完成首场排位后显示段位", "Play a ranked match to reveal your rank")
		_next_rank_label.text = ""
	else:
		_rank_badge.texture = RankedTiers.badge_of(tier)
		_rank_badge.visible = true
		_rank_value.text = RankedTiers.name_of(tier, _is_en())
		if span <= 0:
			_rank_progress.visible = false
			_rank_progress_label.text = _text("累计 %d 排位分" % score, "%d total rank points" % score)
			_next_rank_label.text = _text("最高段位 · 积分持续累积", "Top rank · points continue to accumulate")
		else:
			_rank_progress.visible = true
			_rank_progress.max_value = span
			_rank_progress.value = clampi(progress, 0, span)
			_rank_progress_label.text = _text("本段进度 %d / %d" % [progress, span], "Progress %d / %d" % [progress, span])
			_next_rank_label.text = _text("距「%s」还差 %d 分" % [RankedTiers.name_of(tier + 1), maxi(0, span - progress)],
				"%d points to %s" % [maxi(0, span - progress), RankedTiers.name_of(tier + 1, true)])
	for index in _tier_icons.size():
		_tier_icons[index].modulate.a = 1.0 if games > 0 and index == tier else 0.38
	var wins := int(body.get("wins", 0))
	_record_value.text = str(games)
	_wins_value.text = str(wins)
	_win_rate_value.text = "%d%%" % int(round(float(wins) / float(games) * 100.0)) if games > 0 else "—"

	var credit := int(body.get("credit", 100))
	_credit_value.text = _text("信誉分 %d" % credit, "Credit %d" % credit)
	# <85 是警告线（第四节）。禁赛中另说，那个更要紧。
	if int(body.get("banned_sec", 0)) > 0:
		_credit_value.text = "%s %s" % [_credit_value.text, _text("（禁排位中）", "(suspended)")]
		_credit_value.add_theme_color_override("font_color", Tokens.DANGER)
	elif bool(body.get("credit_warn", false)):
		_credit_value.add_theme_color_override("font_color", Tokens.DANGER)


func _open_match_history() -> void:
	if ModalStack.has(HISTORY_MODAL_ID):
		return
	SfxService.play(SfxService.CUE_UI_POPUP)
	var panel := MatchHistory.new() as Control
	panel.connect("dismissed", func() -> void: ModalStack.pop(HISTORY_MODAL_ID))
	ModalStack.push(panel, {
		"id": HISTORY_MODAL_ID,
		"owner": self,
		"priority": PICKER_PRIORITY,
		"dismiss_on_backdrop": true,
	})


func _placeholder_block(title: String, rows: Array) -> Control:
	# ⚠️ **只在 SELF 模式出现。** 见文件顶部第 1 条。
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Tokens.panel_box(Tokens.SURFACE, Tokens.GOLD_EDGE, Tokens.GAP_M))
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


# 注销账号。**这一版唯一能真正删除个人数据的途径。**
#
# 为什么必须有：生日是「只能设一次」的（产品决定），签名可以清空、性别地区可以
# 设成不显示，但**藏 ≠ 删** —— 没有这个按钮的话，玩家填了生日之后就再也无法
# 删除那条个人数据。可见性开关解决不了它。
#
# 为什么用「手打好友码」而不是密码：匿名账号没有密码，没有任何东西可以在删号前
# 再问一次「真的是你吗」。让玩家把屏幕上那串码打一遍，是这种情况下能做到的最好的
# 确认。同 GitHub 删仓库要你打一遍仓库名。服务端也会再校验一次 ——
# UI 上的确认挡不住一个写错的客户端，而这个操作没有撤销。
func _danger_zone() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override(
		"panel", Tokens.panel_box(Tokens.SURFACE, Tokens.DANGER, Tokens.GAP_M))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Tokens.GAP_S)
	panel.add_child(column)

	var title := Label.new()
	title.text = _text("注销账号", "Delete account")
	title.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	title.add_theme_color_override("font_color", Tokens.DANGER_HOVER)
	column.add_child(title)

	var warn := Label.new()
	# 购买与对局记录会匿名保留（database/017_account_deletion.sql）—— 这件事要在删之前说清楚，
	# 商店的注销政策也要求写明保留了什么、为什么。
	warn.text = _text(
		"昵称、头像、资料、好友和聊天全部删除，宠物、钻石随账号作废，不可恢复，也没有冷静期。"
		+ "购买与对局记录会去掉身份后保留，用于对账和处理违规。",
		"Name, avatar, profile, friends and chats are deleted for good; pets and diamonds go with the account. "
		+ "Purchase and match records are kept without your identity, for accounting and rule enforcement.")
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn.add_theme_font_size_override("font_size", Tokens.FONT_BODY - 4)
	warn.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	column.add_child(warn)

	_delete_code_edit = LineEdit.new()
	_delete_code_edit.max_length = 8
	_delete_code_edit.placeholder_text = _text("输入好友码确认", "Type your friend code")
	_delete_code_edit.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	_delete_code_edit.text_changed.connect(func(_t: String) -> void: _sync_delete_button())
	column.add_child(_delete_code_edit)

	_delete_btn = Button.new()
	_delete_btn.text = _text("注销账号", "Delete account")
	_delete_btn.disabled = true
	_delete_btn.custom_minimum_size = Vector2(0, Tokens.TOUCH_MIN)
	var box := Tokens.button_box(Tokens.DANGER, Tokens.DANGER_HOVER)
	_delete_btn.add_theme_stylebox_override("normal", box)
	_delete_btn.add_theme_stylebox_override("hover",
		Tokens.button_box(Tokens.DANGER_HOVER, Tokens.DANGER_HOVER))
	_delete_btn.add_theme_stylebox_override("pressed",
		Tokens.button_box(Tokens.DANGER_PRESSED, Tokens.DANGER_HOVER))
	_delete_btn.pressed.connect(_on_delete_pressed)
	column.add_child(_delete_btn)
	return panel


# 打对了才让按。大小写不敏感 —— 玩家是照着屏幕抄的。
func _sync_delete_button() -> void:
	if _delete_btn == null or not is_instance_valid(_delete_btn):
		return
	var typed := _delete_code_edit.text.strip_edges().to_upper()
	_delete_btn.disabled = typed.is_empty() or typed != _field("friend_code")


func _on_delete_pressed() -> void:
	if _busy:
		return
	var code := _delete_code_edit.text.strip_edges().to_upper()
	DialogService.confirm({
		"title": _text("确认注销", "Confirm deletion"),
		"body": _text(
			"这会永久删除你的账号和个人资料。没有撤销，也没有冷静期。",
			"This permanently deletes your account and personal data. There is no undo."),
		# DANGER：主按钮暗红，且默认焦点留在取消 —— 见 GloryConfirmDialog.Intent。
		"intent": ConfirmDialog.Intent.DANGER,
		"confirm_text": _text("永久删除", "Delete forever"),
		"owner": self,
		"on_result": func(result: String) -> void:
			if result == ConfirmDialog.RESULT_CONFIRMED:
				_run_delete(code),
	})


func _run_delete(code: String) -> void:
	_begin_submit()
	var result: Dictionary = await AccountManager.delete_account(code)
	_busy = false
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) != 200:
		_set_status(_failure_text(result))
		return
	# 删完不留在这一页 —— 它显示的每一个字段都已经不存在了。
	# 回主菜单会撞上 needs_starter_pick，玩家从「三选一」重新开始，
	# 这正是注销该有的样子。
	_set_status(_text("账号已删除", "Account deleted"))
	back_requested.emit()


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
	# relation=blocked 不区分拉黑方向；仅自己的黑名单才有权限解除。
	if _mode == Mode.PUBLIC and str(_data.get("relation", "")) == "blocked":
		var blocks: Dictionary = await AccountManager.fetch_blocks()
		if not is_inside_tree():
			return
		_data["blocked_by_me"] = false
		for entry in (blocks.get("body", {}) as Dictionary).get("blocks", []):
			if str(entry.get("friend_code", "")) == _target_code:
				_data["blocked_by_me"] = true
	_set_status("")
	_refresh()


func _refresh() -> void:
	var name_text := _field("player_name")
	var code := _field("friend_code")
	# 唯一的显示名拼法。见文件顶部第 3 条。
	_name_label.text = AccountManager.display_name(name_text, code)
	_avatar_rect.texture = Catalog.texture_for(_field("avatar"))
	# 头像框：**默认框也是框**（10.02 反馈：资料页选默认框时整块没有头像框）。
	#
	# 改动前这里是
	#   `_frame_rect.visible = not frame_id.is_empty() and frame_id != "frame_default"`
	# —— 因为默认框那张图（`main_menu_live/profile_avatar.png`）的圆心是**实心**深棕盘，
	# 盖上去就把头像糊掉，所以只能把框整个藏掉；代价是玩家一选默认框资料页就没框，
	# 而大厅名牌、3v3 席位还画着金环，三处口径对不上。
	#
	# ★ 本次**只动资料页这一处**：默认框改读同一张图把内圆抠空后的副本
	# （`assets/ui/shop/headframes/frame_default.png`），于是它跟商城框一样贴得出来。
	# `data/avatars.json` 里 `frame_default.source` **保持不动** —— 那一行同时是大厅
	# 名牌的底板，改它会牵连别的界面。其余 id 仍交给 AvatarCatalog 决定（含
	# 「认不出就回落默认框」那条）。
	var frame_id := Catalog.id_from_value(_field("avatar_frame"))
	_frame_rect.visible = not frame_id.is_empty()
	if _frame_rect.visible:
		_frame_rect.texture = _profile_frame_texture(frame_id, _field("avatar_frame"))
		_avatar_rect.offset_left = 21
		_avatar_rect.offset_top = 21
		_avatar_rect.offset_right = -21
		_avatar_rect.offset_bottom = -21
	else:
		_avatar_rect.offset_left = 0
		_avatar_rect.offset_top = 0
		_avatar_rect.offset_right = 0
		_avatar_rect.offset_bottom = 0

	var days := _field_int("days_since_created", 1)
	_days_label.text = _text("第 %d 天" % days, "Day %d" % days)

	_pet_label.text = _text("出战宠物：%s", "Pet: %s") % _pet_display(PlayerProfile.get_active() if _mode == Mode.SELF else _field("showcase_pet"))

	if _mode == Mode.SELF:
		_refresh_self()
	else:
		_refresh_public()


# 资料页专用的取框函数。只有 `frame_default` 与别处不同：它读**抠空内圆**的副本，
# 好让默认框也能压在头像上（原图圆心实心，压上去等于把头像抹掉）。
# 抠空素材缺失时返回 null（宁可少一个装饰），**不**回落成实心原图 —— 回落就等于
# 把原来的 bug 原样搬回来。其余 id 与改动前完全一致。
func _profile_frame_texture(frame_id: String, raw_value: String) -> Texture2D:
	if frame_id == FRAME_DEFAULT_ID:
		return _frame_default_hollow_texture()
	return Catalog.frame_texture_for(raw_value)


func _frame_default_hollow_texture() -> Texture2D:
	if _frame_default_hollow != null:
		return _frame_default_hollow
	if not ResourceLoader.exists(FRAME_DEFAULT_HOLLOW_PATH):
		return null
	_frame_default_hollow = load(FRAME_DEFAULT_HOLLOW_PATH) as Texture2D
	return _frame_default_hollow


func _rename_hint(ready_at: String, now: int) -> String:
	# 后端ISO时间可能带微秒；共用解析器处理UTC及偏移时区。
	var normalized := RegEx.create_from_string("\\.\\d+").sub(ready_at, "")
	var deadline := preload("res://scripts/account/ServiceStatus.gd").parse_iso_utc(normalized)
	if ready_at.is_empty() or (deadline > 0 and now >= deadline):
		return _text("现在可改名", "You can rename now")
	return _text("下次可改名：%s", "Next rename: %s") % ready_at.left(10)

func _refresh_self() -> void:
	_name_edit.text = _field("player_name")
	var ready_at := _field("rename_available_at")
	_name_hint.text = _rename_hint(ready_at, int(Time.get_unix_time_from_system()))

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
	_sync_delete_button()


func _refresh_public() -> void:
	_update_friend_actions()
	var column := _public_rows
	if column == null or not is_instance_valid(column):
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
	# 9.18：改名成功反馈音。
	SfxService.play(SfxService.CUE_PROFILE_SAVE)


func _on_save_bio_pressed() -> void:
	if _busy:
		return
	var payload := _bio_payload()
	# 生日只能设一次，所以第一次设置要二次确认 —— 手滑填错会永久顶着错生日，
	# 而那必然产生客服工单。已经设过的不再问（后端会保留原值）。
	#
	# ⚠️ 没选生日时 payload["birth_month"] 这个 key 是存在的、值是 null
	# （_bio_payload 里 `month if has_birth else null`）—— Dictionary.get() 的默认值
	# 只在 key 不存在时才生效，key 存在但值是 null 时还是返回 null。
	# 之前直接 int(payload.get("birth_month", 0)) 在 null 上炸了
	# （Nonexistent 'int' constructor），所以要先判 null 再转。
	var payload_month: Variant = payload.get("birth_month")
	var first_time := _field_int("birth_month") == 0 and payload_month != null and int(payload_month) > 0
	if first_time:
		DialogService.confirm({
			"owner": self,
			"request_id": "profile_birthday_%d" % get_instance_id(),
			"title": _text("确认生日", "Confirm birthday"),
			"body": _text(
				"生日设置后**不可更改**。确认是 %d 月 %d 日吗？",
				"Your birthday cannot be changed later. Confirm %d/%d?"
			) % [int(payload["birth_month"]), int(payload["birth_day"])],
			"confirm_text": _text("确认", "Confirm"),
			"on_result": func(result: String, _request_id: String) -> void:
				if result == ConfirmDialog.RESULT_CONFIRMED:
					_save_bio(payload),
		})
		return
	await _save_bio(payload)


func _save_bio(payload: Dictionary) -> void:
	_begin_submit()
	_finish_submit(await AccountManager.update_bio(payload))
	# 9.18：保存资料（签名/生日/性别/地区等）成功反馈音。
	SfxService.play(SfxService.CUE_PROFILE_SAVE)


func _save_avatar(value: String) -> void:
	_begin_submit()
	_finish_submit(await AccountManager.update_profile({"avatar": value}))


func _save_frame(value: String) -> void:
	_begin_submit()
	_finish_submit(await AccountManager.update_profile({"avatar_frame": value}))


func _bio_payload() -> Dictionary:
	var gender_index := _gender_pick.selected
	var hide_gender := gender_index >= GENDER_VALUES.size()
	# 选「不显示」时**保留原来的值**，只把可见性关掉 —— 否则玩家关一次显示
	# 就把自己填过的内容抹了，再打开时是空的。
	var gender: Variant = null
	if hide_gender:
		gender = _field("gender")
	else:
		gender = str(GENDER_VALUES[gender_index])
	if typeof(gender) == TYPE_STRING and str(gender).is_empty():
		gender = null

	var region_index := _region_pick.selected
	var hide_region := region_index >= REGIONS.size()
	var region: Variant = null
	if hide_region:
		region = _field("region")
	else:
		region = str(REGIONS[region_index][0])
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


func _open_frame_picker() -> void:
	if _busy or ModalStack.has(FRAME_PICKER_MODAL_ID):
		return
	var result: Dictionary = await AccountManager.fetch_entitlements()
	if not is_inside_tree():
		return
	if int(result.get("code", 0)) / 100 != 2:
		_set_status(_text("无法载入头像框收藏", "Could not load your frames"))
		return
	var owned: Dictionary = {}
	for value in ((result.get("body", {}) as Dictionary).get("items", []) as Array):
		owned[str(value)] = true
	var picker := FramePicker.new() as Control
	picker.call("configure", _field("avatar_frame"), owned)
	picker.connect("picked", func(value: String) -> void:
		ModalStack.pop(FRAME_PICKER_MODAL_ID)
		_save_frame(value))
	picker.connect("dismissed", func() -> void: ModalStack.pop(FRAME_PICKER_MODAL_ID))
	ModalStack.push(picker, {
		"id": FRAME_PICKER_MODAL_ID,
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


# 标签与控件**左右排**，不是上下排。上下排每一行要占两倍高度，
# 六行下来就是一屏放不下 —— 而这一页的全部内容本来一屏就该放得下。
func _labeled(label_text: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Tokens.GAP_S)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(64, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", Tokens.FONT_BODY - 2)
	label.add_theme_color_override("font_color", Tokens.TEXT_SECONDARY)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	return en if _is_en() else zh


# Names and badges use this locale choice together.
func _is_en() -> bool:
	return TranslationServer.get_locale().begins_with("en")
