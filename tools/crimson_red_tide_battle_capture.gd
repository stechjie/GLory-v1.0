extends SceneTree

# Runs the normal team replay and BattleScreen with a Crimson 7 board.
# Screenshots and assertions come from the live actor tree, not the VFX preview.
const TIMEOUT_MSEC := 90000
const CRIMSON_LINEUP := ["crimson", "dancer", "drumer", "hunter", "armbreaker", "Icey", "skypierce"]

var _screen: Control
var _out := ""
var _failures: Array[String] = []
var _captured: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == "--out":
			_out = ProjectSettings.globalize_path(str(args[i + 1]))
	if _out.is_empty() or DirAccess.make_dir_recursive_absolute(_out) != OK:
		push_error("Red Tide battle capture requires --out /absolute/output/path")
		quit(2)
		return
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
			service.set_physics_process(false)
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	root.get_node("DataRegistry").call("load_all")
	var fixture: Script = load("res://scripts/qa/FixedBattleFixture.gd")
	var simulator: Script = load("res://scripts/battle/BattleSimulator.gd")
	fixture.lineup_b_override = [CRIMSON_LINEUP, [], []]
	fixture.setup_match_state(6, 20261006)
	# The fixed fixture builds every snapshot with the account's team-A synergy.
	# Match the overridden team-B board to its seven actual Crimson units.
	var network_service := root.get_node("NetworkService")
	var team_boards: Dictionary = network_service.get("team_boards")
	var crimson_board: Dictionary = team_boards[3]
	crimson_board["syn"] = load("res://scripts/units/SynergyService.gd").flags_from_counts({"crimson": 7})
	team_boards[3] = crimson_board
	network_service.set("team_boards", team_boards)
	var replay: Dictionary = simulator.compute_team_replay(0, "red-tide-battle-capture")
	fixture.lineup_b_override = []
	var events: Array = replay.get("crimson_red_tide_stack_events", [])
	var roster_ids: Array[String] = []
	for uid in (replay.get("roster", {}) as Dictionary):
		var fighter: Dictionary = replay.roster[uid]
		roster_ids.append("%s:%s:%s" % [uid, fighter.get("id", ""), fighter.get("lane", -1)])
	print("RED_TIDE_ROSTER %s" % JSON.stringify(roster_ids))
	print("RED_TIDE_REPLAY events=%s frames=%d" % [JSON.stringify(events), (replay.get("frames", []) as Array).size()])
	if events.is_empty():
		_failures.append("Crimson 7 battle produced no Red Tide stack events")
		_finish()
		return
	var network := root.get_node("NetworkService")
	network.set("team_active", false)
	network.set("team_replay_rival", {})
	root.get_node("GameState").call("set_pending_battle_package", {
		"mode": "team_replay", "round_index": 6, "replay": replay})
	_screen = load("res://scenes/battle/BattleScreen.tscn").instantiate()
	root.add_child(_screen)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while is_instance_valid(_screen) and Time.get_ticks_msec() < deadline:
		await process_frame
		await RenderingServer.frame_post_draw
		if not bool(_screen.get("_battle_setup_ready")):
			continue
		var fighters: Dictionary = _screen.get("_replay_by_uid")
		var models: Dictionary = _screen.get("_battle_3d_models")
		for uid in models:
			var fighter: Dictionary = fighters.get(uid, {})
			var count := int(fighter.get("crimson_pulse_stacks", 0))
			if count <= 0:
				continue
			var actor := models[uid] as Node3D
			var orbits := actor.get_node_or_null("CrimsonRedTideOrbits3D") if actor != null else null
			if orbits == null or int(orbits.get("_stacks")) != count:
				_failures.append("Actor orbit count does not match replay: uid=%s count=%d" % [uid, count])
				_finish()
				return
			var label := "red_tide_battle_1.png" if count == 1 else "red_tide_battle_%d.png" % count
			if not _captured.has(label):
				var path := _out.path_join(label)
				if root.get_texture().get_image().save_png(path) != OK:
					_failures.append("Failed to save " + label)
				else:
					_captured[label] = true
					print("RED_TIDE_BATTLE_CAPTURE %s uid=%s count=%d" % [path, uid, count])
		if _captured.has("red_tide_battle_5.png"):
			break
		if int(_screen.get("_replay_frame")) >= (replay.get("frames", []) as Array).size():
			break
	if _captured.is_empty():
		_failures.append("No Red Tide orbit appeared in BattleScreen")
	_finish()


func _finish() -> void:
	if is_instance_valid(_screen):
		_screen.queue_free()
	print("RED_TIDE_BATTLE_RESULT status=%s captures=%s failures=%s" % [
		"PASS" if _failures.is_empty() else "FAIL", JSON.stringify(_captured.keys()), JSON.stringify(_failures)])
	quit(0 if _failures.is_empty() else 1)
