extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var out := "res://reports/lane_wall"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: out = args[0]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for name in ["NetworkService", "RealtimeService", "AnalyticsService"]:
		root.get_node(name).set_process(false)
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	root.get_node("DataRegistry").load_all()
	var fixture = load("res://scripts/qa/FixedBattleFixture.gd")
	fixture.setup_match_state(1, 20260823)
	var replay = load("res://scripts/battle/BattleSimulator.gd").compute_team_replay(0, "lane-wall-review")
	root.get_node("NetworkService").team_active = false
	root.get_node("GameState").set_pending_battle_package({"mode":"team_replay", "round_index":1, "replay":replay})
	var screen = load("res://scenes/battle/BattleScreen.tscn").instantiate()
	root.add_child(screen)
	while not screen.get("_battle_setup_ready"):
		await process_frame
	screen.set_process(false)
	for i in 20: await process_frame
	# Check projected centerlines at both ends, using the production battle camera.
	var walls: Array = screen.get("_3v3_barriers")
	var camera: Camera3D = screen.get("_battle_3d_camera")
	var lines: Array[Vector2] = []
	var columns: Array[float] = []
	# 10-06：分路墙换成能量护栏（EnergyBarrierSegment），每条边界上下两段（_3v3_barriers[i * 2] / [i * 2 + 1]）。
	# 旧符文墙「膜面两端不斜切」那条随旧墙一起删了；竖直、平行、三等分照旧验，两段要在同一条竖线上。
	for i in walls.size():
		var wall = walls[i]   # 不标 Node3D：barrier_length 是护栏脚本上的属性
		var a := camera.unproject_position(wall.to_global(Vector3(0, 0.6, -wall.barrier_length * 0.4)))
		var b := camera.unproject_position(wall.to_global(Vector3(0, 0.6, wall.barrier_length * 0.4)))
		if absf(a.x - b.x) > 0.1:
			push_error("Wall centerline is not vertical in battle camera")
			quit(1)
			return
		if i % 2 == 0:
			lines.append((b - a).normalized())
			columns.append(a.x)
		elif absf(a.x - columns[columns.size() - 1]) > 0.1:
			push_error("The two halves of a lane boundary are not on one line")
			quit(1)
			return
	if lines.size() != 2 or absf(lines[0].cross(lines[1])) > 0.0001:
		push_error("Wall centerlines are not parallel")
		quit(1)
		return
	columns.sort()
	var edge_a: Vector3 = screen.call("_sim_to_world_pos", Vector2(95,260), false)
	var edge_b: Vector3 = screen.call("_sim_to_world_pos", Vector2(905,260), false)
	var left_edge := minf(camera.unproject_position(edge_a).x, camera.unproject_position(edge_b).x)
	var right_edge := maxf(camera.unproject_position(edge_a).x, camera.unproject_position(edge_b).x)
	var viewport_width := right_edge - left_edge
	var thirds := [columns[0] - left_edge, columns[1] - columns[0], right_edge - columns[1]]
	for width in thirds:
		if absf(width - viewport_width / 3.0) > 0.1:
			push_error("Walls do not trisect the battle viewport: %s" % str(thirds))
			quit(1)
			return
	print("WALL_PARALLEL PASS directions=", lines, " widths=", thirds)
	for stage in ["full", "low", "released"]:
		for wall in screen.get("_3v3_barriers"):
			if stage == "low": wall.set_low_quality(true)
			if stage == "released": wall.play_release()
		await create_timer(1.0).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join(stage + ".png"))
		print("WALL_CAPTURE ", stage, " walls=", screen.get("_3v3_barriers").size())
	# Replay every authoritative frame through the production renderer. This also
	# catches a display-only correction hiding an invalid simulation position.
	for wall in walls: wall.play_loop()
	var render_samples := 0
	for frame in replay.frames.size():
		screen.call("_apply_replay_frame", frame)
		screen.call("_refresh_visuals")
		screen.call("_update_3v3_dividers")
		var current: Dictionary = screen.get("_state")
		for f: Dictionary in current.player + current.enemy:
			if not bool(f.get("alive",false)): continue
			var shown: Vector2 = screen.call("_visual_sim_pos_for_fighter", f)
			if shown.distance_to(f.pos) > 0.1:
				push_error("Renderer disagrees with authoritative position")
				quit(1)
				return
			render_samples += 1
		await process_frame
		if frame == replay.frames.size() / 2:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(out.path_join("combat.png"))
	print("WALL_RENDER_POSITIONS PASS samples=",render_samples)
	screen.queue_free()
	await process_frame
	quit()
