extends Control

# 联动 / 套装激活特效的预览：在编辑器里打开本场景按 F6，点上面的按钮播放。
#
# 左下角是照备战界面摆的假宝藏栏（TreasureChoicePanel.build_logos_panel 的尺寸与锚点：
# 66px 图标、4 列、间距 5），光线从这里射出，图标最后飞回这里的新格子。
# 四个勾选框只作用于这里的播放，不改玩家设置。

const LinkageFx := preload("res://scenes/prep/fx/LinkageFx.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const TREASURE_LOGO_DIR := "res://assets/ui/treasure_logos/"
const ICON := 66.0

var reduced_box: CheckBox
var no_flash_box: CheckBox
var low_box: CheckBox
var sound_box: CheckBox
var _tray: GridContainer
var _fx: LinkageFx


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Tokens.SURFACE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var top := VBoxContainer.new()
	top.position = Vector2(16.0, 12.0)
	top.add_theme_constant_override("separation", 8)
	add_child(top)
	var title := Label.new()
	title.text = "联动 / 套装激活特效预览：点按钮播放（左下角是假宝藏栏）"
	title.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	top.add_child(title)

	var buttons := HFlowContainer.new()
	buttons.custom_minimum_size = Vector2(1400.0, 0.0)
	buttons.add_theme_constant_override("h_separation", 6)
	buttons.add_theme_constant_override("v_separation", 6)
	top.add_child(buttons)
	for entry in CodexService.entries_for("link"):
		var b := Button.new()
		b.text = str(entry.get("name", ""))
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(play_entry.bind(entry))
		buttons.add_child(b)

	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 18)
	top.add_child(toggles)
	reduced_box = _toggle(toggles, "减弱动态效果")
	no_flash_box = _toggle(toggles, "关闭闪光")
	low_box = _toggle(toggles, "低画质（粒子 ×0.45）")
	sound_box = _toggle(toggles, "播放音效")
	sound_box.button_pressed = true

	var tray_panel := Control.new()
	tray_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tray_panel.anchor_left = 0.0
	tray_panel.anchor_top = 1.0
	tray_panel.anchor_right = 0.0
	tray_panel.anchor_bottom = 1.0
	tray_panel.offset_left = 6.0
	tray_panel.offset_right = 6.0 + 303.0
	tray_panel.offset_top = -10.0 - 161.0
	tray_panel.offset_bottom = -10.0
	add_child(tray_panel)
	_tray = GridContainer.new()
	_tray.columns = 4
	_tray.add_theme_constant_override("h_separation", 5)
	_tray.add_theme_constant_override("v_separation", 5)
	tray_panel.add_child(_tray)


func play_entry(entry: Dictionary) -> void:
	if is_instance_valid(_fx):
		_fx.queue_free()
	var id := str(entry.get("id", ""))
	var tids := _causing_treasures(id)
	for child in _tray.get_children():
		_tray.remove_child(child)
		child.queue_free()
	var icons: Array[TextureRect] = []
	for tid in tids:
		var t := TreasureService.treasure_by_id(tid)
		icons.append(_tray_icon(TREASURE_LOGO_DIR + str(t.get("name", "")) + ".png"))
	var slot := _tray_icon(str(entry.get("portrait", "")))
	slot.modulate.a = 0.0
	# 等栅格排好版，图标的全局矩形才是真的。
	await get_tree().process_frame
	await get_tree().process_frame

	var sources: Array = []
	for i in tids.size():
		var t := TreasureService.treasure_by_id(tids[i])
		sources.append({"rect": icons[i].get_global_rect(), "category": str(t.get("category", ""))})
	var banner_key := "ui_linkage_fx_banner" if TreasureService.set_category_of(id).is_empty() else "ui_set_fx_banner"
	_fx = LinkageFx.new()
	add_child(_fx)
	_fx.landed.connect(func() -> void:
		if is_instance_valid(slot):
			slot.modulate.a = 1.0)
	_fx.play(sources, load(str(entry.get("portrait", ""))) as Texture2D,
		tr(banner_key) % str(entry.get("name", "")), slot.get_global_rect(), {
			"reduced_motion": reduced_box.button_pressed,
			"flash": not no_flash_box.button_pressed,
			"particle_scale": 0.45 if low_box.button_pressed else 1.0,
			"sound": sound_box.button_pressed,
		})


# 与备战界面同一套规则（TreasureService.bonus_sources）；套装假装持有该类别的前 4 件。
func _causing_treasures(id: String) -> Array[String]:
	var category := TreasureService.set_category_of(id)
	var owned: Array = []
	if not category.is_empty():
		for t in DataRegistry.get_table("treasures").get("treasures", []):
			if str(t.get("category", "")) == category and owned.size() < 4:
				owned.append(str(t.get("id", "")))
	return TreasureService.bonus_sources(id, owned)


func _tray_icon(path: String) -> TextureRect:
	var r := TextureRect.new()
	r.texture = load(path) as Texture2D
	r.custom_minimum_size = Vector2(ICON, ICON)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tray.add_child(r)
	return r


func _toggle(parent: Control, text: String) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.focus_mode = Control.FOCUS_NONE
	parent.add_child(box)
	return box
