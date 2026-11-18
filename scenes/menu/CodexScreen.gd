extends Control

const MusicService := preload("res://ui/services/MusicService.gd")
# Codex ("图鉴"). Opened from the main menu; never touches the prep screen.
# Laid out as an open book: the left page picks an entry, the right page shows it.
#   - Left page: back button + title, one sliding row of category tabs, then a
#     3-across grid of portraits. The book fills the whole screen (11.16).
#   - Right page: framed character record, attributes, illustrated ability and four-star upgrade,
#     stats below. Locked entries reveal nothing at all.
# Data comes from CodexService; unlock state from PlayerProfile.

signal back_requested

const BOOK_TEX := preload("res://assets/ui/codex/painted/book_spread_painted.png")
const Kit := preload("res://ui/theme/ParchmentKit.gd")
const SkillArt := preload("res://ui/components/CodexSkillArt.gd")
# ★ 11.16：图鉴书本铺满整屏，书里的按钮 / 图案 / 字体按书的放大比例一起放大。
#   书本贴图（1568×1003）里的关键位置，单位都是**贴图像素**：
#   - BOOK_VISIBLE：书皮外缘（不含伸出去的叶尖和底部书签），这一圈对齐屏幕四边；
#   - 书脊在 BOOK_SPINE_X，左右两半各用一个 NinePatchRect 画：四角叶子 / 卷边和
#     书脊两侧保持原比例，只拉伸页面中间 —— 手机屏比贴图宽得多，整张拉伸会把
#     四角压扁；
#   - PAGE_*：可写字的区域（羊皮纸再往里让开四角的金色卷边和书脊阴影）。
#     右页以书脊为轴镜像左页。
const BOOK_VISIBLE := Rect2(74.0, 79.0, 1422.0, 830.0)
const BOOK_SPINE_X := 784.0
const PATCH_OUTER := 210 # 外侧（含叶子和卷边）
const PATCH_SPINE := 60  # 书脊一侧（含书脊阴影与书签）
const PATCH_TOP := 200
const PATCH_BOTTOM := 260
const PAGE_OUTER_X := 176.0 # 左页内容区外沿
const PAGE_INNER_X := 730.0 # 左页内容区靠书脊一侧
const PAGE_TOP_Y := 141.0
const PAGE_BOTTOM_Y := 817.0
# 旧版（书本没铺满时）在 1600×720 下一页内容区的大小，放大比例以它为 1.0。
# 宽度基准取 500 而不是当时的 591：左页从 4 列改 3 列，每格本来就更宽。
const PAGE_REF_SIZE := Vector2(500.0, 467.0)
const GRID_COLUMNS := 3
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

var _book_left: NinePatchRect
var _book_right: NinePatchRect
var _left_page: Control
var _right_page: Control
var _left_col: VBoxContainer
var _head: HBoxContainer
var _tab_scroll: ScrollContainer
var _tab_row: HBoxContainer
var _title_label: Label
var _count_label: Label
var _grid: GridContainer
var _detail: VBoxContainer
var _detail_scroll: ScrollContainer
var _back_btn: Button
var _back_aspect := 1.0

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
	# 11.16：图鉴独立 BGM。返回主菜单时由 MainMenu 接回主菜单那首。
	MusicService.play(MusicService.CODEX_MUSIC, true)

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
	# 书本铺满后屏幕四边就是书皮；这层深色只在书皮圆角、书脊顶端那几个像素透出来。
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.13, 0.08, 0.05)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	_book_left = _book_half(Rect2(0.0, 0.0, BOOK_SPINE_X, BOOK_TEX.get_height()), PATCH_OUTER, PATCH_SPINE)
	_book_right = _book_half(
		Rect2(BOOK_SPINE_X, 0.0, BOOK_TEX.get_width() - BOOK_SPINE_X, BOOK_TEX.get_height()),
		PATCH_SPINE, PATCH_OUTER)

	_left_page = Control.new()
	_left_page.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_left_page)

	_left_col = VBoxContainer.new()
	_left_col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_left_page.add_child(_left_col)

	# 页眉：返回键 + 分类标题 + 进度。原先顶上那条「图鉴」横幅和左上角返回键
	# 都浮在书外面，书铺满后没地方放 —— 横幅去掉（标题已写明分类），返回键收进左页页眉。
	_head = HBoxContainer.new()
	_left_col.add_child(_head)
	_back_btn = Kit.back_button(func(): back_requested.emit(), 56.0)
	_back_btn.tooltip_text = tr("codex_back")
	_back_btn.focus_mode = Control.FOCUS_ALL
	_back_aspect = _back_btn.custom_minimum_size.x / maxf(1.0, _back_btn.custom_minimum_size.y)
	_head.add_child(_back_btn)
	_title_label = Label.new()
	_title_label.add_theme_color_override("font_color", INK)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.clip_text = true
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_head.add_child(_title_label)
	_count_label = Label.new()
	_count_label.add_theme_color_override("font_color", INK_SOFT)
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_head.add_child(_count_label)

	# 分类有 14 个，按钮放大后排成多行会吃掉小半页 —— 改成一行，左右滑动
	# （手指 / 鼠标拖都行），切换分类时把选中那个滚进视野。
	var tab_scroll := TouchScrollContainer.new()
	tab_scroll.drag_horizontal = true
	tab_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_tab_scroll = tab_scroll
	_left_col.add_child(_tab_scroll)
	_tab_row = HBoxContainer.new()
	_tab_scroll.add_child(_tab_row)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_left_col.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
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
	_detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_scroll.add_child(_detail)

	_apply_static_sizes()
	_layout()

# 书本的半边：一个 NinePatchRect 截贴图的左半或右半。四个 patch 边距以贴图像素计，
# 画出来时边距按节点自身的 scale 缩放，所以四角始终保持原比例。
func _book_half(region: Rect2, margin_left: int, margin_right: int) -> NinePatchRect:
	var half := NinePatchRect.new()
	half.texture = BOOK_TEX
	half.region_rect = region
	half.patch_margin_left = margin_left
	half.patch_margin_right = margin_right
	half.patch_margin_top = PATCH_TOP
	half.patch_margin_bottom = PATCH_BOTTOM
	half.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(half)
	return half

# 书皮外缘（BOOK_VISIBLE）对齐整个视口 —— 书画到刘海底下也没关系，
# 但两页的内容区再和安全区取交集，文字和按钮不会钻进刘海。
func _layout() -> void:
	if _book_left == null or size.x <= 1.0 or size.y <= 1.0:
		return
	var view := Vector2(size.x, size.y)
	# 四角按同一个比例缩放：取宽、高里先撑满的那个，另一个方向靠拉伸页面中间补齐。
	var s := minf(view.x / BOOK_VISIBLE.size.x, view.y / BOOK_VISIBLE.size.y)
	var tex_size := Vector2(BOOK_TEX.get_width(), BOOK_TEX.get_height())
	var pad_left := BOOK_VISIBLE.position.x
	var pad_right := tex_size.x - BOOK_VISIBLE.end.x
	var pad_top := BOOK_VISIBLE.position.y
	var pad_bottom := tex_size.y - BOOK_VISIBLE.end.y
	var spine := view.x * 0.5
	var local_h := pad_top + pad_bottom + view.y / s
	_book_left.scale = Vector2(s, s)
	_book_left.position = Vector2(-pad_left * s, -pad_top * s)
	_book_left.size = Vector2(pad_left + spine / s, local_h)
	_book_right.scale = Vector2(s, s)
	_book_right.position = Vector2(spine, -pad_top * s)
	_book_right.size = Vector2(pad_right + (view.x - spine) / s, local_h)

	# 内容区：外沿和上下落在 patch 边距里（不被拉伸，按 s 换算），书脊一侧以屏幕中线为准。
	var top := (PAGE_TOP_Y - pad_top) * s
	var bottom := view.y - (BOOK_VISIBLE.end.y - PAGE_BOTTOM_Y) * s
	var outer := (PAGE_OUTER_X - pad_left) * s
	var inner := (BOOK_SPINE_X - PAGE_INNER_X) * s
	var safe := SafeArea.rect()
	top = maxf(top, safe.position.y)
	bottom = minf(bottom, safe.end.y)
	var left_x0 := maxf(outer, safe.position.x)
	var right_x1 := minf(view.x - outer, safe.end.x)
	_left_page.position = Vector2(left_x0, top)
	_left_page.size = Vector2(maxf(1.0, spine - inner - left_x0), maxf(1.0, bottom - top))
	_right_page.position = Vector2(spine + inner, top)
	_right_page.size = Vector2(maxf(1.0, right_x1 - spine - inner), maxf(1.0, bottom - top))

	# 书里所有东西的放大比例：两页里较窄 / 较矮的那一边相对旧版内容区的倍数。
	var page := Vector2(minf(_left_page.size.x, _right_page.size.x), _left_page.size.y)
	var ui := clampf(minf(page.x / PAGE_REF_SIZE.x, page.y / PAGE_REF_SIZE.y), 0.8, 1.8)
	var ui_changed := absf(ui - _ui) > 0.005
	_ui = ui
	if _detail_scroll != null:
		_detail_scroll.offset_top = 0
	if ui_changed:
		_apply_static_sizes()
		if _grid != null and _grid.get_child_count() > 0:
			_refresh()

# 只在 _build 里建一次的控件，放大比例变了要跟着改尺寸（其余的每次 _refresh 都重建）。
func _apply_static_sizes() -> void:
	if _left_col == null:
		return
	_left_col.add_theme_constant_override("separation", _sp(8))
	_head.add_theme_constant_override("separation", _sp(10))
	var back_side := _px(52)
	_back_btn.custom_minimum_size = Vector2(back_side * _back_aspect, back_side)
	_title_label.add_theme_font_size_override("font_size", _fs(22))
	_count_label.add_theme_font_size_override("font_size", _fs(14))
	_tab_row.add_theme_constant_override("separation", _sp(4))
	_grid.add_theme_constant_override("h_separation", _sp(8))
	_grid.add_theme_constant_override("v_separation", _sp(8))
	_detail.add_theme_constant_override("separation", _sp(10))

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
	# 每次刷新都重建按钮（语言 / 放大比例可能变了），但别把用户滑到的位置弹回开头。
	var keep_scroll := _tab_scroll.scroll_horizontal
	var selected: Control = null
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
		if key == _category:
			selected = btn
	_tab_scroll.custom_minimum_size.y = _px(44)
	_tab_scroll.set_deferred("scroll_horizontal", keep_scroll)
	if selected != null:
		_tab_scroll.call_deferred("ensure_control_visible", selected)

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
	# 状态是**参考物料**：不是收集目标，计数栏写「N 种」而不是「已发现 N/M」。
	# （「元素」分类页 11.18 已删，克制说明改成点徽章弹出。）
	return _category == "status"

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
	# ★ 11.18：元素 / 系徽章也能点开（或长按），弹出该元素的克制关系 ——
	#   和种族徽章弹羁绊说明同一种手势、同一种弹窗。怪物的 series 与它战斗里的
	#   element 是同一个值（pve_monsters.json 逐条一致），所以弹同一份克制说明。
	var element := str(entry.get("element", ""))
	if not element.is_empty():
		row.add_child(_emblem_badge(_element_icon(element),
			tr("codex_element_suffix") % tr("codex_elem_%s" % element), "", element))
	var series := str(entry.get("series", ""))
	if not series.is_empty():
		row.add_child(_emblem_badge(_element_icon(series),
			tr("codex_series_suffix") % tr("codex_elem_%s" % series), "", series))
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
#
# ★ 10.08 反馈第 2 条：棋子图鉴里的**种族图标**要能**长按**弹出该族的羁绊说明
#   （文本取自备战里的那一份 —— SynergyPanel.format_synergy_effects，不在这里另抄）。
# ★ 11.18：**元素 / 系图标**同样能点开，弹出该元素的克制关系（element 参数）。
#   race / element 都为空的徽章不装手势。
func _emblem_badge(texture_path: String, label: String, race: String = "", element: String = "") -> Control:
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
		art.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_attach_bond_long_press(art, func(): _show_race_bond(race))
	elif CodexService.ELEMENTS.has(element):
		art.mouse_filter = Control.MOUSE_FILTER_STOP
		art.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_attach_bond_long_press(art, func(): _show_element_bond(element))
	col.add_child(art)
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", _fs(12))
	lbl.add_theme_color_override("font_color", INK)
	lbl.text = label
	col.add_child(lbl)
	return col

# 给徽章装「轻点或长按 0.7 秒弹说明」，open_popup 是弹哪份说明。
#
# 手势状态挂在控件 meta 上（与 PrepDetailOverlay.attach_long_press 同一套约定，
# 这里只做图鉴需要的那一小份：按下起表、移动超过 8px 取消、松手停表）：
#   长按常驻说明由 DialogService 的模态接管，所以松手不需要再收掉 —— 不会
#   像备战浮层那样出现「松手把刚弹出来的说明又关掉」。
#
# ★ 11.18「羁绊说明要按两次才关掉」：手机上 Godot 默认把一次触摸**再模拟成一次
#   鼠标点击**（emulate_mouse_from_touch），旧代码触摸抬起、鼠标抬起各弹一次，
#   叠出两个一模一样的框 —— 关掉上面那个，下面还有一个。现在：
#   ① 一次手势只认**先按下的那一路**（"touch" / "mouse"），另一路的按下 / 抬起都忽略；
#   ② 弹窗本身再带固定 request_id（见 _show_race_bond / _show_element_bond），
#      同一份说明已开着时 DialogService 不会再叠第二个 —— 双保险。
func _attach_bond_long_press(art: Control, open_popup: Callable) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = 0.7
	art.add_child(timer)
	art.set_meta("bond_long_press_timer", timer)
	art.set_meta("bond_press_kind", "")
	timer.timeout.connect(func():
		if bool(art.get_meta("bond_long_press_cancelled", false)):
			return
		art.set_meta("bond_long_press_fired", true)
		open_popup.call()
	)
	var on_press := func(kind: String, pos: Vector2) -> void:
		var active := str(art.get_meta("bond_press_kind", ""))
		var since := Time.get_ticks_msec() - int(art.get_meta("bond_press_msec", 0))
		# 另一路紧跟着到的按下 = 同一次手势的副本（触摸模拟出来的鼠标），不再重开。
		# 只在 400ms 内认作副本：上一次的抬起若被列表拖动吃掉了（TouchScrollContainer
		# 会标记已处理），标记会残留，过了这段时间就当新手势，徽章不会从此点不动。
		if active != "" and active != kind and since < 400:
			return
		art.set_meta("bond_press_kind", kind)
		art.set_meta("bond_press_msec", Time.get_ticks_msec())
		art.set_meta("bond_long_press_start", pos)
		art.set_meta("bond_long_press_cancelled", false)
		art.set_meta("bond_long_press_fired", false)
		timer.start()
	var on_release := func(kind: String) -> void:
		if str(art.get_meta("bond_press_kind", "")) != kind:
			return # 不是这次手势开头那一路的抬起：忽略，否则会弹第二次
		art.set_meta("bond_press_kind", "")
		timer.stop()
		# 轻点（没长按）也把说明摊开：手机用户不一定会想到要长按，
		# 而这条说明本来就是「看一眼」的性质，两条路都通不算坏事。
		if not bool(art.get_meta("bond_long_press_fired", false)) \
				and not bool(art.get_meta("bond_long_press_cancelled", false)):
			open_popup.call()
	art.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index != MOUSE_BUTTON_LEFT:
				return
			if mb.pressed:
				on_press.call("mouse", mb.position)
			else:
				on_release.call("mouse")
			art.accept_event()
		elif event is InputEventScreenTouch:
			var touch := event as InputEventScreenTouch
			if touch.pressed:
				on_press.call("touch", touch.position)
			else:
				on_release.call("touch")
			art.accept_event()
		elif event is InputEventMouseMotion and timer.time_left > 0.0:
			# 挪动超过 8px = 用户在滑列表，不是长按。
			var start: Vector2 = art.get_meta("bond_long_press_start", Vector2.ZERO)
			if (event as InputEventMouseMotion).position.distance_to(start) > 8.0:
				art.set_meta("bond_long_press_cancelled", true)
				timer.stop()
		elif event is InputEventScreenDrag and timer.time_left > 0.0:
			var start2: Vector2 = art.get_meta("bond_long_press_start", Vector2.ZERO)
			if (event as InputEventScreenDrag).position.distance_to(start2) > 8.0:
				art.set_meta("bond_long_press_cancelled", true)
				timer.stop()
	)

# 种族羁绊说明弹窗：正文**直接取备战里那份**（SynergyPanel.format_synergy_effects），
# 不在图鉴里另抄一份 —— 两处文案以后要一起改的只有一处。
# request_id 固定：同一族的说明已经开着时不会再叠一个（11.18「要按两次」）。
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
		"request_id": "codex_race_bond_%s" % race,
	})

# 元素克制说明弹窗（11.18）：正文就是原「元素」分类页里那份
# codex_element_<id>_desc（倍率与 BattleSimShared._element_multiplier 一致，
# tools/codex_element_check.gd 逐条核对）。
func _show_element_bond(element: String) -> void:
	if not CodexService.ELEMENTS.has(element):
		return
	var body := tr("codex_element_%s_desc" % element)
	if body.is_empty() or body == "codex_element_%s_desc" % element:
		return
	DialogService.info({
		"title": tr("codex_element_suffix") % tr("codex_elem_%s" % element),
		"body": body,
		"confirm_text": tr("codex_bond_gotit"),
		"owner": self,
		"request_id": "codex_element_bond_%s" % element,
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
#
# 11.16：字号先按「旧版实际显示的大小」取（11、12、13 号以前都被 14 的下限托住），
# 再乘放大比例 —— 否则放大后小字还卡在 14，大字却变大，字与字的比例就乱了。
func _fs(base: float) -> int:
	return maxi(14, int(round(maxf(14.0, base) * _ui)))

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
