extends Node
# Native 3D ward: preserve lane span, release lifecycle and quality behavior.
const CheckHarness := preload("res://tools/CheckHarness.gd")
const Wall := preload("res://effects/battlefield/LaneRunicWall3D.gd")
var h: RefCounted
var release_count := 0
func _ready() -> void:
	call_deferred("run")
func run() -> void:
	h = CheckHarness.new("battle_lane_barrier")
	var wall := Wall.new()
	add_child(wall)
	wall.release_finished.connect(func(): release_count += 1)
	wall.fit_between(Vector3(2,0,-4), Vector3(2,0,4))
	h.expect(wall.position.is_equal_approx(Vector3(2,0,0)) and is_equal_approx(wall.length,8.0), "full_length", "Wall must span both lane endpoints")
	var body: Node3D = wall.get("_body")
	var bounds := AABB()
	var triangles := 0
	for child in body.get_children():
		if child is MeshInstance3D:
			bounds = bounds.merge(child.transform * child.get_aabb())
			for i in child.mesh.get_surface_count():
				var arrays: Array = child.mesh.surface_get_arrays(i)
				triangles += (arrays[Mesh.ARRAY_INDEX].size() if arrays[Mesh.ARRAY_INDEX] != null and arrays[Mesh.ARRAY_INDEX].size() > 0 else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	h.expect(bounds.position.z <= -4.0 and bounds.end.z >= 4.0, "mesh_span", "Actual meshes must cover full lane")
	h.expect(bounds.position.z <= -4.75 and bounds.end.z >= 4.75, "border_overlap", "Visual curtain must continue into both arena borders")
	h.expect(bounds.size.x <= 0.31 and bounds.size.y >= 1.2 and bounds.size.y <= 1.4, "visual_footprint", "Narrow curtain must keep its height and remain at most 0.31 units wide")
	h.expect(body.get_child_count() == 1 and triangles < 800, "geometry_budget", "Ward must contain only the light membrane, no posts or crystals, under 800 triangles")
	wall.play_loop()
	wall.set_low_quality(true)
	var material: ShaderMaterial = wall.get("_material")
	h.expect(bool(material.get_shader_parameter("low_quality")), "low_quality", "Low tier must reach shader")
	wall.set_low_quality(false)
	h.expect(not bool(material.get_shader_parameter("low_quality")), "quality_restore", "Tier must restore")
	await get_tree().create_timer(1.0).timeout
	h.expect(is_zero_approx(float(material.get_shader_parameter("emphasis"))), "opening_settles", "Opening emphasis must settle")
	wall.play_release()
	wall.play_release()
	h.expect(wall.is_released(), "release_state", "Release state should change immediately")
	h.expect(not wall.visible, "release_clears_path", "Entire wall must disappear on the exact unlock frame")
	await get_tree().process_frame
	h.expect(not wall.visible and not wall.is_processing(), "release_hides", "Release must hide and stop CPU processing")
	h.expect(release_count == 1, "one_signal", "Duplicate release must emit only once")
	wall.play_loop()
	h.expect(wall.visible and not wall.is_released() and body.scale == Vector3.ONE, "restart", "Replay restart must restore geometry")
	h.expect(is_zero_approx(float(material.get_shader_parameter("dissolve"))), "restart_opacity", "Restart must restore membrane opacity")
	wall.fit_between(Vector3(2,0,4), Vector3(2,0,-4))
	h.expect(is_equal_approx(wall.length,8.0) and wall.get("_body") == body, "reverse_view", "Other-side view must keep span without rebuilding")
	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleArena.gd")
	h.expect(source.contains("_battle_3d_world.add_child(barrier)"), "world_depth", "Ward must use production 3D depth")
	h.expect(source.contains("barrier.fit_between(p_top, p_bot)"), "real_endpoints", "Production must supply both world endpoints")
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
	print("WALL_GEOMETRY triangles=", triangles, " meshes=", body.get_child_count(), " bounds=", bounds)

	# ★ 加载过场按住（10.04 第 7 条）：读条期这道墙还没被 _update_3v3_dividers() 摆位，
	# 停在原点会叠成画面正中一道墙 ⇒ 必须能被按住不显示，且 rebuild()/play_loop()
	# 都不能把它重新点亮（这两个函数自己都会 visible=true）。
	h.expect(not bool(wall.get("_preview_hidden")), "preview_hold_default_off", "Hold flag must default off (no behavior change)")
	wall.set_preview_hidden(true)
	h.expect(not wall.visible, "preview_hold", "Holding the preview must hide the ward")
	wall.play_loop()
	h.expect(not wall.visible and not wall.is_released(), "preview_hold_beats_play_loop", "play_loop() must not resurrect a held ward")
	wall.rebuild()
	h.expect(not wall.visible, "preview_hold_beats_rebuild", "rebuild() must not resurrect a held ward")
	wall.set_preview_hidden(false)
	h.expect(wall.visible, "preview_hold_release", "Releasing the hold must show the ward again")
	wall.rebuild()
	h.expect(wall.visible, "preview_default_visible", "Without a hold the ward stays visible (default behavior unchanged)")

	# 结构：生产接线（加载期按住 + 摆位首帧撤销），且按住必须在 play_loop() 之后施加，
	# 否则会被 play_loop() 的 visible=true 盖掉。
	var wall_src := FileAccess.get_file_as_string("res://effects/battlefield/LaneRunicWall3D.gd")
	h.expect(wall_src.contains("func set_preview_hidden("), "wall_api", "Ward must expose set_preview_hidden()")
	h.expect(wall_src.contains("visible = not _preview_hidden"), "wall_play_loop_guarded", "play_loop() visibility must route through the hold flag")
	h.expect(wall_src.contains("visible = not _released and not _preview_hidden"), "wall_rebuild_guarded", "rebuild() visibility must route through the hold flag")
	var play_at := source.find("barrier.play_loop(i * 7)")
	var hold_at := source.find("barrier.set_preview_hidden(true)")
	h.expect(play_at >= 0 and hold_at > play_at, "hold_after_play_loop", "Hold must be applied after play_loop() or it would be overwritten")
	h.expect(source.contains("_preview_walls_hidden = true"), "arena_flag_set", "Production must arm the loading-preview suppression")
	h.expect(source.contains("barrier.set_preview_hidden(false)"), "arena_flag_release_wired", "First positioning frame must release the suppression")
	h.expect(source.contains("if _preview_walls_hidden:"), "arena_release_once", "Suppression release must be guarded so it runs once")
	wall.queue_free()
	await get_tree().process_frame
	h.finish(get_tree())
