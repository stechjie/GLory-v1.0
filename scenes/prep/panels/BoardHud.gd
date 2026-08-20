extends Control

# 备战界面的**棋盘与待命区** —— D2 步骤 4′ 的最后一个面板。
#
# 这是四个面板里最难拆的一个：棋盘是整个界面的核心，
# 它同时连着 2D 按钮层、3D 模型层和拖放系统。
#
# 划分依据和前三个一致 —— **面板管「看」与「选」，宿主管「交易」**：
#   * 搬进来：格子刷新、样式、拖放高亮、格子下方的名字标签、选中态
#   * 留在宿主：_on_board_pressed / _on_bench_pressed
#     那两个函数是「按当前选中态决定做哪笔交易」的调度 ——
#     它们要同时看商店的选中态、要调 6 个 _move_or_merge_* / _buy_or_merge_*，
#     那是宿主的职责，不是棋盘的。
#
# 几何函数（_board_plane_world_pos / _board_perspective_point / _board_cell_quad）
# **刻意不搬**：它们被 PrepBoardModels 的 3D 层用了 11 处、被 PrepShared 的
# 命中判定用了 4 处。搬过来会把 3D 层反过来依赖这个面板，方向就错了。
# 需要用到的那一个以 Callable 注入。

const BoardReadabilityLayerScene := preload("res://effects/runtime/presentation/BoardReadabilityLayer.tscn")
const BoardCellButton := preload("res://scenes/prep/PrepBoardCellButton.gd")
const BenchCellButton := preload("res://scenes/prep/PrepBenchCellButton.gd")
const RelationProgressOverlay := preload("res://scenes/prep/PrepRelationProgressOverlay.gd")
const PrepWidgets := preload("res://scenes/prep/PrepWidgets.gd")

signal visuals_dirty(what: String)   # 3D 模型层/可读性层需要跟着刷新（board/standby/readability）
signal state_changed                 # 需要整屏刷新

# 以 Callable 注入而不是持有宿主引用：面板只需要「算一个格子的多边形」和
# 「取一个格子的显示用定义」这两件事，没必要知道宿主是谁。
var display_unit_def: Callable
var cell_quad: Callable

# 这两个在 PrepShared 上是 @export（编辑器里可调）。搬过来会丢掉 inspector 配置，
# 所以留在原处，由 setup() 把当前值传进来。
var cell_size := Vector2(149.5, 84.0)
var board_cell_rest_line := Color(0.48, 1.0, 0.92, 0.55)


func setup(p_display_unit_def: Callable, p_cell_quad: Callable,
		p_cell_size: Vector2, p_rest_line: Color) -> void:
	display_unit_def = p_display_unit_def
	cell_quad = p_cell_quad
	cell_size = p_cell_size
	board_cell_rest_line = p_rest_line


# --- 原 PrepShared 顶层的两个棋盘量（全仓只有本面板在用）--------------------


# --- 原 PrepShared.BoardPanel 的字段 -----------------------------------------
var grid: Control
var bench_row: Control
var standby_frame: Control
var buttons: Array[BoardCellButton] = []
var readability_layer: BoardReadabilityLayer
var relation_overlays: Array[RelationProgressOverlay] = []
var cell_captions: Array[Label] = []   # 棋盘格子下方的「名字 ★星级」标签（有棋子才显示）
var bench_buttons: Array[BenchCellButton] = []
var bench_card_labels: Array[Label] = []
var empty_style: StyleBoxFlat
var hover_style: StyleBoxFlat
var occupied_style: StyleBoxFlat
var drop_style: StyleBoxFlat
var drop_highlight_active := false
var drop_hover_index := -1
var standby_drop_highlight_active := false
var standby_drop_hover_index := -1


# --- 搬过来的成员 ---
var _selected_board := -1
var _selected_bench := -1


# 原 _refresh_board（PrepUI.gd）

func refresh_board() -> void:
	for i in buttons.size():
		var btn := buttons[i]
		var cell = GameState.board_slots[i]
		if cell == null:
			btn.text = ""
			btn.drag_payload = {}
			btn.add_theme_stylebox_override("normal", empty_style)
		else:
			btn.text = ""
			btn.drag_payload = {"kind": "board", "index": i}
			btn.add_theme_stylebox_override("normal", occupied_style)
		btn.set_deployment_highlight(drop_highlight_active, i == drop_hover_index)
		btn.add_theme_stylebox_override("hover", occupied_style if cell != null else empty_style)
		btn.add_theme_stylebox_override("pressed", occupied_style if cell != null else empty_style)
		btn.add_theme_stylebox_override("focus", occupied_style if cell != null else empty_style)
		btn.modulate = Color.WHITE
		if i < relation_overlays.size():
			relation_overlays[i].set_relation_states(RaceRelationService.visual_states_for_cell(cell))
		if i < cell_captions.size():
			var caption := cell_captions[i]
			if cell == null:
				caption.visible = false
			else:
				caption.text = cell_caption_text(cell)
				caption.visible = true
	visuals_dirty.emit("board")
	visuals_dirty.emit("readability")



# 原 _refresh_bench（PrepUI.gd）

func refresh_bench() -> void:
	for i in bench_buttons.size():
		var btn := bench_buttons[i]
		var name_label := bench_card_labels[i]
		var cell = GameState.bench_slots[i]
		btn.disabled = false
		btn.text = ""
		if cell == null:
			PrepWidgets.apply_empty_button_styles(btn)
			btn.text = ""
			btn.tooltip_text = tr("ui_bench_slot")
			btn.set_meta("drag_preview_text", "")
			btn.drag_payload = {}
			name_label.text = ""
			name_label.visible = false
			btn.modulate = Color.WHITE
		else:
			PrepWidgets.apply_empty_button_styles(btn)
			var d: Dictionary = cell.def
			var unit_name := PrepWidgets.unit_name(d)
			btn.tooltip_text = unit_name
			btn.set_meta("drag_preview_text", "%s  %d★" % [unit_name, int(cell.get("star", 1))])
			btn.drag_payload = {} if GameState.tutorial_mode and TutorialMode.step == TutorialMode.Step.BUY_3 else {"kind": "bench", "index": i}
			name_label.text = cell_caption_text(cell)
			name_label.visible = true
		btn.set_standby_highlight(standby_drop_highlight_active, i == standby_drop_hover_index)
		btn.modulate = Color(1, 0.92, 0.55) if i == _selected_bench else Color.WHITE
	visuals_dirty.emit("standby")


# 原 _setup_board_cell_styles（PrepUI.gd）

func setup_cell_styles() -> void:
	empty_style = StyleBoxFlat.new()
	hover_style = StyleBoxFlat.new()
	occupied_style = StyleBoxFlat.new()
	drop_style = StyleBoxFlat.new()
	empty_style.bg_color = Color.TRANSPARENT
	hover_style.bg_color = Color.TRANSPARENT
	occupied_style.bg_color = Color.TRANSPARENT
	drop_style.bg_color = Color(0.38, 0.86, 0.78, 0.085)



# 原 _set_board_drop_hover（PrepBoardController.gd）

func set_board_drop_hover(board_index: int) -> void:
	var next_index := board_index if drop_highlight_active else -1
	if drop_hover_index == next_index:
		return
	drop_hover_index = next_index
	for index in buttons.size():
		buttons[index].set_deployment_highlight(
			drop_highlight_active,
			index == drop_hover_index
		)
	visuals_dirty.emit("readability")



# 原 _set_standby_drop_hover（PrepBoardController.gd）
func set_standby_drop_hover(bench_index: int) -> void:
	var next_index := bench_index if standby_drop_highlight_active else -1
	if standby_drop_hover_index == next_index:
		return
	standby_drop_hover_index = next_index
	for index in bench_buttons.size():
		bench_buttons[index].set_standby_highlight(
			standby_drop_highlight_active,
			index == standby_drop_hover_index
		)



# 原 _cell_caption_text（PrepUI.gd）
func cell_caption_text(cell: Dictionary) -> String:
	# 一行：名字 + ★（星数）
	# Callable 的返回值是 Variant，:= 推断不出来（GDScript 会把它当错误）。
	var d: Dictionary = display_unit_def.call(cell)
	var star := clampi(int(cell.get("star", 1)), 1, GameState.MAX_UNIT_STAR)
	return "%s %s" % [PrepWidgets.unit_name(d), "★".repeat(star)]



# 原 _board_grid_size（PrepShared.gd）
func grid_size() -> Vector2:
	return Vector2(
		cell_size.x * float(GameConstants.BOARD_COLUMNS),
		cell_size.y * float(GameConstants.BOARD_ROWS)
	)



# 原 _board_player_color（PrepShared.gd）

func player_color() -> Color:
	if NetworkService.team_active and NetworkService.team_local_slot >= 0:
		return GameConstants.team_slot_color(NetworkService.team_local_slot)
	return board_cell_rest_line
