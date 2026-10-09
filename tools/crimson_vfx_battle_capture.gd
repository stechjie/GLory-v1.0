extends SceneTree

# 赤律族特效的正式战斗取证（不是特效小舞台）。需要渲染器：
#   Godot --path . --rendering-method gl_compatibility --resolution 1600x720 --fixed-fps 30 \
#     --script res://tools/crimson_vfx_battle_capture.gd -- --out <绝对路径>
# 流程与正式对局相同：FixedBattleFixture（team b 换成赤律族阵容，第 6 回合 PVP）
#   -> BattleSimulator.compute_team_replay -> GameState.pending_battle_package
#   -> BattleScreen 回放。不改任何玩法、UI、fixture 文件；网络处理关闭。
#
# 可选参数：
#   --tier LOW|MEDIUM|HIGH    画质档（默认 MEDIUM）
#   --seed N / --round N      默认 20261009 / 6
#   --shots a,b,c             额外在「开战后第 a/b/c 个渲染帧」截图。配合 --fixed-fps，
#                             改动前后两份工程用同一组帧号即可拿到同一时刻的对比图。
# 只读：截图是引擎视口原样输出；采样只读生产节点，不直接调用特效。
#
# evidence.json 里同时记下回放摘要：simulation_sha256（玩法帧 + 结果）、payload_sha256，
# 以及去掉赤律族表现事件后的事件摘要 —— 用来证明改动前后模拟完全一致、
# 新增的只有表现事件。

const ATTACK_PATH := "res://effects/vfx3d/units/VFXCrimsonAttack3D.gd"
const SKILL_PATH := "res://effects/vfx3d/units/VFXCrimsonSkill3D.gd"
const CRIMSON_LINEUP := [
	["crimson", "hunter", "armbreaker", "lattern"],
	["dancer", "drumer", "skypierce", "Icey"],
	["crimson", "drumer", "hunter", "skypierce"],
]
# 改动前后对比时剔除的赤律族表现事件（team_random_stack 只在中间版本出现过，一并列入）。
const CRIMSON_PROCS := ["block_guard", "team_random_stack", "stacking_def_break"]
const TIMEOUT_MSEC := 600000

var _screen: Control
var _out := ""
var _seed := 20261009
var _round := 6
var _tier := "MEDIUM"
var _fixed_shots: Array[int] = []
var _mirror := false
const CRIMSON_LINEUP_A := [
	["Icey", "lattern", "dancer", "crimson"],
	["hunter", "skypierce", "drumer", "armbreaker"],
	["crimson", "lattern", "Icey", "dancer"],
]
var _shots: Array[Dictionary] = []
var _captured := {}
var _report := {}
var _failures: Array[String] = []
var _timeline: Array[Dictionary] = []
var _peaks := {}
var _first_seen := {}
var _frame_ms: Array[float] = []
var _draw_calls: Array[int] = []
var _captured_last_frame := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if i + 1 >= args.size():
			continue
		match args[i]:
			"--out": _out = ProjectSettings.globalize_path(str(args[i + 1]))
			"--tier": _tier = str(args[i + 1]).to_upper()
			"--seed": _seed = int(args[i + 1])
			"--round": _round = int(args[i + 1])
			"--mirror":
				# 两队都是赤律族：只同步了赤律族模型的精简环境里用（队伍 a 的人族/神族模型不在）。
				_mirror = str(args[i + 1]) != "0"
			"--shots":
				for part in str(args[i + 1]).split(",", false):
					if part.strip_edges().is_valid_int():
						_fixed_shots.append(int(part.strip_edges()))
	if _out.is_empty():
		push_error("crimson capture requires --out <absolute evidence path>")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.set_process(false)
			service.set_physics_process(false)
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	root.get_node("DataRegistry").call("load_all")
	var fixture: Script = load("res://scripts/qa/FixedBattleFixture.gd")
	var simulator: Script = load("res://scripts/battle/BattleSimulator.gd")
	var digest: Script = load("res://scripts/qa/ReplayDigest.gd")
	var budget: Script = load("res://effects/vfx3d/core/VFXQualityBudget.gd")
	budget.set("tier", 0 if _tier == "LOW" else (2 if _tier == "HIGH" else 1))
	if _mirror:
		_setup_mirror(fixture)
	else:
		fixture.set("lineup_b_override", CRIMSON_LINEUP)
		fixture.call("setup_match_state", _round, _seed)
	var replay: Dictionary = simulator.call("compute_team_replay", 0, "crimson-formal:%d:%d" % [_seed, _round])
	var network := root.get_node("NetworkService")
	network.set("team_active", false)
	network.set("team_replay_rival", {})
	var frames: Array = replay.get("frames", [])
	var roster: Dictionary = replay.get("roster", {})
	var crimson_units := {}
	for uid in roster:
		var fighter: Dictionary = roster[uid]
		if str((fighter.get("def", {}) as Dictionary).get("race", "")) == "crimson":
			crimson_units[uid] = {"unit_id": fighter.get("id", ""), "star": fighter.get("star", 1), "lane": fighter.get("lane", 0), "team": fighter.get("team", "")}
	_report = {"seed": _seed, "round": _round, "tier": _tier, "mirror_crimson": _mirror, "output_directory": _out,
		"generated_utc": Time.get_datetime_string_from_system(true, false),
		"engine": Engine.get_version_info().get("string", ""),
		"renderer": RenderingServer.get_current_rendering_method(),
		"pipeline": "FixedBattleFixture(lineup_b=crimson) -> BattleSimulator.compute_team_replay -> GameState.pending_battle_package -> BattleScreen replay playback",
		"crimson_modules_present": ResourceLoader.exists(SKILL_PATH),
		"replay_frames": frames.size(), "crimson_units": crimson_units,
		"replay": _replay_digests(replay, digest),
		"source_sha256": _source_hashes(),
		"notes": ["Screenshots are unmodified engine viewport output.",
			"Shot frames count rendered frames after BattleScreen reports _battle_setup_ready; with --fixed-fps they align across builds.",
			"This capture is functional and visual evidence, not a device performance benchmark."]}
	if frames.is_empty() or crimson_units.is_empty():
		_failures.append("Fixture produced no replay frames or no crimson units")
		_finish()
		return
	root.get_node("GameState").call("set_pending_battle_package", {"mode": "team_replay", "round_index": _round, "replay": replay})
	var packed: PackedScene = load("res://scenes/battle/BattleScreen.tscn")
	_screen = packed.instantiate()
	root.add_child(_screen)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	var playback_frame := -1
	var last_replay_frame := -1
	var last_usec := 0
	while is_instance_valid(_screen) and Time.get_ticks_msec() < deadline:
		await process_frame
		await RenderingServer.frame_post_draw
		if not bool(_screen.get("_battle_setup_ready")):
			continue
		playback_frame += 1
		# 同机同条件的相对开销：每个渲染帧的墙钟耗时与 draw call。截图帧另算（存盘慢）。
		var now_usec := Time.get_ticks_usec()
		if last_usec > 0 and not _captured_last_frame:
			_frame_ms.append(float(now_usec - last_usec) / 1000.0)
			_draw_calls.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
			_peaks["nodes"] = maxi(int(_peaks.get("nodes", 0)), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
		last_usec = now_usec
		_captured_last_frame = false
		var sample := _sample(playback_frame)
		var replay_frame := int(sample.replay_frame)
		for key in ["attack_nodes", "skill_nodes", "active_blocks"]:
			_peaks[key] = maxi(int(_peaks.get(key, 0)), int(sample.get(key, 0)))
		if replay_frame != last_replay_frame and replay_frame % 5 == 0:
			_timeline.append(sample)
			last_replay_frame = replay_frame
		if playback_frame in _fixed_shots:
			_capture("frame-%04d" % playback_frame, sample)
		_event_shots(sample)
		if replay_frame >= frames.size():
			_capture("zz-timeline-end", sample)
			break
	if Time.get_ticks_msec() >= deadline:
		_failures.append("Timed out waiting for BattleScreen playback")
	var director: Variant = _screen.get("_presentation_director") if is_instance_valid(_screen) else null
	if director is Object:
		_report["director_budget"] = (director as Object).call("budget_stats")
	_report["preparation"] = _screen.get("battle_preparation_report") if is_instance_valid(_screen) else {}
	_report["peaks"] = _peaks
	_report["frame_cost"] = _frame_summary()
	_report["first_seen_playback_frame"] = _first_seen
	if bool(_report.crimson_modules_present):
		for kind in ["random_ally_buff", "frost_status", "aoe_silence", "block_guard", "stacking_def_break", "current_hp_strike", "line_pierce"]:
			if not _first_seen.has("skill:" + kind):
				_failures.append("No %s effect appeared in the real BattleScreen tree" % kind)
		if int(_peaks.get("attack_nodes", 0)) == 0:
			_failures.append("No crimson basic attack appeared in the real BattleScreen tree")
	if is_instance_valid(_screen):
		_screen.queue_free()
		await process_frame
		await process_frame
	_report["crimson_nodes_after_screen_free"] = _count(root, ATTACK_PATH) + _count(root, SKILL_PATH)
	if int(_report.crimson_nodes_after_screen_free) != 0:
		_failures.append("A crimson effect node survived BattleScreen disposal")
	_finish()


# 每类表现第一次出现时，等它展开到「最能读出来」的那一刻截一张。
func _event_shots(sample: Dictionary) -> void:
	for state: Dictionary in sample.get("effects", []):
		var key := str(state.get("key", ""))
		if key.is_empty():
			continue
		if not _first_seen.has(key):
			_first_seen[key] = int(sample.playback_frame)
		var label := "event-" + key.replace(":", "-")
		if _captured.has(label) or int(_first_seen[key]) != int(state.get("first_frame", -1)):
			continue
		var ready_at := float(state.get("delay", 0.0)) + (0.30 if key.begins_with("skill:") else float(state.get("flight_time", 0.3)) * 0.55)
		if key in ["skill:frost_status", "skill:aoe_silence"]:
			ready_at = float(state.get("delay", 0.0)) + 0.55
		if float(state.get("elapsed", 0.0)) >= ready_at:
			_capture(label, sample)


var _node_first_frame := {}

func _sample(playback_frame: int) -> Dictionary:
	var result := {"playback_frame": playback_frame, "replay_frame": int(_screen.get("_replay_frame")),
		"render_frame": Engine.get_frames_drawn(), "attack_nodes": _count(_screen, ATTACK_PATH),
		"skill_nodes": _count(_screen, SKILL_PATH),
		"active_blocks": int((load("res://effects/vfx3d/VFXBlockRoot.gd") as Script).call("active_block_count")),
		"effects": []}
	for node: Node in _nodes(_screen, ATTACK_PATH) + _nodes(_screen, SKILL_PATH):
		if not node.has_method("get_debug_state"):
			continue
		var debug: Dictionary = node.call("get_debug_state")
		var id := node.get_instance_id()
		if not _node_first_frame.has(id):
			_node_first_frame[id] = playback_frame
		var key := ("skill:" + str(debug.get("skill", ""))) if debug.has("skill") else ("attack:" + str(debug.get("kind", "")))
		var entry := {"key": key, "first_frame": -1, "elapsed": float(node.call("elapsed")) if node.has_method("elapsed") else 0.0,
			"delay": float(debug.get("delay", 0.0)), "flight_time": float(debug.get("flight_time", 0.0))}
		# 这一类第一次出现的那个节点才用于取证截图。
		if not _first_seen.has(key) or int(_first_seen[key]) == int(_node_first_frame[id]):
			entry["first_frame"] = int(_node_first_frame[id])
		for field in ["targets", "silenced_flashes", "execute", "stacks", "spikes", "unit_id", "mode"]:
			if debug.has(field):
				entry[field] = debug[field]
		(result.effects as Array).append(entry)
	return result


func _capture(label: String, sample: Dictionary) -> void:
	if _captured.has(label):
		return
	_captured[label] = true
	_captured_last_frame = true
	var path := _out.path_join(label + ".png")
	var error := root.get_texture().get_image().save_png(path)
	var evidence := {"file": path.get_file(), "label": label, "playback_frame": sample.playback_frame,
		"replay_frame": sample.replay_frame, "attack_nodes": sample.attack_nodes, "skill_nodes": sample.skill_nodes,
		"effects": sample.effects, "save_error": error}
	_shots.append(evidence)
	if error != OK:
		_failures.append("Screenshot failed: " + label)
	print("CRIMSON_FORMAL_CAPTURE label=%s playback_frame=%d replay_frame=%d attack=%d skill=%d" % [label, int(sample.playback_frame), int(sample.replay_frame), int(sample.attack_nodes), int(sample.skill_nodes)])


# 与 FixedBattleFixture.setup_match_state 同一流程，只是 team a 也换成赤律族阵容。
func _setup_mirror(fixture: Script) -> void:
	var game := root.get_node("GameState")
	var network := root.get_node("NetworkService")
	game.call("reset_run")
	game.set("team_mode", true)
	game.set("round_index", _round)
	game.set("team_hp", game.START_FORMATION_HP)
	game.set("enemy_team_hp", game.START_FORMATION_HP)
	game.set("board_slots", fixture.call("board_from_ids", CRIMSON_LINEUP_A[0]))
	game.set("mercenary_slots", fixture.call("empty_mercenary_slots"))
	network.set("team_active", true)
	network.set("team_local_slot", 0)
	network.set("shared_seed", _seed)
	network.set("team_slot_states", ["player", "player", "player", "player", "player", "player"])
	var boards: Dictionary = {}
	for lane in 3:
		boards[lane] = fixture.call("board_submission", fixture.call("board_from_ids", CRIMSON_LINEUP_A[lane]), fixture.call("empty_mercenary_slots"))
		boards[lane + 3] = fixture.call("board_submission", fixture.call("board_from_ids", CRIMSON_LINEUP[lane]), fixture.call("empty_mercenary_slots"))
	network.set("team_boards", boards)


func _replay_digests(replay: Dictionary, digest: Script) -> Dictionary:
	var histogram := {}
	var stripped: Array = []
	for bucket in replay.get("frame_events", []):
		var kept: Array = []
		for value in bucket:
			if not value is Dictionary:
				kept.append(value)
				continue
			var event: Dictionary = value
			var key := "%s/%s" % [str(event.get("type", "")), str(event.get("skill_id", ""))]
			histogram[key] = int(histogram.get(key, 0)) + 1
			if str(event.get("type", "")) == "unit_skill_proc" and str(event.get("skill_id", "")) in CRIMSON_PROCS:
				continue
			# 插入新事件会让同一 tick 后续事件的序号（event_key / ordinal / presentation_seed）顺延，
			# 比较「其余事件是否不变」时去掉这三个编号字段。
			var copy := event.duplicate(true)
			for field in ["event_key", "ordinal", "presentation_seed"]:
				copy.erase(field)
			kept.append(copy)
		stripped.append(kept)
	return {"simulation_sha256": digest.call("simulation_sha256", replay),
		"payload_sha256": digest.call("payload_sha256", replay),
		"frames_sha256": JSON.stringify(replay.get("frames", [])).sha256_text(),
		"result_sha256": JSON.stringify(replay.get("result", {})).sha256_text(),
		"non_crimson_events_sha256": JSON.stringify(stripped).sha256_text(),
		"event_histogram": histogram}


func _frame_summary() -> Dictionary:
	if _frame_ms.is_empty():
		return {}
	var sorted := _frame_ms.duplicate()
	sorted.sort()
	var calls := _draw_calls.duplicate()
	calls.sort()
	var long_frames := 0
	for value in _frame_ms:
		if value > 100.0:
			long_frames += 1
	return {"samples": sorted.size(), "median_ms": sorted[sorted.size() / 2],
		"p95_ms": sorted[mini(sorted.size() - 1, int(floor(float(sorted.size()) * 0.95)))],
		"max_ms": sorted[sorted.size() - 1], "frames_over_100ms": long_frames,
		"draw_calls_median": calls[calls.size() / 2], "draw_calls_max": calls[calls.size() - 1],
		"note": "Wall time per rendered frame on this machine/renderer; relative old-vs-new only, not a device benchmark."}


func _nodes(node: Node, path: String) -> Array:
	var out: Array = []
	_collect(node, path, out)
	return out


func _collect(node: Node, path: String, out: Array) -> void:
	if node == null or not is_instance_valid(node) or node.is_queued_for_deletion():
		return
	var script: Variant = node.get_script()
	if script is Script and (script as Script).resource_path == path:
		out.append(node)
	for child in node.get_children():
		_collect(child, path, out)


func _count(node: Node, path: String) -> int:
	return _nodes(node, path).size()


func _source_hashes() -> Dictionary:
	var result := {}
	for path in [ATTACK_PATH, SKILL_PATH, "res://effects/vfx3d/units/VFXCrimsonKit3D.gd", "res://effects/vfx3d/units/CrimsonVFXCatalog.gd",
			"res://effects/vfx3d/shaders/crimson_vfx_glow.gdshader", "res://effects/vfx3d/shaders/crimson_vfx_body.gdshader",
			"res://effects/vfx3d/units/UnitSkillVFXComposer3D.gd", "res://effects/BossProceduralVFX3D.gd", "res://scenes/battle/BattleVfx.gd",
			"res://scripts/battle/DamageService.gd", "res://scripts/battle/CrimsonCombat.gd"]:
		result[path] = FileAccess.get_sha256(path) if FileAccess.file_exists(path) else "(absent)"
	return result


func _finish() -> void:
	_report["samples"] = _timeline
	_report["screenshots"] = _shots
	_report["failures"] = _failures
	_report["status"] = "PASS" if _failures.is_empty() else "FAIL"
	var file := FileAccess.open(_out.path_join("evidence.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "  "))
		file.close()
	print("CRIMSON_FORMAL_RESULT status=%s screenshots=%d failures=%s output=%s" % [_report.status, _shots.size(), JSON.stringify(_failures), _out])
	quit(0 if _failures.is_empty() else 1)
