extends Control

# 大厅左侧的观战列表（2026-10-22 定：语音键上方那块，最多 10 人，能往下拖）。
#
# 选手和观战者看到的是同一份列表（服务器 room_state / spectate_state 里的 spectators，
# 只有公开身份）。房主多两样东西：每行一个 X（请出观战席）、标题栏一个「关闭 / 开启观战」。
# 规则都在服务器（SpectatorService.gd），这里只负责画和把按键转成信号 ——
# 非房主就算点到也只是发一条服务器会丢掉的请求。
#
# 尺寸按参考画布（330 × 480）写；大厅用 _track 整体缩放这块，字号在 resized 里按比例跟着缩。

signal kick_requested(sid: int)
signal open_toggled(open: bool)

const AvatarCatalog := preload("res://scripts/account/AvatarCatalog.gd")
const Tokens := preload("res://ui/theme/GloryTokens.gd")
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")
const TEX_PANEL := preload("res://assets/ui/room_v2/friends.png")

const REF_SIZE := Vector2(330, 480)
const ROW_H := 46.0
const AVATAR := 36.0
const INK := Color(0.47, 0.28, 0.08)

var _title: Label
var _toggle: Button
var _empty: Label
var _rows: VBoxContainer
var _scroll: ScrollContainer
var _list: Array = []
var _open := true
var _max := 10
var _is_host := false
var _my_sid := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	var bg := TextureRect.new()
	bg.texture = TEX_PANEL
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", Tokens.GOLD_HOVER)
	_title.add_theme_color_override("font_outline_color", Tokens.INK_PANEL)
	_title.add_theme_constant_override("outline_size", 2)
	add_child(_title)
	_toggle = Button.new()
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_toggle.add_theme_color_override("font_color", INK)
	_toggle.add_theme_stylebox_override("normal", _pill(0.82))
	_toggle.add_theme_stylebox_override("hover", _pill(0.95))
	_toggle.add_theme_stylebox_override("pressed", _pill(0.95))
	_toggle.add_theme_stylebox_override("focus", _pill(0.82))
	_toggle.pressed.connect(func(): open_toggled.emit(not _open))
	add_child(_toggle)
	_scroll = TouchScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_rows)
	_empty = Label.new()
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.add_theme_color_override("font_color", INK)
	add_child(_empty)
	resized.connect(_relayout)
	_rebuild()


# spectators：服务器下发的公开列表 [{sid, guest, identity}]。
func update(spectators: Array, open: bool, max_count: int, is_host: bool, my_sid: int = -1) -> void:
	_list = spectators.duplicate(true)
	_open = open
	_max = maxi(1, max_count)
	_is_host = is_host
	_my_sid = my_sid
	if is_node_ready():
		_rebuild()


func row_count() -> int:
	return _rows.get_child_count() if _rows != null else 0


func _k() -> float:
	return maxf(0.4, size.x / REF_SIZE.x) if size.x > 0.0 else 1.0


func _relayout() -> void:
	var k := _k()
	# 羊皮纸的内区（实测 friends.png 拉到 330×480 时，纸面约在 9%~91% 宽、11%~92% 高）。
	var inner := Rect2(size.x * 0.10, size.y * 0.09, size.x * 0.80, size.y * 0.83)
	_title.position = Vector2(inner.position.x, inner.position.y)
	_title.size = Vector2(inner.size.x, 40 * k)
	_title.add_theme_font_size_override("font_size", maxi(13, roundi(24 * k)))
	_toggle.visible = _is_host
	_toggle.position = Vector2(inner.position.x + inner.size.x * 0.15, inner.position.y + 42 * k)
	_toggle.size = Vector2(inner.size.x * 0.70, 32 * k)
	_toggle.add_theme_font_size_override("font_size", maxi(13, roundi(17 * k)))
	# 标题木牌的图案比标题框往下多伸出一截（约 60），列表从它下面开始，否则第一行被压住。
	var list_top := inner.position.y + (82 if _is_host else 62) * k
	_scroll.position = Vector2(inner.position.x, list_top)
	_scroll.size = Vector2(inner.size.x, inner.end.y - list_top)
	_empty.position = _scroll.position
	_empty.size = Vector2(_scroll.size.x, 80 * k)
	_empty.add_theme_font_size_override("font_size", maxi(13, roundi(18 * k)))
	for row in _rows.get_children():
		_size_row(row as Control, k)


func _rebuild() -> void:
	_title.text = _t("观战席 %d/%d", "Spectators %d/%d") % [_list.size(), _max]
	_toggle.text = _t("关闭观战", "Close spectating") if _open else _t("开启观战", "Open spectating")
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	for entry in _list:
		_rows.add_child(_make_row(entry as Dictionary))
	_empty.visible = _list.is_empty()
	_empty.text = _t("暂无观战者", "No spectators") if _open else _t("观战已关闭", "Spectating is closed")
	_relayout()


func _make_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	var identity: Dictionary = entry.get("identity", {})
	var guest := bool(entry.get("guest", true))
	var sid := int(entry.get("sid", -1))
	var avatar := TextureRect.new()
	avatar.name = "avatar"
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar.texture = AvatarCatalog.texture_for(str(identity.get("avatar", AvatarCatalog.default_avatar())), true)
	avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(avatar)
	var name_lbl := Label.new()
	name_lbl.name = "name"
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.add_theme_color_override("font_color", INK)
	var shown := _t("游客", "Guest") if guest else str(identity.get("player_name", ""))
	if shown.is_empty():
		shown = _t("观战者", "Spectator")
	if sid == _my_sid:
		shown += _t("（我）", " (Me)")
	name_lbl.text = shown
	row.add_child(name_lbl)
	if _is_host:
		var kick := Button.new()
		kick.name = "kick"
		kick.text = "X"
		kick.focus_mode = Control.FOCUS_NONE
		kick.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		kick.add_theme_color_override("font_color", Color(0.82, 0.06, 0.08))
		kick.add_theme_stylebox_override("normal", _pill(0.88))
		kick.add_theme_stylebox_override("hover", _pill(1.0))
		kick.add_theme_stylebox_override("pressed", _pill(1.0))
		kick.add_theme_stylebox_override("focus", _pill(0.88))
		kick.pressed.connect(func(): kick_requested.emit(sid))
		row.add_child(kick)
	return row


func _size_row(row: Control, k: float) -> void:
	row.custom_minimum_size = Vector2(0, ROW_H * k)
	row.add_theme_constant_override("separation", roundi(8 * k))
	var avatar := row.get_node_or_null("avatar") as Control
	if avatar != null:
		avatar.custom_minimum_size = Vector2(AVATAR, AVATAR) * k
	var name_lbl := row.get_node_or_null("name") as Label
	if name_lbl != null:
		name_lbl.add_theme_font_size_override("font_size", maxi(13, roundi(19 * k)))
	var kick := row.get_node_or_null("kick") as Button
	if kick != null:
		kick.custom_minimum_size = Vector2(34, 34) * k
		kick.add_theme_font_size_override("font_size", maxi(13, roundi(16 * k)))


func _pill(alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1.0, 0.93, 0.80, alpha)
	sb.border_color = Color(0.70, 0.42, 0.14)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	return sb


func _t(zh: String, en: String) -> String:
	return en if TranslationServer.get_locale().begins_with("en") else zh
