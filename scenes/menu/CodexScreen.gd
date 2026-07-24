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
var _back_btn: Button

var _category := "god"
var _picked := ""
var _texture_cache: Dictionary = {}

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
	_book.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_book.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_book)

	_left_page = Control.new()
	_left_page.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_left_page)

	var left_col := VBoxContainer.new()
	left_col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	left_col.add_theme_constant_override("separation", 8)
	_left_page.add_child(left_col)

	var head := HBoxContainer.new()
	left_col.add_child(head)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 22)
	_title_label.add_theme_color_override("font_color", INK)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title_label)
	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 14)
	_count_label.add_theme_color_override("font_color", INK_SOFT)
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	head.add_child(_count_label)

	_tab_row = HFlowContainer.new()
	_tab_row.add_theme_constant_override("h_separation", 4)
	_tab_row.add_theme_constant_override("v_separation", 4)
	left_col.add_child(_tab_row)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_col.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)

	_right_page = Control.new()
	_right_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_right_page)

	_detail = VBoxContainer.new()
	_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_detail.add_theme_constant_override("separation", 10)
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right_page.add_child(_detail)

	# Added last so it sits above the pages for input picking.
	_back_btn = Button.new()
	_back_btn.text = "← " + tr("codex_back")
	_back_btn.custom_minimum_size = Vector2(120, 44)
	_back_btn.focus_mode = Control.FOCUS_NONE
	_back_btn.pressed.connect(func(): back_requested.emit())
	add_child(_back_btn)

	_layout()

# Positions the pages over the book art. The texture is letterboxed to keep its
# aspect, so the page rects are mapped through the same scale and offset.
func _layout() -> void:
	if _book == null:
		return
	var view := size
	_book.position = Vector2.ZERO
	_book.size = view
	var scale := minf(view.x / REF_SIZE.x, view.y / REF_SIZE.y)
	var drawn := REF_SIZE * scale
	var origin := (view - drawn) * 0.5
	for pair in [[_left_page, LEFT_PAGE], [_right_page, RIGHT_PAGE]]:
		var node: Control = pair[0]
		var rect: Rect2 = pair[1]
		if node == null:
			continue
		node.position = origin + rect.position * scale
		node.size = rect.size * scale
	if _back_btn != null:
		_back_btn.position = Vector2(view.x - 140.0, 20.0)

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
		btn.add_theme_font_size_override("font_size", 13)
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
	btn.custom_minimum_size = Vector2(0, 96)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func():
		_picked = str(entry.get("id", ""))
		_refresh())

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(col)

	var art := TextureRect.new()
	art.texture = _load_texture(str(entry.get("portrait", "")))
	art.custom_minimum_size = Vector2(0, 62)
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
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	name_lbl.text = _entry_name(entry) if unlocked else tr("codex_locked_name")
	name_lbl.clip_text = true
	col.add_child(name_lbl)

	if entry.has("cost") and int(entry.get("cost", 0)) > 0:
		var cost := Label.new()
		cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost.add_theme_font_size_override("font_size", 10)
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
	top.add_theme_constant_override("separation", 14)
	_detail.add_child(top)
	top.add_child(_build_portrait_column(entry, unlocked))

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 8)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(side)

	var badges := _build_badges(entry, unlocked)
	if badges != null:
		side.add_child(badges)
	if not str(entry.get("skill_id", "")).is_empty():
		side.add_child(_build_skill_box(entry, unlocked))

	if entry.has("stats") or bool(entry.get("hide_stats", false)):
		_detail.add_child(_build_stats(entry, unlocked))

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
	col.custom_minimum_size = Vector2(150, 0)
	col.add_theme_constant_override("separation", 4)

	var art := TextureRect.new()
	art.texture = _load_texture(str(entry.get("portrait", "")))
	art.custom_minimum_size = Vector2(150, 130)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = (TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if bool(entry.get("icon_art", false))
		else TextureRect.STRETCH_KEEP_ASPECT_COVERED)
	if not unlocked:
		art.modulate = Color(0, 0, 0, 0.85)
	col.add_child(art)

	var name_lbl := Label.new()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 22)
	name_lbl.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.text = _entry_name(entry) if unlocked else tr("codex_locked_name")
	col.add_child(name_lbl)

	var en := Label.new()
	en.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	en.add_theme_font_size_override("font_size", 12)
	en.add_theme_color_override("font_color", INK_SOFT)
	en.text = str(entry.get("name_en", "")) if unlocked else tr("codex_locked_hint")
	col.add_child(en)
	return col

func _build_badges(entry: Dictionary, unlocked: bool) -> Control:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 12)
	row.add_theme_constant_override("v_separation", 6)

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
	col.add_theme_constant_override("separation", 2)
	var art := TextureRect.new()
	art.texture = _load_texture(texture_path)
	art.custom_minimum_size = Vector2(58, 58)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	col.add_child(art)
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 12)
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
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 13)
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
	style.border_width_left = 4
	style.border_color = BRASS
	style.set_corner_radius_all(2)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	panel.add_child(col)

	var head := Label.new()
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", INK_SOFT)
	head.text = tr("codex_skill")
	col.add_child(head)

	var body := Label.new()
	body.add_theme_font_size_override("font_size", 15)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	body.text = (_skill_text(str(entry.get("skill_id", "")))
		if unlocked else tr("codex_locked_text"))
	col.add_child(body)

	if not unlocked:
		var hint := Label.new()
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", INK_SOFT)
		hint.text = tr("codex_locked_skill_hint")
		col.add_child(hint)
	return panel

func _skill_text(skill_id: String) -> String:
	# Falls back to the raw id when no copy exists yet, which is honest about the
	# gap rather than showing an empty box.
	var key := "codex_skill_%s" % skill_id
	var text := tr(key)
	return skill_id if text == key else text

func _build_stats(entry: Dictionary, unlocked: bool) -> Control:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 4)

	var hidden := bool(entry.get("hide_stats", false))
	var stats: Dictionary = entry.get("stats", {})
	var rows := [
		["codex_stat_hp", "hp"], ["codex_stat_atk", "atk"], ["codex_stat_def", "def"],
		["codex_stat_speed", "attack_speed"], ["codex_stat_range", "range"], ["codex_stat_move", "move_speed"],
	]
	for row in rows:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 0)
		var key := Label.new()
		key.add_theme_font_size_override("font_size", 10)
		key.add_theme_color_override("font_color", INK_SOFT)
		key.text = tr(str(row[0]))
		cell.add_child(key)
		var value := Label.new()
		value.add_theme_font_size_override("font_size", 17)
		if not unlocked:
			value.text = tr("codex_locked_value")
			value.add_theme_color_override("font_color", LOCKED)
		elif hidden:
			# Boss numbers are withheld by design, not by progression.
			value.text = tr("codex_hidden_stat")
			value.add_theme_color_override("font_color", BRASS)
		else:
			value.text = str(stats.get(str(row[1]), 0))
			value.add_theme_color_override("font_color", INK)
		cell.add_child(value)
		grid.add_child(cell)
	return grid

func _build_text_block(title: String, body: String, unlocked: bool) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	var head := Label.new()
	head.add_theme_font_size_override("font_size", 11)
	head.add_theme_color_override("font_color", INK_SOFT)
	head.text = title
	col.add_child(head)
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", INK if unlocked else LOCKED)
	lbl.text = body
	col.add_child(lbl)
	return col

func _build_state_line(entry: Dictionary, unlocked: bool) -> Control:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", INK_SOFT)
	if not bool(entry.get("collectible", true)):
		lbl.text = tr("codex_status_reference")
	elif unlocked:
		lbl.text = tr("codex_unlocked_state")
	else:
		lbl.text = tr("codex_locked_skill_hint")
	return lbl

# --- helpers -------------------------------------------------------------

func _element_icon(element: String) -> String:
	return CodexService.PORTRAIT_DIR + "elem_" + element + ".png"

# Statuses carry a localisation key; everything else carries a literal name from
# its data table.
func _entry_name(entry: Dictionary) -> String:
	var key := str(entry.get("name_key", ""))
	return tr(key) if not key.is_empty() else str(entry.get("name", ""))

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
