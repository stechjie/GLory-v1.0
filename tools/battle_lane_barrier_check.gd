extends Node
# 分路能量护栏（EnergyBarrierSegment，10-06 换掉旧符文墙）：铺满整条边界、按半场分队伍色、
# 解锁当帧整段消失、低画质退化、加载过场按住，以及策反后同帧开墙。
#
# 换实现时换了口径，没有放松：
#   * 旧墙「3 个网格 < 1000 三角面」→ 新护栏「绘制节点 ≤ 12、粒子总数 ≤ 48」（手机预算）。
#   * 旧墙「宽 ≤ 0.5、高 < 1.0」→ 新护栏「地面线宽 + 光带左右摆幅都留在分路缝里、柱高 ≤ 0.75」。
#   * 「一道墙 fit_between(p_top, p_bot)」→ 「上下两段 p_top→p_mid、p_mid→p_bot 合起来铺满」，
#     铺满的合同另在 battle_final_lane_wall_check 的 _regular_ward_span_contract 里证。
const CheckHarness := preload("res://tools/CheckHarness.gd")
const SEGMENT := preload("res://effects/battlefield/energy_barrier/EnergyBarrierSegment.tscn")
const Arena := preload("res://scenes/battle/BattleArena.gd")
const LANE_GAP_HALF_WIDTH := 0.25
const MAX_BARRIER_HEIGHT := 0.75
const MAX_GEOMETRY_NODES := 12
const MAX_PARTICLES := 48
var h: RefCounted
var release_count := 0


func _ready() -> void:
	call_deferred("run")


func run() -> void:
	h = CheckHarness.new("battle_lane_barrier")
	var wall: Node3D = SEGMENT.instantiate()
	add_child(wall)
	wall.release_finished.connect(func(): release_count += 1)
	wall.fit_between(Vector3(2, 0, -4), Vector3(2, 0, 4))
	h.expect(wall.position.is_equal_approx(Vector3(2, 0, 0)) and is_equal_approx(wall.barrier_length, 8.0), "full_length", "Segment must span both endpoints")
	h.expect(is_equal_approx(wall.get_node("BaseEnergyLine").scale.z, 8.0), "line_span", "Floor line must cover the whole segment length")
	h.expect(wall.get_node("BaseEnergyLine").mesh is PlaneMesh, "line_mesh_present", "BaseEnergyLine lost its PlaneMesh (whole floor line disappears)")

	# 足迹：不压到两侧分路里的单位，也不横切角色。
	var widest: float = wall.get_node("BaseEnergyLine").scale.x * 0.5
	var geometry := 0
	var particles := 0
	for child in wall.get_children():
		if child is GeometryInstance3D and child.visible:
			geometry += 1
		if child is GPUParticles3D:
			particles += (child as GPUParticles3D).amount
		if child.name.begins_with("EnergyRibbon"):
			var mat: ShaderMaterial = child.material_override
			widest = maxf(widest, float(mat.get_shader_parameter("weave_amp")) + float(mat.get_shader_parameter("width")) * 0.5)
	h.expect(widest <= LANE_GAP_HALF_WIDTH, "visual_footprint", "Barrier reaches %.2f m sideways, must stay within %.2f m of the boundary" % [widest, LANE_GAP_HALF_WIDTH])
	h.expect(float(wall.barrier_height) <= MAX_BARRIER_HEIGHT, "visual_height", "Barrier height %.2f m would cut across units (max %.2f)" % [wall.barrier_height, MAX_BARRIER_HEIGHT])
	h.expect(geometry <= MAX_GEOMETRY_NODES and particles <= MAX_PARTICLES, "geometry_budget", "Segment has %d draw nodes / %d particles (max %d / %d)" % [geometry, particles, MAX_GEOMETRY_NODES, MAX_PARTICLES])

	# 队伍颜色：根节点统一色要写到每一层，且各层自己的颜色不被改写。
	var line: ShaderMaterial = wall.get_node("BaseEnergyLine").material_override
	var own_line_color: Color = line.get_shader_parameter("color")
	wall.unify_color = true
	wall.color = Arena.LANE_BARRIER_TEAM_COLORS[GameConstants.TEAM_RED]
	var all_tinted := true
	for child in wall.get_children():
		if child is GeometryInstance3D and (child as GeometryInstance3D).material_override is ShaderMaterial:
			var mat: ShaderMaterial = (child as GeometryInstance3D).material_override
			all_tinted = all_tinted and bool(mat.get_shader_parameter("use_root_color")) \
				and Color(mat.get_shader_parameter("root_color")).is_equal_approx(wall.color)
	h.expect(all_tinted, "team_color_reaches_layers", "Team color must reach every glowing layer")
	h.expect(Color(line.get_shader_parameter("color")).is_equal_approx(own_line_color), "layer_color_kept", "Team color must not overwrite the layer's own color")
	h.expect(Arena.LANE_BARRIER_TEAM_COLORS[GameConstants.TEAM_RED].is_equal_approx(Color("f7937e"))
		and Arena.LANE_BARRIER_TEAM_COLORS[GameConstants.TEAM_BLUE].is_equal_approx(Color("6a9ade")), "team_colors_user_set", "Team colors must stay the ones the user picked (#f7937e / #6a9ade)")
	var red: Color = Arena.LANE_BARRIER_TEAM_COLORS[GameConstants.TEAM_RED]
	var blue: Color = Arena.LANE_BARRIER_TEAM_COLORS[GameConstants.TEAM_BLUE]
	h.expect(_same_colors(Arena.lane_barrier_half_colors(true, GameConstants.TEAM_RED), [blue, red])
		and _same_colors(Arena.lane_barrier_half_colors(true, GameConstants.TEAM_BLUE), [blue, red]), "pvp_half_colors", "PvP: blue team half (visual_min.y) blue, red team half red, same for every viewer")
	h.expect(_same_colors(Arena.lane_barrier_half_colors(false, GameConstants.TEAM_RED), [red, red])
		and _same_colors(Arena.lane_barrier_half_colors(false, GameConstants.TEAM_BLUE), [blue, blue]), "pve_half_colors", "PvE: whole boundary in the local team's color")

	wall.play_loop()
	wall.set_low_quality(true)
	var ribbons_on := 0
	for child in wall.get_children():
		if child.name.begins_with("EnergyRibbon") and child.visible:
			ribbons_on += 1
	h.expect(ribbons_on <= 2 and not wall.get_node("SparkParticles").visible and not wall.get_node("VerticalBeamParticles").visible, "low_quality", "Low tier keeps at most 2 ribbons and no particles")
	wall.set_low_quality(false)
	h.expect(wall.get_node("SparkParticles").visible and wall.get_node("SparkParticles").emitting, "quality_restore", "Tier must restore particles")
	await get_tree().create_timer(1.0).timeout
	h.expect(is_zero_approx(float(line.get_shader_parameter("emphasis"))), "opening_settles", "Opening emphasis must settle")
	wall.play_release()
	wall.play_release()
	h.expect(wall.is_released(), "release_state", "Release state should change immediately")
	h.expect(not wall.visible, "release_clears_path", "Entire segment must disappear on the exact unlock frame")
	await get_tree().process_frame
	h.expect(not wall.visible and not wall.is_processing() and not wall.get_node("SparkParticles").emitting, "release_hides", "Release must hide, stop processing and stop particles")
	h.expect(release_count == 1, "one_signal", "Duplicate release must emit only once")
	wall.play_loop()
	h.expect(wall.visible and not wall.is_released(), "restart", "Replay restart must show the segment again")
	wall.fit_between(Vector3(2, 0, 4), Vector3(2, 0, -4))
	h.expect(is_equal_approx(wall.barrier_length, 8.0) and wall.position.is_equal_approx(Vector3(2, 0, 0)), "reverse_view", "Other-side view must keep the span")

	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd")
	h.expect(source.contains("_battle_3d_world.add_child(barrier)"), "world_depth", "Barrier must use production 3D depth")
	h.expect(source.contains("min_half.fit_between(p_top, p_mid)") and source.contains("max_half.fit_between(p_mid, p_bot)"), "real_endpoints", "Production must supply both halves' world endpoints")
	h.expect(source.contains("var split_y := clampf(SIM_H * 0.5, visual_min.y, visual_max.y)" + String.chr(10) + "\tfor i in BATTLE_3V3_BOUNDS.size():"), "split_at_half_line", "Halves must meet on the same half line as the board shading")
	h.expect(source.contains("min_half.play_release()" + String.chr(10) + "\t\t\tmax_half.play_release()"), "halves_release_together", "Both halves of a boundary must open on the same frame")
	h.expect(source.contains("barrier.color = half_colors[half]"), "team_colors_wired", "Production must color each half by its team")
	h.expect(source.contains("BattleSimShared._boundary_released(_state, boundary_index)"), "gameplay_owner", "Release must remain owned by shared simulation")
	var replay_screen = load("res://scenes/battle/BattleScreen.gd")
	var shared = load("res://scripts/battle/BattleSimShared.gd")
	var defender := {"uid":"defender", "team":"player", "lane":2, "alive":true}
	var converted := {"uid":"converted", "team":"enemy", "lane":2, "alive":true}
	var middle_a := {"uid":"a", "team":"player", "lane":1, "alive":true}
	var middle_b := {"uid":"b", "team":"enemy", "lane":1, "alive":true}
	var state := {"player":[defender,middle_a], "enemy":[converted,middle_b]}
	h.expect(not shared._boundary_released(state,1), "conversion_before", "Both lanes are contested before conversion")
	replay_screen.apply_latched_team(converted,"converted",{"converted":"player"})
	replay_screen.reconcile_replay_teams(state,{"defender":defender,"converted":converted,"a":middle_a,"b":middle_b})
	h.expect(shared._boundary_released(state,1), "conversion_opens_wall", "Converted last opponent must open wall on the same frame")
	h.expect(state.player.size()==3 and state.enemy.size()==1, "conversion_membership", "Replay side arrays must reflect permanent conversion")
	print("BARRIER_BUDGET draw_nodes=", geometry, " particles=", particles, " sideways=", widest)

	# ★ 加载过场按住（10.04 第 7 条）：读条期这道墙还没被 _update_3v3_dividers() 摆位，
	# 停在原点会叠成画面正中一道墙 ⇒ 必须能被按住不显示，且 play_loop() 不能把它重新点亮。
	h.expect(not bool(wall.get("_preview_hidden")), "preview_hold_default_off", "Hold flag must default off (no behavior change)")
	wall.set_preview_hidden(true)
	h.expect(not wall.visible, "preview_hold", "Holding the preview must hide the barrier")
	wall.play_loop()
	h.expect(not wall.visible and not wall.is_released(), "preview_hold_beats_play_loop", "play_loop() must not resurrect a held barrier")
	wall.set_preview_hidden(false)
	h.expect(wall.visible, "preview_hold_release", "Releasing the hold must show the barrier again")

	# 结构：生产接线（加载期按住 + 摆位首帧撤销），且按住必须在 play_loop() 之后施加，
	# 否则会被 play_loop() 的 visible=true 盖掉。
	var wall_src := FileAccess.get_file_as_string("res://effects/battlefield/energy_barrier/EnergyBarrierSegment.gd")
	h.expect(wall_src.contains("func set_preview_hidden("), "wall_api", "Barrier must expose set_preview_hidden()")
	h.expect(wall_src.contains("visible = not _preview_hidden"), "wall_play_loop_guarded", "play_loop() visibility must route through the hold flag")
	var play_at := source.find("barrier.play_loop(i * 7 + half * 3)")
	var hold_at := source.find("barrier.set_preview_hidden(true)")
	h.expect(play_at >= 0 and hold_at > play_at, "hold_after_play_loop", "Hold must be applied after play_loop() or it would be overwritten")
	h.expect(source.contains("_preview_walls_hidden = true"), "arena_flag_set", "Production must arm the loading-preview suppression")
	h.expect(source.contains("barrier.set_preview_hidden(false)"), "arena_flag_release_wired", "First positioning frame must release the suppression")
	h.expect(source.contains("if _preview_walls_hidden:"), "arena_release_once", "Suppression release must be guarded so it runs once")
	wall.queue_free()
	await get_tree().process_frame
	h.finish(get_tree())


func _same_colors(got: Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in got.size():
		if not Color(got[i]).is_equal_approx(want[i]):
			return false
	return true
