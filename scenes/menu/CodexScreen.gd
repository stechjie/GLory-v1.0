extends Control
# Codex ("图鉴"). Opened from the main menu; never touches the prep screen.
# Laid out as an open book: the left page picks an entry, the right page shows it.
#   - Left page: category tabs, then a 4-across grid of portraits.
#   - Right page: portrait with the name beneath, emblems and skill beside it,
#     stats below. Locked entries reveal nothing at all.
# Data comes from CodexService; unlock state from PlayerProfile.

signal back_requested

const BOOK_TEX := preload("res://assets/ui/codex/book_spread.png")
# Same art the main menu paints, so the codex opens over a dimmed menu rather than
# a black void. The menu itself is freed when the codex opens, so its background is
# redrawn here instead of kept alive.
const MENU_BG_TEX := preload("res://assets/ui/main_menu_live/background.png")
const REF_SIZE := Vector2(1536.0, 896.0)

# Page rectangles measured against the book art, in BOOK_TEX pixels.
const LEFT_PAGE := Rect2(184.0, 184.0, 492.0, 500.0)
const RIGHT_PAGE := Rect2(830.0, 184.0, 508.0, 500.0)

# The inked part of BOOK_TEX. The art is drawn on a larger transparent canvas, and
# fitting that whole canvas to the window is what used to leave the book floating
# small in the middle of the screen.
const BOOK_ART := Rect2(98.0, 138.0, 1370.0, 594.0)
# Parchment kept visible around the pages when the spread is overscanned.
const SAFE_MARGIN := 40.0
# The book scale the font sizes and widget sizes below were authored against;
# _ui is how far the current scale departs from it.
const UI_REF_SCALE := 0.804

const GRID_COLUMNS := 4
const PARCHMENT := Color(0.89, 0.83, 0.69)
const INK := Color(0.20, 0.15, 0.11)
const INK_SOFT := Color(0.42, 0.34, 0.26)
const LOCKED := Color(0.64, 0.58, 0.48)
const BRASS := Color(0.72, 0.58, 0.25)
const GOOD := Color(0.36, 0.50, 0.29)
const BAD := Color(0.59, 0.27, 0.18)

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
	_refresh()

func _exit_tree() -> void:
	if PlayerProfile.codex_changed.is_connected(_refresh):
		PlayerProfile.codex_changed.disconnect(_refresh)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()

# --- construction --------------------------------------------------------

func _build() -> void:
	var menu_bg := TextureRect.new()
	menu_bg.texture = MENU_BG_TEX
	menu_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	menu_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	menu_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(menu_bg)

	# Dim overlay: the menu shows through, just darker so the book reads clearly.
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.02, 0.55)
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

	var scroll := ScrollContainer.new()
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
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_right_page.add_child(_detail_scroll)

	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", _sp(10))
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_scroll.add_child(_detail)

	# Added last so it sits above the pages for input picking.
	_back_btn = Button.new()
	_back_btn.text = "← " + tr("codex_back")
	_back_btn.custom_minimum_size = Vector2(_px(120), _px(44))
	_back_btn.focus_mode = Control.FOCUS_NONE
	_back_btn.pressed.connect(func(): back_requested.emit())
	add_child(_back_btn)

	_layout()

# Positions the pages over the book art. The spread is drawn to fill the window:
# the transparent margin baked around the book is scaled off-screen, and the book
# is then overscanned as far as the blank page margins allow, so the screen is
# covered without ever cropping into a page.
func _layout() -> void:
	if _book == null:
		return
	var view := size
	if view.x <= 1.0 or view.y <= 1.0:
		return
	# Cover fills the window; the safe limit is how far we may zoom before the
	# pages themselves start leaving the screen. The smaller of the two wins.
	var cover := maxf(view.x / BOOK_ART.size.x, view.y / BOOK_ART.size.y)
	var safe := _safe_rect()
	var safe_limit := minf(view.x / safe.size.x, view.y / safe.size.y)
	var scale := minf(cover, safe_limit)
	# Screen position of the texture's own origin, so page rects map straight through.
	var origin := Vector2(
		-BOOK_ART.position.x * scale + (view.x - BOOK_ART.size.x * scale) * 0.5,
		-BOOK_ART.position.y * scale + (view.y - BOOK_ART.size.y * scale) * 0.5)
	_book.position = origin
	_book.size = REF_SIZE * scale
	for pair in [[_left_page, LEFT_PAGE], [_right_page, RIGHT_PAGE]]:
		var node: Control = pair[0]
		var rect: Rect2 = pair[1]
		if node == null:
			continue
		node.position = origin + rect.position * scale
		node.size = rect.size * scale
	# Fonts and art follow the same scale, so the page keeps its proportions
	# instead of filling up with a handful of tiny widgets.
	var ui := scale / UI_REF_SCALE
	var ui_changed := absf(ui - _ui) > 0.005
	_ui = ui
	if _back_btn != null:
		_back_btn.custom_minimum_size = Vector2(_px(120), _px(44))
		_back_btn.add_theme_font_size_override("font_size", _fs(16))
		_back_btn.size = _back_btn.custom_minimum_size
		_back_btn.position = Vector2(view.x - _px(140), _px(20))
	if _detail_scroll != null and _back_btn != null and _right_page != null:
		# The spread now reaches the window edges, so the back button sits over the top
		# of the right page rather than beside it. Start the detail below it.
		var btn_bottom := _back_btn.position.y + _back_btn.size.y + _px(8)
		_detail_scroll.offset_top = maxf(0.0, btn_bottom - _right_page.position.y)
	# Everything below the pages is built at the current scale, so a window resize
	# has to lay it out again.
	if ui_changed and _grid != null and _grid.get_child_count() > 0:
		_refresh()

# The rectangle that must stay on screen: both pages plus a little of the
# parchment margin around them.
func _safe_rect() -> Rect2:
	return LEFT_PAGE.merge(RIGHT_PAGE).grow(SAFE_MARGIN)

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

	for child in _grid.get_children():
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
		child.queue_free()
	for meta in CodexService.CATEGORIES:
		var key := str(meta.get("key", ""))
		var btn := Button.new()
		btn.text = tr("codex_tab_%s" % key)
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", _fs(13))
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
	return _category == "status"

# --- grid tiles ----------------------------------------------------------

func _build_tile(entry: Dictionary) -> Control:
	var unlocked := CodexService.is_unlocked(entry)
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	# Tall enough that a two-line name does not eat into the portrait.
	btn.custom_minimum_size = Vector2(_px(0), _px(110))
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func():
		_picked = str(entry.get("id", ""))
		_refresh())

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", _sp(2))
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(col)

	var art := TextureRect.new()
	art.texture = _load_texture(str(entry.get("portrait", "")))
	art.custom_minimum_size = Vector2(_px(0), _px(62))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = (TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if bool(entry.get("icon_art", false))
		else TextureRect.STRETCH_KEEP_ASPECT_COVERED)
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
	# English names run far longer than the Chinese ones and used to be cut off
	# mid-word by clip_text. Two lines is enough for every name currently shipped.
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.max_lines_visible = 2
	col.add_child(name_lbl)

	if entry.has("cost") and int(entry.get("cost", 0)) > 0:
		var cost := Label.new()
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost.add_theme_font_size_override("font_size", _fs(10))
		cost.add_theme_color_override("font_color", INK_SOFT)
		cost.text = tr("codex_cost") % int(entry.get("cost", 0))
		col.add_child(cost)

	return btn

# --- detail page ---------------------------------------------------------

func _build_detail(entry: Dictionary) -> void:
	for child in _detail.get_children():
		child.queue_free()
	if entry.is_empty():
		return
	var unlocked := CodexService.is_unlocked(entry)

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
		var pct := int(round(float(entry.get("effect_value", 0.0)) * 100.0))
		var pet_body := (tr("pet_effect_%s" % str(entry.get("effect_key", ""))) % pct
			if unlocked else tr("codex_locked_text"))
		_detail.add_child(_build_text_block(tr("codex_effect"), pet_body, unlocked))

	_detail.add_child(_build_state_line(entry, unlocked))

func _build_portrait_column(entry: Dictionary, unlocked: bool) -> Control:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(_px(150), _px(0))
	col.add_theme_constant_override("separation", _sp(4))

	var art := TextureRect.new()
	art.texture = _load_texture(str(entry.get("portrait", "")))
	art.custom_minimum_size = Vector2(_px(150), _px(130))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = (TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if bool(entry.get("icon_art", false))
		else TextureRect.STRETCH_KEEP_ASPECT_COVERED)
	if not unlocked:
		art.modulate = Color(0, 0, 0, 0.85)
	col.add_child(art)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", _fs(22))
	name_lbl.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.text = _entry_name(entry) if unlocked else tr("codex_locked_name")
	col.add_child(name_lbl)

	var en := Label.new()
	en.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	en.add_theme_font_size_override("font_size", _fs(12))
	en.add_theme_color_override("font_color", INK_SOFT)
	en.text = _entry_subtitle(entry) if unlocked else tr("codex_locked_hint")
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
			CodexService.RACE_LOGO_DIR + race + ".png", tr("codex_tab_%s" % race)))
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
	return row if row.get_child_count() > 0 else null

# Emblem above, label beneath: the round art identifies the entry, the words only
# confirm it.
func _emblem_badge(texture_path: String, label: String) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", _sp(2))
	var art := TextureRect.new()
	art.texture = _load_texture(texture_path)
	art.custom_minimum_size = Vector2(_px(58), _px(58))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	col.add_child(art)
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", _fs(12))
	lbl.add_theme_color_override("font_color", INK)
	lbl.text = label
	col.add_child(lbl)
	return col

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
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.85, 0.79, 0.65, 0.55)
	style.border_color = Color(0.20, 0.15, 0.11, 0.28)
	style.set_border_width_all(1)
	style.border_width_left = int(_px(4))
	style.border_color = BRASS
	style.set_corner_radius_all(2)
	style.content_margin_left = _px(10)
	style.content_margin_right = _px(10)
	style.content_margin_top = _px(8)
	style.content_margin_bottom = _px(8)
	panel.add_theme_stylebox_override("panel", style)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", _sp(3))
	panel.add_child(col)

	var head := Label.new()
	head.add_theme_font_size_override("font_size", _fs(11))
	head.add_theme_color_override("font_color", INK_SOFT)
	head.text = tr("codex_skill")
	col.add_child(head)

	var body := Label.new()
	body.add_theme_font_size_override("font_size", _fs(15))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	body.text = (_skill_text(entry)
		if unlocked else tr("codex_locked_text"))
	col.add_child(body)

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

func _build_stats(entry: Dictionary, unlocked: bool) -> Control:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", _sp(6))
	grid.add_theme_constant_override("v_separation", _sp(4))

	var stats: Dictionary = entry.get("stats", {})
	var rows := [
		["codex_stat_hp", "hp"], ["codex_stat_atk", "atk"], ["codex_stat_def", "def"],
		["codex_stat_speed", "attack_speed"], ["codex_stat_range", "range"], ["codex_stat_move", "move_speed"],
	]
	for row in rows:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", _sp(0))
		var key := Label.new()
		key.add_theme_font_size_override("font_size", _fs(10))
		key.add_theme_color_override("font_color", INK_SOFT)
		key.text = tr(str(row[0]))
		cell.add_child(key)
		var value := Label.new()
		value.add_theme_font_size_override("font_size", _fs(17))
		if not unlocked:
			value.text = tr("codex_locked_value")
			value.add_theme_color_override("font_color", LOCKED)
		else:
			value.text = str(stats.get(str(row[1]), 0))
			value.add_theme_color_override("font_color", INK)
		cell.add_child(value)
		grid.add_child(cell)
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
	if not bool(entry.get("collectible", true)):
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
	return maxi(1, int(round(base * _ui)))

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
