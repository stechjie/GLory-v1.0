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
	for wall in walls:
		var body: Node3D = wall.get("_body")
		if body.get_child_count() != 1:
			push_error("Light walls must not contain posts")
			quit(1)
			return
		var membrane: MeshInstance3D = body.get_child(0)
		var arrays: Array = membrane.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var top_min := INF
		var top_max := -INF
		var bottom_min := INF
		var bottom_max := -INF
		for k in vertices.size():
			var projected := camera.unproject_position(membrane.to_global(vertices[k]))
			if uvs[k].x < 0.001:
				top_min = minf(top_min, projected.y)
				top_max = maxf(top_max, projected.y)
			if uvs[k].x > 0.999:
				bottom_min = minf(bottom_min, projected.y)
				bottom_max = maxf(bottom_max, projected.y)
		if top_max - top_min > 0.1 or bottom_max - bottom_min > 0.1:
			push_error("Visible membrane ends are skewed")
			quit(1)
			return
		var a := camera.unproject_position(wall.to_global(Vector3(0, 0.6, -wall.length * 0.4)))
		var b := camera.unproject_position(wall.to_global(Vector3(0, 0.6, wall.length * 0.4)))
		lines.append((b - a).normalized())
		columns.append(a.x)
		if absf(a.x - b.x) > 0.1:
			push_error("Wall centerline is not vertical in battle camera")
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
