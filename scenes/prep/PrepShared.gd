extends Control

signal battle_requested

# D2 第一步：通用 UI 工具箱。放在继承链最底层，五个面板与宿主共用同一份。
# 用 preload 而非 class_name：新增全局类要等编辑器重扫才进类缓存。
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")

# D2 第二步：规则查询。面板要先知道「这步能不能做」才决定要不要发事件，
# 把这层留在宿主身上会一直把面板拴住。
const PrepRules := preload("res://scenes/prep/PrepRules.gd")

# D2 第三步：详情浮层。四个面板共用，自带状态（弹窗节点 + 关闭时序），
# 所以是实例不是静态工具。
const PrepDetailOverlay := preload("res://scenes/prep/PrepDetailOverlay.gd")

# D2 第三步：可拖拽按钮与出售放置面板搬成独立文件。
# 起因是商店面板要独立成文件，而它的字段需要这两个类型；
# 类型留在本文件里，独立出去的面板就引用不到（退成基类会丢掉 drag_payload 的静态检查）。
const DragButton := preload("res://scenes/prep/PrepDragButton.gd")
const SellDropPanel := preload("res://scenes/prep/PrepSellDropPanel.gd")
const BoardCellButton := preload("res://scenes/prep/PrepBoardCellButton.gd")
const BenchCellButton := preload("res://scenes/prep/PrepBenchCellButton.gd")
const RelationProgressOverlay := preload("res://scenes/prep/PrepRelationProgressOverlay.gd")
const GloryBusyButtonScript := preload("res://ui/components/GloryBusyButton.gd")
# 五个面板都以**场景**形式存在，可以脱离备战界面单独 load 起来跑测试
# （tools/panel_scene_check.tscn 就是这么做的）—— 这是 README D2 的验收之一。
# 两个常量各有用处：Script 用于类型标注（保住静态检查），Scene 用于实例化。
const ShopPanelScript := preload("res://scenes/prep/panels/ShopPanel.gd")
const ShopPanelScene := preload("res://scenes/prep/panels/ShopPanel.tscn")
const SynergyPanelScript := preload("res://scenes/prep/panels/SynergyPanel.gd")
const SynergyPanelScene := preload("res://scenes/prep/panels/SynergyPanel.tscn")
const BattleStatsPanelScript := preload("res://scenes/prep/panels/BattleStatsPanel.gd")
const BattleStatsPanelScene := preload("res://scenes/prep/panels/BattleStatsPanel.tscn")
const TreasureChoicePanelScript := preload("res://scenes/prep/panels/TreasureChoicePanel.gd")
const TreasureChoicePanelScene := preload("res://scenes/prep/panels/TreasureChoicePanel.tscn")
const BoardHudScript := preload("res://scenes/prep/panels/BoardHud.gd")
const BoardHudScene := preload("res://scenes/prep/panels/BoardHud.tscn")

const BoardReadabilityLayerScene := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")

@export_group("4x4 Board Layout")
@export var cell_size := Vector2(149.5, 84.0)
@export var board_grid_offset := Vector2.ZERO
@export_group("4x4 Board Perspective")
@export var board_top_left := Vector2(0.32, 0.0)
@export var board_top_right := Vector2(0.68, 0.0)
@export var board_bottom_right := Vector2(1.0, 1.0)
@export var board_bottom_left := Vector2(0.0, 1.0)
@export var board_foreshorten := 0.5
# 常态：16 个圆圈格子平时就画亮（#3）——始终可见的青色环。
@export var board_cell_rest_fill := Color(0.20, 0.80, 0.74, 0.06)
@export var board_cell_rest_line := Color(0.48, 1.0, 0.92, 0.55)
# 拖动放置时非目标格（更亮一点，让 16 格全部亮起）。
@export var board_cell_idle_fill := Color(0.20, 0.85, 0.80, 0.14)
@export var board_cell_idle_line := Color(0.48, 1.0, 0.92, 0.78)
# 放置目标格（#2）——高亮 + 发光。
@export var board_cell_hover_fill := Color(0.20, 1.0, 1.0, 0.42)
@export var board_cell_hover_line := Color(0.60, 1.0, 1.0, 1.0)
@export var board_origin := Vector3(-0.01, 0.035, -0.005)
@export var board_rotation := Vector3.ZERO
@export var board_scale := Vector3.ONE
@export var board_cell_spacing := Vector2(0.17, 0.18)
@export_range(0.45, 0.75, 0.01) var unit_visual_scale := 0.56
@export var unit_cell_anchor_offset := Vector2.ZERO
@export_range(-0.08, 0.20, 0.005) var unit_y_offset := 0.0

@export_group("Standby Bench Layout")
@export var standby_origin := Vector3.ZERO
@export var standby_rotation := Vector3.ZERO
@export var standby_unit_scale := 0.46
@export_range(-0.08, 0.20, 0.005) var standby_unit_y_offset := 0.0
@export var standby_face_battlefield := false
@export_range(-180.0, 180.0, 1.0) var standby_facing_yaw_offset := 0.0
@export var standby_idle_fill := Color(0.22, 0.74, 0.62, 0.0)
@export var standby_idle_line := Color(0.42, 0.94, 0.78, 0.0)
@export var standby_hover_line := Color(0.40, 1.0, 0.82, 0.92)
# 调试：把所有按钮的点击判定区域用线条画出来（多边形格子按真实多边形，普通按钮按矩形）。
# 满屏覆盖、不吃输入、z 极高，永远画在最上层。由 SHOW_HIT_AREAS 常量控制是否创建。
class HitAreaDebugOverlay:
	extends Control
	var scan_root: Control

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		z_index = 900

	func _process(_delta: float) -> void:
		# 格子跟随 3D 投影每帧移动，必须每帧重画。
		queue_redraw()

	func _draw() -> void:
		if scan_root == null:
			return
		var inv := get_global_transform().affine_inverse()
		_scan(scan_root, inv)

	func _scan(node: Node, inv: Transform2D) -> void:
		for child in node.get_children():
			if not (child is Control):
				continue
			var c := child as Control
			if not c.visible:
				continue
			if c is Button:
				_draw_button(c as Button, inv)
			_scan(c, inv)

	func _draw_button(btn: Button, inv: Transform2D) -> void:
		# IGNORE 的按钮不参与输入拾取，跳过。
		if btn.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			return
		var xf := inv * btn.get_global_transform()
		var poly := PackedVector2Array()
		if "cell_polygon" in btn:
			poly = btn.get("cell_polygon")
		if poly.size() >= 3:
			# 多边形判定（棋盘圆/待命格）——绿色。
			var pts := PackedVector2Array()
			for p in poly:
				pts.append(xf * p)
			pts.append(pts[0])
			draw_polyline(pts, Color(0.25, 1.0, 0.45, 0.95), 1.5)
		else:
			# 矩形判定（普通按钮）——品红。
			var r := Rect2(Vector2.ZERO, btn.size)
			var corners := PackedVector2Array([
				xf * r.position,
				xf * Vector2(r.end.x, r.position.y),
				xf * r.end,
				xf * Vector2(r.position.x, r.end.y),
				xf * r.position,
			])
			draw_polyline(corners, Color(1.0, 0.35, 0.85, 0.95), 1.5)

# 满屏覆盖、不吃输入、z 高，扫描整棵界面树，把每个可见控件的矩形（空间框）画成黑边。
# 由 SHOW_SPACE_FRAMES 常量控制是否创建。判定框(z900)画在它上面。
class SpaceFrameDebugOverlay:
	extends Control
	var scan_root: Control

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		z_index = 899

	func _process(_delta: float) -> void:
		# 有些框跟随 3D 投影/布局每帧变化，直接每帧重画。
		queue_redraw()

	func _draw() -> void:
		if scan_root == null:
			return
		var inv := get_global_transform().affine_inverse()
		_scan(scan_root, inv)

	func _scan(node: Node, inv: Transform2D) -> void:
		for child in node.get_children():
			if not (child is Control):
				continue
			var c := child as Control
			if not c.visible:
				continue
			if c.name.ends_with("DebugOverlay"):
				continue   # 跳过调试层自身
			_draw_frame(c, inv)
			_scan(c, inv)

	func _draw_frame(c: Control, inv: Transform2D) -> void:
		if c.size.x <= 0.0 or c.size.y <= 0.0:
			return
		var xf := inv * c.get_global_transform()
		var r := Rect2(Vector2.ZERO, c.size)
		var corners := PackedVector2Array([
			xf * r.position,
			xf * Vector2(r.end.x, r.position.y),
			xf * r.end,
			xf * Vector2(r.position.x, r.end.y),
			xf * r.position,
		])
		draw_polyline(corners, Color(0.0, 0.0, 0.0, 0.9), 1.0)

var _player_formation_art: FormationCrystal
var _enemy_formation_art: FormationCrystal
var _start_battle_label: Label
var _start_battle_button: GloryBusyButtonScript
var _round_info_label: Label
var _ready_indicator: Control
var _ready_dots: Array = []
var _toast_label: Label
var _toast_tween: Tween
var _player_formation_bar: TextureProgressBar
var _enemy_formation_bar: TextureProgressBar
var _player_formation_hp_label: Label
var _enemy_formation_hp_label: Label
# 棋盘/待命区这一簇的 17 个成员变量已收进下方的 BoardPanel 内部类（D2 第四步）。
# 全仓 132 处引用统一改成 _board_hud.xxx（含 tools/board_4x4_smoke_node.gd 的 10 处）。
# 商店这一簇的 19 个成员变量已收进下方的 ShopPanel 内部类（D2 第三步）。
# PrepShared 的共享状态池因此从 110 个降到 91 个，商店状态的归属一眼可见。
# 引用统一改成 _shop.xxx（全仓 133 处，映射表见 ShopPanel 类末尾的注释）。
# 商店面板现在是独立文件里的 Control 节点（scenes/prep/panels/ShopPanel.gd）。
# 它在 _enter_tree 时被 add_child 进来 —— 见本文件的 _ready/_enter_tree。
var _shop: ShopPanelScript = ShopPanelScene.instantiate()

# 左侧羁绊面板（含黄金祭坛/慷慨命运两个按钮）。与 _shop 同一套结构。
var _synergy: SynergyPanelScript = SynergyPanelScene.instantiate()

# 战力推荐与上一场战报。纯显示，不发信号。
var _stats: BattleStatsPanelScript = BattleStatsPanelScene.instantiate()

# 宝物三选一浮层与已持有 logo 栏。
var _treasure: TreasureChoicePanelScript = TreasureChoicePanelScene.instantiate()

# 棋盘与待命区。原 class BoardPanel 的 17 个字段已并入这个节点。
var _board_hud: BoardHudScript = BoardHudScene.instantiate()

# ---------------------------------------------------------------------------
# 商店这一簇的状态与节点引用（D2 第三步）。
#
# 做成**内部类**而不是独立文件：DragButton / SellDropPanel 都是本文件的内部类，
# 独立文件要引用它们就得 preload PrepShared，而 PrepShared 又要 preload 它 ——
# 循环依赖。退而用无类型 Array 的话，_shop.buttons 的静态类型会丢，
# 二十来处调用点全部退化成 Variant。内部类两头都保住。
var _merc_scroll: ScrollContainer
var _merc_panel: VBoxContainer
var _merc_overlay: PanelContainer
var _merc_overlay_grid: GridContainer
var _merc_count_label: Label
var _merc_button: Button
var _merc_picker_open := false
var _team_mercs_overlay: PanelContainer
var _team_mercs_viewport: SubViewport
var _team_mercs_stage_root: Node3D
var _team_mercs_empty_label: Label
var _team_mercs_render_timer: Timer
var _team_mercs_open := false
var _team_mercs_stage_signature := "unset"
# 详情浮层的节点与状态都归 _overlay 管；这两个 var 保留是因为构建代码要先造节点，
# 造完再 bind 给它。
var _detail: PopupPanel
var _detail_text: RichTextLabel
var _overlay := PrepDetailOverlay.new()
var _active_drag_payload: Dictionary = {}   # for snap-to-nearest-cell on release
var _drop_consumed := false
var _battle_launch_emitted := false
func _board_perspective_point(u: float, v: float, board_size: Vector2) -> Vector2:
	var v_fore := v / (1.0 + board_foreshorten * (1.0 - v))
	var top := board_top_left.lerp(board_top_right, u)
	var bottom := board_bottom_left.lerp(board_bottom_right, u)
	var normalized := top.lerp(bottom, v_fore)
	return normalized * board_size

func _board_cell_quad(index: int, board_size: Vector2) -> PackedVector2Array:
	var column := index % GameConstants.BOARD_COLUMNS
	var row := floori(float(index) / float(GameConstants.BOARD_COLUMNS))
	var u0 := float(column) / float(GameConstants.BOARD_COLUMNS)
	var u1 := float(column + 1) / float(GameConstants.BOARD_COLUMNS)
	var v0 := float(row) / float(GameConstants.BOARD_ROWS)
	var v1 := float(row + 1) / float(GameConstants.BOARD_ROWS)
	return PackedVector2Array([
		_board_perspective_point(u0, v0, board_size),
		_board_perspective_point(u1, v0, board_size),
		_board_perspective_point(u1, v1, board_size),
		_board_perspective_point(u0, v1, board_size),
	])

# Cross-layer hooks keep the original single-instance method dispatch intact.
func _load_board_art_texture() -> Texture2D:
	return null
func _can_drop_to_sell(data: Variant) -> bool:
	return false

func _has_any_board_unit() -> bool:
	return false

func _first_empty_board_slot() -> int:
	return 0
func _merge_three_into_cell(target: Dictionary, incoming: Dictionary, excluded_board: Array = [], excluded_bench: Array = []) -> bool:
	return false

func _take_extra_merge_piece(id: String, star: int, excluded_board: Array, excluded_bench: Array) -> Dictionary:
	return {}

func _unique_king_growth_score(d: Dictionary) -> float:
	return 0.0
func _sell_refund_for_cell(cell: Dictionary) -> int:
	return 0

func _roll_shop_tier(rng: RandomNumberGenerator) -> int:
	return 0

func _shop_unit_cost(unit_def: Dictionary) -> int:
	return 0
func _format_treasure_detail(t: Dictionary) -> String:
	return ""


# ─── 抽象桩 ─────────────────────────────────────────────────────────────────
#
# D2 步骤 6′：这一层原本有 44 个只写 pass 的桩 —— 它们是给内部类和基类代码
# 「按名字调用子类方法」用的占位。五个面板与四个内部类搬走之后，
# 其中 26 个已经没有任何调用点，删掉了。
#
# 剩下这 18 个是编译器点名要留的：本层或 PrepBoardModels/PrepUI 里仍有直接调用，
# 而实现在更派生的层。它们是继承链还没拆干净的直接证据 ——
# 每少一个，就说明又有一块行为不再需要「父类声明、子类实现」这种绕法。
func _auto_combine_all() -> void:
	pass
func _buy_or_merge_shop_to_bench(shop_index: int, bench_index: int) -> void:
	pass
func _claim_pending_treasure_round() -> void:
	pass
func _on_bench_pressed(index: int) -> void:
	pass

func _on_board_pressed(index: int) -> void:
	pass

func _on_generous_fate_gamble() -> void:
	pass

func _on_golden_altar() -> void:
	pass

func _on_hire_mercenary(index: int) -> void:
	pass
func _on_refresh_shop() -> void:
	pass

func _on_start_battle() -> void:
	pass

func _on_start_battle_input_down() -> void:
	pass

func _pick_treasure(tid: String) -> void:
	pass
func _set_stats_group(group: String) -> void:
	pass
func _show_bench_detail(index: int) -> void:
	pass
func _show_board_detail(index: int) -> void:
	pass

func _show_linkage_detail(link_id: String) -> void:
	pass

func _show_shop_detail(index: int) -> void:
	pass

func _sync_prep_board_readability_geometry() -> void:
	pass

func _sync_prep_board_readability_state() -> void:
	pass
