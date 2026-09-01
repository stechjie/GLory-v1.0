extends Node

# Final-round horizontal light-wall contract. It is intentionally separate
# from battle_lane_barrier_check: the latter protects the user-approved full-
# height vertical crystals and must not inherit final-only rules.

const CheckHarness := preload("res://tools/CheckHarness.gd")
const WallScript := preload("res://scenes/battle/FinalLaneLightWall2D.gd")
const CHECK_NAME := "battle_final_lane_wall"
const MAX_SCREEN_HEIGHT_PX := 20.0
const STEADY_ALPHA_MIN := 0.25
const STEADY_ALPHA_MAX := 0.45

var _h: RefCounted


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_h = CheckHarness.new(CHECK_NAME)
	_check_geometry_and_alpha()
	_check_arena_wiring()
	await _check_release()
	_h.finish(get_tree())


func _check_geometry_and_alpha() -> void:
	var texture: Texture2D = WallScript.WALL_TEXTURE
	if not _h.expect(texture != null, "wall_texture_missing", "决赛横向光墙贴图不存在"):
		return
	var effective_height := float(texture.get_height()) * WallScript.SCREEN_HEIGHT_SCALE
	_h.expect(effective_height <= MAX_SCREEN_HEIGHT_PX,
		"wall_too_thick",
		"决赛光墙有效高度 %.2f px，超过 %.1f px；会横切角色主体" % [effective_height, MAX_SCREEN_HEIGHT_PX])
	_h.expect(WallScript.STEADY_ALPHA >= STEADY_ALPHA_MIN and WallScript.STEADY_ALPHA <= STEADY_ALPHA_MAX,
		"wall_alpha_out_of_range",
		"决赛光墙常驻 alpha %.3f 不在 %.2f-%.2f" % [WallScript.STEADY_ALPHA, STEADY_ALPHA_MIN, STEADY_ALPHA_MAX])
	_h.note("决赛光墙保持 1024 px 横向源宽，有效高度 %.2f px，常驻 alpha %.2f"
		% [effective_height, WallScript.STEADY_ALPHA])


func _check_arena_wiring() -> void:
	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd")
	if not _h.expect(not source.is_empty(), "arena_unreadable", "读不到 BattleArena.gd"):
		return
	var final_stmt := "wall.scale = Vector2(maxf(0.1, p_left.distance_to(p_right) / 1024.0), FinalLaneLightWall2D.SCREEN_HEIGHT_SCALE)"
	_h.expect(source.contains(final_stmt),
		"final_wall_scale_not_wired",
		"BattleArena 没有同时保留完整横向宽度并使用决赛光墙高度常量")
	# Guard the accepted regular-crystal contract against collateral edits.
	var crystal_stmt := "barrier.scale = Vector2(0.42, maxf(0.1, (bot_y - top_y) / 512.0))"
	_h.expect(source.contains(crystal_stmt),
		"regular_crystal_changed",
		"普通竖向晶柱高度公式被决赛光墙改动波及")


func _check_release() -> void:
	var wall: Node2D = WallScript.new()
	add_child(wall)
	await get_tree().process_frame
	wall.play_loop()
	_h.expect(wall.visible, "wall_loop_hidden", "play_loop 后决赛光墙不可见")
	wall.play_release()
	await get_tree().create_timer(WallScript.RELEASE_SEC + 0.12).timeout
	_h.expect(wall.is_released() and not wall.visible,
		"wall_release_incomplete", "决赛光墙释放动画结束后没有隐藏")
	wall.queue_free()
