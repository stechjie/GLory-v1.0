extends Control
# Codex ("图鉴"). Opened from the main menu; never touches the prep screen.
# Laid out as an open book: the left page picks an entry, the right page shows it.
#   - Left page: category tabs, then a 4-across grid of portraits.
#   - Right page: framed character record, attributes, illustrated ability and four-star upgrade,
#     stats below. Locked entries reveal nothing at all.
# Data comes from CodexService; unlock state from PlayerProfile.

signal back_requested

const BOOK_TEX := preload("res://assets/ui/codex/painted/book_spread_painted.png")
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const SkillArt := preload("res://ui/components/CodexSkillArt.gd")
# Same art the main menu paints, so the codex opens over a dimmed menu rather than
# a black void. The menu itself is freed when the codex opens, so its background is
# redrawn here instead of kept alive.
const MENU_BG_TEX := preload("res://assets/ui/main_menu_v2/background.png")
const GRID_COLUMNS := 4
# ★ 10.08 反馈第 2 条：分类按钮在中/英下大小不一 —— 因为按钮宽度随文字长度走
#   （「神」vs「God」、「宝藏」vs「Treasures」）。钉一个统一的最小尺寸，
#   配合 HFlowContainer 的等宽排布，两种语言下按钮块大小一致。
#   高度取 Tokens.TOUCH_MIN（触摸最小点击高度），宽度给中英最长标签都放得下。
const TAB_BUTTON_SIZE := Vector2(132.0, 44.0)
# 图鉴里的种族徽章长按弹羁绊说明 —— 文本复用备战里那一份（不另抄）。
const SynergyBond := preload("res://scenes/prep/panels/SynergyPanel.gd")
const PARCHMENT := Color(0.89, 0.83, 0.69)
const INK := Color(0.20, 0.15, 0.11)
const INK_SOFT := Color(0.42, 0.34, 0.26)
const LOCKED := Color(0.64, 0.58, 0.48)
const BRASS := Color(0.72, 0.58, 0.25)
const GOOD := Color(0.36, 0.50, 0.29)
const BAD := Color(0.59, 0.27, 0.18)
const TouchScrollContainer := preload("res://ui/components/TouchScrollContainer.gd")

var _book: TextureRect
var _left_page: Control
var _right_page: Control
var _tab_row: HFlowContainer
var _title_label: Label
var _count_label: Label
var _grid: GridContainer
var _detail: VBoxContainer
var _detail_scroll: ScrollContainer
var _back_btn: Button
var _page_banner: Control

var _category := "god"
var _picked := ""
var _texture_cache: Dictionary = {}
var _ui := 1.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Pets never appear on the battlefield, so ownership is what unlocks them.
	CodexService.sync_owned_pets()
	_build()
	if not PlayerProfile.codex_changed.is_connected(_refresh):
		PlayerProfile.codex_changed.connect(_refresh)
	# Rotating the phone moves the Dynamic Island to the other side without a resize.
	if not SafeArea.changed.is_connected(_layout):
		SafeArea.changed.connect(_layout)
	_refresh()

func _exit_tree() -> void:
	if PlayerProfile.codex_changed.is_connected(_refresh):
		PlayerProfile.codex_changed.disconnect(_refresh)
	if SafeArea.changed.is_connected(_layout):
		SafeArea.changed.disconnect(_layout)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

# --- construction --------------------------------------------------------

func _build() -> void:
	theme = Kit.theme()
	var menu_bg := TextureRect.new()
	menu_bg.texture = MENU_BG_TEX
	menu_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	menu_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	menu_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(menu_bg)

	# Dim overlay: the menu shows through, just darker so the book reads clearly.
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.06, 0.03, 0.30)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	_book = TextureRect.new()
	_book.texture = BOOK_TEX
	_book.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# _layout sizes and offsets the rect itself, so the texture maps 1:1 onto it.
	_book.stretch_mode = TextureRect.STRETCH_SCALE
	_book.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_book)

	_left_page = Control.new()
	_left_page.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_left_page)

	var left_col := VBoxContainer.new()
	left_col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	left_col.add_theme_constant_override("separation", _sp(8))
	_left_page.add_child(left_col)

	var head := HBoxContainer.new()
	left_col.add_child(head)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", _fs(22))
	_title_label.add_theme_color_override("font_color", INK)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title_label)
	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", _fs(14))
	_count_label.add_theme_color_override("font_color", INK_SOFT)
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	head.add_child(_count_label)

	_tab_row = HFlowContainer.new()
	_tab_row.add_theme_constant_override("h_separation", _sp(4))
	_tab_row.add_theme_constant_override("v_separation", _sp(4))
	left_col.add_child(_tab_row)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_col.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.add_theme_constant_override("h_separation", _sp(8))
	_grid.add_theme_constant_override("v_separation", _sp(8))
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)

	_right_page = Control.new()
	_right_page.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_right_page)

	# The longest entries (母灵, 人王) write more than a page holds, so the detail
	# side scrolls rather than running off the bottom of the book.
	_detail_scroll = TouchScrollContainer.new()
	_detail_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_right_page.add_child(_detail_scroll)

	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", _sp(10))
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_scroll.add_child(_detail)

	_page_banner = Kit.title_banner("Codex" if UnitDetailFormat.is_en() else "图鉴", 70.0, 26)
	add_child(_page_banner)
	_back_btn = Kit.back_button(func(): back_requested.emit(), 56.0)
	_back_btn.tooltip_text = tr("codex_back")
	_back_btn.focus_mode = Control.FOCUS_ALL
	add_child(_back_btn)

	_layout()

# Keep the two writing areas inside the device safe area. Book art may stretch;
# all text and portraits remain unscaled controls with readable minimum font sizes.
func _layout() -> void:
	if _book == null or size.x <= 1.0 or size.y <= 1.0:
		return
	var safe := SafeArea.rect()
	var ui := clampf(minf(safe.size.x / 1600.0, safe.size.y / 720.0), 0.8, 1.5)
	var ui_changed := absf(ui - _ui) > 0.005
	_ui = ui
	var origin := safe.position + Vector2(_px(12), _px(66))
	var book_size := safe.size - Vector2(_px(24), _px(72))
	_book.position = origin
	_book.size = book_size
	_left_page.position = origin + book_size * Vector2(0.085, 0.14)
	_left_page.size = book_size * Vector2(0.375, 0.72)
	_right_page.position = origin + book_size * Vector2(0.535, 0.14)
	_right_page.size = book_size * Vector2(0.375, 0.72)
	if _back_btn != null:
		_back_btn.position = safe.position + Vector2(_px(24), _px(12))
		_back_btn.size = Vector2(_px(56), _px(56))
	if _page_banner != null:
		_page_banner.size = Vector2(_px(350), _px(70))
		_page_banner.position = Vector2(safe.get_center().x - _page_banner.size.x * 0.5, safe.position.y)
	if _detail_scroll != null:
		_detail_scroll.offset_top = 0
	if ui_changed and _grid != null and _grid.get_child_count() > 0:
		_refresh()

# --- refresh -------------------------------------------------------------

func _refresh() -> void:
	if _grid == null:
		return
	_build_tabs()
	var entries := CodexService.entries_for(_category)
	_title_label.text = _category_title()
	var progress := CodexService.progress_for(_category)
	_count_label.text = (tr("codex_reference_count") % progress.y
		if _is_reference_category()
		else tr("codex_progress") % [progress.x, progress.y])

	if not entries.is_empty():
		var present := false
		for candidate in entries:
			if str(candidate.get("id", "")) == _picked:
				present = true
		if not present:
			_picked = str(entries[0].get("id", ""))
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	for entry in entries:
		_grid.add_child(_build_tile(entry))

	var chosen: Dictionary = {}
	for entry in entries:
		if str(entry.get("id", "")) == _picked:
			chosen = entry
			break
	if chosen.is_empty() and not entries.is_empty():
		chosen = entries[0]
	_build_detail(chosen)

func _build_tabs() -> void:
	for child in _tab_row.get_children():
		_tab_row.remove_child(child)
		child.queue_free()
	for meta in CodexService.CATEGORIES:
		var key := str(meta.get("key", ""))
		var btn := Button.new()
		btn.text = tr("codex_tab_%s" % key)
		# 统一尺寸：否则按钮宽度随标签长度走，中/英切换后大小不一（10.08 第 2 条）。
		Kit.style_tab(btn, _px(44), _fs(15))
		btn.custom_minimum_size = Vector2(_px(112), _px(44))
		btn.focus_mode = Control.FOCUS_ALL
		btn.add_theme_font_size_override("font_size", _fs(15))
		btn.toggle_mode = true
		btn.button_pressed = key == _category
		btn.pressed.connect(func():
			_category = key
			_picked = ""
			_refresh())
		_tab_row.add_child(btn)

func _category_title() -> String:
	var meta := {}
	for c in CodexService.CATEGORIES:
		if str(c.get("key", "")) == _category:
			meta = c
			break
	var label := tr("codex_tab_%s" % _category)
	if str(meta.get("kind", "")) == "unit":
		return tr("codex_cat_unit") % label
	return label

func _is_reference_category() -> bool:
	# 状态和元素都是**参考物料**：不是收集目标，计数栏写「N 种」而不是
	# 「已发现 N/M」（10.01 第 11 条把「元素」并进这一档）。
	return _category == "status" or _category == "element"

# --- grid tiles ----------------------------------------------------------

func _build_tile(entry: Dictionary) -> Control:
	var unlocked := CodexService.is_unlocked(entry)
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_ALL
	var min_height := _px(130)
	btn.custom_minimum_size.y = min_height
	btn.toggle_mode = true
	btn.button_pressed = str(entry.get("id", "")) == _picked
	btn.tooltip_text = _entry_name(entry) if unlocked else tr("codex_locked_name")
	var tile_box := Kit.box("slot", Vector4(8, 8, 8, 8))
	btn.add_theme_stylebox_override("normal", tile_box)
	btn.add_theme_stylebox_override("hover", Kit.box("slot", Vector4(8, 8, 8, 8), Color(1.08, 1.04, 0.89)))
	btn.add_theme_stylebox_override("pressed", Kit.box("slot", Vector4(8, 8, 8, 8), Color(1.0, 0.84, 0.48)))
	btn.add_theme_stylebox_override("hover_pressed", btn.get_theme_stylebox("pressed"))
	btn.add_theme_stylebox_override("focus", Kit.box("slot", Vector4(8, 8, 8, 8), Color(1.0, 0.88, 0.60)))
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func():
		_picked = str(entry.get("id", ""))
		_detail_scroll.scroll_vertical = 0
		_refresh())

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.offset_left = _px(10)
	col.offset_right = -_px(10)
	col.offset_top = _px(10)
	col.offset_bottom = -_px(10)
	col.add_theme_constant_override("separation", _sp(2))
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(col)

	var art := TextureRect.new()
	art.texture = _load_texture(str(entry.get("portrait", "")))
	art.custom_minimum_size = Vector2(_px(0), _px(80))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Locked tiles give nothing away, not even a silhouette.
	if not unlocked:
		art.modulate = Color(0, 0, 0, 0.85)
	col.add_child(art)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", _fs(12))
	name_lbl.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	name_lbl.text = _entry_name(entry) if unlocked else tr("codex_locked_name")
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_lbl)

	# Anchored children of a Button do not contribute to its minimum size.
	# Include the wrapped name and both insets so the grid row grows with the text.
	var vertical_padding := _px(20)
	var fit_height := func() -> void:
		btn.custom_minimum_size.y = maxf(min_height, col.get_combined_minimum_size().y + vertical_padding)
	col.minimum_size_changed.connect(fit_height)
	fit_height.call()

	return btn

# --- detail page ---------------------------------------------------------

func _build_detail(entry: Dictionary) -> void:
	for child in _detail.get_children():
		_detail.remove_child(child)
		child.queue_free()
	if entry.is_empty():
		return
	var unlocked := CodexService.is_unlocked(entry)

	var detail_title := Label.new()
	detail_title.text = (("Character record" if UnitDetailFormat.is_en() else "角色档案") if entry.has("raw") else ("Entry details" if UnitDetailFormat.is_en() else "图鉴详情"))
	detail_title.add_theme_font_size_override("font_size", _fs(23))
	detail_title.add_theme_color_override("font_color", INK)
	_detail.add_child(detail_title)
	_detail.add_child(Kit.separator(_px(16)))

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", _sp(14))
	_detail.add_child(top)
	top.add_child(_build_portrait_column(entry, unlocked))

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", _sp(8))
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(side)

	var badges := _build_badges(entry, unlocked)
	if badges != null:
		side.add_child(badges)
	if not str(entry.get("skill_id", "")).is_empty():
		side.add_child(_build_skill_box(entry, unlocked))

	# The stats live in the portrait column now: they used to sit below the whole
	# top row, which meant a long skill description pushed them down the page.
	if bool(entry.get("growth_note", false)):
		_detail.add_child(_build_note(tr("codex_growth_note")))

	# Status descriptions arrive as a localisation key rather than a literal.
	if entry.has("desc_key"):
		var body := (tr(str(entry.get("desc_key", ""))) if unlocked else tr("codex_locked_text"))
		_detail.add_child(_build_text_block(tr("codex_effect"), body, unlocked))

	for pair in [["effect", "codex_effect"], ["trigger", "codex_trigger"], ["requires_text", "codex_requires"]]:
		var field := str(pair[0])
		if str(entry.get(field, "")).is_empty():
			continue
		var text := str(entry.get(field, "")) if unlocked else tr("codex_locked_text")
		_detail.add_child(_build_text_block(tr(str(pair[1])), text, unlocked))

	if entry.has("effect_key"):
		var pet_body := PetService.skill_detail_text(str(entry.get("id", ""))) if unlocked else tr("codex_locked_text")
		if pet_body.is_empty():
			var pct := int(round(float(entry.get("effect_value", 0.0)) * 100.0))
			pet_body = tr("pet_effect_%s" % str(entry.get("effect_key", ""))) % pct
		_detail.add_child(_build_text_block(tr("codex_effect"), pet_body, unlocked))

	_detail.add_child(_build_state_line(entry, unlocked))

func _build_portrait_column(entry: Dictionary, unlocked: bool) -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(_px(190), _px(0))
	col.add_theme_constant_override("separation", _sp(4))

	var art := TextureRect.new()
	art.texture = _load_texture(str(entry.get("portrait", "")))
	art.custom_minimum_size = Vector2(_px(170), _px(142))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if not unlocked:
		art.modulate = Color(0, 0, 0, 0.85)
	var portrait_frame := PanelContainer.new()
	portrait_frame.add_theme_stylebox_override("panel", Kit.box("slot", Vector4(8, 8, 8, 8)))
	portrait_frame.add_child(art)
	col.add_child(portrait_frame)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", _fs(22))
	name_lbl.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 详情页名称后面补「（唯一）」：unique_on_board 的棋子只能上场一只，
	# 图鉴不写玩家只能靠试放才发现（9.13 测试反馈）。
	name_lbl.text = (_entry_name(entry) + UnitDetailFormat.unique_suffix(entry.get("raw", {}))) if unlocked else tr("codex_locked_name")
	col.add_child(name_lbl)

	var en := Label.new()
	en.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	en.add_theme_font_size_override("font_size", _fs(12))
	en.add_theme_color_override("font_color", INK_SOFT)
	en.text = (tr("codex_tier") % int(entry.get("tier", 0)) if int(entry.get("tier", 0)) > 0 else "") if unlocked else tr("codex_locked_hint")
	en.visible = false # Tier is already beside the race/element badges.
	col.add_child(en)

	# Kept in this column so the numbers always sit under the portrait, whatever
	# length the skill copy beside them runs to.
	if entry.has("stats"):
		col.add_child(_build_stats(entry, unlocked))
	return col

func _build_badges(entry: Dictionary, unlocked: bool) -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", _sp(12))
	row.add_theme_constant_override("v_separation", _sp(6))

	if not unlocked:
		var slots := 2 if (entry.has("race") or entry.has("series")) else 1
		for i in slots:
			row.add_child(_flat_badge(tr("codex_locked_value"), LOCKED))
		return row

	var race := str(entry.get("race", ""))
	if not race.is_empty():
		row.add_child(_emblem_badge(
			CodexService.RACE_LOGO_DIR + race + ".png", tr("codex_tab_%s" % race), race))
	var element := str(entry.get("element", ""))
	if not element.is_empty():
		row.add_child(_emblem_badge(_element_icon(element),
			tr("codex_element_suffix") % tr("codex_elem_%s" % element)))
	var series := str(entry.get("series", ""))
	if not series.is_empty():
		row.add_child(_emblem_badge(_element_icon(series),
			tr("codex_series_suffix") % tr("codex_elem_%s" % series)))
	if int(entry.get("tier", 0)) > 0:
		row.add_child(_flat_badge(tr("codex_tier") % int(entry.get("tier", 0)), INK))
	var category := str(entry.get("category", ""))
	if not category.is_empty():
		row.add_child(_flat_badge(category, INK))
	if entry.has("buff"):
		var is_buff := bool(entry.get("buff", false))
		row.add_child(_flat_badge(
			tr("codex_buff") if is_buff else tr("codex_debuff"),
			GOOD if is_buff else BAD))
	# 元素图鉴的角标是「属性」；状态那条走 buff / debuff（10.01 第 11 条）。
	if bool(entry.get("attribute", false)):
		row.add_child(_flat_badge(tr("codex_attr"), INK))
	return row if row.get_child_count() > 0 else null

# Emblem above, label beneath: the round art identifies the entry, the words only
# confirm it.
#
# ★ 10.08 反馈第 2 条：棋子图鉴里的**种族图标**要能**长按**弹出该族的羁绊说明
#   （文本取自备战里的那一份 —— SynergyPanel.format_synergy_effects，不在这里另抄）。
#   race 参数只在种族徽章上传（元素 / 系列徽章传空），长按入口也就只装在种族上。
func _emblem_badge(texture_path: String, label: String, race: String = "") -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", _sp(2))
	var art := TextureRect.new()
	art.texture = _load_texture(texture_path)
	art.custom_minimum_size = Vector2(_px(58), _px(58))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# 要收 gui_input 才收得到手指按下/抬起 —— 默认 IGNORE 会让长按永不触发，
	# 而且完全静默（没有任何报错，只是「按了没反应」）。
	if not race.is_empty():
		art.mouse_filter = Control.MOUSE_FILTER_STOP
		_attach_synergy_bond_long_press(art, race)
	col.add_child(art)
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", _fs(12))
	lbl.add_theme_color_override("font_color", INK)
	lbl.text = label
	col.add_child(lbl)
	return col

# 给种族徽章装「长按 0.7 秒弹羁绊说明」。
#
# 手势状态挂在控件 meta 上（与 PrepDetailOverlay.attach_long_press 同一套约定，
# 这里只做图鉴需要的那一小份：按下起表、移动超过 8px 取消、松手停表）：
#   长按常驻说明由 DialogService 的模态接管，所以松手不需要再收掉 —— 不会
#   像备战浮层那样出现「松手把刚弹出来的说明又关掉」。
func _attach_synergy_bond_long_press(art: Control, race: String) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 0.7
	art.add_child(timer)
	art.set_meta("race_long_press_timer", timer)
	timer.timeout.connect(func():
		if bool(art.get_meta("race_long_press_cancelled", false)):
			return
		art.set_meta("race_long_press_fired", true)
		_show_race_bond(race)
	)
	art.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index != MOUSE_BUTTON_LEFT:
				return
			if mb.pressed:
				art.set_meta("race_long_press_start", mb.position)
				art.set_meta("race_long_press_cancelled", false)
				art.set_meta("race_long_press_fired", false)
				timer.start()
			else:
				timer.stop()
				# 轻点（没长按）也把说明摊开：手机用户不一定会想到要长按，
				# 而这条说明本来就是「看一眼」的性质，两条路都通不算坏事。
				if not bool(art.get_meta("race_long_press_fired", false)):
					_show_race_bond(race)
			art.accept_event()
		elif event is InputEventScreenTouch:
			var touch := event as InputEventScreenTouch
			if touch.pressed:
				art.set_meta("race_long_press_start", touch.position)
				art.set_meta("race_long_press_cancelled", false)
				art.set_meta("race_long_press_fired", false)
				timer.start()
			else:
				timer.stop()
				if not bool(art.get_meta("race_long_press_fired", false)):
					_show_race_bond(race)
			art.accept_event()
		elif event is InputEventMouseMotion and timer.time_left > 0.0:
			# 挪动超过 8px = 用户在滑列表，不是长按。
			var start: Vector2 = art.get_meta("race_long_press_start", Vector2.ZERO)
			if (event as InputEventMouseMotion).position.distance_to(start) > 8.0:
				art.set_meta("race_long_press_cancelled", true)
				timer.stop()
		elif event is InputEventScreenDrag and timer.time_left > 0.0:
			var start2: Vector2 = art.get_meta("race_long_press_start", Vector2.ZERO)
			if (event as InputEventScreenDrag).position.distance_to(start2) > 8.0:
				art.set_meta("race_long_press_cancelled", true)
				timer.stop()
	)

# 种族羁绊说明弹窗：正文**直接取备战里那份**（SynergyPanel.format_synergy_effects），
# 不在图鉴里另抄一份 —— 两处文案以后要一起改的只有一处。
func _show_race_bond(race: String) -> void:
	if race.is_empty():
		return
	var body: String = SynergyBond.format_synergy_effects(race)
	if body.is_empty():
		return
	DialogService.info({
		"title": SynergyBond.format_synergy_title(race),
		"body": body,
		"confirm_text": tr("codex_bond_gotit"),
		"owner": self,
	})

func _flat_badge(text: String, color: Color) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.75, 0.64, 0.46, 0.30)
	style.border_color = Color(0.20, 0.15, 0.11, 0.25)
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = _px(8)
	style.content_margin_right = _px(8)
	style.content_margin_top = _px(4)
	style.content_margin_bottom = _px(4)
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", _fs(13))
	lbl.add_theme_color_override("font_color", color)
	lbl.text = text
	panel.add_child(lbl)
	return panel

func _build_skill_box(entry: Dictionary, unlocked: bool) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", Kit.box("card", Vector4(35, 46, 35, 36)))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", _sp(3))
	panel.add_child(col)

	var skill_header := HBoxContainer.new()
	skill_header.add_theme_constant_override("separation", _sp(10))
	col.add_child(skill_header)
	var skill_icon: Texture2D = SkillArt.for_entry(entry) if unlocked else null
	if skill_icon != null:
		var icon := TextureRect.new()
		icon.name = "AbilityIcon"
		icon.texture = skill_icon
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(_px(64), _px(64))
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		skill_header.add_child(icon)
	var head := Label.new()
	head.add_theme_font_size_override("font_size", _fs(20))
	head.add_theme_color_override("font_color", INK)
	head.text = tr("codex_skill")
	skill_header.add_child(head)

	var body := Label.new()
	body.add_theme_font_size_override("font_size", _fs(17))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	body.text = (_skill_text(entry)
		if unlocked else tr("codex_locked_text"))
	col.add_child(body)

	# 10.07 bug 文档第 2 条：补上四星技能说明。
	# 只在「有 star4 覆写」且已解锁时出现；文案尺寸口径照需求：
	#   「四级升星后」与上面的「技能」标签同字号（_fs(11)）；
	#   四星技能正文与上面的一~三星正文同字号（_fs(17)）。
	var four_star := _four_star_skill_text(entry) if unlocked else ""
	if not four_star.is_empty():
		var star_head := Label.new()
		star_head.add_theme_font_size_override("font_size", _fs(11))
		star_head.add_theme_color_override("font_color", INK_SOFT)
		star_head.text = tr("codex_skill_4star")
		col.add_child(star_head)

		var star_body := Label.new()
		star_body.add_theme_font_size_override("font_size", _fs(17))
		star_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		star_body.add_theme_color_override("font_color", INK)
		star_body.text = four_star
		col.add_child(star_body)

	if not unlocked:
		var hint := Label.new()
		hint.add_theme_font_size_override("font_size", _fs(11))
		hint.add_theme_color_override("font_color", INK_SOFT)
		hint.text = tr("codex_locked_skill_hint")
		col.add_child(hint)
	return panel

# The prep screen already writes a sentence per skill, numbers filled in from the
# same data row; the codex shows exactly that instead of a bare skill id. The row
# is carried on the entry as "raw" — entries without one (statuses, pets) never
# reach here.
func _skill_text(entry: Dictionary) -> String:
	var raw: Dictionary = entry.get("raw", {})
	if not raw.is_empty():
		return UnitDetailFormat.format_skill_detail(raw)
	return str(entry.get("skill_id", ""))


# 10.07 bug 文档第 2 条：四星技能文案。
#
# ★ 唯一正确的取法：把 raw 交给 `UnitFactory.apply_star_stats(raw, 4)` 再交给
#   `UnitDetailFormat.format_skill_detail()`。不能自己 `raw.merge(raw.star4)` 了事 ——
#   apply_star_stats 是「产出按星级缩放的 def」的唯一解析点（它会整块覆盖 star4、
#   再 erase 掉 star4 子对象），与战斗里四星棋子的数值同源。手动拼一份就是第二份
#   数值真相，以后 star4 多加一个键就跟战斗对不上。
#
# 没有 star4 覆写（40 个族棋子里有 2 个）⇒ 返回空串，调用方不画这一段。
func _four_star_skill_text(entry: Dictionary) -> String:
	var raw: Dictionary = entry.get("raw", {})
	if raw.is_empty() or typeof(raw.get("star4", null)) != TYPE_DICTIONARY:
		return ""
	return UnitDetailFormat.format_skill_detail(
		UnitFactory.apply_star_stats(raw, GameConstants.MAX_STAR))

func _build_stats(entry: Dictionary, unlocked: bool) -> Control:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", _sp(6))
	grid.add_theme_constant_override("v_separation", _sp(2))

	var stats: Dictionary = entry.get("stats", {})
	var rows := [
		["codex_stat_hp", "hp"], ["codex_stat_atk", "atk"], ["codex_stat_def", "def"], ["codex_stat_mres", "mres"],
		["codex_stat_speed", "attack_speed"], ["codex_stat_range", "range"], ["codex_stat_move", "move_speed"],
	]
	for row in rows:
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", _sp(6))
		var key := Label.new()
		key.add_theme_font_size_override("font_size", _fs(14))
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		key.add_theme_color_override("font_color", INK_SOFT)
		key.text = tr(str(row[0]))
		cell.add_child(key)
		var value := Label.new()
		value.add_theme_font_size_override("font_size", _fs(17))
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		if not unlocked:
			value.text = tr("codex_locked_value")
			value.add_theme_color_override("font_color", LOCKED)
		else:
			value.text = str(stats.get(str(row[1]), 0))
			value.add_theme_color_override("font_color", INK)
		cell.add_child(value)
		var plate := PanelContainer.new()
		plate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var stat_style := StyleBoxFlat.new()
		stat_style.bg_color = Color(0.56, 0.38, 0.17, 0.09)
		stat_style.set_corner_radius_all(3)
		stat_style.content_margin_left = _px(8)
		stat_style.content_margin_right = _px(8)
		stat_style.content_margin_top = _px(1)
		stat_style.content_margin_bottom = _px(1)
		plate.add_theme_stylebox_override("panel", stat_style)
		plate.add_child(cell)
		grid.add_child(plate)
	return grid

func _build_text_block(title: String, body: String, unlocked: bool) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", _sp(2))
	var head := Label.new()
	head.add_theme_font_size_override("font_size", _fs(11))
	head.add_theme_color_override("font_color", INK_SOFT)
	head.text = title
	col.add_child(head)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", _fs(14))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	lbl.text = body
	col.add_child(lbl)
	return col

# A footnote in the running text: smaller and softer than a labelled block, for
# things that qualify the numbers rather than describe the entry.
func _build_note(text: String) -> Control:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", _fs(11))
	lbl.add_theme_color_override("font_color", INK_SOFT)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.text = text
	return lbl

func _build_state_line(entry: Dictionary, unlocked: bool) -> Control:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", _fs(12))
	lbl.add_theme_color_override("font_color", INK_SOFT)
	if bool(entry.get("attribute", false)):
		# 元素不能复用状态那条：「图标与战斗中显示的完全一致」讲的是战斗
		# HUD 的减益图标，元素图标只在图鉴里出现，套上去就是文案≠实现。
		lbl.text = tr("codex_element_reference")
	elif not bool(entry.get("collectible", true)):
		lbl.text = tr("codex_status_reference")
	elif unlocked:
		lbl.text = tr("codex_unlocked_state")
	else:
		lbl.text = tr("codex_locked_skill_hint")
	return lbl

# --- helpers -------------------------------------------------------------

# Font size, pixel length and container separation at the current book scale.
# Everything the pages draw goes through these, so the book and its contents grow
# together and a resize never leaves one out of step with the other.
func _fs(base: float) -> int:
	return maxi(14, int(round(base * _ui)))

func _px(base: float) -> float:
	return base * _ui

func _sp(base: float) -> int:
	return maxi(0, int(round(base * _ui)))

func _element_icon(element: String) -> String:
	return CodexService.PORTRAIT_DIR + "elem_" + element + ".png"

# Statuses carry a localisation key; everything else carries a literal name from
# its data table. English builds show name_en as the title where the table has
# one — monsters, bosses, allies and linkages ship Chinese names only, and those
# fall back to the Chinese rather than showing an empty heading.
func _entry_name(entry: Dictionary) -> String:
	var key := str(entry.get("name_key", ""))
	if not key.is_empty():
		return tr(key)
	var en := str(entry.get("name_en", ""))
	if UnitDetailFormat.is_en() and not en.is_empty():
		return en
	return str(entry.get("name", ""))

# The line under the big name: whichever spelling the title is not using, so both
# are on the page whenever the data carries both.
func _entry_subtitle(entry: Dictionary) -> String:
	var en := str(entry.get("name_en", ""))
	if en.is_empty():
		return ""
	return str(entry.get("name", "")) if UnitDetailFormat.is_en() else en

# Textures are cached because the grid rebuilds on every tab switch and several
# entries share the same emblem.
func _load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _texture_cache.has(path):
		return _texture_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = ResourceLoader.load(path) as Texture2D
	else:
		push_warning("Codex art missing: %s" % path)
	_texture_cache[path] = tex
	return tex
