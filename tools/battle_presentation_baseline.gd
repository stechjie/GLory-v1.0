extends Node

# Desktop-only D0 baseline recorder for the first two fixed-seed PVE rounds.
#
# This tool is intentionally read-only with respect to combat state: it calls the
# same BattleSimulator replay entry point used by the game, serializes its output,
# then feeds that already-computed replay to BattleScreen for rendering metrics.
# It must never change damage, targeting, RNG consumption, replay payloads, VFX,
# scenes, resources, export presets, or Android configuration.

const BattleSim := preload("res://scripts/battle/BattleSimulator.gd")
const BattleReplay := preload("res://scripts/battle/BattleReplayUtil.gd")
const ReplayDigest := preload("res://tools/ReplayDigest.gd")
const BattleScreenScene := preload("res://scenes/battle/BattleScreen.tscn")
const UnitVisualResolverScript := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")

const TOOL_VERSION := 1
const DEFAULT_SEED := 20260807
const DEFAULT_ROUNDS: Array[int] = [1, 2]
const DEFAULT_LOCALE := "en"
const FIXED_PET_ID := ""
const MIN_PERF_SAMPLES := 30
const ROUND_TIMEOUT_SEC := 180.0
const SCREENSHOT_LABELS: Array[String] = ["start", "mid", "end"]

# Keep this identical to tools/promo_capture.gd and the existing D0 evidence.
const FILL_ORDER: Array[int] = [1, 2, 0, 3, 5, 6, 4, 7]
const LINEUP := {
	"a": [
		["human_swordsman", "human_archer", "human_king", "human_mage"],
		["god_guard", "god_arbiter", "god_king", "god_priestess"],
		["human_militia", "god_aurora", "god_archangel", "human_cleric"],
	],
	"b": [
		["dark_suc", "dark_scythe", "dark_dragon", "dark_mage"],
		["undead_spike", "undead_bomb", "undead_mother", "undead_poison"],
		["dark_fear", "undead_titan", "dark_doom", "undead_fly"],
	],
}

var _out_dir := ""
var _seed := DEFAULT_SEED
var _rounds: Array[int] = DEFAULT_ROUNDS.duplicate()
var _locale := DEFAULT_LOCALE
var _git_commit := ""
var _capture_screenshots := true

var _round_cursor := 0
var _screen: Node = null
var _replay: Dictionary = {}
var _round_dir := ""
var _round_started_msec := 0
var _setup_seen := false
var _render_frame := 0
var _playback_complete_seen := false
var _exclude_next_perf_sample := false
var _round_finishing := false
var _inter_round_frames := 0

var _perf_samples: Array[Dictionary] = []
var _perf_deltas_ms: Array[float] = []
var _peak_video_mb := 0.0
var _peak_texture_mb := 0.0
var _peak_buffer_mb := 0.0
var _peak_static_mb := 0.0
var _peak_nodes := 0
var _peak_objects := 0
var _peak_orphans := 0
var _peak_draw_calls := 0
var _peak_tweens := 0
var _screenshots: Array[Dictionary] = []
var _actor_audit: Dictionary = {}
var _current_summary: Dictionary = {}

var _round_summaries: Array[Dictionary] = []
var _failures: Array[Dictionary] = []
# D3: every cue the Director refused during the round, tallied by reason.
var _director_drops: Dictionary = {}
var _director_missing_actor_drops := 0
# D6: node/orphan counts taken between rounds, after the previous BattleScreen was
# freed. A presentation layer that leaks pooled nodes, tweens or corpses across
# battles shows up here as a rising floor.
var _residue_samples: Array[Dictionary] = []


func _ready() -> void:
	_parse_arguments()
	if _out_dir.is_empty():
		_out_dir = ProjectSettings.globalize_path("user://battle_presentation_baseline")
	if not _ensure_dir(_out_dir):
		get_tree().quit(1)
		return
	DataRegistry.load_all()
	LocaleManager.set_locale(_locale)
	print("[D0BASELINE] output=%s seed=%d rounds=%s locale=%s" % [
		_out_dir, _seed, str(_rounds), _locale])
	call_deferred("_start_next_round")


func _process(delta: float) -> void:
	if _screen == null:
		if _inter_round_frames > 0:
			_inter_round_frames -= 1
			if _inter_round_frames == 0:
				_round_cursor += 1
				_round_finishing = false
				_start_next_round()
		return
	if Time.get_ticks_msec() - _round_started_msec > int(ROUND_TIMEOUT_SEC * 1000.0):
		_record_failure("round_timeout", "Round exceeded %.0f seconds" % ROUND_TIMEOUT_SEC)
		_abort_current_round()
		return
	if not _setup_seen:
		if bool(_screen.get("_battle_setup_ready")):
			_setup_seen = true
			_render_frame = 0
			_actor_audit = _audit_actors()
			if int(_actor_audit.get("blank_uid_count", 0)) > 0:
				_record_failure("blank_roster_uid", "%d roster entries have an empty uid" % int(_actor_audit.get("blank_uid_count", 0)))
			print("[D0BASELINE] round=%d render-ready actors=%d visible_fallbacks=%d" % [
				_current_round(),
				int(_actor_audit.get("actor_present_count", 0)),
				int(_actor_audit.get("visible_body_fallback_count", 0)),
			])
		return
	if _playback_complete_seen:
		return

	_render_frame += 1
	var replay_frame := int(_screen.get("_replay_frame"))
	if _exclude_next_perf_sample:
		_exclude_next_perf_sample = false
	else:
		_record_performance_sample(delta, replay_frame)

	if _capture_screenshots:
		if not _has_screenshot("start") and _render_frame >= 3:
			_capture_screenshot("start", replay_frame)
		elif not _has_screenshot("mid") and replay_frame >= int((_replay.get("frames", []) as Array).size() / 2):
			_capture_screenshot("mid", replay_frame)

	var replay_size := (_replay.get("frames", []) as Array).size()
	if replay_size > 0 and replay_frame >= replay_size - 1:
		_playback_complete_seen = true
		if _capture_screenshots and not _has_screenshot("end"):
			_capture_screenshot("end", replay_frame)


func _start_next_round() -> void:
	if _round_cursor >= _rounds.size():
		_finish_all()
		return
	_reset_round_metrics()
	var round_index := _current_round()
	_round_dir = _out_dir.path_join("round_%02d" % round_index)
	if not _ensure_dir(_round_dir):
		_finish_all()
		return

	_setup_match_state(round_index)
	var compute_start := Time.get_ticks_usec()
	var replay_1: Dictionary = BattleSim.compute_team_replay(0)
	var compute_1_ms := float(Time.get_ticks_usec() - compute_start) / 1000.0

	_setup_match_state(round_index)
	compute_start = Time.get_ticks_usec()
	var replay_2: Dictionary = BattleSim.compute_team_replay(0)
	var compute_2_ms := float(Time.get_ticks_usec() - compute_start) / 1000.0

	if not BattleReplay.valid_team_replay(replay_1):
		_record_failure("invalid_replay", "First replay failed BattleReplayUtil validation")
	if not BattleReplay.valid_team_replay(replay_2):
		_record_failure("invalid_repeat_replay", "Repeat replay failed BattleReplayUtil validation")

	var replay_1_canonical := _canonical_json(replay_1)
	var replay_2_canonical := _canonical_json(replay_2)
	var replay_1_sha := _sha256_text(replay_1_canonical)
	var replay_2_sha := _sha256_text(replay_2_canonical)
	var repeatable := replay_1_sha == replay_2_sha
	var first_difference := ""
	if not repeatable:
		first_difference = _first_difference(replay_1, replay_2)
		_record_failure("replay_not_repeatable", "Replay SHA-256 differs at %s" % first_difference)

	_replay = replay_1
	var frames: Array = _replay.get("frames", [])
	var frame_events: Array = _replay.get("frame_events", [])
	var roster: Dictionary = _replay.get("roster", {})
	var result: Dictionary = _replay.get("result", {})
	if frames.size() != frame_events.size():
		_record_failure("event_frame_count_mismatch", "frames=%d frame_events=%d" % [frames.size(), frame_events.size()])

	var final_state := {
		"final_frame_index": frames.size() - 1,
		"final_frame": frames[-1] if not frames.is_empty() else [],
		"result": result,
	}
	var indexed_events := _indexed_events(frame_events)
	var hashes := {
		"roster_sha256": _sha256_variant(roster),
		"frame_events_sha256": _sha256_variant(frame_events),
		"final_state_sha256": _sha256_variant(final_state),
		"replay_sha256": replay_1_sha,
		"repeat_replay_sha256": replay_2_sha,
		"repeatable": repeatable,
		"first_difference": first_difference,
	}
	var event_summary := _event_summary(frame_events)
	_current_summary = {
		"tool_version": TOOL_VERSION,
		"round": round_index,
		"seed": _seed,
		"locale": _locale,
		"kind": str(_replay.get("kind", "")),
		"roster_count": roster.size(),
		"frame_count": frames.size(),
		"frame_event_bucket_count": frame_events.size(),
		"event_count": int(event_summary.get("event_count", 0)),
		"event_types": event_summary.get("event_types", {}),
		"result_reason": str(result.get("reason", "")),
		"player_wins": bool(result.get("player_wins", false)),
		"sim_elapsed_sec": float(result.get("elapsed", 0.0)),
		"compute_first_ms": compute_1_ms,
		"compute_repeat_ms": compute_2_ms,
		"hashes": hashes,
	}

	_write_json(_round_dir.path_join("roster.json"), roster)
	_write_json(_round_dir.path_join("frame_events.json"), frame_events)
	_write_json(_round_dir.path_join("events_indexed.json"), indexed_events)
	_write_json(_round_dir.path_join("result.json"), result)
	_write_json(_round_dir.path_join("final_state.json"), final_state)
	_write_json(_round_dir.path_join("hashes.json"), hashes)
	_write_text(_round_dir.path_join("replay.canonical.json"), replay_1_canonical + "\n")

	# Re-establish the exact fixed state before rendering the already-computed replay.
	_setup_match_state(round_index)
	_prime_profile_seen(roster)
	GameState.set_pending_battle_package({
		"mode": "team_replay",
		"round_index": round_index,
		"replay": _replay,
	})
	_sample_residue()
	_screen = BattleScreenScene.instantiate()
	if _screen == null:
		_record_failure("battle_screen_instantiate_failed", "Could not instantiate BattleScreen")
		_abort_current_round()
		return
	_screen.connect("battle_finished", Callable(self, "_on_battle_finished"), CONNECT_ONE_SHOT)
	# D3: subscribe before the screen enters the tree so the very first tick is
	# observed. A cue lost to a missing actor is exactly the failure mode this
	# stage has to prove absent on real replay data.
	_hook_presentation_director()
	add_child(_screen)
	_round_started_msec = Time.get_ticks_msec()
	print("[D0BASELINE] round=%d roster=%d frames=%d events=%d replay_sha=%s" % [
		round_index, roster.size(), frames.size(), int(event_summary.get("event_count", 0)), replay_1_sha])


# BattleRenderer marks every encountered unit in the account-level codex. Seed the
# in-memory list directly so mark_seen() is a no-op during this diagnostic run;
# this prevents a baseline capture from writing user://profile.json.
func _prime_profile_seen(roster: Dictionary) -> void:
	for roster_entry_value in roster.values():
		if not (roster_entry_value is Dictionary):
			continue
		var unit_id := str((roster_entry_value as Dictionary).get("id", ""))
		if not unit_id.is_empty() and not PlayerProfile.codex_seen.has(unit_id):
			PlayerProfile.codex_seen.append(unit_id)


func _on_battle_finished(_result: Dictionary) -> void:
	if _round_finishing:
		return
	_round_finishing = true
	if _capture_screenshots and not _has_screenshot("end"):
		_capture_screenshot("end", int(_screen.get("_replay_frame")))
	_finish_current_round()
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = null
	_inter_round_frames = 3


func _finish_current_round() -> void:
	var performance := _performance_summary()
	if int(performance.get("sample_count", 0)) < MIN_PERF_SAMPLES:
		_record_failure("insufficient_perf_samples", "Only %d usable frame samples" % int(performance.get("sample_count", 0)))
	_current_summary["actor_audit"] = _actor_audit
	var director_audit := _director_audit()
	_current_summary["director_audit"] = director_audit
	var resolution: Dictionary = director_audit.get("resolution", {})
	if int(resolution.get("resolved_cues", 0)) <= 0:
		_record_failure("director_resolved_nothing",
			"Director resolved 0 cues; an empty result is a wiring break, not a pass")
	var played: Dictionary = (director_audit.get("legacy_adapter", {}) as Dictionary).get("played_by_type", {})
	var loaded_ids: Array = (director_audit.get("profiles", {}) as Dictionary).get("loaded_ids", [])
	if loaded_ids.size() < 5:
		_record_failure("cue_profiles_missing",
			"expected 5 cue profiles, loaded %d" % loaded_ids.size())
	if played.is_empty():
		_record_failure("slice_played_nothing",
			"The D4 slice adapter played no cue at all; an empty slice cannot be read as a pass")
	_current_summary["performance"] = performance
	_current_summary["screenshots"] = _screenshots.duplicate(true)
	_current_summary["viewport"] = _viewport_metadata()
	_write_perf_csv(_round_dir.path_join("frame_performance.csv"))
	_write_json(_round_dir.path_join("actor_audit.json"), _actor_audit)
	_write_json(_round_dir.path_join("director_audit.json"), director_audit)
	_write_json(_round_dir.path_join("summary.json"), _current_summary)
	_round_summaries.append(_current_summary.duplicate(true))
	print("[D0BASELINE] round=%d avg_fps=%.2f one_pct_low=%.2f samples=%d" % [
		_current_round(),
		float(performance.get("average_fps", 0.0)),
		float(performance.get("one_percent_low_fps", 0.0)),
		int(performance.get("sample_count", 0)),
	])


func _finish_all() -> void:
	_sample_residue()
	_check_cross_battle_residue()
	var manifest := {
		"tool": "battle_presentation_baseline",
		"tool_version": TOOL_VERSION,
		"generated_utc": Time.get_datetime_string_from_system(true, false),
		"project_path": ProjectSettings.globalize_path("res://"),
		"project_version": str(ProjectSettings.get_setting("application/config/version", "")),
		"git_commit": _git_commit,
		"godot": Engine.get_version_info(),
		"os": OS.get_name(),
		"processor": OS.get_processor_name(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"rendering_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"seed": _seed,
		"rounds_requested": _rounds,
		"locale": _locale,
		"lineup": LINEUP,
		"viewport": _viewport_metadata(),
		"rounds": _round_summaries,
		"residue_samples": _residue_samples.duplicate(true),
		"failures": _failures,
		"passed": _failures.is_empty() and _round_summaries.size() == _rounds.size(),
		"android": "DEFERRED_BY_USER",
	}
	_write_json(_out_dir.path_join("manifest.json"), manifest)
	_write_text(_out_dir.path_join("D0_DESKTOP_BASELINE_SUMMARY.md"), _summary_markdown(manifest))
	print("[D0BASELINE] complete passed=%s rounds=%d failures=%d" % [
		str(bool(manifest.get("passed", false))), _round_summaries.size(), _failures.size()])
	get_tree().quit(0 if bool(manifest.get("passed", false)) else 1)


func _abort_current_round() -> void:
	if _screen != null and is_instance_valid(_screen):
		_screen.queue_free()
	_screen = null
	_round_finishing = true
	_inter_round_frames = 1


func _reset_round_metrics() -> void:
	_screen = null
	_replay = {}
	_round_dir = ""
	_setup_seen = false
	_render_frame = 0
	_playback_complete_seen = false
	_exclude_next_perf_sample = false
	_perf_samples.clear()
	_perf_deltas_ms.clear()
	_peak_video_mb = 0.0
	_peak_texture_mb = 0.0
	_peak_buffer_mb = 0.0
	_peak_static_mb = 0.0
	_peak_nodes = 0
	_peak_objects = 0
	_peak_orphans = 0
	_peak_draw_calls = 0
	_peak_tweens = 0
	_screenshots.clear()
	_actor_audit = {}
	_current_summary = {}


func _setup_match_state(round_index: int) -> void:
	GameState.reset_run()
	GameState.team_mode = true
	GameState.round_index = round_index
	GameState.team_hp = GameState.START_FORMATION_HP
	GameState.enemy_team_hp = GameState.START_FORMATION_HP
	GameState.board_slots = _board_from_ids((LINEUP["a"] as Array)[0])
	GameState.mercenary_slots = _empty_mercenary_slots()

	NetworkService.team_active = true
	NetworkService.team_local_slot = 0
	NetworkService.shared_seed = _seed
	NetworkService.team_slot_states = ["player", "player", "player", "player", "player", "player"]
	var boards: Dictionary = {}
	for lane in 3:
		boards[lane] = _fixed_board_submission(_board_from_ids((LINEUP["a"] as Array)[lane]), _empty_mercenary_slots())
		boards[lane + 3] = _fixed_board_submission(_board_from_ids((LINEUP["b"] as Array)[lane]), _empty_mercenary_slots())
	NetworkService.team_boards = boards


func _fixed_board_submission(board: Array, mercenaries: Array) -> Dictionary:
	# A reproducible baseline cannot inherit the account's currently selected pet.
	# D0 was recorded with no pet; pin that fixture without changing PlayerProfile.
	var snapshot: Dictionary = NetProtocol.team_board_submission(board, mercenaries)
	snapshot["pet"] = FIXED_PET_ID
	return snapshot


func _board_from_ids(unit_ids: Array) -> Array:
	var board: Array = []
	board.resize(GameConstants.CELL_COUNT)
	var defs := _unit_defs()
	var placed := 0
	for value in unit_ids:
		if placed >= FILL_ORDER.size() or placed >= GameState.MAX_NORMAL_UNITS:
			break
		var unit_id := str(value)
		if not defs.has(unit_id):
			_record_failure("unknown_unit", "Lineup references missing unit '%s'" % unit_id)
			continue
		var unit_def: Dictionary = (defs[unit_id] as Dictionary).duplicate(true)
		board[FILL_ORDER[placed]] = {"id": unit_id, "star": 3, "def": unit_def}
		placed += 1
	return board


func _empty_mercenary_slots() -> Array:
	var slots: Array = []
	slots.resize(GameState.MERCENARY_SLOTS)
	return slots


func _unit_defs() -> Dictionary:
	var defs: Dictionary = {}
	var units: Array = DataRegistry.get_table("race_units").get("units", [])
	for value in units:
		if value is Dictionary:
			var unit_def := value as Dictionary
			defs[str(unit_def.get("id", ""))] = unit_def
	return defs


func _indexed_events(frame_events: Array) -> Array[Dictionary]:
	var indexed: Array[Dictionary] = []
	for tick_index in frame_events.size():
		indexed.append({
			"tick_index": tick_index,
			"sim_time_sec": float(tick_index + 1) * BattleSimShared.TICK_SEC,
			"events": frame_events[tick_index],
		})
	return indexed


func _event_summary(frame_events: Array) -> Dictionary:
	var count := 0
	var types: Dictionary = {}
	for bucket_value in frame_events:
		if not (bucket_value is Array):
			continue
		for event_value in bucket_value as Array:
			count += 1
			var event_type := "unknown"
			if event_value is Dictionary:
				var event := event_value as Dictionary
				event_type = str(event.get("type", event.get("event", event.get("kind", "unknown"))))
			types[event_type] = int(types.get(event_type, 0)) + 1
	return {"event_count": count, "event_types": types}


func _audit_actors() -> Dictionary:
	var roster: Dictionary = _replay.get("roster", {})
	var models_value = _screen.get("_battle_3d_models")
	var unit_nodes_value = _screen.get("_unit_nodes")
	var models: Dictionary = models_value if models_value is Dictionary else {}
	var unit_nodes: Dictionary = unit_nodes_value if unit_nodes_value is Dictionary else {}
	var entries: Array[Dictionary] = []
	var actor_present_count := 0
	var actor_contract_count := 0
	var live_expected_count := 0
	var missing_live_actor_count := 0
	var not_live_at_audit_count := 0
	var fallback_defined_count := 0
	var visible_fallback_count := 0
	var portrait_fallback_count := 0
	var missing_model_path_count := 0
	var blank_uid_count := 0
	var live_uids: Dictionary = {}
	var state_value = _screen.get("_state")
	if state_value is Dictionary:
		var state := state_value as Dictionary
		for fighter_value in (state.get("player", []) as Array) + (state.get("enemy", []) as Array):
			if fighter_value is Dictionary and bool((fighter_value as Dictionary).get("alive", false)):
				live_uids[str((fighter_value as Dictionary).get("uid", ""))] = true
	var roster_keys: Array = roster.keys()
	roster_keys.sort_custom(Callable(self, "_key_less"))
	for key_value in roster_keys:
		var uid := str(key_value)
		# BattleRenderer._visual_id() falls back to "team_id" when a fighter has no
		# uid, which would register the actor under a key no event can ever name.
		if uid.is_empty():
			blank_uid_count += 1
		var roster_entry: Dictionary = roster.get(key_value, {})
		var unit_def: Dictionary = roster_entry.get("def", {})
		var model_path := str(unit_def.get("model", ""))
		if model_path.is_empty():
			missing_model_path_count += 1
		var model_value = models.get(uid)
		var model: Node = model_value if model_value is Node and is_instance_valid(model_value) else null
		var actor_present := model != null
		var alive_at_audit := live_uids.has(uid)
		if alive_at_audit:
			live_expected_count += 1
		elif not actor_present:
			not_live_at_audit_count += 1
		if actor_present:
			actor_present_count += 1
		elif alive_at_audit:
			missing_live_actor_count += 1
		var anchors := {
			"ActorRoot": actor_present and model.get_node_or_null("ActorRoot") != null,
			"FootAnchor": actor_present and model.get_node_or_null("FootAnchor") != null,
			"FeetAnchor_legacy": actor_present and model.get_node_or_null("FeetAnchor") != null,
			"HeadAnchor": actor_present and model.get_node_or_null("HeadAnchor") != null,
			"CastAnchor": actor_present and model.get_node_or_null("CastAnchor") != null,
			"HitAnchor": actor_present and model.get_node_or_null("HitAnchor") != null,
			"Shadow": actor_present and (model.get_node_or_null("Shadow") != null or model.get_node_or_null("GroundShadow3D") != null),
		}
		var complete_contract := actor_present
		for required in ["ActorRoot", "FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor", "Shadow"]:
			complete_contract = complete_contract and bool(anchors.get(required, false))
		if complete_contract:
			actor_contract_count += 1
		var unit_node_value = unit_nodes.get(uid)
		var unit_node: Node = unit_node_value if unit_node_value is Node and is_instance_valid(unit_node_value) else null
		var fallback: CanvasItem = null
		if unit_node != null:
			var fallback_value = unit_node.get_node_or_null("BodyFallback")
			if fallback_value is CanvasItem:
				fallback = fallback_value as CanvasItem
		var fallback_defined := fallback != null
		var fallback_visible := fallback_defined and fallback.visible and fallback.is_visible_in_tree()
		if fallback_defined:
			fallback_defined_count += 1
		if fallback_visible:
			visible_fallback_count += 1
		var portrait_fallback := actor_present and str(model.get_meta("visual_kind", "")) == "portrait_fallback"
		if portrait_fallback:
			portrait_fallback_count += 1
		entries.append({
			"uid": uid,
			"unit_id": str(roster_entry.get("id", "")),
			"team": str(roster_entry.get("team", "")),
			"model_path": model_path,
			"model_resource_exists": not model_path.is_empty() and ResourceLoader.exists(model_path),
			"alive_at_audit": alive_at_audit,
			"actor_present": actor_present,
			"actor_node_name": model.name if actor_present else "",
			"visual_kind": str(model.get_meta("visual_kind", "")) if actor_present else "",
			"anchors": anchors,
			"complete_actor_contract": complete_contract,
			"body_fallback_defined": fallback_defined,
			"body_fallback_visible": fallback_visible,
			"portrait_fallback_visible": portrait_fallback,
		})
	return {
		"roster_count": roster.size(),
		"live_visual_expected_count": live_expected_count,
		"actor_present_count": actor_present_count,
		"missing_actor_count_raw": roster.size() - actor_present_count,
		"missing_live_actor_count": missing_live_actor_count,
		"not_live_at_audit_count": not_live_at_audit_count,
		"complete_actor_contract_count": actor_contract_count,
		"body_fallback_defined_count": fallback_defined_count,
		"visible_body_fallback_count": visible_fallback_count,
		"visible_portrait_fallback_count": portrait_fallback_count,
		"missing_model_path_count": missing_model_path_count,
		"blank_uid_count": blank_uid_count,
		"entries": entries,
	}


func _record_performance_sample(delta: float, replay_frame: int) -> void:
	if delta <= 0.0 or delta > 1.0:
		return
	var delta_ms := delta * 1000.0
	var video_mb := _monitor_mb(Performance.RENDER_VIDEO_MEM_USED)
	var texture_mb := _monitor_mb(Performance.RENDER_TEXTURE_MEM_USED)
	var buffer_mb := _monitor_mb(Performance.RENDER_BUFFER_MEM_USED)
	var static_mb := _monitor_mb(Performance.MEMORY_STATIC)
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var objects := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var tweens := get_tree().get_processed_tweens().size()
	_peak_video_mb = maxf(_peak_video_mb, video_mb)
	_peak_texture_mb = maxf(_peak_texture_mb, texture_mb)
	_peak_buffer_mb = maxf(_peak_buffer_mb, buffer_mb)
	_peak_static_mb = maxf(_peak_static_mb, static_mb)
	_peak_nodes = maxi(_peak_nodes, nodes)
	_peak_objects = maxi(_peak_objects, objects)
	_peak_orphans = maxi(_peak_orphans, orphans)
	_peak_draw_calls = maxi(_peak_draw_calls, draw_calls)
	_peak_tweens = maxi(_peak_tweens, tweens)
	_perf_deltas_ms.append(delta_ms)
	_perf_samples.append({
		"render_frame": _render_frame,
		"replay_frame": replay_frame,
		"delta_ms": delta_ms,
		"instant_fps": 1.0 / delta,
		"engine_fps": Engine.get_frames_per_second(),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"video_mb": video_mb,
		"texture_mb": texture_mb,
		"buffer_mb": buffer_mb,
		"static_mb": static_mb,
		"objects": objects,
		"nodes": nodes,
		"orphans": orphans,
		"draw_calls": draw_calls,
		"tweens": tweens,
	})


func _performance_summary() -> Dictionary:
	if _perf_deltas_ms.is_empty():
		return {"sample_count": 0, "average_fps": 0.0, "one_percent_low_fps": 0.0}
	var total_ms := 0.0
	for value in _perf_deltas_ms:
		total_ms += value
	var average_fps := float(_perf_deltas_ms.size()) / maxf(0.001, total_ms / 1000.0)
	var sorted_desc := _perf_deltas_ms.duplicate()
	sorted_desc.sort()
	sorted_desc.reverse()
	var slow_count := maxi(1, int(ceil(float(sorted_desc.size()) * 0.01)))
	var slow_total_ms := 0.0
	for index in slow_count:
		slow_total_ms += float(sorted_desc[index])
	var one_percent_low := 1000.0 / maxf(0.001, slow_total_ms / float(slow_count))
	var sorted_asc := _perf_deltas_ms.duplicate()
	sorted_asc.sort()
	var p95_index := clampi(int(ceil(float(sorted_asc.size()) * 0.95)) - 1, 0, sorted_asc.size() - 1)
	return {
		"sample_count": _perf_deltas_ms.size(),
		"average_fps": average_fps,
		"one_percent_low_fps": one_percent_low,
		"p95_frame_time_ms": float(sorted_asc[p95_index]),
		"max_frame_time_ms": float(sorted_desc[0]),
		"measurement_window_sec": total_ms / 1000.0,
		"peak_video_mb": _peak_video_mb,
		"peak_texture_mb": _peak_texture_mb,
		"peak_buffer_mb": _peak_buffer_mb,
		"peak_static_mb": _peak_static_mb,
		"peak_objects": _peak_objects,
		"peak_nodes": _peak_nodes,
		"peak_orphans": _peak_orphans,
		"peak_draw_calls": _peak_draw_calls,
		"peak_tweens": _peak_tweens,
		"screenshots_excluded_from_timing": _capture_screenshots,
	}


func _write_perf_csv(path: String) -> void:
	var headers := [
		"render_frame", "replay_frame", "delta_ms", "instant_fps", "engine_fps",
		"process_ms", "physics_ms", "video_mb", "texture_mb", "buffer_mb", "static_mb",
		"objects", "nodes", "orphans", "draw_calls", "tweens",
	]
	var lines: Array[String] = []
	lines.append(",".join(headers))
	for sample in _perf_samples:
		var cells: Array[String] = []
		for header in headers:
			cells.append(_csv_cell(sample.get(header, "")))
		lines.append(",".join(cells))
	_write_text(path, "\n".join(lines) + "\n")


func _capture_screenshot(label: String, replay_frame: int) -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		_record_failure("screenshot_empty", "Could not capture %s screenshot" % label)
		return
	var path := _round_dir.path_join("%s.png" % label)
	var error := image.save_png(path)
	if error != OK:
		_record_failure("screenshot_write_failed", "%s error=%d" % [path, error])
		return
	_screenshots.append({
		"label": label,
		"path": path,
		"replay_frame": replay_frame,
		"width": image.get_width(),
		"height": image.get_height(),
		"sha256": _sha256_file(path),
	})
	_exclude_next_perf_sample = true


func _has_screenshot(label: String) -> bool:
	for screenshot in _screenshots:
		if str(screenshot.get("label", "")) == label:
			return true
	return false


func _viewport_metadata() -> Dictionary:
	var rect := get_viewport().get_visible_rect()
	return {
		"viewport_width": int(rect.size.x),
		"viewport_height": int(rect.size.y),
		"window_width": DisplayServer.window_get_size().x,
		"window_height": DisplayServer.window_get_size().y,
	}


func _monitor_mb(monitor: int) -> float:
	return float(Performance.get_monitor(monitor)) / 1048576.0


# 以下四个改为委托 tools/ReplayDigest.gd —— determinism_check 要用同一套规范化与哈希，
# 两份实现会漂移，跨平台比对就失去意义。行为逐字不变：Director 的四个冻结哈希依赖它们。
func _canonical_json(value: Variant) -> String:
	return ReplayDigest.canonical_json(value)


func _sha256_variant(value: Variant) -> String:
	return ReplayDigest.sha256_variant(value)


func _sha256_text(value: String) -> String:
	var digest := ReplayDigest.sha256_text(value)
	if digest.is_empty():
		# 保留原有的失败记账：共享实现只返回空串，由调用方决定怎么记。
		_record_failure("hash_start_failed", "HashingContext start failed")
	return digest


func _sha256_file(path: String) -> String:
	return ReplayDigest.sha256_file(path)


func _json_safe(value: Variant) -> Variant:
	return ReplayDigest.json_safe(value)


func _first_difference(a: Variant, b: Variant, path: String = "$") -> String:
	return ReplayDigest.first_difference(a, b, path)


func _write_json(path: String, value: Variant) -> void:
	_write_text(path, JSON.stringify(_json_safe(value), "  ", true, true) + "\n")


func _write_text(path: String, text: String) -> void:
	if not _ensure_dir(path.get_base_dir()):
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_record_failure("file_open_failed", "Could not write %s" % path)
		return
	file.store_string(text)
	file.close()


func _ensure_dir(path: String) -> bool:
	var error := DirAccess.make_dir_recursive_absolute(path)
	if error != OK:
		_record_failure("directory_create_failed", "%s error=%d" % [path, error])
		return false
	return true


func _sample_residue() -> void:
	_residue_samples.append({
		"before_round": _current_round(),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"tweens": get_tree().get_processed_tweens().size(),
	})


func _check_cross_battle_residue() -> void:
	if _residue_samples.size() < 2:
		return
	var first: Dictionary = _residue_samples[0]
	var last: Dictionary = _residue_samples[_residue_samples.size() - 1]
	# A small drift is normal (autoloads warm caches on the first battle); a
	# presentation leak looks like tens or hundreds of nodes surviving each round.
	var node_growth := int(last.get("nodes", 0)) - int(first.get("nodes", 0))
	var orphan_growth := int(last.get("orphans", 0)) - int(first.get("orphans", 0))
	if node_growth > 200:
		_record_failure("cross_battle_node_growth",
			"node count between rounds grew by %d" % node_growth)
	if orphan_growth > 0:
		_record_failure("cross_battle_orphan_growth",
			"orphan node count between rounds grew by %d" % orphan_growth)
	if int(last.get("tweens", 0)) > 0:
		_record_failure("cross_battle_tween_residue",
			"%d tween(s) were still running between rounds" % int(last.get("tweens", 0)))


func _hook_presentation_director() -> void:
	_director_drops = {}
	_director_missing_actor_drops = 0
	UnitVisualResolverScript.reset_failure_report()
	var director_value = _screen.get("_presentation_director")
	if director_value == null:
		_record_failure("presentation_director_missing", "BattleScreen exposed no _presentation_director")
		return
	(director_value as Object).connect("cue_dropped", Callable(self, "_on_cue_dropped"))


func _on_cue_dropped(event_key: String, reason: String) -> void:
	_director_drops[reason] = int(_director_drops.get(reason, 0)) + 1
	if not reason.begins_with("missing_actor"):
		return
	_director_missing_actor_drops += 1
	# Cap the recorded detail so one systemic wiring break cannot flood the report;
	# the counter below still carries the true total.
	if _director_missing_actor_drops <= 5:
		_record_failure("director_missing_actor", "%s dropped: %s" % [event_key, reason])


func _director_audit() -> Dictionary:
	var stats: Dictionary = {}
	if _screen != null and is_instance_valid(_screen):
		var director_value = _screen.get("_presentation_director")
		if director_value != null and (director_value as Object).has_method("resolution_stats"):
			stats = (director_value as Object).call("resolution_stats")
	var adapter_stats: Dictionary = {}
	if _screen != null and is_instance_valid(_screen):
		var adapter_value = _screen.get("_legacy_vfx_adapter")
		if adapter_value != null and (adapter_value as Object).has_method("stats"):
			adapter_stats = (adapter_value as Object).call("stats")
	var budget_stats: Dictionary = {}
	var profile_report: Dictionary = {}
	if _screen != null and is_instance_valid(_screen):
		var director_obj = _screen.get("_presentation_director")
		if director_obj != null and (director_obj as Object).has_method("budget_stats"):
			budget_stats = (director_obj as Object).call("budget_stats")
		var resolver_obj = _screen.get("_vfx_profile_resolver")
		if resolver_obj != null and (resolver_obj as Object).has_method("resolved_counts"):
			profile_report = {
				"loaded_ids": (resolver_obj as Object).call("profile_ids"),
				"resolved_counts": (resolver_obj as Object).call("resolved_counts"),
				"missing_rows": (resolver_obj as Object).call("missing_rows"),
			}
	var anchor_rows: Array[Dictionary] = []
	for row in UnitVisualResolverScript.failure_rows():
		if str(row.get("consumer", "")) == "director":
			anchor_rows.append(row)
	return {
		"drops_by_reason": _director_drops.duplicate(true),
		"drop_count": _director_drop_total(),
		"missing_actor_drop_count": _director_missing_actor_drops,
		"anchor_degradation_rows": anchor_rows,
		"anchor_degradation_count": anchor_rows.size(),
		"resolution": stats,
		"legacy_adapter": adapter_stats,
		"budget": budget_stats,
		"profiles": profile_report,
	}


func _director_drop_total() -> int:
	var total := 0
	for value in _director_drops.values():
		total += int(value)
	return total


func _record_failure(code: String, detail: String) -> void:
	var failure := {"round": _current_round() if _round_cursor < _rounds.size() else -1, "code": code, "detail": detail}
	_failures.append(failure)
	push_error("[D0BASELINE] %s: %s" % [code, detail])


func _summary_markdown(manifest: Dictionary) -> String:
	var lines: Array[String] = [
		"# D0 Desktop Battle Presentation Baseline",
		"",
		"- Generated UTC: `%s`" % str(manifest.get("generated_utc", "")),
		"- Seed: `%d`" % _seed,
		"- Locale: `%s`" % _locale,
		"- Godot: `%s`" % str((manifest.get("godot", {}) as Dictionary).get("string", "")),
		"- Renderer: `%s`" % str(manifest.get("rendering_method", "")),
		"- Android: `DEFERRED_BY_USER`",
		"- Tool pass: `%s`" % str(bool(manifest.get("passed", false))),
		"",
		"| Round | Roster | Frames | Events | Replay SHA-256 | Final-state SHA-256 | Avg FPS | 1% Low | Visible fallbacks | Complete actor contracts |",
		"| ---: | ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | ---: |",
	]
	for summary in _round_summaries:
		var hashes: Dictionary = summary.get("hashes", {})
		var performance: Dictionary = summary.get("performance", {})
		var audit: Dictionary = summary.get("actor_audit", {})
		lines.append("| %d | %d | %d | %d | `%s` | `%s` | %.2f | %.2f | %d | %d/%d |" % [
			int(summary.get("round", 0)),
			int(summary.get("roster_count", 0)),
			int(summary.get("frame_count", 0)),
			int(summary.get("event_count", 0)),
			str(hashes.get("replay_sha256", "")),
			str(hashes.get("final_state_sha256", "")),
			float(performance.get("average_fps", 0.0)),
			float(performance.get("one_percent_low_fps", 0.0)),
			int(audit.get("visible_body_fallback_count", 0)),
			int(audit.get("complete_actor_contract_count", 0)),
			int(audit.get("roster_count", 0)),
		])
	lines.append("")
	lines.append("## Failures")
	lines.append("")
	if _failures.is_empty():
		lines.append("None.")
	else:
		for failure in _failures:
			lines.append("- Round %d `%s`: %s" % [int(failure.get("round", -1)), str(failure.get("code", "")), str(failure.get("detail", ""))])
	lines.append("")
	lines.append("This report closes only the desktop D0 data/performance gate. Android remains deferred, and a visible-fallback count of zero does not mean the E1 actor/fallback architecture is complete.")
	lines.append("")
	return "\n".join(lines)


func _csv_cell(value: Variant) -> String:
	var text := str(value)
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		return "\"%s\"" % text.replace("\"", "\"\"")
	return text


func _key_less(a: Variant, b: Variant) -> bool:
	return str(a) < str(b)


func _current_round() -> int:
	return _rounds[_round_cursor] if _round_cursor >= 0 and _round_cursor < _rounds.size() else -1


func _parse_arguments() -> void:
	var args := OS.get_cmdline_user_args()
	var index := 0
	while index < args.size():
		var key := str(args[index])
		var value := str(args[index + 1]) if index + 1 < args.size() else ""
		match key:
			"--out":
				_out_dir = value
			"--seed":
				_seed = int(value)
			"--locale":
				_locale = value
			"--git-commit":
				_git_commit = value
			"--no-screenshots":
				_capture_screenshots = false
				index += 1
				continue
			_:
				push_warning("[D0BASELINE] unknown argument '%s'" % key)
				index += 1
				continue
		index += 2
