extends Control

# 触控下限从令牌来，不再写字面量：这一页原本有三个控件是 46 / 46 / 40，
# 都低于 TOUCH_MIN=48 —— 而 P1-04 第 1 条要的正是移动端最小触控尺寸。
const Theming := preload("res://ui/theme/GloryTheme.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const ActionButtonScene := preload("res://ui/components/GloryActionButton.tscn")
const SfxService := preload("res://ui/services/SfxService.gd")

signal back_requested
signal replay_tutorial_requested

var _btn_zh: Button
var _btn_en: Button
var _quality_btns: Array[Button] = []
var _board_guides_btn: CheckButton
var _presentation_btns: Dictionary = {}
# 每个开关的原始标题。刷新时要在它后面拼「开 / 关」，不能拿已经拼过的文本再拼一次。
var _presentation_labels: Dictionary = {}

func _ready() -> void:
	_build()
	LocaleManager.locale_changed.connect(_on_locale_changed)

func _build() -> void:
	# V3 P1-04 验收原文：「无业务按钮使用 Godot 默认主题」。
	# 这一页此前既没有 theme=，也没有任何 add_theme_stylebox_override，
	# 而 project.godot 也没有 gui/theme/custom —— 所以按钮走的是引擎
	# 默认灰色样式，和游戏其它地方长得完全不是一套。
	theme = Theming.get_theme()
	_presentation_btns.clear()
	_presentation_labels.clear()
	# 先 remove_child 再 queue_free：本函数现在会被 `_on_locale_changed()` 再调一次，
	# 只 queue_free 的话旧节点要到帧末才真离树，同一帧里 `_build()` 的新旧两套内容会并存。
	# 与 `CarrotCampPanelV3._on_locale_changed()` 同一写法。
	for child in get_children():
		remove_child(child)
		child.queue_free()

	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.09)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -10

	# 内容比画布高时必须滚得动。
	#
	# 这一页的开关是一路加上来的（语言 / 画质 / 棋盘辅助 / 屏震 / 闪光 /
	# hit-stop / 降低动态 / 界面音效 / 触感），到 P1-04 这两行为止，
	# 20:9（2400×1080）下面板底部已经溢出 110px —— 返回键直接点不到。
	# responsive_layout 的门禁注释里早就记着「20:9 下边距只剩 7px」，
	# 那是这次溢出的预告。
	#
	# 靠压缩行高/间距只能把下一次溢出往后推一行；真正的修法是让它能滚。
	# 横向禁用滚动：这一页从来不需要横向滚，开着只会让手指划错方向。
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)

	var panel := VBoxContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.add_theme_constant_override("separation", 16)
	center.add_child(panel)

	var title := Label.new()
	title.text = tr("settings_title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.96, 0.96, 0.92))
	panel.add_child(title)

	var sep := HSeparator.new()
	panel.add_child(sep)

	var lang_label := Label.new()
	lang_label.text = tr("settings_language")
	lang_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lang_label.add_theme_color_override("font_color", Color(0.86, 0.9, 0.9))
	panel.add_child(lang_label)

	var lang_row := HBoxContainer.new()
	lang_row.alignment = BoxContainer.ALIGNMENT_CENTER
	lang_row.add_theme_constant_override("separation", 12)
	panel.add_child(lang_row)

	_btn_zh = Button.new()
	_btn_zh.text = "中文"
	_btn_zh.custom_minimum_size = Vector2(140, 48)
	# 9.20 bug 文档第 3 条：语言切换也要有反馈音。
	# 此前只有无障碍开关（屏震/闪光/hit-stop）和棋盘辅助线挂了 CUE_SETTINGS_SWITCH，
	# 语言这一排没挂 —— 玩家点「中文 / English」是静音的，切完界面整体重建、更容易
	# 让人怀疑是不是点空了。与那两个开关用同一条 cue，听感一致。
	_btn_zh.pressed.connect(func():
		SfxService.play(SfxService.CUE_SETTINGS_SWITCH)
		PlayerProfile.select_language("zh"))
	lang_row.add_child(_btn_zh)

	_btn_en = Button.new()
	_btn_en.text = "English"
	_btn_en.custom_minimum_size = Vector2(140, 48)
	_btn_en.pressed.connect(func():
		SfxService.play(SfxService.CUE_SETTINGS_SWITCH)
		PlayerProfile.select_language("en"))
	lang_row.add_child(_btn_en)

	_refresh_lang_buttons()

	var sep_q := HSeparator.new()
	panel.add_child(sep_q)

	# 画质档。自动判定按总内存分（<4GB -> 流畅），但玩家选了就永远优先，
	# 自动判定不再覆盖 —— 低端机上默认保守，愿意的人可以自己往上调。
	var quality_label := Label.new()
	quality_label.text = tr("settings_quality")
	quality_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	quality_label.add_theme_color_override("font_color", Color(0.86, 0.9, 0.9))
	panel.add_child(quality_label)

	var quality_row := HBoxContainer.new()
	quality_row.alignment = BoxContainer.ALIGNMENT_CENTER
	quality_row.add_theme_constant_override("separation", 10)
	panel.add_child(quality_row)

	_quality_btns.clear()
	var options := [
		[VFXQualityBudget.Tier.LOW, "settings_quality_low"],
		[VFXQualityBudget.Tier.MEDIUM, "settings_quality_medium"],
		[VFXQualityBudget.Tier.HIGH, "settings_quality_high"],
	]
	for opt in options:
		var tier_value: int = opt[0]
		var btn := Button.new()
		btn.text = tr(str(opt[1]))
		btn.custom_minimum_size = Vector2(96, 48)
		btn.pressed.connect(func():
			# 9.20 bug 文档第 3 条：画质切换也要有反馈音（同上，语言那一排的理由）。
			SfxService.play(SfxService.CUE_SETTINGS_SWITCH)
			VFXManager.set_quality_pref(tier_value)
			_refresh_quality_buttons())
		quality_row.add_child(btn)
		_quality_btns.append(btn)
	_refresh_quality_buttons()

	var sep_guides := HSeparator.new()
	panel.add_child(sep_guides)

	_board_guides_btn = CheckButton.new()
	_board_guides_btn.text = tr("settings_board_guides")
	_board_guides_btn.custom_minimum_size = Vector2(280, Tokens.TOUCH_MIN)
	_board_guides_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_board_guides_btn.button_pressed = PlayerProfile.board_readability_enabled
	_board_guides_btn.toggled.connect(func(enabled: bool):
		PlayerProfile.set_board_readability_enabled(enabled)
		_refresh_board_guides_button()
		# 9.18：设置项切换反馈音。
		SfxService.play(SfxService.CUE_SETTINGS_SWITCH))
	panel.add_child(_board_guides_btn)
	_refresh_board_guides_button()

	# V2 P1-05 第 4 条：屏震 / 闪光 / hit-stop 三个无障碍开关。
	# 三项默认开启 —— 它们是演出效果，默认关掉等于让绝大多数玩家看到更差的版本。
	var sep_access := HSeparator.new()
	panel.add_child(sep_access)
	for spec in [
		{"key": "screen_shake", "label": "settings_screen_shake"},
		{"key": "flash_effects", "label": "settings_flash_effects"},
		{"key": "hit_stop", "label": "settings_hit_stop"},
		# V3 P1-09：降低动态效果。压掉过场与呼吸动画，默认关闭。
		{"key": "reduced_motion", "label": "settings_reduced_motion"},
		# 9.17 反馈第 5 条：背景音乐开关。**排在「界面音效」上面** ——
		# 反馈原文就是「放置在界面音效开关功能的上面」。它走同一条
		# PlayerProfile.get/set_presentation_toggle 通道，只是键是
		# "music"，落盘字段 music_enabled，裁决在 PresentationSettings.music_allowed()，
		# 由 MusicService 那个常驻播放器执行（关 = stream_paused，可续播）。
		{"key": "music", "label": "settings_music"},
		# V3 P1-04：界面音效与触感反馈，默认开启。
		{"key": "ui_sound", "label": "settings_ui_sound"},
		{"key": "haptics", "label": "settings_haptics"},
	]:
		var spec_dict: Dictionary = spec
		var key := str(spec_dict["key"])
		var btn := CheckButton.new()
		btn.text = tr(str(spec_dict["label"]))
		btn.custom_minimum_size = Vector2(280, Tokens.TOUCH_MIN)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.button_pressed = PlayerProfile.get_presentation_toggle(key)
		btn.toggled.connect(func(enabled: bool):
			PlayerProfile.set_presentation_toggle(key, enabled)
			_refresh_presentation_button(key)
			# 9.18：设置项切换反馈音（含音乐 / 界面音效 / 无障碍开关）。
			SfxService.play(SfxService.CUE_SETTINGS_SWITCH))
		panel.add_child(btn)
		_presentation_btns[key] = btn
		_presentation_labels[key] = tr(str(spec_dict["label"]))
		_refresh_presentation_button(key)

	var sep2 := HSeparator.new()
	panel.add_child(sep2)

	var replay_btn := ActionButtonScene.instantiate() as Button
	replay_btn.text = tr("settings_replay_tutorial")
	replay_btn.custom_minimum_size = Vector2(280, Tokens.TOUCH_MIN)
	replay_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	replay_btn.pressed.connect(func(): replay_tutorial_requested.emit())
	panel.add_child(replay_btn)

	var back_btn := Button.new()
	back_btn.text = tr("settings_back")
	back_btn.custom_minimum_size = Vector2(160, Tokens.TOUCH_MIN)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.pressed.connect(func(): back_requested.emit())
	panel.add_child(back_btn)

# V3 P1-09：状态不能只靠颜色。
#
# 迁移前语言、画质、三个无障碍开关的「当前选中」全部只用 modulate 表示。
# 色觉障碍、强光下的手机屏幕、以及任何截图转灰度的场合，这些界面都读不出
# 自己选的是哪一项 —— 而这几项恰好都是「选错了要重新找回来」的设置。
#
# 加一个文字标记，颜色照常保留：两条通道并存，不是用一条换另一条。
const SELECTED_MARK := "✓ "


static func _mark_selected(text: String, selected: bool) -> String:
	var bare := text.trim_prefix(SELECTED_MARK)
	return SELECTED_MARK + bare if selected else bare


func _refresh_quality_buttons() -> void:
	var current := VFXManager.get_quality_tier()
	for i in _quality_btns.size():
		var btn := _quality_btns[i]
		if is_instance_valid(btn):
			var on := i == current
			btn.modulate = Color(1.0, 0.85, 0.3) if on else Color(1, 1, 1)
			btn.text = _mark_selected(btn.text, on)

func _refresh_presentation_button(key: String) -> void:
	var btn_value = _presentation_btns.get(key)
	if not (btn_value is CheckButton) or not is_instance_valid(btn_value):
		return
	var btn := btn_value as CheckButton
	var on: bool = PlayerProfile.get_presentation_toggle(key)
	btn.button_pressed = on
	btn.modulate = Color(1.0, 0.88, 0.48) if on else Color(0.76, 0.78, 0.78)
	# CheckButton 自带的滑块本身就是第二条通道，但它在低对比度屏上不明显；
	# 再补一句开/关文字，读屏和灰度截图都拿得到。
	btn.text = _toggle_label(str(_presentation_labels.get(key, "")), on)


func _toggle_label(base: String, on: bool) -> String:
	if base.is_empty():
		return ""
	var suffix := tr("settings_toggle_on") if on else tr("settings_toggle_off")
	return "%s  %s" % [base, suffix]


func _refresh_board_guides_button() -> void:
	if not is_instance_valid(_board_guides_btn):
		return
	var on := PlayerProfile.board_readability_enabled
	_board_guides_btn.button_pressed = on
	_board_guides_btn.modulate = Color(1.0, 0.88, 0.48) if on else Color(0.76, 0.78, 0.78)
	_board_guides_btn.text = _toggle_label(tr("settings_board_guides"), on)

func _refresh_lang_buttons() -> void:
	if not is_instance_valid(_btn_zh) or not is_instance_valid(_btn_en):
		return
	var locale := LocaleManager.get_locale()
	var zh_on := locale == "zh"
	_btn_zh.modulate = Color(1.0, 0.85, 0.3) if zh_on else Color(1, 1, 1)
	_btn_en.modulate = Color(1.0, 0.85, 0.3) if not zh_on else Color(1, 1, 1)
	_btn_zh.text = _mark_selected("中文", zh_on)
	_btn_en.text = _mark_selected("English", not zh_on)

# 9.20 bug 文档第 1 条：在设置页里改成英文必须**当场**变英文。
#
# ★ 根因不是「没人听信号」，而是**翻译键丢了**：`_build()` 里每一处都是
#   `text = tr("settings_xxx")`，取到的是**已翻译好的字符串**；Godot 的自动翻译
#   只会拿节点上现存文本去查表，键名丢了就再也查不回去 —— 于是切到 en 之后
#   这些 Label 原样停在中文，只有重开设置页（`Main._show_settings()` 会重新
#   instantiate）才会走一遍新 locale 下的 `_build()`。
#   本函数此前也只刷了语言按钮的选中态，没管其余文案。
#
# 修法沿用本仓既有约定（`CarrotCampPanelV3._on_locale_changed()`）：整个重建。
# 页面本来就没有需要保留的瞬时状态（开关值都存在 PlayerProfile 里），重建是安全的。
func _on_locale_changed(_locale: String) -> void:
	_build()
