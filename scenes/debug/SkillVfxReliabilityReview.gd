extends Node

# Isolated, read-only presentation probe. It renders a computed replay through the
# real BattleScreen, but does not alter the simulator, cue routing, or VFX budgets.
const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const BattleReplay := preload("res://scripts/battle/BattleReplayUtil.gd")
const ReplayDigest := preload("res://scripts/qa/ReplayDigest.gd")
const Fixture := preload("res://scripts/qa/FixedBattleFixture.gd")
const BattleScreenScene := preload("res://scenes/battle/BattleScreen.tscn")
const QualityBudget := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const VFXBlockRootScript := preload("res://effects/vfx3d/VFXBlockRoot.gd")

const DEFAULT_SEED := 20260823
const DEFAULT_ROUND := 6
const MAX_SAMPLES := 8192
const TIMEOUT_MSEC := 120000
const TRACKED_TYPES := ["skill_cast", "unit_skill_proc", "sfx_proc", "skill_shake", "impact", "hit_number"]

var _seed := DEFAULT_SEED
var _round := DEFAULT_ROUND
var _tier_name := "MEDIUM"
var _mercenary_id := "merc_sagittarius_rain"
var _focus_skill_id := ""
var _scan_seeds := 0
var _label := "baseline"
var _out_root := "user://skill_vfx_reliability"
var _out_dir := ""
var _capture_frames: Array[int] = [0, 20, 40]
var _keep_open := false

var _screen: Node = null
var _replay: Dictionary = {}
var _expected: Array[Dictionary] = []
var _snapshot_candidates: Array[Dictionary] = []
var _receipts: Dictionary = {}
var _samples: Array[Dictionary] = []
var _wall_samples: Array[float] = []
var _screenshots: Array[Dictionary] = []
var _focus_vfx_nodes: Array[Dictionary] = []
var _skill_visual_receipts: Array[Dictionary] = []
var _warnings: Array[String] = []
var _result: Dictionary = {}
var _start_msec := 0
var _setup_ready_msec := 0
var _last_frame_usec := 0
var _finishing := false
var _capture_busy := false
var _skip_next_wall_sample := false
var _excluded_capture_samples := 0
var _last_replay_frame := -1
var _cap_denials_start := -1


func _ready() -> void:
	_parse_args()
	_start_msec = Time.get_ticks_msec()
	DataRegistry.load_all()
	QualityBudget.tier = _tier_value(_tier_name)
	if _scan_seeds > 0:
		_scan_fixed_seeds()
		return
	Fixture.setup_match_state(_round, _seed)
	if not _mercenary_id.is_empty() and not _add_local_mercenary(_mercenary_id):
		_finish_with_error("mercenary_definition_missing:" + _mercenary_id)
		return
	var compute_started := Time.get_ticks_usec()
	_replay = BattleSim.compute_team_replay(0, "skill_vfx_review:%d:%d:%s" % [_seed, _round, _mercenary_id])
	var compute_ms := float(Time.get_ticks_usec() - compute_started) / 1000.0
	if not BattleReplay.valid_team_replay(_replay):
		_finish_with_error("invalid_replay")
		return
	_expected = _index_events(_replay)
	_snapshot_candidates = _skill_ready_candidates(_replay)
	var focus := _focus_replay_report(_replay)
	var resolved_root := ProjectSettings.globalize_path(_out_root)
	_out_dir = resolved_root.path_join("%s_%d_%d_%s_%d" % [
		_label, _seed, _round, _tier_name.to_lower(), Time.get_ticks_msec()])
	if DirAccess.make_dir_recursive_absolute(_out_dir) != OK:
		_finish_with_error("output_directory_failed:" + _out_dir)
		return
	_prime_profile_seen(_replay.get("roster", {}))
	GameState.set_pending_battle_package({"mode": "team_replay", "round_index": _round, "replay": _replay})
	_screen = BattleScreenScene.instantiate()
	if _screen == null:
		_finish_with_error("battle_screen_instantiate_failed")
		return
	_screen.connect("battle_finished", Callable(self, "_on_battle_finished"), CONNECT_ONE_SHOT)
	_screen.connect("skill_visual_submitted", Callable(self, "_on_skill_visual_submitted"))
	_hook_director_before_enter_tree()
	add_child(_screen)
	_last_frame_usec = Time.get_ticks_usec()
	_warnings.append("compute_ms=%.2f (excluded from playback frame samples)" % compute_ms)
	if int(focus.get("skill_ready_rises", 0)) == 0:
		_warnings.append("focus_skill_not_observed; this replay cannot assess its VFX visibility")
	print("[SKILL_VFX_REVIEW] output=" + _out_dir)


func _process(_delta: float) -> void:
	if _finishing or _screen == null or not is_instance_valid(_screen):
		return
	var now_usec := Time.get_ticks_usec()
	var wall_ms := float(now_usec - _last_frame_usec) / 1000.0
	_last_frame_usec = now_usec
	if Time.get_ticks_msec() - _start_msec > TIMEOUT_MSEC:
		_finish_with_error("timeout")
		return
	if not bool(_screen.get("_battle_setup_ready")):
		return
	if _setup_ready_msec == 0:
		_setup_ready_msec = Time.get_ticks_msec()
		_cap_denials_start = VFXBlockRootScript.cap_denial_count()
	var replay_frame := int(_screen.get("_replay_frame"))
	if replay_frame <= 0:
		return
	if _skip_next_wall_sample:
		_skip_next_wall_sample = false
		_excluded_capture_samples += 1
	elif _wall_samples.size() < MAX_SAMPLES:
		_wall_samples.append(wall_ms)
		_samples.append({
			"sample": _samples.size(),
			"replay_frame": replay_frame,
			"wall_frame_ms": wall_ms,
			"active_vfx_blocks": VFXBlockRootScript.active_block_count(),
			"pending_textures": VFXManager.pending_texture_count(),
			"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		})
	if replay_frame != _last_replay_frame:
		_last_replay_frame = replay_frame
		if _focus_skill_id == "arrow_rain" and replay_frame >= 25 and replay_frame <= 60:
			var shafts := _screen.find_children("ArrowRain_Shaft", "MeshInstance3D", true, false)
			var impacts := _screen.find_children("ArrowRain_Impact", "MeshInstance3D", true, false)
			_focus_vfx_nodes.append({"replay_frame": replay_frame,
				"active_vfx_blocks": VFXBlockRootScript.active_block_count(),
				"important_block_cap": QualityBudget.max_simultaneous_effects_for("important"),
				"cap_denials_total": VFXBlockRootScript.cap_denial_count(),
				"shafts": shafts.size(), "impacts": impacts.size(),
				"impact_projection": _focus_node_projection(impacts) if replay_frame in [37, 39, 41] else []})
		if not _capture_frames.is_empty() and replay_frame >= _capture_frames[0] \
				and not _capture_busy and DisplayServer.get_name() != "headless":
			_capture_busy = true
			var requested: int = _capture_frames.pop_front()
			_capture_after_draw(requested, replay_frame)


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var key := str(args[i])
		var value := str(args[i + 1]) if i + 1 < args.size() else ""
		match key:
			"--seed":
				if value.is_valid_int():
					_seed = int(value)
			"--round":
				if value.is_valid_int():
					_round = int(value)
			"--tier":
				_tier_name = value.to_upper()
			"--mercenary-id":
				_mercenary_id = value
			"--scan-seeds":
				if value.is_valid_int():
					_scan_seeds = clampi(int(value), 0, 100)
			"--label":
				_label = value.replace("/", "_").replace("\\", "_").replace(":", "_")
			"--out":
				_out_root = value
			"--capture-frames":
				_capture_frames.clear()
				for part in value.split(",", false):
					if part.strip_edges().is_valid_int():
						_capture_frames.append(maxi(0, int(part.strip_edges())))
				_capture_frames.sort()
			"--keep-open":
				_keep_open = true
				i += 1
				continue
			_:
				_warnings.append("unknown_arg:" + key)
				i += 1
				continue
		i += 2
	if _tier_name not in ["LOW", "MEDIUM", "HIGH"]:
		_tier_name = "MEDIUM"
	if _capture_frames.is_empty():
		_capture_frames = [20]
	if _label.is_empty():
		_label = "baseline"


func _tier_value(name_value: String) -> int:
	match name_value:
		"LOW": return QualityBudget.Tier.LOW
		"HIGH": return QualityBudget.Tier.HIGH
		_: return QualityBudget.Tier.MEDIUM


func _add_local_mercenary(unit_id: String) -> bool:
	for value in DataRegistry.get_table("mercenaries").get("mercenaries", []):
		if not (value is Dictionary) or str(value.get("id", "")) != unit_id:
			continue
		var mercenary := {"id": unit_id, "star": 1, "def": (value as Dictionary).duplicate(true)}
		_focus_skill_id = str(value.get("skill_id", ""))
		var slots: Array = GameState.mercenary_slots.duplicate(true)
		if slots.is_empty():
			return false
		slots[0] = mercenary
		GameState.mercenary_slots = slots
		var boards: Dictionary = NetworkService.team_boards.duplicate(true)
		boards[0] = Fixture.board_submission(GameState.board_slots, slots)
		NetworkService.team_boards = boards
		return true
	return false


func _scan_fixed_seeds() -> void:
	for offset in _scan_seeds:
		var candidate_seed := _seed + offset
		Fixture.setup_match_state(_round, candidate_seed)
		if not _mercenary_id.is_empty() and not _add_local_mercenary(_mercenary_id):
			push_error("[SKILL_VFX_REVIEW] missing mercenary: " + _mercenary_id)
			get_tree().quit(1)
			return
		var candidate := BattleSim.compute_team_replay(0,
			"skill_vfx_scan:%d:%d:%s" % [candidate_seed, _round, _mercenary_id])
		if not BattleReplay.valid_team_replay(candidate):
			print("[SKILL_VFX_SCAN] seed=%d invalid_replay" % candidate_seed)
			continue
		var focus := _focus_replay_report(candidate)
		print("[SKILL_VFX_SCAN] seed=%d frames=%d focus=%s" % [candidate_seed,
			(candidate.get("frames", []) as Array).size(), JSON.stringify(focus)])
	get_tree().quit()


func _prime_profile_seen(roster: Dictionary) -> void:
	# Same diagnostic guard as battle_presentation_baseline: avoid codex saves.
	for roster_value in roster.values():
		if not (roster_value is Dictionary):
			continue
		var unit_id := str((roster_value as Dictionary).get("id", ""))
		if not unit_id.is_empty() and not PlayerProfile.codex_seen.has(unit_id):
			PlayerProfile.codex_seen.append(unit_id)


func _index_events(replay: Dictionary) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var buckets: Array = replay.get("frame_events", [])
	for tick in buckets.size():
		if not (buckets[tick] is Array):
			continue
		var events: Array = buckets[tick]
		for ordinal in events.size():
			if not (events[ordinal] is Dictionary):
				continue
			var event: Dictionary = events[ordinal]
			var kind := str(event.get("type", ""))
			if kind not in TRACKED_TYPES:
				continue
			rows.append({
				"event_key": str(event.get("event_key", "tick:%d:%d" % [tick, ordinal])),
				"tick": tick,
				"type": kind,
				"skill_id": str(event.get("skill_id", "")),
				"source_uid": str(event.get("source_uid", "")),
				"target_uids": event.get("target_uids", []),
			})
	return rows


func _skill_ready_candidates(replay: Dictionary) -> Array[Dictionary]:
	# A cooldown rise is a diagnostic candidate, never proof of a successful cast.
	var rows: Array[Dictionary] = []
	var previous: Dictionary = {}
	var frames: Array = replay.get("frames", [])
	for tick in frames.size():
		if not (frames[tick] is Array):
			continue
		for value in frames[tick]:
			if not (value is Array) or (value as Array).size() <= 6:
				continue
			var entry: Array = value
			var uid := str(entry[0])
			var ready := float(entry[6])
			if previous.has(uid) and ready > float(previous[uid]) + 0.1:
				rows.append({"tick": tick, "source_uid": uid,
					"previous_skill_ready": previous[uid], "skill_ready": ready})
			previous[uid] = ready
	return rows


func _focus_replay_report(replay: Dictionary) -> Dictionary:
	var focus_uid := ""
	for key in (replay.get("roster", {}) as Dictionary).keys():
		var unit: Variant = (replay.get("roster", {}) as Dictionary)[key]
		if unit is Dictionary and str(unit.get("id", "")) == _mercenary_id \
				and str(unit.get("team", "")) == "player":
			focus_uid = str(key)
			break
	var report := {"unit_id": _mercenary_id, "skill_id": _focus_skill_id,
		"source_uid": focus_uid, "first_seen_tick": -1, "first_dead_tick": -1,
		"first_skill_ready": -1.0, "skill_ready_rises": 0, "rise_ticks": [],
		"rise_recorded_targets": []}
	if focus_uid.is_empty():
		return report
	var previous_ready := -1.0
	for tick in (replay.get("frames", []) as Array).size():
		var frame: Variant = (replay.get("frames", []) as Array)[tick]
		if not (frame is Array):
			continue
		for entry_value in frame:
			if not (entry_value is Array) or (entry_value as Array).size() <= 6:
				continue
			var entry: Array = entry_value
			if str(entry[0]) != focus_uid:
				continue
			var ready := float(entry[6])
			if int(report["first_seen_tick"]) < 0:
				report["first_seen_tick"] = tick
				report["first_skill_ready"] = ready
			if not bool(entry[4]) and int(report["first_dead_tick"]) < 0:
				report["first_dead_tick"] = tick
			if previous_ready >= 0.0 and ready > previous_ready + 0.1:
				report["skill_ready_rises"] = int(report["skill_ready_rises"]) + 1
				(report["rise_ticks"] as Array).append(tick)
				(report["rise_recorded_targets"] as Array).append({"tick": tick,
					"target_uids": str(entry[12]) if entry.size() > 12 else ""})
			previous_ready = ready
			break
	return report


func _hook_director_before_enter_tree() -> void:
	var director: Object = _screen.get("_presentation_director")
	if director == null:
		_warnings.append("director_unavailable_before_enter_tree")
		return
	director.connect("cue_started", Callable(self, "_on_cue_started"))
	director.connect("cue_completed", Callable(self, "_on_cue_completed"))
	director.connect("cue_dropped", Callable(self, "_on_cue_dropped"))


func _receipt(event_key: String) -> Dictionary:
	if not _receipts.has(event_key):
		_receipts[event_key] = {"started": 0, "completed": 0, "dropped": []}
	return _receipts[event_key]


func _on_cue_started(event_key: String) -> void:
	var row := _receipt(event_key)
	row["started"] = int(row["started"]) + 1


func _on_cue_completed(event_key: String) -> void:
	var row := _receipt(event_key)
	row["completed"] = int(row["completed"]) + 1


func _on_cue_dropped(event_key: String, reason: String) -> void:
	var row := _receipt(event_key)
	(row["dropped"] as Array).append(reason)


func _on_skill_visual_submitted(source_uid: String, skill_id: String,
		target_count: int, core_node_created: bool) -> void:
	_skill_visual_receipts.append({"replay_frame": int(_screen.get("_replay_frame")),
		"source_uid": source_uid, "skill_id": skill_id,
		"resolved_target_count": target_count, "core_node_created": core_node_created})


func _focus_node_projection(nodes: Array) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var camera := _screen.get("_battle_3d_camera") as Camera3D
	for value in nodes:
		var mesh := value as MeshInstance3D
		if mesh == null:
			continue
		var row := {"visible_in_tree": mesh.is_visible_in_tree(),
			"world": str(mesh.global_position)}
		if camera != null:
			row["viewport_xy"] = str(camera.unproject_position(mesh.global_position))
			row["viewport_size"] = str(camera.get_viewport().get_visible_rect().size)
			row["behind_camera"] = camera.is_position_behind(mesh.global_position)
		var material := mesh.material_override as ShaderMaterial
		if material != null:
			row["opacity"] = material.get_shader_parameter("opacity")
			row["reveal"] = material.get_shader_parameter("reveal")
			row["dissolve"] = material.get_shader_parameter("dissolve")
		rows.append(row)
	return rows


func _capture_after_draw(requested: int, actual: int) -> void:
	await RenderingServer.frame_post_draw
	if not is_inside_tree() or _finishing or _screen == null or not is_instance_valid(_screen):
		_capture_busy = false
		return
	var image := get_viewport().get_texture().get_image()
	var path := _out_dir.path_join("frame_%03d.png" % requested)
	# PNG readback and disk encoding are probe overhead, not battle frame cost.
	_skip_next_wall_sample = true
	var status := image.save_png(path) if image != null and not image.is_empty() else ERR_CANT_CREATE
	_screenshots.append({"requested_replay_frame": requested, "actual_replay_frame": actual,
		"path": path if status == OK else "", "status": status})
	_capture_busy = false


func _on_battle_finished(result: Dictionary) -> void:
	_result = result.duplicate(true)
	call_deferred("_finish")


func _finish_with_error(reason: String) -> void:
	_warnings.append(reason)
	_finish(1)


func _finish(exit_code := 0) -> void:
	if _finishing:
		return
	_finishing = true
	var playback_ok := exit_code == 0 and _setup_ready_msec > 0 \
		and not _samples.is_empty() and _result.has("player_wins") \
		and not _result.has("error")
	if not playback_ok:
		_warnings.append("battle_screen_failed_or_never_started:" + str(_result.get("error", "unknown")))
	var frame_values := _wall_samples.duplicate()
	frame_values.sort()
	var summary := {
		"status": "ok" if playback_ok else "error",
		"seed": _seed, "round": _round, "quality_tier": _tier_name,
		"mercenary_id": _mercenary_id, "label": _label,
		"headless": DisplayServer.get_name() == "headless",
		"replay_frames": (_replay.get("frames", []) as Array).size(),
		"replay_simulation_sha256": ReplayDigest.simulation_sha256(_replay) if not _replay.is_empty() else "",
		"replay_payload_sha256": ReplayDigest.payload_sha256(_replay) if not _replay.is_empty() else "",
		"setup_ms": _setup_ready_msec - _start_msec if _setup_ready_msec > 0 else -1,
		"sampled_frames": frame_values.size(),
		"excluded_screenshot_readback_samples": _excluded_capture_samples,
		"p50_wall_ms": _percentile(frame_values, 0.50),
		"p95_wall_ms": _percentile(frame_values, 0.95),
		"p99_wall_ms": _percentile(frame_values, 0.99),
		"max_wall_ms": frame_values[-1] if not frame_values.is_empty() else -1.0,
		"frames_over_50ms": _count_over(frame_values, 50.0),
		"frames_over_100ms": _count_over(frame_values, 100.0),
		"tracked_replay_events": _expected.size(),
		"skill_cast_events": _count_event_type("skill_cast"),
		"unit_skill_proc_events": _count_event_type("unit_skill_proc"),
		"skill_ready_rise_candidates_not_proven_casts": _snapshot_candidates.size(),
		"focus": _focus_replay_report(_replay),
		"focus_vfx_nodes": _focus_vfx_nodes,
		"skill_visual_receipts": _skill_visual_receipts,
		"vfx_cap_denials_during_playback": VFXBlockRootScript.cap_denial_count() - _cap_denials_start if _cap_denials_start >= 0 else -1,
		"director_receipt_keys": _receipts.size(),
		"screenshots": _screenshots,
		"battle_result": _result,
		"warnings": _warnings,
		"limits": ["Director started/completed does not prove a pixel was visible.",
			"skill_ready rise is a candidate, not a successful cast.",
			"Spawned scene nodes do not prove a visible pixel or distinguish overdraw.",
			"Desktop and headless frame times are not Android device performance."],
	}
	if not _out_dir.is_empty():
		_write_json(_out_dir.path_join("summary.json"), summary)
		_write_json(_out_dir.path_join("tracked_events.json"), _expected)
		_write_json(_out_dir.path_join("snapshot_candidates.json"), _snapshot_candidates)
		_write_json(_out_dir.path_join("director_receipts.json"), _receipts)
		_write_json(_out_dir.path_join("frame_samples.json"), _samples)
	print("[SKILL_VFX_REVIEW] status=%s frames=%d events=%d samples=%d output=%s" % [
		str(summary["status"]), int(summary["replay_frames"]), _expected.size(), _samples.size(), _out_dir])
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	if not _keep_open:
		get_tree().quit(0 if playback_ok else 1)


func _count_event_type(kind: String) -> int:
	var count := 0
	for row in _expected:
		if str(row.get("type", "")) == kind:
			count += 1
	return count


func _percentile(sorted_values: Array[float], fraction: float) -> float:
	if sorted_values.is_empty():
		return -1.0
	return sorted_values[maxi(0, int(ceil(sorted_values.size() * fraction)) - 1)]


func _count_over(values: Array[float], threshold: float) -> int:
	var count := 0
	for value in values:
		if value > threshold:
			count += 1
	return count


func _write_json(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SKILL_VFX_REVIEW] Cannot write " + path)
		return
	file.store_string(JSON.stringify(value, "  "))
	file.close()
