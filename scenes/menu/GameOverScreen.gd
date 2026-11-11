extends Control
# Battle result presentation. Main still owns settlement state and navigation.

signal details_requested
signal return_room_requested
signal return_party_requested
signal return_menu_requested

const Tokens := preload("res://ui/theme/GloryTokens.gd")
const Theming := preload("res://ui/theme/GloryTheme.gd")
const WIN_ART := preload("res://assets/ui/game_over/victory.png")
const LOSE_ART := preload("res://assets/ui/game_over/defeat.png")
# 11.11 羊皮纸风：石台背景 + 胜负平横幅（第二批图）+ 羊皮纸正文卡 / 按钮（ui/theme/ParchmentKit.gd）
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const UiJuice := preload("res://ui/theme/UiJuice.gd")

var result_kind := "lose"
var title_text := ""
var body_text := ""
var show_details := false
var tutorial_result := false
var can_return_room := false
# 10.10 bug 第 9 条：休闲 / 排位的账号服务器队伍房间在「六人确认」时被后端保留，
# 所以结算首屏也要能「返回队伍」（原来这颗只在结算面板里，而休闲首屏走的是本界面）。
var can_return_party := false
var _body_label: Label
var _menu_button: Button


func tutorial_menu_target() -> Control:
	return _menu_button


func show_tutorial_level_up(gained_xp: int) -> void:
	if _body_label == null:
		return
	var english := LocaleManager.get_locale().begins_with("en")
	var status := ""
	if english:
		status = ("Tutorial complete · Lv 2 · +%d XP" % gained_xp) if gained_xp > 0 \
			else "Lv 2 reward is in your account"
	else:
		status = ("教学完成 · Lv 2 · +%d XP" % gained_xp) if gained_xp > 0 \
			else "教学完成 · Lv 2 奖励已存入账号"
	_body_label.text = body_text + "\n" + status


func _ready() -> void:
	theme = Kit.theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var accent := Color("8a4b12") if result_kind == "win" else Color("4f5d66")
	Kit.backdrop(self, "rooms_arena", 0.3)

	# 10.19 教程反馈第 3 条：教学结算界面只保留「返回主菜单」。
	#   ① 「查看详情」与「返回主菜单」挤在同一行，还会把下方的文字说明压给按钮；
	#   ② result_menu 引导气泡贴在主菜单按钮上方（约 0.69~0.84 屏高），
	#      原来的正文区 0.69~0.82 正好整段被它盖住（截图 image11「最终胜利及下面」）。
	# 只对教学生效：联机 / 单机的结算照旧要能看详情。
	var compact := tutorial_result
	var heading := VBoxContainer.new()
	heading.add_theme_constant_override("separation", 8)
	_region(0.20 if compact else 0.38, 0.66 if compact else 0.82).add_child(heading)
	var eyebrow := _label(
		_text("荣耀战绩", "MATCH RESULT") if result_kind == "win" else _text("战局落幕", "MATCH ENDED"),
		18, Color(1.0, 0.95, 0.82))
	heading.add_child(eyebrow)
	# 标题写在横幅上：胜利 / 失败 / 平局三张图，字色随横幅
	var banner_key := result_kind if result_kind in ["win", "lose", "draw"] else "lose"
	var banner := Kit.result_banner(banner_key, title_text, 150.0 if not compact else 120.0, 52)
	heading.add_child(banner)

	# 正文放在一张羊皮纸卡里（原来是白字直接压在大图上）
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", Kit.box("card", Vector4(44, 36, 44, 34)))
	var body := _label(body_text, 21, Kit.INK)
	body.add_theme_constant_override("outline_size", 0)
	_body_label = body
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(540, 54)
	Kit.bold_label(body)
	card.add_child(body)
	heading.add_child(card)

	# 横幅从大到小砸下来（赢了砸得更有力），正文卡随后弹出
	banner.pivot_offset = banner.custom_minimum_size * 0.5
	banner.scale = Vector2.ONE * (1.7 if result_kind == "win" else 1.25)
	banner.modulate.a = 0.0
	var slam := banner.create_tween()
	slam.tween_interval(0.1)
	slam.tween_property(banner, "modulate:a", 1.0, 0.12)
	slam.parallel().tween_property(banner, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	UiJuice.pop_in([card], 0.35, 0.0, 0.9)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 18)
	_region(0.83, 0.96).add_child(actions)
	if show_details and not tutorial_result:
		var details := _button(_text("查看详情", "View Details"), actions, accent)
		details.pressed.connect(func() -> void: details_requested.emit())
	if not show_details and not tutorial_result:
		if can_return_room:
			var room := _button(_text("返回房间", "Return to Room"), actions, accent)
			room.pressed.connect(func() -> void:
				room.disabled = true
				return_room_requested.emit())
		# 10.10 bug 第 9 条：休闲 / 排位对局结束能回到原队伍房间。
		# ⚠ 文案走 LocaleManager 的 settle_back_party —— 与结算面板那颗是**同一个 key**，
		#   一处改中英两边都跟着变，别在这里再写一份字面量。
		if can_return_party:
			var party := _button(tr("settle_back_party"), actions, accent)
			party.pressed.connect(func() -> void:
				party.disabled = true
				return_party_requested.emit())
	if not show_details or tutorial_result:
		var menu := _button(_text("返回主菜单", "Main Menu"), actions, accent)
		_menu_button = menu
		menu.pressed.connect(func() -> void: return_menu_requested.emit())


func _region(top: float, bottom: float) -> CenterContainer:
	var region := CenterContainer.new()
	region.anchor_left = 0.0
	region.anchor_right = 1.0
	region.anchor_top = top
	region.anchor_bottom = bottom
	add_child(region)
	return region


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 5)
	label.add_theme_color_override("font_outline_color", Color(0.12, 0.07, 0.025, 0.95))
	return label


func _button(value: String, parent: Node, accent: Color) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(200, Tokens.TOUCH_MIN + 6)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 羊皮纸金色底板（跟其它页面的主按钮一致）
	Kit.style_plate(button, true)
	button.add_theme_font_size_override("font_size", 21)
	parent.add_child(button)
	return button


func _text(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
