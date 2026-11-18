extends Node
## 视觉样片：战斗左下角钱袋（BattlePurse）——杀怪跳字、连杀合并、前三名奖励金币飞进钱袋。
## 不进对局、不碰存档。用法：
##   Godot --path . --resolution 1600x720 res://scenes/debug/BattlePurseReview.tscn -- --out <新目录>
## 打怪局（m_*.png，右边清路榜）和 PvP（v_*.png，左边伤害榜）各一段。

const Purse := preload("res://effects/runtime/presentation/BattlePurse.gd")
const LaneBoard := preload("res://effects/runtime/presentation/LaneClearBoard.gd")
const DamageBoard := preload("res://effects/runtime/presentation/DamageLeaderboard.gd")
const PVE_BG := "res://assets/board/2_5d/battlefield_jungle_pve.png"
const PVP_BG := "res://assets/board/2_5d/battlefield_snow_pvp.png"
const LOCAL_SLOT := 2
## 单人局右上角只有视角按钮（右边距 16、宽 68、y 54 高 68），清路榜接在它下面。
const LANE_POS := Vector2(1600.0 - 16.0 - 120.0 + 26.0, 54.0 + 68.0 + 8.0)
const PURSE_MARGIN := 16.0
const PLAYERS := [
	{"slot": 0, "name": "阿文", "avatar": "preset:avatar_003", "frame": "preset:avatar_frame_shop_02", "team": 0},
	{"slot": 1, "name": "小静", "avatar": "preset:avatar_007", "frame": "preset:frame_default", "team": 0},
	{"slot": 2, "name": "Leno", "avatar": "preset:avatar_012", "frame": "preset:avatar_frame_7day_01", "team": 0},
	{"slot": 3, "name": "KaiTheGreat", "avatar": "preset:avatar_005", "frame": "preset:avatar_frame_shop_04", "team": 1},
	{"slot": 4, "name": "月影", "avatar": "preset:avatar_009", "frame": "preset:avatar_frame_shop_05", "team": 1},
	{"slot": 5, "name": "Bot·狼", "avatar": "preset:avatar_002", "frame": "preset:frame_default", "team": 1},
]

var _out := ""
var _bg: TextureRect


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--out":
			_out = ProjectSettings.globalize_path(args[i + 1])
	# 样片按中文出（只改本次进程的语言，不写存档）。
	LocaleManager.set_locale("zh")
	var root := Control.new()
	root.size = Vector2(1600, 720)
	add_child(root)
	_bg = TextureRect.new()
	_bg.size = root.size
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	root.add_child(_bg)
	_set_bg(PVE_BG)

	# —— 打怪局 ——
	var purse = Purse.new()
	purse.position = Vector2(PURSE_MARGIN, 720.0 - PURSE_MARGIN - Purse.PURSE_SIZE.y)
	root.add_child(purse)
	var lane = LaneBoard.new()
	lane.position = LANE_POS
	root.add_child(lane)
	await _frames(10)
	await _capture("m1_start")
	purse.add_kill(15)
	await _wait(0.2)
	await _capture("m2_kill")
	await _wait(1.6)
	# 0.3 秒里连杀三只：合并成一个「+45」。
	for i in 3:
		purse.add_kill(15)
		await _wait(0.1)
	await _wait(0.15)
	await _capture("m3_combo")
	await _wait(1.6)
	# Kai 第一个清完，自己第二个清完 → 第二名 30 金从绶带飞进钱袋。
	lane.update_entries(_lane_entries({3: 18.4}), true)
	await _wait(0.6)
	lane.update_entries(_lane_entries({3: 18.4, 2: 19.9}), true)
	await _wait(0.6)
	purse.fly_in(lane.anchor_global(LOCAL_SLOT), 30, "清路第 2 名")
	await _wait(0.42)
	await _capture("m4_fly_mid")
	await _wait(0.5)
	await _capture("m5_arrive")
	await _wait(1.8)
	await _capture("m6_final")
	lane.queue_free()

	# —— PvP ——
	_set_bg(PVP_BG)
	purse.reset()
	var board = DamageBoard.new()
	board.position = Vector2(8, 141)
	root.add_child(board)
	var damage := [12500, 9100, 16800, 10400, 3000, 2500]
	board.update_entries(_damage_entries(damage), LOCAL_SLOT, 12, false, true)
	purse.add_kill(40)
	purse.add_kill(30)
	await _wait(1.8)
	purse.fly_in(board.anchor_global(LOCAL_SLOT), 150, "伤害第 1 名")
	await _wait(0.42)
	await _capture("v1_fly_mid")
	await _wait(0.5)
	await _capture("v2_arrive")
	await _wait(1.8)
	await _capture("v3_final")
	print("BATTLE_PURSE_REVIEW PASS total=%d" % purse.total())
	get_tree().quit()


func _set_bg(path: String) -> void:
	if ResourceLoader.exists(path):
		_bg.texture = load(path)


func _lane_entries(clear: Dictionary) -> Array:
	var out: Array = []
	for p in PLAYERS:
		var e: Dictionary = (p as Dictionary).duplicate()
		e["clear_sec"] = float(clear.get(int(e.slot), -1.0))
		out.append(e)
	return out


func _damage_entries(damage: Array) -> Array:
	var out: Array = []
	for p in PLAYERS:
		var e: Dictionary = (p as Dictionary).duplicate()
		e["damage"] = damage[int(e.slot)]
		out.append(e)
	return out


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	if _out.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_out)
	get_viewport().get_texture().get_image().save_png(_out.path_join(name + ".png"))
