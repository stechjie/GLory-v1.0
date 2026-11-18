extends Node
## 视觉样片：战斗里两块前三名榜在真实战场底图上的样子：
##   PvP 左边伤害木牌榜 DamageLeaderboard（p_*.png），打怪 / Boss 右边清路签 LaneClearBoard（l_*.png）。
## 不进对局、不碰存档。用法：
##   Godot --path . --resolution 1600x720 res://scenes/debug/DamageLeaderboardReview.tscn -- --out <新目录>

const Board := preload("res://effects/runtime/presentation/DamageLeaderboard.gd")
const LaneBoard := preload("res://effects/runtime/presentation/LaneClearBoard.gd")
const BG_PATH := "res://assets/board/2_5d/battlefield_jungle_pve.png"
const LOCAL_SLOT := 2

var _out := ""
var _board: Control
var _damage := [12500, 9100, 4000, 10400, 3000, 2500]
var _clear_sec := [-1.0, -1.0, -1.0, -1.0, -1.0, -1.0]
## 右上角那列按钮（BattleScreen：右边距 16、宽 120）。视角按钮 y 54 高 68；组队局语音按钮从 y 128 起、每个间隔 64、高 56。
const BUTTON_COLUMN_X := 1600.0 - 16.0 - 120.0
const SOLO_LANE_TOP := 54.0 + 68.0 + 8.0
const TEAM_LANE_TOP := 128.0 + 64.0 * 2.0 + 56.0 + 8.0
const PLAYERS := [
	{"slot": 0, "name": "阿文", "avatar": "preset:avatar_003", "frame": "preset:avatar_frame_shop_02", "team": 0},
	{"slot": 1, "name": "小静", "avatar": "preset:avatar_007", "frame": "preset:frame_default", "team": 0},
	{"slot": 2, "name": "Leno", "avatar": "preset:avatar_012", "frame": "preset:avatar_frame_7day_01", "team": 0},
	{"slot": 3, "name": "KaiTheGreat", "avatar": "preset:avatar_005", "frame": "preset:avatar_frame_shop_04", "team": 1},
	{"slot": 4, "name": "月影", "avatar": "preset:avatar_009", "frame": "preset:avatar_frame_shop_05", "team": 1},
	{"slot": 5, "name": "Bot·狼", "avatar": "preset:avatar_002", "frame": "preset:frame_default", "team": 1},
]


func _ready() -> void:
	call_deferred("_run")


func _entries() -> Array:
	var out: Array = []
	for p in PLAYERS:
		var e: Dictionary = (p as Dictionary).duplicate()
		e["damage"] = _damage[int(e.slot)]
		e["clear_sec"] = _clear_sec[int(e.slot)]
		out.append(e)
	return out


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--out":
			_out = ProjectSettings.globalize_path(args[i + 1])
	var root := Control.new()
	root.size = Vector2(1600, 720)
	add_child(root)
	var bg := TextureRect.new()
	bg.size = root.size
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	if ResourceLoader.exists(BG_PATH):
		bg.texture = load(BG_PATH)
	root.add_child(bg)
	_board = Board.new()
	# 和原来单人伤害木牌同一个起点（BattleCombatFeedback：x 8、y 141，1600×720 下 factor = 1）。
	_board.position = Vector2(8, 141)
	root.add_child(_board)
	_board.rewards = [150, 100, 50]
	_board.update_entries(_entries(), LOCAL_SLOT, 12, false)
	await _frames(10)
	await _capture("p1_start")
	# 月影冲上来，超过 Kai 和小静，抢到第二。
	_damage[4] = 11000
	_board.update_entries(_entries(), LOCAL_SLOT, 12, true)
	await get_tree().create_timer(0.12).timeout
	await _capture("p2_overtake_mid")
	await get_tree().create_timer(0.6).timeout
	await _capture("p3_overtake_done")
	# 月影再超阿文，当上第一：火跟过去、升到第二档。
	_damage[4] = 16200
	_damage[0] = 13100
	_board.update_entries(_entries(), LOCAL_SLOT, 12, true)
	await get_tree().create_timer(0.10).timeout
	await _capture("p4_new_leader_mid")
	await get_tree().create_timer(0.8).timeout
	await _capture("p5_new_leader")
	# 本地玩家打进前三，底下那块「你 · 第 N 名」应该消失。
	_damage[2] = 12000
	_board.update_entries(_entries(), LOCAL_SLOT, 12, true, true)
	await get_tree().create_timer(0.8).timeout
	await _capture("p6_me_in_top3")
	_board.queue_free()

	# 打怪 / Boss：右边清路头像列，接在右上角按钮下面。按钮用半透明灰块占位（样片不搭真按钮）。
	var ghosts: Array = []
	ghosts.append(_ghost(root, Rect2(BUTTON_COLUMN_X + 52, 54, 68, 68), "视角"))
	var lane = LaneBoard.new()
	# 单人局只有视角按钮（68 宽、贴右），头像列和它对齐中线。
	lane.position = Vector2(BUTTON_COLUMN_X + (120.0 - 68.0) * 0.5, SOLO_LANE_TOP)
	root.add_child(lane)
	lane.update_entries(_entries(), false)
	await _frames(10)
	await _capture("l1_empty")
	_clear_sec[3] = 18.4
	lane.update_entries(_entries(), true)
	await get_tree().create_timer(0.15).timeout
	await _capture("l2_first_clear_mid")
	await get_tree().create_timer(0.8).timeout
	await _capture("l3_first_clear")
	_clear_sec[4] = 19.7
	_clear_sec[0] = 21.2
	_clear_sec[2] = 23.0
	lane.update_entries(_entries(), true)
	await get_tree().create_timer(0.9).timeout
	await _capture("l4_three_cleared")
	# 组队局：多了三个语音按钮，整列往下挪。
	for i in 3:
		ghosts.append(_ghost(root, Rect2(BUTTON_COLUMN_X, 128 + 64 * i, 120, 56), "语音"))
	lane.position = Vector2(BUTTON_COLUMN_X, TEAM_LANE_TOP)
	await _frames(3)
	await _capture("l5_team_mode")
	print("DAMAGE_LEADERBOARD_REVIEW PASS")
	get_tree().quit()


func _ghost(root: Control, rect: Rect2, text: String) -> Panel:
	var panel := Panel.new()
	panel.position = rect.position
	panel.size = rect.size
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.35)
	style.border_color = Color(1, 1, 1, 0.5)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = text + "（占位）"
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 12)
	panel.add_child(label)
	root.add_child(panel)
	return panel


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	if _out.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_viewport().get_texture().get_image().save_png(_out.path_join(name + ".png"))
