extends SceneTree

const IDS := [
	"merc_libra_judge", "merc_taurus_charge", "merc_virgo_heal",
	"merc_leo_sun", "merc_aries_blood", "merc_capricorn_steel",
	"merc_scorpio_death",
]
const SKILLS := ["balance_judge", "gold_charge", "holy_song", "king_aura", "blood_rampage", "steel_order", "death_hunt"]
var _out := ""
var _screen: Control
var _capture_skills: Array[String] = ["balance_judge", "gold_charge", "holy_song", "king_aura", "blood_rampage", "steel_order", "death_hunt"]
var _metrics_only := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	var focus := ""
	for i in args.size() - 1:
		if str(args[i]) == "--out":
			_out = str(args[i + 1])
		elif str(args[i]) == "--focus":
			focus = str(args[i + 1])
		elif str(args[i]) == "--metrics-only":
			_metrics_only = true
	var selected_ids: Array = IDS
	match focus:
		"judge":
			selected_ids = ["merc_libra_judge"]
			_capture_skills = ["balance_judge"]
		"death":
			selected_ids = ["merc_scorpio_death"]
			_capture_skills = ["death_hunt", "death_hunt_kill"]
		"cleanse":
			selected_ids = ["merc_virgo_heal"]
			_capture_skills = ["holy_song", "holy_song_cleanse"]
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	root.get_node("DataRegistry").call("load_all")
	var fixture: Script = load("res://scripts/qa/FixedBattleFixture.gd")
	var simulator: Script = load("res://scripts/battle/BattleSimulator.gd")
	fixture.setup_match_state(6, 20261012)
	var defs := {}
	for row in root.get_node("DataRegistry").call("get_table", "mercenaries").get("mercenaries", []):
		defs[str(row.get("id", ""))] = row
	var slots: Array = fixture.empty_mercenary_slots()
	for index in selected_ids.size():
		var unit_id: String = selected_ids[index]
		var definition: Dictionary = (defs[unit_id] as Dictionary).duplicate(true)
		definition["is_mercenary"] = true
		slots[index] = {"id": unit_id, "uid": "audit_merc_%d" % index, "star": 1, "def": definition, "is_mercenary": true}
	root.get_node("GameState").set("mercenary_slots", slots)
	var network := root.get_node("NetworkService")
	var boards: Dictionary = network.get("team_boards")
	if focus.is_empty():
		boards[0] = fixture.board_submission(root.get_node("GameState").get("board_slots"), slots)
	else:
		var ally_board: Array = fixture.board_from_ids(["god_guard"] if focus == "cleanse" else [])
		var enemy_ids: Array = ["undead_titan"] if focus == "judge" else (["human_militia", "human_militia"] if focus == "death" else ["dark_mage", "dark_suc"])
		boards[0] = fixture.board_submission(ally_board, slots)
		boards[3] = fixture.board_submission(fixture.board_from_ids(enemy_ids), fixture.empty_mercenary_slots())
	network.set("team_boards", boards)
	var replay: Dictionary = simulator.compute_team_replay(0, "mercenary-rework-audit")
	var frames: Array = replay.get("frames", [])
	var roster: Dictionary = replay.get("roster", {})
	var mercs := {}
	for uid in roster:
		var fighter: Dictionary = roster[uid]
		if str(fighter.get("id", "")) in IDS:
			mercs[str(uid)] = {"unit_id": fighter.get("id", ""), "team": fighter.get("team", ""), "lane": fighter.get("lane", -1)}
	var event_counts := {}
	for frame in replay.get("frame_events", []):
		for event in frame:
			if typeof(event) != TYPE_DICTIONARY:
				continue
			var key := "%s/%s" % [str(event.get("type", "")), str(event.get("skill_id", ""))]
			event_counts[key] = int(event_counts.get(key, 0)) + 1
	var report := {"focus": focus, "frames": frames.size(), "roster_count": roster.size(), "roster_mercenaries": mercs, "event_counts": event_counts, "result": replay.get("result", {}).get("reason", ""), "elapsed": replay.get("result", {}).get("elapsed", 0.0)}
	print("MERC_REWORK_AUDIT " + JSON.stringify(report))
	if not _out.is_empty() and not frames.is_empty():
		await _capture_formal(replay, report)
	quit(0 if not frames.is_empty() and mercs.size() == selected_ids.size() else 1)

func _capture_formal(replay: Dictionary, report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(_out)
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
			service.set_physics_process(false)
	var network := root.get_node("NetworkService")
	network.set("team_active", false)
	network.set("team_replay_rival", {})
	root.get_node("GameState").call("set_pending_battle_package", {"mode": "team_replay", "round_index": 6, "replay": replay})
	_screen = load("res://scenes/battle/BattleScreen.tscn").instantiate()
	root.add_child(_screen)
	var captures := {}
	var peak_live := 0
	var last_frame := -1
	var frame_ms: Array[float] = []
	var last_wall_usec := 0
	var deadline := Time.get_ticks_msec() + 90000
	while is_instance_valid(_screen) and Time.get_ticks_msec() < deadline:
		await process_frame
		var wall_usec := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		if not bool(_screen.get("_battle_setup_ready")):
			continue
		if last_wall_usec > 0 and _metrics_only:
			frame_ms.append(float(wall_usec - last_wall_usec) / 1000.0)
		last_wall_usec = wall_usec
		var replay_frame := int(_screen.get("_replay_frame"))
		if replay_frame == last_frame:
			continue
		last_frame = replay_frame
		var active := {}
		_collect_effects(_screen, active)
		peak_live = maxi(peak_live, active.size())
		for skill_id in _capture_skills:
			if _metrics_only:
				break
			if not active.has(skill_id) or captures.has(skill_id):
				continue
			var effect: Node3D = active[skill_id]
			var image_path := _out.path_join("formal_%s.png" % skill_id)
			var save_error := root.get_texture().get_image().save_png(image_path)
			captures[skill_id] = {"replay_frame": replay_frame, "source_sim_uid": effect.get_meta("source_sim_uid", ""), "target_sim_uid": effect.get_meta("target_sim_uid", ""), "effect_script": effect.get_script().resource_path, "save_error": save_error}
			print("MERC_REWORK_FORMAL skill=%s frame=%d source=%s target=%s save=%d" % [skill_id, replay_frame, captures[skill_id].source_sim_uid, captures[skill_id].target_sim_uid, save_error])
		if replay_frame >= (replay.get("frames", []) as Array).size():
			break
	report["formal_capture"] = {"captures": captures, "peak_live_effect_nodes": peak_live, "last_replay_frame": last_frame, "missing": _capture_skills.filter(func(skill_id: String) -> bool: return not captures.has(skill_id))}
	if _metrics_only:
		frame_ms.sort()
		var over_100 := 0
		for value in frame_ms:
			if value > 100.0:
				over_100 += 1
		report["performance"] = {"samples": frame_ms.size(), "median_ms": _percentile(frame_ms, 0.5), "p95_ms": _percentile(frame_ms, 0.95), "over_100ms": over_100, "route_sha256": FileAccess.get_sha256("res://effects/BossProceduralVFX3D.gd"), "battle_vfx_sha256": FileAccess.get_sha256("res://scenes/battle/BattleVfx.gd")}
	var file := FileAccess.open(_out.path_join("formal_evidence.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print("MERC_REWORK_FORMAL_RESULT " + JSON.stringify(report.formal_capture))
	if _metrics_only:
		print("MERC_REWORK_PERFORMANCE " + JSON.stringify(report.performance))
	if is_instance_valid(_screen):
		_screen.queue_free()
		await process_frame

func _collect_effects(node: Node, out: Dictionary) -> void:
	if node.name.begins_with("MercenaryRework_"):
		var skill_id := str(node.get_meta("skill_id", ""))
		if skill_id in _capture_skills:
			out[skill_id] = node
	for child in node.get_children():
		_collect_effects(child, out)

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	return values[clampi(int(round(float(values.size() - 1) * fraction)), 0, values.size() - 1)]
