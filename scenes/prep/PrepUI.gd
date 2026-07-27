extends "res://scenes/prep/PrepBoardModels.gd"

const PrepShopRaceIcon = preload("res://scenes/prep/PrepShopRaceIcon.gd")
const PrepMoneyBagIcon = preload("res://scenes/prep/PrepMoneyBagIcon.gd")
const SHOP_REFRESH_WIDTH := 112.0
const SHOP_GOLD_WIDTH := 112.0
const SHOP_PANEL_BACKGROUND_PATH := "res://assets/ui/shop/btm_stone_frame_v4.png"
const SHOP_POPUP_SIZE := Vector2(896, 230)   # 商店弹窗判定框：宽=屏宽70%(1280*0.7)、高=屏高40%(720*0.4)
const SHOP_POPUP_OFFSET := Vector2(0, 7)     # 商店弹窗判定框中心的平移（正 x 右移、正 y 下移）
const SHOP_BG_SIZE := Vector2(920, 280)     # 背景卷轴显示尺寸（像素）：独立于判定框，改这里只变视觉不变判定
const SHOP_BG_OFFSET := Vector2(0, -2)        # 背景相对弹窗中心的平移（正 x 右移、正 y 下移）
const SHOP_BTN_SIZE := Vector2(200, 66)      # 底部「商店」按钮（木牌框）
const SHOP_CARD_SIZE := Vector2(180, 180)    # 手牌卡尺寸（稀有度框比例 ~1:1）
const SHOP_CARD_SEPARATION := 12             # 手牌卡间距
const SHOP_CARD_FRAME_PATHS := {             # tier(1/2/3) → 普通/稀有/史诗框
	1: "res://assets/ui/shop/card_frame_common.png",
	2: "res://assets/ui/shop/card_frame_rare.png",
	3: "res://assets/ui/shop/card_frame_epic.png",
}
const UNIT_PORTRAIT_DIR := "res://assets/ui/unit_portraits"   # 头像 = <dir>/<unit_id>.png
const HP_FRAME_EMPTY_PATH := "res://assets/ui/buttons/btn_hp_empty.png"   # 血条石框（深色空槽）
const HP_FRAME_RED_PATH := "res://assets/ui/buttons/btn_hp_red.png"       # 血条红条填充贴图
const HP_FRAME_SIZE := Vector2(246, 82)                                   # 高清框 2172x724，比例 3.0
const START_BTN_PATH := "res://assets/ui/buttons/btn_start.png"           # 开始战斗木牌框（高清透明）
const START_BTN_SIZE := Vector2(240, 80)                                  # 比例 3.0
const STATS_BTN_PATH := "res://assets/ui/buttons/btn_stats.png"           # 统计/战力石板框（高清透明）
const STATS_BTN_SIZE := Vector2(140, 94)                                  # 比例 1.5
const REFRESH_BTN_PATH := "res://assets/ui/buttons/btn_refresh.png"       # 刷新循环箭头方框（1254x1254）
const MERC_BTN_PATH := "res://assets/ui/buttons/btn_merc.png"             # 佣兵盾牌圆框（1254x1254）
const MERC_BTN_SIZE := Vector2(132, 132)                                  # 方形
const SHOP_CLOSED_BTN_PATH := "res://assets/ui/buttons/shop_closed.png"   # 底部商店按钮图（自带文字，无需再叠字）
const CRYSTAL_FIRE_PATHS := [                 # 火队（slot 0-2 红蓝绿）红水晶：按血量段 0-10..40-50
	"res://assets/ui/crystals/red_0_10.png",
	"res://assets/ui/crystals/red_10_20.png",
	"res://assets/ui/crystals/red_20_30.png",
	"res://assets/ui/crystals/red_30_40.png",
	"res://assets/ui/crystals/red_40_50.png",
]
const CRYSTAL_WATER_PATHS := [                # 水队（slot 3-5 黄紫橙）蓝水晶
	"res://assets/ui/crystals/blue_0_10.png",
	"res://assets/ui/crystals/blue_10_20.png",
	"res://assets/ui/crystals/blue_20_30.png",
	"res://assets/ui/crystals/blue_30_40.png",
	"res://assets/ui/crystals/blue_40_50.png",
]
const TOP_ROW_BTN_SIZE := Vector2(96, 64)                                 # 右上角横排三键（战力/统计/静音）缩小尺寸
# 调试：把所有按钮的点击判定区域用线条画出来。不需要时改成 false。
const SHOW_HIT_AREAS := false
# 调试：把所有布局控件的矩形（空间框）用黑边画出来，方便看排版。不需要时改成 false。
const SHOW_SPACE_FRAMES := false
# 「队伍佣兵」弹窗 3D 检阅台。缩放/相机抄备战河流视口的量级，取景不对就调这几个。
# AREA_HALF / MIN_DIST 是 stage root 本地坐标（stage 再被 STAGE_SCALE 放大）。
const TEAM_MERCS_STAGE_SCALE := 3.2
const TEAM_MERCS_CAMERA_POSITION := Vector3(0.0, 2.4, 1.9)
const TEAM_MERCS_CAMERA_TARGET := Vector3(0.0, 0.05, 0.0)
const TEAM_MERCS_CAMERA_FOV := 40.0
const TEAM_MERCS_AREA_HALF := Vector2(0.42, 0.24)
const TEAM_MERCS_MIN_DIST := 0.15
const TEAM_MERCS_PLATE_RADIUS := 0.055
const TEAM_MERCS_PLATE_HEIGHT := 0.012
const TREASURE_LOGO_DIRECTORY := "res://assets/ui/treasure_logos"
const TREASURE_CARD_DIRECTORY := "res://assets/ui/treasure_cards"
const TREASURE_LINKAGE_LOGOS := {
	"link_phoenix": "凤凰涅槃",
	"link_money_magic": "金钱魔法",
	"link_blood_covenant": "血之契约",
	"link_paralysis_shackles": "瘫痪枷锁",
	"link_oppression_counter": "压迫反击",
	"link_fraud_fate": "诡诈命运",
	"link_iron_maiden": "铁处女",
	"link_toxic_burst": "剧毒爆发",
	"link_rich_path": "富裕之路",
	"link_clearance_sale": "清仓特卖",
	"link_hu_pai_master": "胡牌手",
}
const PVP_WARNING_FRAME_PATH := "res://assets/ui/pvp_warning_frame.png"

const MERCENARY_PORTRAIT_PATHS := {
	"merc_pisces_bubble": "res://assets/ui/mercenary_portraits/merc_pisces_bubble.png",
	"merc_cancer_shell": "res://assets/ui/mercenary_portraits/merc_cancer_shell.png",
	"merc_libra_judge": "res://assets/ui/mercenary_portraits/merc_libra_judge.png",
	"merc_taurus_charge": "res://assets/ui/mercenary_portraits/merc_taurus_charge.png",
	"merc_virgo_heal": "res://assets/ui/mercenary_portraits/merc_virgo_heal.png",
	"merc_gemini_assassin": "res://assets/ui/mercenary_portraits/merc_gemini_assassin.png",
	"merc_leo_sun": "res://assets/ui/mercenary_portraits/merc_leo_sun.png",
	"merc_sagittarius_rain": "res://assets/ui/mercenary_portraits/merc_sagittarius_rain.png",
	"merc_aries_blood": "res://assets/ui/mercenary_portraits/merc_aries_blood.png",
	"merc_capricorn_steel": "res://assets/ui/mercenary_portraits/merc_capricorn_steel.png",
	"merc_aquarius_time": "res://assets/ui/mercenary_portraits/merc_aquarius_time.png",
	"merc_scorpio_death": "res://assets/ui/mercenary_portraits/merc_scorpio_death.png",
}

var _mute_button: Button
# 强引用贴图缓存：load() 只在资源仍被引用时命中引擎缓存，
# 这里持有引用保证商店头像/宝物图标等反复刷新的贴图零重复 I/O。
# static：PrepScreen 每回合都被 Main 重建，缓存必须跨实例存活。
static var _texture_cache: Dictionary = {}
# 增量刷新签名：_refresh_all 每次操作都会全量调用各分区刷新，
# 签名没变的分区直接跳过重建。签名必须覆盖该分区渲染的全部数据，漏字段 = UI 不刷新。
var _left_panel_signature := "unset"
var _owned_logos_signature := "unset"
var _shop_cards_signature := "unset"
var _merc_overlay_signature := "unset"

func _cached_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var cached: Texture2D = _texture_cache.get(path)
	if cached != null:
		return cached
	var tex := load(path) as Texture2D
	if tex != null:
		_texture_cache[path] = tex
	return tex

func _ui_unit_name(d: Dictionary) -> String:
	if LocaleManager.get_locale() == "en":
		var en := str(d.get("name_en", ""))
		if not en.is_empty():
			return en
	return str(d.get("name", str(d.get("id", "?"))))

# 棋盘 caption 位置（待命的不受影响）：
# DROP=相对格子底往下的【比例】（用格子高度比例、不是固定像素，才能补透视——不同排格子大小不同，
#   固定像素会"越往上越偏"）。负=往上、正=往下；太高调大、太低调小。
# DX =左右【像素】偏移：正=右移、负=左移。
const BOARD_CAPTION_DROP := 0.5
const BOARD_CAPTION_DX := 0

func _make_cell_caption() -> Label:
	# 格子正下方的一行「名字 ★星级」标签（棋盘 / 待命共用）。默认隐藏，有棋子时才显示。
	# 竖直方向文字居中于框、框中心固定（改字号不会让位置跑）；位置微调改 offset。
	var cap := Label.new()
	cap.name = "CellCaption"
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.anchor_left = 0.5
	cap.anchor_right = 0.5
	cap.anchor_top = 1.0
	cap.anchor_bottom = 1.0
	cap.offset_left = -78
	cap.offset_right = 78
	cap.offset_top = -14      # 框中心 = 格子底 + 4.5（改字号不影响这个中心）
	cap.offset_bottom = 23
	cap.add_theme_font_size_override("font_size", 18)   # 字号（放大到接近模型上的）；两处共用
	cap.add_theme_color_override("font_color", Color.WHITE)
	cap.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	cap.add_theme_constant_override("outline_size", 3)
	cap.z_index = 10
	cap.visible = false
	cap.set_meta("caption_w", 156.0)   # 框宽/高：棋盘按圆心质心定位时用（_fit_cell_to_screen_polygon）
	cap.set_meta("caption_h", 37.0)
	return cap

func _cell_caption_text(cell: Dictionary) -> String:
	# 一行：名字 + ★（星数）
	var d := _prep_display_unit_def(cell)
	var star := clampi(int(cell.get("star", 1)), 1, GameState.MAX_UNIT_STAR)
	return "%s %s" % [_ui_unit_name(d), "★".repeat(star)]

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.38, 0.70, 0.88)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	bg.z_index = -21

	# 满屏 2D 背景垫底：用同一张棋盘 base 图，KEEP_ASPECT_COVERED 铺满任何屏幕；
	# 3D 视口已设透明，棋盘没盖到的角落就露出这张图的草地，不再有黑角。
	var sky_background := TextureRect.new()
	sky_background.name = "PrepFullscreenBackground"
	sky_background.texture = _cached_texture(PREP_BOARD_BASE_PATH)
	sky_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky_background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	sky_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sky_background.z_index = -20
	add_child(sky_background)
	_setup_prep_river_background()

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12
	root.offset_top = 10
	root.offset_right = -12
	root.offset_bottom = -10
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	_build_top_bar(root)
	_build_rest(root)

	# 调试空间框：满屏覆盖层，扫描整棵界面树，把每个可见控件的矩形用黑边画出来。
	if SHOW_SPACE_FRAMES:
		var space_overlay := SpaceFrameDebugOverlay.new()
		space_overlay.name = "SpaceFrameDebugOverlay"
		space_overlay.scan_root = self
		add_child(space_overlay)

	# 调试判定线条：满屏覆盖层，扫描整棵界面树，画出每个按钮的点击判定区域。
	if SHOW_HIT_AREAS:
		var hit_overlay := HitAreaDebugOverlay.new()
		hit_overlay.name = "HitAreaDebugOverlay"
		hit_overlay.scan_root = self
		add_child(hit_overlay)

func _build_top_bar(root: VBoxContainer) -> void:
	var top := SellDropPanel.new()
	top.screen = self
	top.custom_minimum_size = Vector2(0, 68)
	_apply_prep_transparent_panel_style(top)
	root.add_child(top)
	var top_content := Control.new()
	top_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	top.add_child(top_content)

	var formation_row := HBoxContainer.new()
	formation_row.anchor_left = 0.5
	formation_row.anchor_top = 0.5
	formation_row.anchor_right = 0.5
	formation_row.anchor_bottom = 0.5
	formation_row.offset_left = -470
	formation_row.offset_top = -46
	formation_row.offset_right = 470
	formation_row.offset_bottom = 46
	formation_row.alignment = BoxContainer.ALIGNMENT_CENTER
	formation_row.add_theme_constant_override("separation", 8)
	top_content.add_child(formation_row)

	var player_bar_stack := _create_formation_health_bar(false)
	formation_row.add_child(player_bar_stack)
	_player_formation_bar = null   # 血条红条已删，只留数字
	_player_formation_hp_label = player_bar_stack.get_child(0) as Label

	_player_formation_art = _create_formation_crystal(false)
	formation_row.add_child(_player_formation_art)

	var battle := Button.new()
	_start_battle_button = battle
	battle.custom_minimum_size = START_BTN_SIZE
	battle.focus_mode = Control.FOCUS_NONE
	battle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var battle_style := _menu_button_style()          # 统一「离线自测」样式
	battle.add_theme_stylebox_override("normal", battle_style)
	battle.add_theme_stylebox_override("hover", battle_style)
	battle.add_theme_stylebox_override("pressed", battle_style)
	battle.pressed.connect(_on_start_battle)
	var battle_label := Label.new()          # 单独 Label：_refresh_start_button_label 会改它的文字
	battle_label.text = tr("ui_start_battle_btn")
	battle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	battle_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	battle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	battle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	battle_label.add_theme_font_size_override("font_size", 20)
	battle_label.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	battle.add_child(battle_label)
	_start_battle_label = battle_label
	# (3) Round number + next battle type (PVE / PVP / BOSS), stacked under the button.
	var battle_col := VBoxContainer.new()
	battle_col.alignment = BoxContainer.ALIGNMENT_CENTER
	battle_col.add_theme_constant_override("separation", 1)
	battle_col.add_child(battle)
	var round_lbl := Label.new()
	round_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	round_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	round_lbl.add_theme_font_size_override("font_size", 14)
	round_lbl.add_theme_color_override("font_color", Color(0.98, 0.92, 0.74))
	round_lbl.add_theme_color_override("font_outline_color", Color(0.10, 0.05, 0.0, 0.95))
	round_lbl.add_theme_constant_override("outline_size", 3)
	_round_info_label = round_lbl
	battle_col.add_child(round_lbl)
	formation_row.add_child(battle_col)

	# Top-right: per-player ready indicator (6 colored dots, ✓ when ready).
	_build_ready_indicator()

	_enemy_formation_art = _create_formation_crystal(true)
	formation_row.add_child(_enemy_formation_art)

	var enemy_bar_stack := _create_formation_health_bar(true)
	formation_row.add_child(enemy_bar_stack)
	_enemy_formation_bar = null   # 血条红条已删，只留数字
	_enemy_formation_hp_label = enemy_bar_stack.get_child(0) as Label

func _build_rest(root: VBoxContainer) -> void:
	_build_top_actions()

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	root.add_child(body)

	var left_drop := SellDropPanel.new()
	left_drop.screen = self
	left_drop.custom_minimum_size = Vector2(260, 0)
	_apply_prep_transparent_panel_style(left_drop)
	body.add_child(left_drop)
	# 种族羁绊面板：不滚动，直接把 VBox 放进面板（内容确定放得下）。
	_left_panel = VBoxContainer.new()
	_left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_panel.add_theme_constant_override("separation", 8)
	left_drop.add_child(_left_panel)

	var center_host := Control.new()
	center_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(center_host)

	# 待命区背景已改为 3D 地面 quad（见 PrepBoardModels._add_prep_standby_bg_plane），不再用 2D 贴图。

	var center := VBoxContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_theme_constant_override("separation", 6)
	center_host.add_child(center)

	_build_treasure_overlay()

	_build_treasure_logos_panel()

	var board_and_bench := HBoxContainer.new()
	board_and_bench.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_and_bench.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_and_bench.alignment = BoxContainer.ALIGNMENT_BEGIN
	board_and_bench.add_theme_constant_override("separation", 8)
	center.add_child(board_and_bench)

	# 待命区容器：只当 8 个待命格子的父节点 + 投影原点用。它的位置在投影里会被减掉，
	# 摆哪都不影响格子出现的位置（格子由 STANDBY_SPOTS 的 3D 投影定位），所以保持最简。
	var left_bench := Control.new()
	left_bench.name = "StandbyFrame"
	_bench_row = left_bench
	_standby_frame = left_bench
	left_bench.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center_host.add_child(left_bench)
	for i in mini(GameState.BENCH_SLOTS, STANDBY_SLOT_COUNT):
		var standby_slot := _create_bench_portrait_card(i)
		# 位置/大小/多边形由 _realign_prep_standby_cells 每帧按 STANDBY_SPOTS 投影设定。
		left_bench.add_child(standby_slot)

	var board_frame := Control.new()
	var board_size := _board_grid_size()
	board_frame.custom_minimum_size = board_size
	board_frame.size = board_size
	board_frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 棋盘框靠左（C 需求）
	board_frame.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	board_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 同上：布局框不吃点击
	board_and_bench.add_child(board_frame)

	_setup_prep_board_model_view(board_frame)

	_board_grid = Control.new()
	_board_grid.custom_minimum_size = board_size
	_board_grid.size = board_size
	_board_grid.position = board_grid_offset
	_board_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 同上：格子自己接输入
	board_frame.add_child(_board_grid)
	for i in GameConstants.CELL_COUNT:
		var cell := BoardCellButton.new()
		cell.board_index = i
		cell.screen = self
		cell.drag_owner = self
		var quad := _board_cell_quad(i, board_size)
		var bounds := Rect2(quad[0], Vector2.ZERO)
		for point in quad:
			bounds = bounds.expand(point)
		var hit_bounds := bounds.grow(18.0)
		cell.position = hit_bounds.position
		cell.size = hit_bounds.size
		cell.custom_minimum_size = hit_bounds.size
		var local_circle := PackedVector2Array()
		var circle_center := bounds.get_center() - hit_bounds.position
		var radius := minf(bounds.size.x, bounds.size.y) * 0.32
		for segment in BOARD_CELL_SEGMENTS:
			var angle := TAU * float(segment) / float(BOARD_CELL_SEGMENTS)
			local_circle.append(circle_center + Vector2(cos(angle), sin(angle)) * radius)
		cell.configure_polygon(local_circle)
		cell.add_theme_font_size_override("font_size", 11)
		cell.add_theme_color_override("font_outline_color", Color(0.01, 0.01, 0.01, 0.96))
		cell.add_theme_constant_override("outline_size", 2)
		cell.add_theme_stylebox_override("normal", _board_empty_style)
		cell.add_theme_stylebox_override("hover", _board_hover_style)
		cell.add_theme_stylebox_override("pressed", _board_hover_style)
		cell.add_theme_stylebox_override("focus", _board_hover_style)
		cell.pressed.connect(_on_board_pressed.bind(i))
		_attach_long_press(cell, func(): _show_board_detail(i))
		_board_grid.add_child(cell)
		_board_buttons.append(cell)
		var relation_overlay := RelationProgressOverlay.new()
		relation_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		relation_overlay.z_index = 8
		cell.add_child(relation_overlay)
		_board_relation_overlays.append(relation_overlay)
		var caption := _make_cell_caption()
		# 棋盘：跟「圆圈真正的中心」定位（在 _fit_cell_to_screen_polygon 里按椭圆质心摆），补透视。
		caption.set_meta("caption_centroid", true)
		caption.set_meta("caption_dx", BOARD_CAPTION_DX)      # 左右像素微调
		caption.set_meta("caption_drop", BOARD_CAPTION_DROP)  # 相对格子高度往下的比例（负=往上，绕圆心）
		cell.add_child(caption)
		_board_cell_captions.append(caption)

	var right_board_spacer := Control.new()
	right_board_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 主犯：手机宽屏(aspect=expand)下棋盘投影右移，右列格子滑进这个占位控件底下，
	# 它默认 STOP 且树顺序在 board_frame 之后（拾取优先），把右列点击全吃了。
	right_board_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board_and_bench.add_child(right_board_spacer)

	var board_bottom_reserve := Control.new()
	board_bottom_reserve.custom_minimum_size = Vector2(0, 248)
	board_bottom_reserve.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(board_bottom_reserve)

	# 底部「商店」按钮：点击打开/关闭商店弹窗（弹窗打开时被弹窗盖住）。保留 shop_closed.png 贴图框、图自带文字。
	var shop_open_btn := _make_framed_text_button("", SHOP_CLOSED_BTN_PATH, SHOP_BTN_SIZE, 18, _toggle_shop_picker)
	_shop_open_button = shop_open_btn
	shop_open_btn.anchor_left = 0.5
	shop_open_btn.anchor_top = 1.0
	shop_open_btn.anchor_right = 0.5
	shop_open_btn.anchor_bottom = 1.0
	shop_open_btn.offset_left = -SHOP_BTN_SIZE.x * 0.5
	shop_open_btn.offset_right = SHOP_BTN_SIZE.x * 0.5
	shop_open_btn.offset_top = -SHOP_BTN_SIZE.y - 40
	shop_open_btn.offset_bottom = -40
	shop_open_btn.z_index = 6
	center_host.add_child(shop_open_btn)

	# 钱袋 B（商店关闭时显示）：放在「商店」按钮左边，显示金币，长按看利息。商店打开时隐藏（那时看钱袋 A）。
	var closed_money_btn := Button.new()
	_closed_money_bag = closed_money_btn
	closed_money_btn.flat = true
	closed_money_btn.focus_mode = Control.FOCUS_NONE
	closed_money_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	closed_money_btn.anchor_left = 0.5
	closed_money_btn.anchor_top = 1.0
	closed_money_btn.anchor_right = 0.5
	closed_money_btn.anchor_bottom = 1.0
	closed_money_btn.offset_left = -SHOP_BTN_SIZE.x * 0.5 - 8 - 60   # 商店按钮左边 8px 间隙，宽 60
	closed_money_btn.offset_right = -SHOP_BTN_SIZE.x * 0.5 - 8
	closed_money_btn.offset_top = -SHOP_BTN_SIZE.y - 40
	closed_money_btn.offset_bottom = -40
	closed_money_btn.z_index = 6
	center_host.add_child(closed_money_btn)
	var closed_bag_icon: Control = PrepMoneyBagIcon.new()
	closed_bag_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	closed_bag_icon.anchor_left = 0.5
	closed_bag_icon.anchor_top = 0.5
	closed_bag_icon.anchor_right = 0.5
	closed_bag_icon.anchor_bottom = 0.5
	closed_bag_icon.offset_left = -22
	closed_bag_icon.offset_top = -34
	closed_bag_icon.offset_right = 22
	closed_bag_icon.offset_bottom = 10
	closed_money_btn.add_child(closed_bag_icon)
	_closed_gold_label = Label.new()
	_closed_gold_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_closed_gold_label.anchor_left = 0.5
	_closed_gold_label.anchor_top = 0.5
	_closed_gold_label.anchor_right = 0.5
	_closed_gold_label.anchor_bottom = 0.5
	_closed_gold_label.offset_left = -30
	_closed_gold_label.offset_right = 30
	_closed_gold_label.offset_top = 12
	_closed_gold_label.offset_bottom = 40
	_closed_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_closed_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_closed_gold_label.add_theme_font_size_override("font_size", 15)
	_closed_gold_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.34))
	_closed_gold_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_closed_gold_label.add_theme_constant_override("outline_size", 3)
	closed_money_btn.add_child(_closed_gold_label)
	# 长按看利息（短按不做事，纯金币显示）
	_attach_long_press(closed_money_btn, func() -> void: _show_gold_interest_detail())

	# 商店「外挂控件层」：钱袋A（购买键）和刷新按钮挂这里，不再是商店面板的子节点。
	# 满屏 + IGNORE（空白处不吃点击），z=41 盖过宝藏(z-5)和商店面板(z40)；只在商店开时显示；
	# 点它里面的控件不会被判成"点商店外面"而误关店（PrepScreen._input 里有白名单）。
	_shop_side_controls = Control.new()
	_shop_side_controls.name = "ShopSideControls"
	_shop_side_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shop_side_controls.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shop_side_controls.z_index = 41
	_shop_side_controls.visible = false
	add_child(_shop_side_controls)

	# 商店弹窗：卷轴背景，底部中央 896x288（SHOP_POPUP_SIZE），默认隐藏，点「商店」按钮打开
	var shop_panel := SellDropPanel.new()
	_shop_panel = shop_panel
	shop_panel.screen = self
	shop_panel.visible = false
	shop_panel.z_index = 40
	shop_panel.anchor_left = 0.5
	shop_panel.anchor_top = 1.0
	shop_panel.anchor_right = 0.5
	shop_panel.anchor_bottom = 1.0
	shop_panel.offset_left = -SHOP_POPUP_SIZE.x * 0.5
	shop_panel.offset_right = SHOP_POPUP_SIZE.x * 0.5
	shop_panel.offset_top = -SHOP_POPUP_SIZE.y - 8
	shop_panel.offset_bottom = -8
	shop_panel.custom_minimum_size = SHOP_POPUP_SIZE
	_apply_prep_transparent_panel_style(shop_panel)
	shop_panel.clip_contents = false
	center_host.add_child(shop_panel)
	var shop_background_host := Control.new()
	shop_background_host.name = "ShopBackgroundHost"
	shop_background_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shop_background_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shop_panel.add_child(shop_background_host)
	var shop_background := TextureRect.new()
	shop_background.name = "ShopPanelBackground"
	shop_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shop_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shop_background.stretch_mode = TextureRect.STRETCH_SCALE   # 卷轴图(1672x941)拉伸到 SHOP_BG_SIZE，接受轻微变形
	# 居中于弹窗、独立尺寸：只由 SHOP_BG_SIZE / SHOP_BG_OFFSET 决定显示大小和位置，
	# 与弹窗判定框(SHOP_POPUP_SIZE)解耦；背景层 IGNORE 输入，改大改小都不影响判定。
	shop_background.anchor_left = 0.5
	shop_background.anchor_top = 0.5
	shop_background.anchor_right = 0.5
	shop_background.anchor_bottom = 0.5
	shop_background.offset_left = -SHOP_BG_SIZE.x * 0.5 + SHOP_BG_OFFSET.x
	shop_background.offset_right = SHOP_BG_SIZE.x * 0.5 + SHOP_BG_OFFSET.x
	shop_background.offset_top = -SHOP_BG_SIZE.y * 0.5 + SHOP_BG_OFFSET.y
	shop_background.offset_bottom = SHOP_BG_SIZE.y * 0.5 + SHOP_BG_OFFSET.y
	var shop_background_source := _cached_texture(SHOP_PANEL_BACKGROUND_PATH)
	shop_background.texture = shop_background_source
	shop_background_host.add_child(shop_background)
	var shop_layout := Control.new()
	shop_layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shop_panel.add_child(shop_layout)
	# 钱袋A（购买键）：挂在外挂层 = 【屏幕坐标】，锚左下角。改这 4 个 offset 就能自由摆，
	# 不受商店面板范围限制，也不会被宝藏抢走点击（外挂层 z=41 在宝藏之上）。
	var gold_area := Control.new()
	gold_area.anchor_left = 0.0
	gold_area.anchor_top = 1.0
	gold_area.anchor_right = 0.0
	gold_area.anchor_bottom = 1.0
	gold_area.offset_left = 117
	gold_area.offset_right = 255
	gold_area.offset_top = -201
	gold_area.offset_bottom = -60
	_shop_side_controls.add_child(gold_area)
	var money_bag: Control = PrepMoneyBagIcon.new()
	money_bag.anchor_left = 0.5
	money_bag.anchor_top = 0.5
	money_bag.anchor_right = 0.5
	money_bag.anchor_bottom = 0.5
	money_bag.offset_left = -22
	money_bag.offset_top = -31
	money_bag.offset_right = 22
	money_bag.offset_bottom = 13
	gold_area.add_child(money_bag)
	_gold_amount_label = Label.new()
	_gold_amount_label.anchor_left = 0.5
	_gold_amount_label.anchor_top = 0.5
	_gold_amount_label.anchor_right = 0.5
	_gold_amount_label.anchor_bottom = 0.5
	_gold_amount_label.offset_left = -26
	_gold_amount_label.offset_right = 26
	_gold_amount_label.offset_top = 18
	_gold_amount_label.offset_bottom = 46
	_gold_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_amount_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_gold_amount_label.add_theme_font_size_override("font_size", 15)
	_gold_amount_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.34))
	gold_area.add_child(_gold_amount_label)
	var gold_info_btn := Button.new()
	gold_info_btn.flat = true
	gold_info_btn.focus_mode = Control.FOCUS_NONE
	gold_info_btn.modulate = Color(1, 1, 1, 0)
	gold_info_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gold_info_btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gold_area.add_child(gold_info_btn)
	# 钱袋 A（商店内）：短按=购买选中的卡（没选卡时 _on_buy_selected_shop 直接返回）；长按=看利息
	gold_info_btn.pressed.connect(func() -> void:
		if bool(gold_info_btn.get_meta("long_press_triggered", false)):
			return
		_on_buy_selected_shop())
	_attach_long_press(gold_info_btn, func() -> void: _show_gold_interest_detail())
	# 手牌区：4 张随机棋子卡，横排居中在卷轴空白区。
	# 卡片层级（从底到顶）：头像 → 稀有度框（tier 换图） → 左上种族 logo → 右上价格（框自带金币） → 底部铭牌名字 → 灰色不可买覆盖层
	var shop_card_area := Control.new()
	shop_card_area.anchor_left = 0.0
	shop_card_area.anchor_top = 0.10
	shop_card_area.anchor_right = 1.0
	shop_card_area.anchor_bottom = 0.92
	shop_layout.add_child(shop_card_area)
	_shop_row = HBoxContainer.new()
	_shop_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_shop_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_shop_row.add_theme_constant_override("separation", SHOP_CARD_SEPARATION)
	shop_card_area.add_child(_shop_row)
	for i in GameState.SHOP_UNIT_SLOTS:
		var slot := DragButton.new()
		slot.drag_owner = self
		slot.custom_minimum_size = SHOP_CARD_SIZE
		slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slot.clip_contents = false
		slot.pressed.connect(_on_shop_card_pressed.bind(slot, i))
		_attach_long_press(slot, func(): _show_shop_detail(i))
		_configure_unframed_portrait_card(slot)
		_shop_row.add_child(slot)
		_shop_buttons.append(slot)

		# 头像：先加（画在框下面），稍微伸进框梁内侧，由框盖住毛边
		var portrait := TextureRect.new()
		portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		portrait.anchor_left = 0.09
		portrait.anchor_top = 0.07
		portrait.anchor_right = 0.91
		portrait.anchor_bottom = 0.80
		slot.add_child(portrait)
		_shop_portraits.append(portrait)

		# 稀有度框：刷新时按棋子 tier 换普通/稀有/史诗贴图
		var card_frame := TextureRect.new()
		card_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		card_frame.stretch_mode = TextureRect.STRETCH_SCALE
		card_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(card_frame)
		_shop_card_frames.append(card_frame)

		# 左上角种族 logo（复用详情弹窗的静态 logo 控件）
		var race_icon: Control = PrepShopRaceIcon.new()
		race_icon.anchor_left = 0.02
		race_icon.anchor_top = 0.02
		race_icon.anchor_right = 0.26
		race_icon.anchor_bottom = 0.26
		race_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(race_icon)
		_shop_race_icons.append(race_icon)

		# 右上角价格：写在框自带的金币圆牌上（金币是亮金色，用深棕字不加描边）
		var price_label := Label.new()
		price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		price_label.anchor_left = 0.75
		price_label.anchor_top = 0.02
		price_label.anchor_right = 0.98
		price_label.anchor_bottom = 0.23
		price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		price_label.add_theme_font_size_override("font_size", 16)
		price_label.add_theme_color_override("font_color", Color(0.28, 0.16, 0.02))
		slot.add_child(price_label)
		_shop_price_labels.append(price_label)

		# 底部铭牌：棋子名字（切英文时自动显示英文名）
		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.anchor_left = 0.14
		name_label.anchor_top = 0.76
		name_label.anchor_right = 0.86
		name_label.anchor_bottom = 0.95
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.add_theme_font_size_override("font_size", 16)
		name_label.add_theme_color_override("font_color", Color(0.94, 0.90, 0.80))
		name_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
		name_label.add_theme_constant_override("outline_size", 3)
		slot.add_child(name_label)
		_shop_card_labels.append(name_label)

		var reason_label := _create_purchase_reason_overlay(slot)
		_shop_reason_labels.append(reason_label)

	# 出售区域覆盖层本身做成 SellDropPanel：放下去直接卖，不靠穿透传递
	var sell_overlay := SellDropPanel.new()
	sell_overlay.screen = self
	sell_overlay.is_sell_zone = true  # 唯一的有效出售区：拖动棋盘/待命单位时点亮的红色区域
	_shop_sell_overlay = sell_overlay
	_shop_sell_overlay.visible = false
	_shop_sell_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	# 常驻底部中央（与商店弹窗同一位置），独立于商店弹窗：仅拖拽 board/bench 单位时显示。
	# z_index 高于弹窗(40)：弹窗开着时红区盖在弹窗上，丢上来直接卖，不会误触购买。
	_shop_sell_overlay.z_index = 50
	_shop_sell_overlay.anchor_left = 0.5
	_shop_sell_overlay.anchor_right = 0.5
	_shop_sell_overlay.anchor_top = 1.025
	_shop_sell_overlay.anchor_bottom = 1.025
	_shop_sell_overlay.offset_left = -SHOP_POPUP_SIZE.x * 0.5
	_shop_sell_overlay.offset_right = SHOP_POPUP_SIZE.x * 0.5
	_shop_sell_overlay.offset_top = -SHOP_POPUP_SIZE.y + 80
	_shop_sell_overlay.offset_bottom = 0
	var sell_style := StyleBoxFlat.new()
	sell_style.bg_color = Color(0.34, 0.07, 0.07, 0.94)
	sell_style.border_color = Color(0.94, 0.35, 0.25, 0.92)
	sell_style.set_border_width_all(2)
	sell_style.set_corner_radius_all(4)
	_shop_sell_overlay.add_theme_stylebox_override("panel", sell_style)
	center_host.add_child(_shop_sell_overlay)
	var sell_label := Label.new()
	sell_label.text = tr("ui_sell_zone")
	sell_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sell_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sell_label.add_theme_font_size_override("font_size", 24)
	sell_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.72))
	_shop_sell_overlay.add_child(sell_label)

	# 只包住刷新按钮的小框（132×132）。锚在面板右侧中间，别再撑成巨框吃卡片点击。
	# 要移动刷新：改下面 4 个 offset（框小才不会误吃点击）；锚点保持 left≤right、都在 0~1。
	var refresh_shop := Button.new()
	_refresh_shop_button = refresh_shop
	refresh_shop.text = ""
	refresh_shop.tooltip_text = tr("ui_refresh_shop_tooltip")
	refresh_shop.flat = true                  # 去默认样式，只显示循环箭头框
	# 直接挂外挂层 =【屏幕坐标】，锚右下角。只剩这一套 offset，改它就能挪按钮。
	refresh_shop.anchor_left = 1.0           
	refresh_shop.anchor_top = 1.0
	refresh_shop.anchor_right = 1.0
	refresh_shop.anchor_bottom = 1.0
	refresh_shop.offset_left = -105
	refresh_shop.offset_top = -200
	refresh_shop.offset_right = 25
	refresh_shop.offset_bottom = -70
	refresh_shop.focus_mode = Control.FOCUS_NONE
	var refresh_frame := TextureRect.new()    # 循环箭头图标框（箭头已画死）
	refresh_frame.texture = _cached_texture(REFRESH_BTN_PATH)
	refresh_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	refresh_frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	refresh_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	refresh_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_shop.add_child(refresh_frame)
	refresh_shop.pressed.connect(_on_refresh_shop_control_pressed)
	_shop_side_controls.add_child(refresh_shop)

	var refresh_icon := Label.new()
	_refresh_shop_icon = refresh_icon
	refresh_icon.text = "↻"
	refresh_icon.visible = false              # 框已自带循环箭头，隐藏文字图标（旋转动画无害）
	refresh_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_icon.anchor_left = 0.5
	refresh_icon.anchor_top = 0.5
	refresh_icon.anchor_right = 0.5
	refresh_icon.anchor_bottom = 0.5
	refresh_icon.offset_left = -14
	refresh_icon.offset_top = -22
	refresh_icon.offset_right = 14
	refresh_icon.offset_bottom = 2
	refresh_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refresh_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	refresh_icon.add_theme_font_size_override("font_size", 19)
	refresh_icon.pivot_offset = Vector2(14, 12)
	refresh_shop.add_child(refresh_icon)

	var refresh_cost_label := Label.new()
	_refresh_shop_cost_label = refresh_cost_label
	refresh_cost_label.text = tr("ui_free")
	refresh_cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refresh_cost_label.anchor_left = 0.5
	refresh_cost_label.anchor_top = 0.5
	refresh_cost_label.anchor_right = 0.5
	refresh_cost_label.anchor_bottom = 0.5
	refresh_cost_label.offset_left = -28
	refresh_cost_label.offset_top = 18
	refresh_cost_label.offset_right = 28
	refresh_cost_label.offset_bottom = 40
	refresh_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	refresh_cost_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	refresh_cost_label.add_theme_font_size_override("font_size", 12)
	refresh_shop.add_child(refresh_cost_label)

	var right_drop := PanelContainer.new()
	right_drop.custom_minimum_size = Vector2(110, 0)
	right_drop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_prep_transparent_panel_style(right_drop)
	body.add_child(right_drop)
	_merc_scroll = ScrollContainer.new()
	_merc_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_merc_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_merc_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_merc_scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	right_drop.add_child(_merc_scroll)
	_merc_panel = VBoxContainer.new()
	_merc_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merc_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_merc_panel.add_theme_constant_override("separation", 8)
	_merc_scroll.add_child(_merc_panel)

	_merc_overlay = PanelContainer.new()
	_merc_overlay.visible = false
	_merc_overlay.z_index = 40
	_merc_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_merc_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var overlay_style := StyleBoxFlat.new()
	overlay_style.bg_color = Color(0.055, 0.065, 0.075, 0.98)
	overlay_style.border_color = Color(0.42, 0.50, 0.58, 0.92)
	overlay_style.set_border_width_all(2)
	overlay_style.set_corner_radius_all(4)
	_merc_overlay.add_theme_stylebox_override("panel", overlay_style)
	center_host.add_child(_merc_overlay)
	var overlay_margin := MarginContainer.new()
	overlay_margin.add_theme_constant_override("margin_left", 12)
	overlay_margin.add_theme_constant_override("margin_top", 10)
	overlay_margin.add_theme_constant_override("margin_right", 12)
	overlay_margin.add_theme_constant_override("margin_bottom", 12)
	_merc_overlay.add_child(overlay_margin)
	var overlay_box := VBoxContainer.new()
	overlay_box.add_theme_constant_override("separation", 8)
	overlay_margin.add_child(overlay_box)
	var overlay_header := HBoxContainer.new()
	overlay_box.add_child(overlay_header)
	var overlay_title := Label.new()
	overlay_title.text = tr("ui_choose_mercenary")
	overlay_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overlay_title.add_theme_font_size_override("font_size", 18)
	overlay_header.add_child(overlay_title)
	# 右上角「已雇 N/8」：备战界面没有其它已购佣兵的提示，这里是唯一的计数反馈。
	_merc_count_label = Label.new()
	_merc_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_merc_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_merc_count_label.add_theme_font_size_override("font_size", 18)
	_merc_count_label.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	_merc_count_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	_merc_count_label.add_theme_constant_override("outline_size", 3)
	overlay_header.add_child(_merc_count_label)
	_merc_overlay_grid = GridContainer.new()
	_merc_overlay_grid.columns = 4
	_merc_overlay_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merc_overlay_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_merc_overlay_grid.add_theme_constant_override("h_separation", 8)
	_merc_overlay_grid.add_theme_constant_override("v_separation", 8)
	overlay_box.add_child(_merc_overlay_grid)

	_build_team_mercs_overlay(center_host)

	_build_detail_popups()

func _build_top_actions() -> void:
	# 右上角横排：战力推荐 | 统计 | 静音（缩小，A 需求）。加到 self 顶层（z 高，不被 body 拦点击）。
	var top_row := HBoxContainer.new()
	top_row.anchor_left = 1.0
	top_row.anchor_right = 1.0
	top_row.anchor_top = 0.0
	top_row.anchor_bottom = 0.0
	var row_w := TOP_ROW_BTN_SIZE.x * 3.0 + 6.0 * 2.0
	top_row.offset_left = -row_w - 8
	top_row.offset_right = -8
	top_row.offset_top = 2
	top_row.offset_bottom = 2 + TOP_ROW_BTN_SIZE.y
	top_row.alignment = BoxContainer.ALIGNMENT_END
	top_row.add_theme_constant_override("separation", 6)
	top_row.z_index = 20
	add_child(top_row)
	top_row.add_child(_make_menu_button(tr("ui_power"), TOP_ROW_BTN_SIZE, 13, _show_power_recommendation))
	top_row.add_child(_make_menu_button(tr("ui_stats"), TOP_ROW_BTN_SIZE, 13, _show_last_battle_stats))
	# 静音按钮：切换全局 Master 总线静音
	var mute_btn := _make_menu_button(_mute_label_text(), TOP_ROW_BTN_SIZE, 13, _toggle_mute)
	_mute_button = mute_btn
	top_row.add_child(mute_btn)

	# 佣兵盾牌 / 队伍佣兵：不改，仍竖排，挪到横排下面（A1-a）。宽度保持 140，尺寸不变。
	var side_col := VBoxContainer.new()
	side_col.anchor_left = 1.0
	side_col.anchor_right = 1.0
	side_col.anchor_top = 0.0
	side_col.anchor_bottom = 0.0
	side_col.offset_left = -STATS_BTN_SIZE.x - 8
	side_col.offset_right = -8
	side_col.offset_top = 2 + TOP_ROW_BTN_SIZE.y + 6
	side_col.offset_bottom = 2 + TOP_ROW_BTN_SIZE.y + 6 + MERC_BTN_SIZE.y + STATS_BTN_SIZE.y + 6
	side_col.alignment = BoxContainer.ALIGNMENT_BEGIN
	side_col.add_theme_constant_override("separation", 6)
	side_col.z_index = 20
	add_child(side_col)
	# 佣兵按钮：盾牌框 + 下方写「佣兵」（保留原贴图框，不改）
	var merc_btn := _make_framed_text_button("", MERC_BTN_PATH, MERC_BTN_SIZE, 16, _toggle_merc_picker)
	_merc_button = merc_btn
	var merc_lbl := Label.new()
	merc_lbl.text = tr("ui_mercenary")
	merc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	merc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	merc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	merc_lbl.anchor_left = 0.2
	merc_lbl.anchor_right = 0.8
	merc_lbl.anchor_top = 0.72
	merc_lbl.anchor_bottom = 0.93
	merc_lbl.add_theme_font_size_override("font_size", 15)
	merc_lbl.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	merc_lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	merc_lbl.add_theme_constant_override("outline_size", 3)
	merc_btn.add_child(merc_lbl)
	side_col.add_child(merc_btn)
	# 队伍佣兵检阅台：教学模式没有队友，直接藏
	var team_mercs_btn := _make_menu_button(tr("ui_team_mercs"), STATS_BTN_SIZE, 16, _toggle_team_mercs_picker)
	team_mercs_btn.visible = not GameState.tutorial_mode
	side_col.add_child(team_mercs_btn)

func _toggle_mute() -> void:
	# 全局静音开关：静音 Master 总线（BGM + 音效都停），引擎级状态，切场景仍生效
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_mute(master, not AudioServer.is_bus_mute(master))
	if _mute_button != null:
		_mute_button.text = _mute_label_text()

func _mute_label_text() -> String:
	var muted := AudioServer.is_bus_mute(AudioServer.get_bus_index("Master"))
	if LocaleManager.get_locale() == "en":
		return "Muted" if muted else "Mute"
	return "已静音" if muted else "静音"

func _build_treasure_overlay() -> void:
	# Treasure draw: full-screen modal overlay (dim background + 3 big cards,
	# forced pick) centered over the prep screen. z_index keeps it above the board.
	_treasure_overlay = ColorRect.new()
	_treasure_overlay.color = Color(0.0, 0.0, 0.0, 0.66)
	_treasure_overlay.visible = false
	_treasure_overlay.z_index = 60
	_treasure_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_treasure_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Added to the screen root (self) so the dim + cards cover the ENTIRE screen,
	# not just the center column.
	add_child(_treasure_overlay)
	var treasure_box := VBoxContainer.new()
	treasure_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	treasure_box.alignment = BoxContainer.ALIGNMENT_CENTER
	treasure_box.add_theme_constant_override("separation", 16)
	_treasure_overlay.add_child(treasure_box)
	_treasure_timer_lbl = Label.new()
	_treasure_timer_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_treasure_timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_treasure_timer_lbl.add_theme_font_size_override("font_size", 24)
	_treasure_timer_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.66))
	_treasure_timer_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_treasure_timer_lbl.add_theme_constant_override("outline_size", 3)
	treasure_box.add_child(_treasure_timer_lbl)
	_treasure_choice_row = HBoxContainer.new()
	_treasure_choice_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_treasure_choice_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_treasure_choice_row.add_theme_constant_override("separation", 28)
	treasure_box.add_child(_treasure_choice_row)
	var treasure_refresh_holder := HBoxContainer.new()
	treasure_refresh_holder.alignment = BoxContainer.ALIGNMENT_CENTER
	treasure_refresh_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	treasure_box.add_child(treasure_refresh_holder)
	_treasure_refresh_btn = Button.new()
	_treasure_refresh_btn.custom_minimum_size = Vector2(220, 46)
	_treasure_refresh_btn.focus_mode = Control.FOCUS_NONE
	_apply_refresh_button_styles(_treasure_refresh_btn)
	_treasure_refresh_btn.pressed.connect(_refresh_treasure_candidates)
	treasure_refresh_holder.add_child(_treasure_refresh_btn)

func _build_treasure_logos_panel() -> void:
	# Active treasure/linkage logos, pinned to the bottom-left corner of the screen.
	# Grows up-right so it can hold 8-9 icons (owned treasures + active linkages).
	# 宝藏 logo：只保留图标，不再加左下灰色底框。
	var tp_w := 303.0
	var tp_h := 161.0
	var treasure_panel := Control.new()
	treasure_panel.name = "TreasurePanel"
	treasure_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	treasure_panel.anchor_left = 0.0
	treasure_panel.anchor_top = 1.0
	treasure_panel.anchor_right = 0.0
	treasure_panel.anchor_bottom = 1.0
	treasure_panel.offset_left = 6
	treasure_panel.offset_right = 6 + tp_w
	treasure_panel.offset_top = -10 - tp_h
	treasure_panel.offset_bottom = -10
	treasure_panel.z_index = -5            # 河流(z-19)之上、石框(z0)之下：石框画在灰框上面，不被挡
	add_child(treasure_panel)
	# 宝藏 grid 左对齐（4 列 × 2 行横排，66px）。
	_owned_treasure_box = GridContainer.new()
	_owned_treasure_box.columns = 4
	_owned_treasure_box.anchor_left = 0.0
	_owned_treasure_box.anchor_top = 0.0
	_owned_treasure_box.anchor_right = 0.0
	_owned_treasure_box.anchor_bottom = 0.0
	_owned_treasure_box.offset_left = 0
	_owned_treasure_box.offset_top = 0
	_owned_treasure_box.grow_horizontal = Control.GROW_DIRECTION_END
	_owned_treasure_box.grow_vertical = Control.GROW_DIRECTION_END
	_owned_treasure_box.add_theme_constant_override("h_separation", 5)
	_owned_treasure_box.add_theme_constant_override("v_separation", 5)
	treasure_panel.add_child(_owned_treasure_box)

func _build_detail_popups() -> void:
	_detail = PopupPanel.new()
	add_child(_detail)
	var detail_margin := MarginContainer.new()
	detail_margin.add_theme_constant_override("margin_left", 12)
	detail_margin.add_theme_constant_override("margin_top", 12)
	detail_margin.add_theme_constant_override("margin_right", 12)
	detail_margin.add_theme_constant_override("margin_bottom", 12)
	_detail.add_child(detail_margin)
	_detail_text = RichTextLabel.new()
	_detail_text.bbcode_enabled = true
	_detail_text.fit_content = true
	_detail_text.custom_minimum_size = Vector2(500, 360)
	detail_margin.add_child(_detail_text)

	_stats_popup = PopupPanel.new()
	add_child(_stats_popup)
	var stats_margin := MarginContainer.new()
	stats_margin.add_theme_constant_override("margin_left", 12)
	stats_margin.add_theme_constant_override("margin_top", 12)
	stats_margin.add_theme_constant_override("margin_right", 12)
	stats_margin.add_theme_constant_override("margin_bottom", 12)
	_stats_popup.add_child(stats_margin)
	var stats_box := VBoxContainer.new()
	stats_box.add_theme_constant_override("separation", 8)
	stats_margin.add_child(stats_box)
	var stats_tabs := HBoxContainer.new()
	stats_tabs.add_theme_constant_override("separation", 8)
	stats_box.add_child(stats_tabs)
	for item in [["player", tr("ui_stats_player")], ["boss", "Boss"]]:
		var tab := Button.new()
		tab.text = str(item[1])
		tab.custom_minimum_size = Vector2(96, 34)
		tab.pressed.connect(_set_stats_group.bind(str(item[0])))
		stats_tabs.add_child(tab)
	_stats_text = RichTextLabel.new()
	_stats_text.bbcode_enabled = true
	_stats_text.scroll_active = true
	_stats_text.custom_minimum_size = Vector2(920, 420)
	stats_box.add_child(_stats_text)

func _create_formation_crystal(_is_enemy: bool) -> FormationCrystal:
	# 图片式水晶：贴图（火队红/水队蓝，按血量段）在 _refresh_formation_status 里按队伍指定。
	var crystal := FormationCrystal.new()
	crystal.custom_minimum_size = Vector2(56, 56)
	return crystal

func _crystal_textures_for_element(is_fire: bool) -> Array:
	# 火队 → 红水晶 5 段图；水队 → 蓝水晶 5 段图。缓存复用，顺序 0-10..40-50。
	var paths: Array = CRYSTAL_FIRE_PATHS if is_fire else CRYSTAL_WATER_PATHS
	var texs: Array = []
	for p in paths:
		texs.append(_cached_texture(str(p)))
	return texs

func _create_formation_health_bar(_mirrored: bool) -> Control:
	# 需求 #1：去掉石框和红条，只留血量数字（50/50）。唯一子节点就是数字 Label（get_child(0)）。
	var stack := Control.new()
	stack.custom_minimum_size = Vector2(96, 56)
	stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stack.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var hp_label := Label.new()
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_label.add_theme_font_size_override("font_size", 22)
	hp_label.add_theme_color_override("font_color", Color.WHITE)
	hp_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.96))
	hp_label.add_theme_constant_override("outline_size", 3)
	stack.add_child(hp_label)
	return stack

func _menu_button_style() -> StyleBoxFlat:
	# 仿主界面「离线自测」按钮：深棕底 + 古铜边框 + 大圆角。所有备战按钮统一用它。
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.11, 0.075, 0.035, 0.95)
	s.border_color = Color(0.78, 0.56, 0.24)
	s.set_border_width_all(2)
	s.set_corner_radius_all(16)
	return s

func _make_menu_button(label_text: String, size: Vector2, font_size: int, on_press: Callable) -> Button:
	# 仿主界面「离线自测」样式按钮（深棕底 + 古铜圆角边框 + 浅金字）。战力/统计/静音/队伍佣兵用它。
	var btn := Button.new()
	btn.text = label_text
	btn.custom_minimum_size = size
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.clip_text = true
	var style := _menu_button_style()
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("hover", style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.add_theme_color_override("font_color", Color(1.0, 0.90, 0.60))
	btn.add_theme_font_size_override("font_size", font_size)
	if on_press.is_valid():
		btn.pressed.connect(on_press)
	return btn

func _make_framed_text_button(label_text: String, frame_path: String, size: Vector2, font_size: int, on_press: Callable) -> Button:
	# 「带贴图框文字按钮」：高清框背景 + 居中文字。商店/佣兵仍用它（保留原贴图框）。
	var btn := Button.new()
	btn.flat = true
	btn.custom_minimum_size = size
	if on_press.is_valid():
		btn.pressed.connect(on_press)
	var frame := TextureRect.new()
	frame.texture = _cached_texture(frame_path)
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(frame)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.anchor_left = 0.14
	lbl.anchor_right = 0.86
	lbl.anchor_top = 0.30
	lbl.anchor_bottom = 0.66
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	lbl.add_theme_constant_override("outline_size", 3)
	btn.add_child(lbl)
	return btn

func _refresh_formation_status() -> void:
	# (1) 3v3 uses the shared team HP, not the 1v1 formation HP fields.
	var player_hp: int
	var enemy_hp: int
	if GameState.team_mode:
		player_hp = clampi(GameState.team_hp, 0, GameState.START_FORMATION_HP)
		enemy_hp = clampi(GameState.enemy_team_hp, 0, GameState.START_FORMATION_HP)
	else:
		player_hp = clampi(GameState.player_formation_hp, 0, GameState.START_FORMATION_HP)
		enemy_hp = clampi(GameState.enemy_formation_hp, 0, GameState.START_FORMATION_HP)
	if _player_formation_bar != null:
		_player_formation_bar.value = player_hp
	if _enemy_formation_bar != null:
		_enemy_formation_bar.value = enemy_hp
	if _player_formation_hp_label != null:
		_player_formation_hp_label.text = "%d/%d" % [player_hp, GameState.START_FORMATION_HP]
	if _enemy_formation_hp_label != null:
		_enemy_formation_hp_label.text = "%d/%d" % [enemy_hp, GameState.START_FORMATION_HP]
	var max_hp := maxi(1, GameState.START_FORMATION_HP)
	# 队伍元素：组队时本人 slot<3=火队(红)、slot>=3=水队(蓝)，敌方取反；非组队默认本方火/敌方水。
	var local_fire := true
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		local_fire = NetworkService.team_local_slot < 3
	if _player_formation_art != null:
		_player_formation_art.set_bracket_textures(_crystal_textures_for_element(local_fire))
		_player_formation_art.set_hp_ratio(float(player_hp) / float(max_hp))
	if _enemy_formation_art != null:
		_enemy_formation_art.set_bracket_textures(_crystal_textures_for_element(not local_fire))
		_enemy_formation_art.set_hp_ratio(float(enemy_hp) / float(max_hp))
	_refresh_start_button_label()
	_refresh_round_info_label()
	_refresh_ready_indicator()

func _refresh_round_info_label() -> void:
	if _round_info_label == null:
		return
	var kind: String
	if GameState.team_mode:
		kind = RoundService.schedule_kind_for_round(GameState.round_index)
	else:
		# 教学：和 BattleScreen 用同一个来源，标签才不会和实战对不上。
		kind = TutorialMode.battle_kind()
	var type_txt := "Final Round" if kind == "final" else kind.to_upper()
	if LocaleManager.get_locale() == "en":
		_round_info_label.text = "Round %d · %s" % [GameState.round_index, type_txt]
	else:
		_round_info_label.text = "第 %d 回合 · %s" % [GameState.round_index, type_txt]

func _refresh_start_button_label() -> void:
	if _start_battle_label == null:
		return
	if NetworkService.team_active:
		var my := NetworkService.team_local_slot
		var ready := my >= 0 and my < NetworkService.team_ready.size() and bool(NetworkService.team_ready[my])
		_start_battle_label.text = tr("lobby_ready_done") if ready else tr("lobby_ready")
	else:
		_start_battle_label.text = tr("ui_start_battle_btn")

func show_message(text: String) -> void:
	# Transient centered toast that fades out (used for rejected placements, etc.).
	if _toast_label == null:
		_toast_label = Label.new()
		_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_toast_label.anchor_left = 0.0
		_toast_label.anchor_right = 1.0
		_toast_label.anchor_top = 0.34
		_toast_label.anchor_bottom = 0.34
		_toast_label.offset_bottom = 44
		_toast_label.add_theme_font_size_override("font_size", 24)
		_toast_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
		_toast_label.add_theme_color_override("font_outline_color", Color(0.12, 0.02, 0.0, 0.96))
		_toast_label.add_theme_constant_override("outline_size", 5)
		_toast_label.z_index = 60
		add_child(_toast_label)
	_toast_label.text = text
	_toast_label.visible = true
	_toast_label.modulate = Color(1, 1, 1, 1)
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.3)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.6)

func _build_ready_indicator() -> void:
	# 3v3 准备状态：上排=敌队 3 个、下排=自己队 3 个（自己队永远在下，和战斗演示一致）。
	# _ready_dots 按「位置」存：0-2=上排左中右、3-5=下排左中右；刷新时再映射到对应 slot。
	_ready_indicator = VBoxContainer.new()
	# (7) Ready checks live in the empty TOP-LEFT corner, not the right side.
	_ready_indicator.anchor_left = 0.0
	_ready_indicator.anchor_right = 0.0
	_ready_indicator.anchor_top = 0.0
	_ready_indicator.anchor_bottom = 0.0
	_ready_indicator.offset_left = 16
	_ready_indicator.offset_right = 16 + 92
	_ready_indicator.offset_top = 8
	_ready_indicator.offset_bottom = 8 + 56
	_ready_indicator.add_theme_constant_override("separation", 4)
	_ready_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ready_indicator.z_index = 25
	add_child(_ready_indicator)
	_ready_dots = []
	for row in 2:
		var row_box := HBoxContainer.new()
		row_box.alignment = BoxContainer.ALIGNMENT_BEGIN
		row_box.add_theme_constant_override("separation", 4)
		row_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ready_indicator.add_child(row_box)
		for col in 3:
			var dot := Label.new()
			dot.custom_minimum_size = Vector2(24, 24)
			dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			dot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			dot.add_theme_font_size_override("font_size", 20)
			dot.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
			dot.add_theme_constant_override("outline_size", 3)
			dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row_box.add_child(dot)
			_ready_dots.append(dot)
	_refresh_ready_indicator()

func _refresh_ready_indicator() -> void:
	if _ready_indicator == null or _ready_dots.size() < 6:
		return
	_ready_indicator.visible = NetworkService.team_active
	if not NetworkService.team_active:
		return
	var states: Array = NetworkService.team_slot_states
	var ready_arr: Array = NetworkService.team_ready
	# 自己队永远在下排：team_local_slot<3=火队(0,1,2)、≥3=水队(3,4,5)；-1(没入队)默认火队在下。
	var local_fire := NetworkService.team_local_slot < 3
	var own_slots: Array = [0, 1, 2] if local_fire else [3, 4, 5]
	var enemy_slots: Array = [3, 4, 5] if local_fire else [0, 1, 2]
	var pos_to_slot: Array = enemy_slots + own_slots   # 位置 0-2=上排(敌)、3-5=下排(自己)
	for pos in 6:
		var dot: Label = _ready_dots[pos]
		var slot: int = int(pos_to_slot[pos])
		var st := str(states[slot]) if slot < states.size() else "empty"
		if st == "empty":
			dot.text = ""   # 空位保留占位，保持上下 3×3 对齐
			continue
		var col := GameConstants.team_slot_color(slot)
		var is_ready := st == "dummy" or (slot < ready_arr.size() and bool(ready_arr[slot]))
		dot.text = "✓" if is_ready else "○"
		dot.add_theme_color_override("font_color", col if is_ready else Color(col.r, col.g, col.b, 0.5))

func _create_bench_portrait_card(index: int) -> BenchCellButton:
	var card := BenchCellButton.new()
	card.bench_index = index
	card.screen = self
	card.drag_owner = self
	card.custom_minimum_size = Vector2(80, 72)   # 仅投影生效前的占位；真正大小由 _realign_prep_standby_cells 设定
	card.clip_contents = false   # 关裁剪：格子下方的名字/星级标签才不会被裁掉
	card.text = ""
	card.tooltip_text = tr("ui_bench_slot")
	card.pressed.connect(_on_bench_pressed.bind(index))
	_attach_long_press(card, func(): _show_bench_detail(index))
	_configure_unframed_portrait_card(card)
	_bench_buttons.append(card)

	var name_label := _make_cell_caption()   # 待命格子下方的「名字 ★星级」，和棋盘一致
	card.add_child(name_label)
	_bench_card_labels.append(name_label)
	return card

func _apply_prep_transparent_panel_style(panel: PanelContainer) -> void:
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

func _apply_empty_button_styles(button: Button) -> void:
	var empty_style := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		button.add_theme_stylebox_override(state, empty_style)

func _apply_refresh_button_styles(button: Button) -> void:
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0.025, 0.075, 0.055, 0.78)
	normal_style.border_color = Color(0.34, 0.52, 0.24, 0.82)
	normal_style.set_border_width_all(1)
	normal_style.set_corner_radius_all(4)
	var hover_style := normal_style.duplicate() as StyleBoxFlat
	hover_style.bg_color = Color(0.075, 0.19, 0.105, 0.92)
	hover_style.border_color = Color(0.72, 0.84, 0.36, 0.96)
	var pressed_style := hover_style.duplicate() as StyleBoxFlat
	pressed_style.bg_color = Color(0.04, 0.13, 0.075, 0.96)
	button.add_theme_stylebox_override("normal", normal_style)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_stylebox_override("pressed", pressed_style)
	button.add_theme_stylebox_override("focus", hover_style)
	button.add_theme_stylebox_override("disabled", normal_style)

func _apply_empty_bench_slot_styles(button: Button) -> void:
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0.04, 0.09, 0.065, 0.18)
	normal_style.border_color = Color(0.52, 0.68, 0.54, 0.38)
	normal_style.set_border_width_all(1)
	normal_style.set_corner_radius_all(4)
	var hover_style := normal_style.duplicate() as StyleBoxFlat
	hover_style.bg_color = Color(0.10, 0.18, 0.12, 0.36)
	hover_style.border_color = Color(0.72, 0.86, 0.70, 0.72)
	button.add_theme_stylebox_override("normal", normal_style)
	button.add_theme_stylebox_override("hover", hover_style)
	button.add_theme_stylebox_override("pressed", hover_style)
	button.add_theme_stylebox_override("focus", normal_style)
	button.add_theme_stylebox_override("disabled", normal_style)

func _configure_unframed_portrait_card(card: Button) -> void:
	card.focus_mode = Control.FOCUS_NONE
	card.pivot_offset = card.custom_minimum_size * 0.5
	_apply_empty_button_styles(card)
	card.mouse_entered.connect(_on_portrait_card_hover.bind(card, true))
	card.mouse_exited.connect(_on_portrait_card_hover.bind(card, false))

func _create_purchase_reason_overlay(card: Control) -> Label:
	var dimmer := ColorRect.new()
	dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dimmer.visible = false
	dimmer.color = Color(0.015, 0.02, 0.025, 0.64)
	dimmer.z_index = 29
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.add_child(dimmer)
	var overlay := PanelContainer.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	overlay.z_index = 30
	overlay.anchor_left = 0.08
	overlay.anchor_top = 0.35
	overlay.anchor_right = 0.92
	overlay.anchor_bottom = 0.65
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.015, 0.018, 0.92)
	style.border_color = Color(1.0, 0.34, 0.24, 0.96)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	overlay.add_theme_stylebox_override("panel", style)
	card.add_child(overlay)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.72))
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.0, 0.0, 1.0))
	label.add_theme_constant_override("outline_size", 4)
	overlay.add_child(label)
	label.set_meta("purchase_dimmer", dimmer)
	return label

func _set_purchase_reason(label: Label, reason: String) -> void:
	label.text = reason
	var overlay := label.get_parent() as Control
	if overlay != null:
		overlay.visible = not reason.is_empty()
	var dimmer := label.get_meta("purchase_dimmer", null) as ColorRect
	if dimmer != null:
		dimmer.visible = not reason.is_empty()

func _shop_purchase_reason(index: int) -> String:
	if index < 0 or index >= GameState.shop_offers.size():
		return tr("ui_cannot_buy")
	var offer: Dictionary = GameState.shop_offers[index]
	if offer.is_empty():
		return tr("ui_no_item")
	if bool(GameState.shop_sold[index]):
		return tr("ui_sold")
	if GameState.gold < _shop_unit_cost(offer):
		return tr("ui_not_enough_gold")
	if _first_empty_bench_slot() < 0:
		return tr("ui_bench_full")
	return ""

func _mercenary_purchase_reason(index: int) -> String:
	var mercenaries: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	if index < 0 or index >= mercenaries.size():
		return tr("ui_cannot_buy")
	if _first_empty_mercenary_slot() < 0:
		return tr("ui_merc_full")
	var mercenary: Dictionary = mercenaries[index]
	if GameState.gold < int(mercenary.get("cost", 0)):
		return tr("ui_not_enough_gold")
	return ""

func _on_portrait_card_hover(card: Control, hovered: bool) -> void:
	if card.has_meta("portrait_hover_tween"):
		var previous: Variant = card.get_meta("portrait_hover_tween")
		if previous is Tween:
			(previous as Tween).kill()
	card.pivot_offset = card.size * 0.5
	card.z_index = 20 if hovered else 0
	var tween: Tween = create_tween()
	card.set_meta("portrait_hover_tween", tween)
	var target_scale := Vector2(1.07, 1.07) if hovered else Vector2.ONE
	tween.tween_property(card, "scale", target_scale, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _on_refresh_shop_control_pressed() -> void:
	if _refresh_shop_icon != null:
		var spin_tween: Tween = create_tween()
		spin_tween.tween_property(_refresh_shop_icon, "rotation", _refresh_shop_icon.rotation + TAU, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		spin_tween.tween_callback(func(): _refresh_shop_icon.rotation = 0.0)
	_on_refresh_shop()

func _on_shop_card_pressed(card: BaseButton, index: int) -> void:
	if bool(card.get_meta("long_press_triggered", false)):
		return
	_on_shop_pressed(index)

func _create_mercenary_purchase_card(mercenary: Dictionary, index: int) -> DragButton:
	var card := DragButton.new()
	card.drag_owner = self
	card.custom_minimum_size = Vector2(120, 120)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.clip_contents = false
	card.text = ""
	card.drag_enabled = false
	card.set_meta("drag_preview_text", "%s\n%s" % [str(mercenary.get("name", tr("ui_mercenary"))), tr("ui_gold_format") % int(mercenary.get("cost", 0))])
	var purchase_reason := _mercenary_purchase_reason(index)
	var can_purchase := purchase_reason.is_empty()
	card.set_meta("can_purchase", can_purchase)
	card.drag_payload = {}
	card.pressed.connect(_on_mercenary_purchase_card_pressed.bind(card, index))
	_attach_long_press(card, func(): _show_text_detail(_format_unit_def(mercenary)))
	_configure_unframed_portrait_card(card)
	card.modulate = Color.WHITE

	var portrait := TextureRect.new()
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	portrait.offset_left = 4
	portrait.offset_top = 2
	portrait.offset_right = -4
	portrait.offset_bottom = -38
	var portrait_path := str(MERCENARY_PORTRAIT_PATHS.get(str(mercenary.get("id", "")), ""))
	portrait.texture = _cached_texture(portrait_path)
	card.add_child(portrait)

	var name_label := Label.new()
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.anchor_left = 0.0
	name_label.anchor_top = 1.0
	name_label.anchor_right = 1.0
	name_label.anchor_bottom = 1.0
	name_label.offset_left = 1
	name_label.offset_top = -38
	name_label.offset_right = -1
	name_label.offset_bottom = -19
	name_label.text = _ui_unit_name(mercenary)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	name_label.add_theme_constant_override("outline_size", 0)
	card.add_child(name_label)

	var price_label := Label.new()
	price_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	price_label.anchor_left = 0.0
	price_label.anchor_top = 1.0
	price_label.anchor_right = 1.0
	price_label.anchor_bottom = 1.0
	price_label.offset_left = 1
	price_label.offset_top = -19
	price_label.offset_right = -1
	price_label.offset_bottom = 0
	price_label.text = tr("ui_gold_format") % int(mercenary.get("cost", 0))
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	price_label.add_theme_font_size_override("font_size", 10)
	price_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	price_label.add_theme_constant_override("outline_size", 2)
	card.add_child(price_label)
	var reason_label := _create_purchase_reason_overlay(card)
	_set_purchase_reason(reason_label, purchase_reason)
	return card

func _on_mercenary_purchase_card_pressed(card: BaseButton, index: int) -> void:
	if bool(card.get_meta("long_press_triggered", false)):
		return
	if not bool(card.get_meta("can_purchase", false)):
		return
	_on_hire_mercenary(index)

func _refresh_all() -> void:
	if not GameState.tutorial_mode:
		_auto_combine_all()
	if GameState.tutorial_mode:
		TutorialMode.sync()
	RaceRelationService.reconcile_board(GameState.board_slots, GameState.bench_slots, false, true)
	_refresh_formation_status()
	_refresh_board()
	_refresh_bench()
	_refresh_shop()
	_refresh_left_panel()
	_refresh_merc_panel()
	_refresh_treasure_panel()
	_refresh_owned_treasure_logos()
	if GameState.tutorial_mode:
		TutorialMode.update_overlay()

func _refresh_board() -> void:
	for i in _board_buttons.size():
		var btn := _board_buttons[i]
		var cell = GameState.board_slots[i]
		if cell == null:
			btn.text = ""
			btn.drag_payload = {}
			btn.add_theme_stylebox_override("normal", _board_empty_style)
		else:
			btn.text = ""
			btn.drag_payload = {"kind": "board", "index": i}
			btn.add_theme_stylebox_override("normal", _board_occupied_style)
		btn.set_deployment_highlight(_board_drop_highlight_active, i == _board_drop_hover_index)
		btn.add_theme_stylebox_override("hover", _board_occupied_style if cell != null else _board_empty_style)
		btn.add_theme_stylebox_override("pressed", _board_occupied_style if cell != null else _board_empty_style)
		btn.add_theme_stylebox_override("focus", _board_occupied_style if cell != null else _board_empty_style)
		btn.modulate = Color(1, 0.92, 0.55) if i == _selected_board else Color.WHITE
		if i < _board_relation_overlays.size():
			_board_relation_overlays[i].set_relation_states(RaceRelationService.visual_states_for_cell(cell))
		if i < _board_cell_captions.size():
			var caption := _board_cell_captions[i]
			if cell == null:
				caption.visible = false
			else:
				caption.text = _cell_caption_text(cell)
				caption.visible = true
	_refresh_prep_board_models()

func _setup_board_cell_styles() -> void:
	_board_empty_style = StyleBoxFlat.new()
	_board_hover_style = StyleBoxFlat.new()
	_board_occupied_style = StyleBoxFlat.new()
	_board_drop_style = StyleBoxFlat.new()
	_board_empty_style.bg_color = Color.TRANSPARENT
	_board_hover_style.bg_color = Color.TRANSPARENT
	_board_occupied_style.bg_color = Color.TRANSPARENT
	_board_drop_style.bg_color = Color(0.38, 0.86, 0.78, 0.085)

func _load_board_art_texture() -> Texture2D:
	return null

func _refresh_bench() -> void:
	for i in _bench_buttons.size():
		var btn := _bench_buttons[i]
		var name_label := _bench_card_labels[i]
		var cell = GameState.bench_slots[i]
		btn.disabled = false
		btn.text = ""
		if cell == null:
			_apply_empty_button_styles(btn)
			btn.text = ""
			btn.tooltip_text = tr("ui_bench_slot")
			btn.set_meta("drag_preview_text", "")
			btn.drag_payload = {}
			name_label.text = ""
			name_label.visible = false
			btn.modulate = Color.WHITE
		else:
			_apply_empty_button_styles(btn)
			var d: Dictionary = cell.def
			var unit_name := _ui_unit_name(d)
			btn.tooltip_text = unit_name
			btn.set_meta("drag_preview_text", "%s  %d★" % [unit_name, int(cell.get("star", 1))])
			btn.drag_payload = {} if GameState.tutorial_mode and TutorialMode.step == TutorialMode.Step.BUY_3 else {"kind": "bench", "index": i}
			name_label.text = _cell_caption_text(cell)
			name_label.visible = true
		btn.set_standby_highlight(_standby_drop_highlight_active, i == _standby_drop_hover_index)
		btn.modulate = Color(1, 0.92, 0.55) if i == _selected_bench else Color.WHITE
	_refresh_prep_standby_models()

func _refresh_shop() -> void:
	var gold_text := TutorialMode.GOLD_TEXT if GameState.tutorial_mode else tr("ui_gold_format") % GameState.gold
	if _gold_amount_label != null:
		_gold_amount_label.text = gold_text
	if _closed_gold_label != null:
		_closed_gold_label.text = gold_text
	if _gold_interest_detail_open and _detail != null and _detail.visible:
		_detail_text.text = _format_gold_interest_detail()
	if _refresh_shop_button != null:
		var all_free := TreasureService.has_set("money")
		var refresh_cost := EconomyService.shop_refresh_cost(GameState.shop_refresh_uses_this_round, all_free)
		_refresh_shop_button.disabled = GameState.gold < refresh_cost
		_refresh_shop_icon.modulate = Color(0.46, 0.46, 0.46) if _refresh_shop_button.disabled else Color.WHITE
		_refresh_shop_cost_label.text = tr("ui_free") if refresh_cost == 0 else tr("ui_gold_format") % refresh_cost
		_refresh_shop_cost_label.modulate = Color(0.46, 0.46, 0.46) if _refresh_shop_button.disabled else Color.WHITE
	var selected_valid: bool = (
		_selected_shop >= 0
		and _selected_shop < GameState.shop_offers.size()
		and not GameState.shop_offers[_selected_shop].is_empty()
		and not bool(GameState.shop_sold[_selected_shop])
	)
	if not selected_valid:
		_selected_shop = -1
	var offer_ids: Array = []
	for offer_entry in GameState.shop_offers:
		offer_ids.append(str((offer_entry as Dictionary).get("id", "")))
	var cards_sig := JSON.stringify([
		offer_ids,
		GameState.shop_sold,
		GameState.gold,
		_selected_shop,
		_first_empty_bench_slot() < 0,
		GameState.tutorial_mode,
		LocaleManager.get_locale(),
	])
	if cards_sig == _shop_cards_signature:
		return
	_shop_cards_signature = cards_sig
	for i in _shop_buttons.size():
		var btn := _shop_buttons[i]
		var portrait := _shop_portraits[i]
		var card_frame := _shop_card_frames[i]
		var name_label := _shop_card_labels[i]
		var price_label := _shop_price_labels[i]
		var race_icon := _shop_race_icons[i]
		var reason_label := _shop_reason_labels[i]
		var offer: Dictionary = GameState.shop_offers[i]
		if offer.is_empty():
			btn.text = ""
			btn.set_meta("drag_preview_text", "")
			btn.disabled = true
			btn.drag_payload = {}
			portrait.texture = null
			portrait.visible = false
			card_frame.visible = false
			name_label.text = tr("ui_empty_slot")
			price_label.text = ""
			race_icon.visible = false
			_set_purchase_reason(reason_label, tr("ui_no_item"))
			btn.modulate = Color.WHITE
			continue
		var sold := bool(GameState.shop_sold[i])
		var cost := _shop_unit_cost(offer)
		var can_purchase := not sold and GameState.gold >= cost
		var unit_name := _ui_unit_name(offer)
		btn.disabled = false
		btn.text = ""
		btn.set_meta("drag_preview_text", "%s\n%s" % [unit_name, tr("ui_gold_format") % cost])
		portrait.texture = _cached_texture("%s/%s.png" % [UNIT_PORTRAIT_DIR, str(offer.get("id", ""))])
		portrait.visible = portrait.texture != null
		card_frame.visible = true
		card_frame.texture = _cached_texture(str(SHOP_CARD_FRAME_PATHS.get(int(offer.get("tier", 1)), SHOP_CARD_FRAME_PATHS[1])))
		name_label.text = unit_name
		price_label.text = str(cost)   # 金币图案已画死在框右上角，只写数字
		race_icon.visible = true
		race_icon.call("set_race", str(offer.get("race", "")))
		btn.drag_payload = {} if GameState.tutorial_mode else ({"kind": "shop", "index": i} if can_purchase else {})
		var purchase_reason := _shop_purchase_reason(i)
		_set_purchase_reason(reason_label, purchase_reason)
		btn.modulate = Color(0.52, 0.64, 0.72, 0.92) if purchase_reason.is_empty() and i == _selected_shop else Color.WHITE

func _show_gold_interest_detail() -> void:
	_gold_interest_detail_open = true
	_detail_text.custom_minimum_size = Vector2(180, 72)
	_detail_text.text = _format_gold_interest_detail()
	_detail_waiting_for_release = false
	_detail_release_seen_press = false
	_detail.popup_centered(Vector2i(220, 104))

func _format_gold_interest_detail() -> String:
	var gold := maxi(0, GameState.gold)
	var base_interest := EconomyService.base_interest(gold)
	var money_compound_bonus := 0
	if GameState.owned_treasures.has("money_compound"):
		money_compound_bonus = int(floor(float(gold) * 0.05))
	var pet_interest_bonus := EconomyService.pet_interest_bonus(gold, PlayerProfile.get_active())
	var total_interest := base_interest + money_compound_bonus + pet_interest_bonus
	var is_en := TranslationServer.get_locale().begins_with("en")
	var lines: Array[String] = []
	if is_en:
		lines.append("Current gold: %d" % gold)
		lines.append("Interest: +%d" % total_interest)
	else:
		lines.append("当前金币：%d" % gold)
		lines.append("利息：+%d" % total_interest)
	return "\n".join(lines)

func _refresh_left_panel() -> void:
	var sig_altar_hp := GameState.team_hp if GameState.team_mode else GameState.player_formation_hp
	var sig := JSON.stringify([
		SynergyService.count_races_from_board(),
		GameState.owned_treasures,
		GameState.golden_altar_uses,
		GameState.gamble_used,
		sig_altar_hp <= 10,
		LocaleManager.get_locale(),
	])
	if sig == _left_panel_signature:
		return
	_left_panel_signature = sig
	for child in _left_panel.get_children():
		child.queue_free()
	var title := Label.new()
	title.text = tr("ui_bond_treasure")
	title.add_theme_font_size_override("font_size", 16)
	_left_panel.add_child(title)

	_add_current_synergy_widgets()

	var sell_hint := Label.new()
	sell_hint.text = tr("ui_sell_hint")
	sell_hint.modulate = Color(0.9, 0.82, 0.55)
	_left_panel.add_child(sell_hint)

	# Owned-treasure logos now live next to the money bag (see _owned_treasure_box).
	if GameState.owned_treasures.has("money_golden_altar"):
		var altar := Button.new()
		altar.text = tr("ui_altar") % [5, GameState.golden_altar_uses]
		var altar_hp := GameState.team_hp if GameState.team_mode else GameState.player_formation_hp
		altar.disabled = altar_hp <= NetworkService.ALTAR_MIN_HP or GameState.golden_altar_uses >= NetworkService.ALTAR_MAX_USES_PER_ROUND
		altar.pressed.connect(_on_golden_altar)
		_left_panel.add_child(altar)

	if GameState.owned_treasures.has("money_generous_fate"):
		var gamble := Button.new()
		gamble.text = tr("ui_gamble_used") if GameState.gamble_used else tr("ui_gamble")
		gamble.disabled = GameState.gamble_used
		gamble.pressed.connect(_on_generous_fate_gamble)
		_attach_long_press(gamble, _show_treasure_detail.bind("money_generous_fate"))
		_left_panel.add_child(gamble)

func _refresh_merc_panel() -> void:
	if _merc_scroll != null:
		_merc_scroll.visible = true
	for child in _merc_panel.get_children():
		child.queue_free()
	# 佣兵「佣兵」开启按钮已移到右上角统计/战力列下面（盾牌框）。
	# 已购佣兵不在备战界面出模型，只在佣兵弹窗右上角显示「已雇 N/8」。
	_refresh_mercenary_overlay()

func _hired_mercenary_count() -> int:
	var n := 0
	for cell in GameState.mercenary_slots:
		if cell != null:
			n += 1
	return n

func _refresh_mercenary_overlay() -> void:
	if _merc_overlay == null or _merc_overlay_grid == null:
		return
	_merc_overlay.visible = _merc_picker_open
	if not _merc_picker_open:
		_merc_overlay_signature = "unset"
		for child in _merc_overlay_grid.get_children():
			child.queue_free()
		return
	# 计数放在下面的签名短路之前，否则签名没变时会漏更新。
	if _merc_count_label != null:
		_merc_count_label.text = tr("ui_merc_hired_count") % [_hired_mercenary_count(), GameState.MERCENARY_SLOTS]
	# 打开状态下只有影响卡片内容的数据变了才重建 12 张卡。
	var sig := JSON.stringify([
		GameState.gold,
		GameState.mercenary_slots,
		GameState.tutorial_mode,
		LocaleManager.get_locale(),
	])
	if sig == _merc_overlay_signature:
		return
	_merc_overlay_signature = sig
	for child in _merc_overlay_grid.get_children():
		child.queue_free()
	var mercs: Array = DataRegistry.get_table("mercenaries").get("mercenaries", [])
	for i in mercs.size():
		var m: Dictionary = mercs[i]
		_merc_overlay_grid.add_child(_create_mercenary_purchase_card(m, i))

func _toggle_merc_picker() -> void:
	_merc_picker_open = not _merc_picker_open
	if _merc_picker_open:
		_close_team_mercs_picker()
		_close_shop_picker()
	_refresh_merc_panel()

func _close_merc_picker() -> void:
	if not _merc_picker_open:
		return
	_merc_picker_open = false
	_refresh_merc_panel()

func _toggle_shop_picker() -> void:
	_shop_picker_open = not _shop_picker_open
	if _shop_picker_open:
		_close_merc_picker()
		_close_team_mercs_picker()
	_refresh_shop_picker()

func _close_shop_picker() -> void:
	if not _shop_picker_open:
		return
	_shop_picker_open = false
	_refresh_shop_picker()

func _refresh_shop_picker() -> void:
	if _shop_panel != null:
		_shop_panel.visible = _shop_picker_open
	if _shop_side_controls != null:
		_shop_side_controls.visible = _shop_picker_open     # 外挂层（钱袋A+刷新）跟商店一起显隐
	if _closed_money_bag != null:
		_closed_money_bag.visible = not _shop_picker_open   # 商店关时才显示钱袋 B
	# 商店开着时待命格子被商店盖住，禁用它们的输入，别去抢商店区域的点击；关店恢复。
	var bench_filter := Control.MOUSE_FILTER_IGNORE if _shop_picker_open else Control.MOUSE_FILTER_STOP
	for btn in _bench_buttons:
		if btn != null:
			btn.mouse_filter = bench_filter

# ─── team mercs review stage ──────────────────────────────────────────────────

func _build_team_mercs_overlay(center_host: Control) -> void:
	_team_mercs_overlay = PanelContainer.new()
	_team_mercs_overlay.visible = false
	_team_mercs_overlay.z_index = 40
	_team_mercs_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_team_mercs_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var overlay_style := StyleBoxFlat.new()
	overlay_style.bg_color = Color(0.055, 0.065, 0.075, 0.98)
	overlay_style.border_color = Color(0.42, 0.50, 0.58, 0.92)
	overlay_style.set_border_width_all(2)
	overlay_style.set_corner_radius_all(4)
	_team_mercs_overlay.add_theme_stylebox_override("panel", overlay_style)
	center_host.add_child(_team_mercs_overlay)
	var overlay_margin := MarginContainer.new()
	overlay_margin.add_theme_constant_override("margin_left", 12)
	overlay_margin.add_theme_constant_override("margin_top", 10)
	overlay_margin.add_theme_constant_override("margin_right", 12)
	overlay_margin.add_theme_constant_override("margin_bottom", 12)
	_team_mercs_overlay.add_child(overlay_margin)
	var overlay_box := VBoxContainer.new()
	overlay_box.add_theme_constant_override("separation", 8)
	overlay_margin.add_child(overlay_box)
	var overlay_title := Label.new()
	overlay_title.text = tr("ui_team_mercs")
	overlay_title.add_theme_font_size_override("font_size", 18)
	overlay_box.add_child(overlay_title)
	var stage_holder := Control.new()
	stage_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	overlay_box.add_child(stage_holder)
	var viewport_container := SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage_holder.add_child(viewport_container)
	_team_mercs_viewport = SubViewport.new()
	_team_mercs_viewport.own_world_3d = true
	_team_mercs_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport_container.add_child(_team_mercs_viewport)
	# 灯光/环境照抄备战河流视口，让模型观感一致；背景色同弹窗底色，视觉上无缝
	var env_node := WorldEnvironment.new()
	var stage_env := Environment.new()
	stage_env.background_mode = Environment.BG_COLOR
	stage_env.background_color = Color(0.055, 0.065, 0.075)
	stage_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	stage_env.ambient_light_color = Color(0.58, 0.68, 0.61)
	stage_env.ambient_light_energy = 0.40
	stage_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = stage_env
	_team_mercs_viewport.add_child(env_node)
	var key_light := DirectionalLight3D.new()
	key_light.light_color = Color(1.0, 0.92, 0.76)
	key_light.light_energy = 0.64
	key_light.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	key_light.shadow_enabled = false
	_team_mercs_viewport.add_child(key_light)
	var fill_light := DirectionalLight3D.new()
	fill_light.light_color = Color(0.48, 0.68, 0.82)
	fill_light.light_energy = 0.18
	fill_light.rotation_degrees = Vector3(-38.0, 142.0, 0.0)
	fill_light.shadow_enabled = false
	_team_mercs_viewport.add_child(fill_light)
	var camera := Camera3D.new()
	camera.fov = TEAM_MERCS_CAMERA_FOV
	camera.look_at_from_position(TEAM_MERCS_CAMERA_POSITION, TEAM_MERCS_CAMERA_TARGET, Vector3.UP)
	camera.current = true
	_team_mercs_viewport.add_child(camera)
	_team_mercs_stage_root = Node3D.new()
	_team_mercs_stage_root.name = "TeamMercsStageRoot"
	_team_mercs_stage_root.scale = Vector3.ONE * TEAM_MERCS_STAGE_SCALE
	_team_mercs_viewport.add_child(_team_mercs_stage_root)
	_team_mercs_empty_label = Label.new()
	_team_mercs_empty_label.text = tr("ui_team_mercs_empty")
	_team_mercs_empty_label.visible = false
	_team_mercs_empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_team_mercs_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_team_mercs_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_team_mercs_empty_label.add_theme_font_size_override("font_size", 18)
	_team_mercs_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage_holder.add_child(_team_mercs_empty_label)
	# 30Hz 渲染节流：和河流视口同一采样率，动画推进不受影响
	_team_mercs_render_timer = Timer.new()
	_team_mercs_render_timer.wait_time = 1.0 / PREP_RIVER_RENDER_HZ
	_team_mercs_render_timer.timeout.connect(_on_team_mercs_render_tick)
	add_child(_team_mercs_render_timer)
	if not NetworkService.team_prep_mercs_changed.is_connected(_on_team_prep_mercs_changed):
		NetworkService.team_prep_mercs_changed.connect(_on_team_prep_mercs_changed)

func _on_team_mercs_render_tick() -> void:
	if _team_mercs_open and _team_mercs_viewport != null and is_visible_in_tree():
		_team_mercs_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

func _on_team_prep_mercs_changed() -> void:
	if _team_mercs_open:
		_refresh_team_mercs_overlay()

func _toggle_team_mercs_picker() -> void:
	_team_mercs_open = not _team_mercs_open
	if _team_mercs_open:
		_close_merc_picker()
	_refresh_team_mercs_overlay()

func _close_team_mercs_picker() -> void:
	if not _team_mercs_open:
		return
	_team_mercs_open = false
	_refresh_team_mercs_overlay()

func _refresh_team_mercs_overlay() -> void:
	if _team_mercs_overlay == null:
		return
	_team_mercs_overlay.visible = _team_mercs_open
	if not _team_mercs_open:
		# 关闭即清场：模型的 AnimationPlayer 不渲染也吃 CPU，不能留在树里空转
		_team_mercs_stage_signature = "unset"
		if _team_mercs_render_timer != null:
			_team_mercs_render_timer.stop()
		if _team_mercs_viewport != null:
			_team_mercs_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if _team_mercs_stage_root != null:
			for child in _team_mercs_stage_root.get_children():
				child.queue_free()
		return
	_rebuild_team_mercs_stage()
	if _team_mercs_render_timer != null and _team_mercs_render_timer.is_stopped():
		_team_mercs_render_timer.start()

func _team_mercs_entries() -> Array:
	# 自己的佣兵直接读本地状态（永远最新）；队友的走备战期同步。
	# AI/占位座位不会有同步数据，自然空着。
	var my_slot := NetworkService.team_local_slot if NetworkService.team_active else 0
	if my_slot < 0:
		my_slot = 0
	var first := GameConstants.team_first_slot(GameConstants.team_of_slot(my_slot))
	var out: Array = []
	for slot in range(first, first + GameConstants.TEAM_SIDE_SIZE):
		var ids: Array = []
		if slot == my_slot:
			for cell in GameState.mercenary_slots:
				if typeof(cell) == TYPE_DICTIONARY:
					ids.append(str((cell as Dictionary).get("id", "")))
		else:
			ids = NetworkService.team_prep_merc_ids(slot, GameState.round_index)
		for i in ids.size():
			out.append({"slot": slot, "index": i, "id": str(ids[i])})
	return out

func _rebuild_team_mercs_stage() -> void:
	if _team_mercs_stage_root == null:
		return
	var entries := _team_mercs_entries()
	var sig := JSON.stringify([GameState.round_index, entries])
	if sig == _team_mercs_stage_signature:
		return
	_team_mercs_stage_signature = sig
	for child in _team_mercs_stage_root.get_children():
		child.queue_free()
	if _team_mercs_empty_label != null:
		_team_mercs_empty_label.visible = entries.is_empty()
	var defs := {}
	for row in (DataRegistry.get_table("mercenaries").get("mercenaries", []) as Array):
		defs[str((row as Dictionary).get("id", ""))] = row
	var taken: Array = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var def_value = defs.get(str(entry.get("id", "")))
		if typeof(def_value) != TYPE_DICTIONARY:
			continue
		var def: Dictionary = def_value
		var slot := int(entry.get("slot", 0))
		# 每回合固定的随机站位：种子=回合+槽位+序号，重开弹窗不变，
		# 后买的佣兵也不会挪动先前佣兵的位置。
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("team_mercs_%d_%d_%d" % [GameState.round_index, slot, int(entry.get("index", 0))])
		var pos := _team_mercs_spot(rng, taken)
		taken.append(pos)
		var cell := {"id": str(entry.get("id", "")), "star": 1, "def": def, "is_mercenary": true}
		var pivot := _make_prep_board_model(cell, def)
		if pivot == null:
			continue
		# 模型已不带 3D 名字/星级浮标，队伍佣兵检阅台本就不需要显示，无需再隐藏。
		pivot.position = pos
		pivot.rotation_degrees = Vector3(0.0, float(def.get("model_base_yaw", 180.0)) + rng.randf_range(-20.0, 20.0), 0.0)
		_team_mercs_stage_root.add_child(pivot)
		_team_mercs_stage_root.add_child(_make_team_mercs_plate(slot, pos))

func _team_mercs_spot(rng: RandomNumberGenerator, taken: Array) -> Vector3:
	var candidate := Vector3.ZERO
	for attempt in 24:
		candidate = Vector3(
			rng.randf_range(-TEAM_MERCS_AREA_HALF.x, TEAM_MERCS_AREA_HALF.x),
			0.0,
			rng.randf_range(-TEAM_MERCS_AREA_HALF.y, TEAM_MERCS_AREA_HALF.y)
		)
		var clear := true
		for taken_pos in taken:
			if candidate.distance_to(taken_pos) < TEAM_MERCS_MIN_DIST:
				clear = false
				break
		if clear:
			return candidate
	return candidate

func _make_team_mercs_plate(slot: int, pos: Vector3) -> MeshInstance3D:
	var plate := MeshInstance3D.new()
	var plate_mesh := CylinderMesh.new()
	plate_mesh.top_radius = TEAM_MERCS_PLATE_RADIUS
	plate_mesh.bottom_radius = TEAM_MERCS_PLATE_RADIUS
	plate_mesh.height = TEAM_MERCS_PLATE_HEIGHT
	plate.mesh = plate_mesh
	var plate_material := StandardMaterial3D.new()
	plate_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plate_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var slot_color := GameConstants.team_slot_color(slot)
	plate_material.albedo_color = Color(slot_color.r, slot_color.g, slot_color.b, 0.92)
	plate.material_override = plate_material
	plate.position = Vector3(pos.x, TEAM_MERCS_PLATE_HEIGHT * 0.5, pos.z)
	return plate

func _refresh_treasure_panel() -> void:
	if _treasure_overlay == null:
		return
	var active := bool(GameState.pending_treasure.get("active", false))
	_treasure_overlay.visible = active
	if not active:
		return
	_treasure_timer_lbl.text = tr("ui_treasure_pick")
	for child in _treasure_choice_row.get_children():
		child.queue_free()
	var cands: Array = GameState.pending_treasure.get("candidates", [])
	for i in cands.size():
		var tid := str(cands[i])
		var t := TreasureService.treasure_by_id(tid)
		var tname := str(t.get("name", tid))
		var card := Button.new()
		# 三选一抽宝藏卡整体放大 30%（336×448 → 437×582）。
		card.custom_minimum_size = Vector2(437, 582)
		card.focus_mode = Control.FOCUS_NONE
		_apply_empty_button_styles(card)
		_configure_unframed_portrait_card(card)
		card.pressed.connect(_pick_treasure.bind(tid))
		_attach_long_press(card, _show_treasure_detail.bind(tid))
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var _card_suffix := "_en" if LocaleManager.get_locale() == "en" else ""
		var _tex_path := "%s/%s%s.png" % [TREASURE_CARD_DIRECTORY, tname, _card_suffix]
		var _loaded_tex := _cached_texture(_tex_path)
		if _loaded_tex == null:
			_loaded_tex = _cached_texture("%s/%s.png" % [TREASURE_CARD_DIRECTORY, tname])
		tex.texture = _loaded_tex
		card.add_child(tex)
		# Safety net: if the card art is missing, never leave the card invisible —
		# show the treasure name so it stays selectable.
		if _loaded_tex == null:
			var fallback := Label.new()
			fallback.text = _ui_unit_name(t)
			fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
			fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			fallback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			fallback.add_theme_font_size_override("font_size", 28)
			fallback.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
			fallback.add_theme_constant_override("outline_size", 4)
			card.add_child(fallback)
		_treasure_choice_row.add_child(card)
	var cost := TreasureService.refresh_cost(int(GameState.pending_treasure.get("refresh_index", 0)), TreasureService.has_set("money"))
	_treasure_refresh_btn.text = tr("ui_treasure_refresh_free") if cost == 0 else tr("ui_treasure_refresh_cost") % cost
	_treasure_refresh_btn.disabled = GameState.gold < cost

func _refresh_owned_treasure_logos() -> void:
	if _owned_treasure_box == null:
		return
	# 联动 logo 完全由已拥有宝物推导，所以签名只需 owned_treasures。
	var sig := JSON.stringify(GameState.owned_treasures)
	if sig == _owned_logos_signature:
		return
	_owned_logos_signature = sig
	for child in _owned_treasure_box.get_children():
		child.queue_free()
	# Owned treasures.
	for tid in GameState.owned_treasures:
		var tid_str := str(tid)
		var t := TreasureService.treasure_by_id(tid)
		_add_owned_treasure_logo(str(t.get("name", tid_str)), _show_treasure_detail.bind(tid_str))
	# Active linkages (their required treasures are all owned) get their own logo too.
	var links: Array = DataRegistry.get_table("treasures").get("linkages", [])
	for link in links:
		var lid := str(link.get("id", ""))
		if TREASURE_LINKAGE_LOGOS.has(lid) and TreasureService.has_linkage(lid):
			_add_owned_treasure_logo(str(TREASURE_LINKAGE_LOGOS[lid]), _show_linkage_detail.bind(lid))

func _add_owned_treasure_logo(logo_name: String, detail: Callable) -> void:
	var b := Button.new()
	b.text = ""
	b.tooltip_text = logo_name
	b.custom_minimum_size = Vector2(66, 66)
	b.focus_mode = Control.FOCUS_NONE
	_apply_empty_button_styles(b)
	var logo := TextureRect.new()
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	logo.texture = _cached_texture("%s/%s.png" % [TREASURE_LOGO_DIRECTORY, logo_name])
	b.add_child(logo)
	if detail.is_valid():
		b.pressed.connect(detail)
	_owned_treasure_box.add_child(b)

func _maybe_show_pvp_warning(kind: String) -> void:
	if kind != "pvp" and kind != "final":
		return
	_show_pvp_warning_overlay()

func _show_pvp_warning_overlay() -> void:
	var tex := _cached_texture(PVP_WARNING_FRAME_PATH)
	if tex == null:
		return
	var overlay := Control.new()
	overlay.name = "PvPWarningOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.z_index = 120
	add_child(overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.0)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var center := Control.new()
	center.anchor_left = 0.5
	center.anchor_top = 0.5
	center.anchor_right = 0.5
	center.anchor_bottom = 0.5
	center.offset_left = -600
	center.offset_top = -310
	center.offset_right = 600
	center.offset_bottom = 310
	center.pivot_offset = Vector2(600, 310)
	center.modulate.a = 0.0
	center.scale = Vector2(0.90, 0.90)
	overlay.add_child(center)

	var glow := TextureRect.new()
	glow.texture = tex
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.modulate = Color(1.0, 0.05, 0.02, 0.28)
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var glow_mat := CanvasItemMaterial.new()
	glow_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = glow_mat
	center.add_child(glow)

	var frame := TextureRect.new()
	frame.texture = tex
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.add_child(frame)

	var title := Label.new()
	title.text = "Showdown Time!" if LocaleManager.get_locale() == "en" else "敌袭快准备！"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title.offset_top = 90
	title.offset_bottom = -70
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(1.0, 0.05, 0.02))
	title.add_theme_color_override("font_outline_color", Color(0.10, 0.0, 0.0, 0.95))
	title.add_theme_constant_override("outline_size", 6)
	center.add_child(title)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(dim, "color:a", 0.48, 0.12)
	tween.tween_property(center, "modulate:a", 1.0, 0.12)
	tween.tween_property(center, "scale", Vector2(1.04, 1.04), 0.12)
	tween.set_parallel(false)
	tween.tween_property(center, "scale", Vector2.ONE, 0.13)

	var glow_tween := create_tween().set_loops()
	glow_tween.tween_property(glow, "modulate:a", 0.58, 0.35)
	glow_tween.tween_property(glow, "modulate:a", 0.22, 0.35)

	await get_tree().create_timer(2.0).timeout
	glow_tween.kill()
	var out := create_tween()
	out.set_parallel(true)
	out.tween_property(dim, "color:a", 0.0, 0.18)
	out.tween_property(center, "modulate:a", 0.0, 0.18)
	out.tween_property(center, "scale", Vector2(0.96, 0.96), 0.18)
	await out.finished
	overlay.queue_free()
