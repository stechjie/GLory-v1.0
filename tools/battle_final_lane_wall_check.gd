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
	# Guard the accepted regular-ward contract against collateral edits.
	#
	# 口径随第 1 条（2026-10-04 隔离墙重设计）更新，**不是放松**：
	# 旧实现是 `BattleLaneBarrier2D` 的贴图晶柱，靠
	# `barrier.scale = Vector2(0.42, maxf(0.1, (bot_y - top_y) / 512.0))` 铺满高度。
	# 第 1 条把它换成原生 3D 符文墙后，"隔断必须铺满整条边界、不许再被缩短"
	# 这条**用户实看定下的合同**改由"两个端点必须取自整幅战场可视上下边界"承载。
	# 只查 `fit_between(` 不够 —— 传两个挨在一起的点也过，必须证到端点来源。
	var span := _regular_ward_span_contract(source)
	_h.expect(bool(span.get("ok", false)), "regular_ward_span_broken", str(span.get("detail", "")))
	# 判据自检：直接调那个纯函数喂合成源码。不这样验，就等于让外层
	# `if not _h.expect(source.is_empty())` 的守卫替它背书 —— 把内层整段删掉也照样绿。
	for row in _span_contract_probes():
		_h.expect(bool(row["ok"]), str(row["name"]), str(row["detail"]))


# 普通分路墙"铺满边界、不许缩短"的合同（说明见 _check_arena_wiring）。
# 抽成 static 纯函数，门禁才能直接喂合成源码验它自己的判别力。
static func _regular_ward_span_contract(source: String) -> Dictionary:
	if source.is_empty():
		return {"ok": false, "detail": "BattleArena.gd 读不到"}
	var body := _update_3v3_dividers_body(source)
	if body.is_empty():
		return {"ok": false, "detail": "找不到 _update_3v3_dividers()"}
	# 只取"普通分路"那一支：决赛那一支在上面已单独守过。
	var nl := String.chr(10)
	var cut := body.find("if _3v3_barriers.is_empty():")
	if cut < 0:
		return {"ok": false, "detail": "找不到普通分路墙分支（_3v3_barriers.is_empty() 守卫）"}
	var regular := body.substr(cut)
	var rules := [
		["var p_top := _sim_to_world_pos(Vector2(sx, visual_min.y), false)",
			"普通分路墙上端点必须取自 visual_min.y（整幅战场上边界）"],
		["var p_bot := _sim_to_world_pos(Vector2(sx, visual_max.y), false)",
			"普通分路墙下端点必须取自 visual_max.y（整幅战场下边界）"],
		["barrier.fit_between(p_top, p_bot)",
			"普通分路墙必须按这两个端点铺满整条边界"],
	]
	for rule in rules:
		if not regular.contains(str(rule[0])):
			return {"ok": false, "detail": str(rule[1])}
	# "不许缩短"：普通分支里不允许再出现任何 barrier.scale 赋值。
	if regular.contains("barrier.scale"):
		return {"ok": false, "detail": "普通分路墙又出现 barrier.scale 赋值 —— 会把铺满的高度缩短"}
	return {"ok": true, "detail": ""}


# 取 `_update_3v3_dividers()` 的函数体（到下一个顶层 `func ` 为止）。
# 换行用 chr(10) 显式拼：本环境写文件会把字符串里的 `\n` 转义改坏。
static func _update_3v3_dividers_body(source: String) -> String:
	var nl := String.chr(10)
	var start := source.find("func _update_3v3_dividers(")
	if start < 0:
		return ""
	var rest := source.substr(start)
	var next := rest.find(nl + "func ", 4)
	return rest.substr(0, next) if next > 0 else rest


# 合成正例 / 反例，用来证明上面那条合同的判别力。
static func _span_contract_probes() -> Array:
	var nl := String.chr(10)
	var head := "func _update_3v3_dividers() -> void:" + nl + "if _3v3_barriers.is_empty():" + nl
	var top := "var p_top := _sim_to_world_pos(Vector2(sx, visual_min.y), false)" + nl
	var bot := "var p_bot := _sim_to_world_pos(Vector2(sx, visual_max.y), false)" + nl
	var fit := "barrier.fit_between(p_top, p_bot)" + nl
	var good := head + top + bot + fit
	var shrunk := head + top + bot + "barrier.fit_between(p_top, p_top.lerp(p_bot, 0.6))" + nl
	var scaled := head + top + bot + fit + "barrier.scale = Vector2(0.42, maxf(0.1, (bot_y - top_y) / 512.0))" + nl
	var wrong_end := head + "var p_top := _sim_to_world_pos(Vector2(sx, visual_max.y), false)" + nl + bot + fit
	return [
		{"name": "probe_span_ok", "ok": bool(_regular_ward_span_contract(good).get("ok", false)),
			"detail": "合成正例（两端点齐全 + fit_between）必须通过"},
		{"name": "probe_span_shrunk", "ok": not bool(_regular_ward_span_contract(shrunk).get("ok", true)),
			"detail": "合成反例（把两端点缩到 60%）必须被拒"},
		{"name": "probe_span_scaled", "ok": not bool(_regular_ward_span_contract(scaled).get("ok", true)),
			"detail": "合成反例（补一条 barrier.scale 缩短高度）必须被拒"},
		{"name": "probe_span_wrong_end", "ok": not bool(_regular_ward_span_contract(wrong_end).get("ok", true)),
			"detail": "合成反例（上端点误用 visual_max）必须被拒"},
	]


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
