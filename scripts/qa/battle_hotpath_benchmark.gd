extends Node

# QA-only CPU microbenchmark, explicitly not a frame-rate, GPU or heat test.
# Both arms execute in one process/PCK. Only the three isolated hotspots differ;
# gameplay replay generation, scene-node infrastructure and Registry are shared.
# No production entry point, rendering setting or asset is modified.
const OldVfx := preload("res://scripts/qa/hotpath_baseline_vfx.gd")
const NewVfx := preload("res://scenes/battle/BattleVfx.gd")
const OldStatus := preload("res://scripts/qa/hotpath_baseline_status.gd")
const NewStatus := preload("res://scenes/battle/StatusVFXController.gd")
const Registry := preload("res://effects/runtime/presentation/UnitActorRegistry.gd")
const Fixture := preload("res://scripts/qa/FixedBattleFixture.gd")
const Simulator := preload("res://scripts/battle/BattleSimulator.gd")
const ReplayUtil := preload("res://scripts/battle/BattleReplayUtil.gd")
const ReplayScreen := preload("res://scenes/battle/BattleScreen.gd")
const Digest := preload("res://scripts/qa/ReplayDigest.gd")
const SourceManifest := preload("res://scripts/qa/hotpath_baseline_manifest.gd")

class CountingRegistry:
	extends "res://effects/runtime/presentation/UnitActorRegistry.gd"
	var actor_reads: int = 0
	var anchor_reads: int = 0
	func get_actor(uid: String) -> Node3D:
		actor_reads += 1
		return super.get_actor(uid)
	func get_anchor(uid: String, anchor_name: String) -> Node3D:
		anchor_reads += 1
		return super.get_anchor(uid, anchor_name)

const ROUNDS: Array[int] = [1, 5, 20, 21]
const SEED: int = 20260807
const ANCHORS: Array[String] = ["ActorRoot", "FootAnchor", "HeadAnchor", "CastAnchor", "HitAnchor", "Shadow"]

var _batches: int = 7
var _cycles: int = 24
var _warmup_cycles: int = 3
var _run_label: String = "default"
var _variant_label: String = "same-process-ab"
var _out_dir: String = "user://hotpath-benchmark"
var _checks: int = 0
var _failures: Array = []
var _cases: Array = []
var _round_reports: Array = []
var _sink: int = 0
var _result: Dictionary = {}
var _started_usec: int = 0


func _ready() -> void:
	_parse_args()
	_started_usec = Time.get_ticks_usec()
	_result = {
		"schema_version": 1,
		"passed": false,
		"status": "running",
		"run": _run_label,
		"variant": _variant_label,
		"scope": "isolated script CPU hotspots; no pixel drawing or frame pacing measurement",
		"not_measured": ["iPhone temperature", "iPhone power", "GPU throughput", "game FPS", "whole-game speedup"],
		"runtime": _runtime(),
		"source_manifest": SourceManifest.DATA,
		"protocol": {
			"batches": _batches, "cycles_per_batch": _cycles,
			"warmup_cycles_excluded": _warmup_cycles,
			"order": "AB on even batches, BA on odd batches; per-arm median and paired reductions",
			"timed_registry": "unmodified production Registry; counting subclass only outside timing",
			"status_nodes": "real controllers and Sprite3D instances; hidden parents; automatic process disabled equally",
			"decoder": "production BattleScreen roster and frame decoder; event enactment suppressed, outside timing",
			"shared_registry_fix": "both arms use validity-before-type check for freed actors",
			"clock": "Time.get_ticks_usec monotonic wall duration around synchronous CPU loops",
			"interpretation": "same simulator-process relative CPU timing only; not mobile hardware performance"
		}
	}
	_write_results()
	call_deferred("_run")


func _parse_args() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty() and not DeviceHarness.tool_args.is_empty():
		args = DeviceHarness.tool_args
	if args.is_empty():
		args = OS.get_cmdline_args()
	var at: int = 0
	while at < args.size():
		var key: String = str(args[at])
		if at + 1 < args.size():
			match key:
				"--batches":
					_batches = maxi(7, int(args[at + 1]))
					at += 1
				"--cycles":
					_cycles = maxi(1, int(args[at + 1]))
					at += 1
				"--run":
					_run_label = str(args[at + 1]).validate_filename()
					at += 1
				"--variant":
					_variant_label = str(args[at + 1])
					at += 1
				"--out":
					_out_dir = str(args[at + 1])
					at += 1
		at += 1


func _runtime() -> Dictionary:
	var settings: Dictionary = {}
	for key in [
		"rendering/renderer/rendering_method", "rendering/renderer/rendering_method.mobile",
		"rendering/scaling_3d/scale", "display/window/size/viewport_width",
		"display/window/size/viewport_height", "display/window/stretch/mode",
		"rendering/anti_aliasing/quality/msaa_3d"
	]:
		if ProjectSettings.has_setting(key):
			settings[key] = ProjectSettings.get_setting(key)
	var resource_hashes: Dictionary = {}
	for path: String in SourceManifest.DATA.get("current_sources", {}):
		var resource_path: String = "res://" + path
		if FileAccess.file_exists(resource_path):
			resource_hashes[path] = FileAccess.get_sha256(resource_path)
	return {
		"os": OS.get_name(), "model": OS.get_model_name(),
		"engine": Engine.get_version_info(), "debug_build": OS.is_debug_build(),
		"pid": OS.get_process_id(), "processor": OS.get_processor_name(),
		"processor_count": OS.get_processor_count(), "display_server": DisplayServer.get_name(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"features": {"arm64": OS.has_feature("arm64"), "ios": OS.has_feature("ios"), "mobile": OS.has_feature("mobile")},
		"project_settings_read_only": settings,
		"available_resource_byte_hashes": resource_hashes,
		"resource_hash_note": "Exported resources may be compiled/remapped; original-source identities are in source_manifest",
		"started_utc": Time.get_datetime_string_from_system(true)
	}


func _run() -> void:
	DataRegistry.load_all()
	LocaleManager.set_locale("en")
	_check_uid_edges()
	for round_index: int in ROUNDS:
		_run_round(round_index)
		if not _failures.is_empty():
			break
	_result["passed"] = _failures.is_empty() and _round_reports.size() == ROUNDS.size()
	_result["status"] = "finished"
	_result["checks"] = _checks
	_result["failures"] = _failures
	_result["cases"] = _cases
	_result["rounds"] = _round_reports
	_result["sink"] = _sink
	_result["elapsed_ms"] = float(Time.get_ticks_usec() - _started_usec) / 1000.0
	_write_results()
	print("[HOTPATH_BENCH] passed=%s checks=%d cases=%d output=%s" % [
		str(_result.passed), _checks, _cases.size(), ProjectSettings.globalize_path(_out_dir.path_join("results.json"))])
	get_tree().quit(0 if bool(_result.passed) else 1)


func _check(condition: bool, label: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(label)
		printerr("[HOTPATH_BENCH_FAIL] " + label)
	return condition


func _check_uid_edges() -> void:
	var old = OldVfx.new()
	var current = NewVfx.new()
	var cases: Array = [
		{}, {"team": "player", "id": "human_swordsman"},
		{"uid": "present"}, {"uid": ""}, {"uid": null}, {"uid": 17},
		{"uid": 0.5}, {"uid": StringName("named")}, {"team": null, "id": 42}
	]
	for i: int in cases.size():
		_check(old._visual_id(cases[i]) == current._visual_id(cases[i]), "uid_edge_%d" % i)
	_measure_pair("uid_boundary_inputs", old, current, cases, "uid", cases.size(), {})
	old.free()
	current.free()


func _run_round(round_index: int) -> void:
	Fixture.setup_match_state(round_index, SEED)
	var started: int = Time.get_ticks_usec()
	var replay: Dictionary = Simulator.compute_team_replay(0)
	var compute_ms: float = float(Time.get_ticks_usec() - started) / 1000.0
	if not _check(ReplayUtil.valid_team_replay(replay), "round_%d_valid_replay" % round_index):
		return
	var simulation_sha: String = Digest.simulation_sha256(replay)
	Fixture.setup_match_state(round_index, SEED)
	var repeated: Dictionary = Simulator.compute_team_replay(0)
	if not _check(simulation_sha == Digest.simulation_sha256(repeated), "round_%d_deterministic_simulation" % round_index):
		return
	var samples: Array = _decode_samples(replay)
	if not _check(not samples.is_empty(), "round_%d_nonempty_samples" % round_index):
		return
	var roster: Dictionary = replay.get("roster", {})
	var report: Dictionary = {
		"round": round_index, "kind": replay.get("kind"), "seed": SEED,
		"roster_units": roster.size(), "replay_frames": (replay.get("frames", []) as Array).size(),
		"simulation_sha256": simulation_sha, "payload_sha256": Digest.payload_sha256(replay),
		"replay_compute_ms_context_only": compute_ms,
		"samples": []
	}
	var states: Array = []
	for sample_value: Dictionary in samples:
		states.append(sample_value.state)
		report.samples.append(sample_value.metadata)
	_round_reports.append(report)
	var world: Node3D = Node3D.new()
	world.name = "CPUOnlyHiddenFixture"
	world.visible = false
	add_child(world)
	var arena: Control = Control.new()
	add_child(arena)
	arena.size = Vector2(1600, 720)
	var vfx_root: Node3D = Node3D.new()
	world.add_child(vfx_root)
	vfx_root.position = Vector3(2.0, -0.5, 1.5)
	vfx_root.rotation.y = -0.2
	vfx_root.scale = Vector3(0.8, 1.1, 1.3)
	var old = OldVfx.new()
	var current = NewVfx.new()
	# These are function receivers only. Do not enter BattleScreen._ready or
	# build a renderer; actual actor/anchor nodes live in the hidden scene.
	var actors: Dictionary = {}
	for uid: String in roster:
		var actor: Node3D = _make_actor(world, Vector3(float(actors.size()) * 0.17, 0.0, -0.3))
		actors[uid] = actor
	for screen in [old, current]:
		screen._arena = arena
		screen._battle_3d_vfx_root = vfx_root
		screen._unit_actor_registry = Registry.new()
		for uid: String in actors:
			_check(screen._unit_actor_registry.register_actor(uid, actors[uid]), "round_%d_register_%s" % [round_index, uid])
	_check_collections(round_index, old, current, states)
	_check_actor_lifecycle(round_index, old, current, states[0], actors, world)
	var counts: Dictionary = _probe_collect_counts(old, current, states, actors)
	_measure_pair("round_%d_collect_vfx_units" % round_index, old, current, states, "collect",
		states.size(), counts)
	var uid_inputs: Array = []
	for side: String in ["player", "enemy"]:
		for fighter: Dictionary in states[0].get(side, []):
			uid_inputs.append(fighter)
	_measure_pair("round_%d_uid" % round_index, old, current, uid_inputs, "uid", uid_inputs.size(),
		{"uid_present_inputs": uid_inputs.size(), "fallback_inputs": 0})
	_run_status_case(round_index, states, false, world)
	_run_status_case(round_index, states, true, world)
	old._unit_actor_registry.clear()
	current._unit_actor_registry.clear()
	old.free()
	current.free()
	arena.free()
	world.free()


func _decode_samples(replay: Dictionary) -> Array:
	var frames: Array = replay.get("frames", [])
	var wanted: Dictionary = {}
	for fraction: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
		wanted[int(float(frames.size() - 1) * fraction)] = true
	var richest_status_tick: int = 0
	var richest_status_count: int = -1
	var first_dead_tick: int = -1
	for tick: int in frames.size():
		var count: int = 0
		for row: Array in frames[tick]:
			if row.size() > 9 and row[9] is Dictionary and not (row[9] as Dictionary).is_empty():
				count += 1
			if row.size() > 4 and not bool(row[4]) and first_dead_tick < 0:
				first_dead_tick = tick
		if count > richest_status_count:
			richest_status_count = count
			richest_status_tick = tick
	wanted[richest_status_tick] = true
	if first_dead_tick >= 0:
		wanted[first_dead_tick] = true
	var decoder = ReplayScreen.new()
	decoder._replay = replay
	decoder._load_replay_roster(replay)
	# Only event enactment is bypassed. All fighter tuple decoding, team
	# conversions and presentation-state side channels use production code.
	decoder._replay_events_applied = frames.size()
	var result: Array = []
	for tick: int in frames.size():
		decoder._apply_replay_frame(tick)
		if wanted.has(tick):
			var state: Dictionary = decoder._state.duplicate(true)
			var alive: int = 0
			var dead: int = 0
			var status_units: int = 0
			for side: String in ["player", "enemy"]:
				for fighter: Dictionary in state.get(side, []):
					if bool(fighter.get("alive", false)):
						alive += 1
					else:
						dead += 1
					if not (fighter.get("statuses", {}) as Dictionary).is_empty():
						status_units += 1
			result.append({"state": state, "metadata": {
				"tick": tick, "alive": alive, "dead_retained": dead,
				"status_units": status_units, "input_sha256": Digest.sha256_variant(state)
			}})
	decoder.free()
	return result


func _make_actor(parent: Node3D, offset: Vector3) -> Node3D:
	var actor: Node3D = Node3D.new()
	parent.add_child(actor)
	actor.position = offset
	actor.rotation.y = 0.31
	actor.scale = Vector3(1.2, 0.9, 1.1)
	for anchor_name: String in ANCHORS:
		var anchor: Node3D = Node3D.new()
		anchor.name = anchor_name
		actor.add_child(anchor)
		anchor.position = Vector3(float(actor.get_child_count()) * 0.1, float(actor.get_child_count()) * 0.2, -0.3)
	return actor


func _compare_collect(old, current, state: Dictionary, label: String) -> Dictionary:
	var input_before: Dictionary = state.duplicate(true)
	old._state = state
	current._state = state
	var a: Dictionary = old._collect_vfx_units(state)
	var b: Dictionary = current._collect_vfx_units(state)
	_check(a == b, label + "_all_snapshot_fields_equal")
	_check(state == input_before, label + "_input_unmodified")
	return b


func _check_collections(round_index: int, old, current, states: Array) -> void:
	for i: int in states.size():
		var previous: Dictionary = _compare_collect(old, current, states[i], "round_%d_sample_%d" % [round_index, i])
		var frozen_previous: Dictionary = previous.duplicate(true)
		var next_state: Dictionary = states[(i + 1) % states.size()]
		_compare_collect(old, current, next_state, "round_%d_double_buffer_%d" % [round_index, i])
		_check(previous == frozen_previous, "round_%d_double_buffer_retains_previous_%d" % [round_index, i])


func _check_actor_lifecycle(round_index: int, old, current, state: Dictionary, actors: Dictionary, world: Node3D) -> void:
	var uid: String = str(actors.keys()[0])
	var actor: Node3D = actors[uid]
	actor.position += Vector3(1.0, 0.2, -0.4)
	(actor.get_node("HeadAnchor") as Node3D).position += Vector3(0.1, 0.3, 0.2)
	_compare_collect(old, current, state, "round_%d_dynamic_anchor" % round_index)
	var dead_state: Dictionary = state.duplicate(true)
	for side: String in ["player", "enemy"]:
		for fighter: Dictionary in dead_state.get(side, []):
			if str(fighter.get("uid", "")) == uid:
				fighter.alive = false
				fighter.hp = 0
	var dead_snapshot: Dictionary = _compare_collect(old, current, dead_state, "round_%d_corpse_retention" % round_index)
	_check(dead_snapshot.has(uid) and dead_snapshot[uid].model_node == actor, "round_%d_dead_actor_still_resolves" % round_index)
	var replacement: Node3D = _make_actor(world, Vector3(-3, 2, 1))
	for screen in [old, current]:
		_check(screen._unit_actor_registry.register_actor(uid, replacement), "round_%d_replace_register" % round_index)
		_check(not screen._unit_actor_registry.unregister_if_holds(uid, actor), "round_%d_old_corpse_cannot_unregister_new_actor" % round_index)
	actor.free()
	actors[uid] = replacement
	var replaced: Dictionary = _compare_collect(old, current, state, "round_%d_same_uid_replacement" % round_index)
	_check(replaced[uid].model_node == replacement, "round_%d_replacement_resolved" % round_index)
	# Exercise the shared Registry safety fix; no per-arm timing credit for it.
	replacement.free()
	_compare_collect(old, current, state, "round_%d_freed_actor_no_crash" % round_index)
	var restored: Node3D = _make_actor(world, Vector3(0.4, 0.0, 0.2))
	actors[uid] = restored
	for screen in [old, current]:
		_check(screen._unit_actor_registry.register_actor(uid, restored), "round_%d_restore_register" % round_index)
	_compare_collect(old, current, state, "round_%d_restored_actor" % round_index)


func _probe_collect_counts(old, current, states: Array, actors: Dictionary) -> Dictionary:
	var saved: Array = [old._unit_actor_registry, current._unit_actor_registry]
	var reports: Array = []
	var which: int = 0
	for screen in [old, current]:
		var probe = CountingRegistry.new()
		for uid: String in actors:
			probe.register_actor(uid, actors[uid])
		screen._unit_actor_registry = probe
		var units: int = 0
		for state: Dictionary in states:
			screen._state = state
			screen._collect_vfx_units(state)
			units += (state.get("player", []) as Array).size() + (state.get("enemy", []) as Array).size()
		reports.append({
			"collector_calls": states.size(), "unit_records": units,
			"actor_reads_observed": probe.actor_reads, "registry_anchor_reads_observed": probe.anchor_reads
		})
		screen._unit_actor_registry = saved[which]
		which += 1
	_check(int(reports[0].actor_reads_observed) == int(reports[0].unit_records) * 9, "baseline_nine_actor_reads_per_unit")
	_check(int(reports[1].actor_reads_observed) == int(reports[1].unit_records), "current_one_actor_read_per_unit")
	return {"probe_outside_timed_region": true, "baseline": reports[0], "current": reports[1]}


func _run_status_case(round_index: int, states: Array, missing: bool, world: Node3D) -> void:
	var failures_before: int = _failures.size()
	var fighters: Array = []
	var baseline_controllers: Array = []
	var current_controllers: Array = []
	var by_uid: Dictionary = {}
	var hosts: Array = []
	var actual_status_inputs: int = 0
	for state: Dictionary in states:
		for side: String in ["player", "enemy"]:
			for fighter_source: Dictionary in state.get(side, []):
				var fighter: Dictionary = fighter_source.duplicate(true)
				if missing:
					fighter.erase("statuses")
					fighter.shield = 0
				elif not (fighter.get("statuses", {}) as Dictionary).is_empty():
					actual_status_inputs += 1
				var uid: String = str(fighter.get("uid", ""))
				if not by_uid.has(uid):
					var old_host: Node3D = Node3D.new()
					var current_host: Node3D = Node3D.new()
					world.add_child(old_host)
					world.add_child(current_host)
					hosts.append(old_host)
					hosts.append(current_host)
					var a = OldStatus.new()
					var b = NewStatus.new()
					old_host.add_child(a)
					current_host.add_child(b)
					a.process_mode = Node.PROCESS_MODE_DISABLED
					b.process_mode = Node.PROCESS_MODE_DISABLED
					a._phase = 0.25
					b._phase = 0.25
					by_uid[uid] = [a, b]
				fighters.append(fighter)
				baseline_controllers.append(by_uid[uid][0])
				current_controllers.append(by_uid[uid][1])
	var suffix: String = "missing_status_field" if missing else "replay_status_sequence"
	var label: String = "round_%d_status_%s" % [round_index, suffix]
	for i: int in fighters.size():
		var before: Dictionary = fighters[i].duplicate(true)
		baseline_controllers[i].update_from_fighter(fighters[i])
		current_controllers[i].update_from_fighter(fighters[i])
		_check(_status_state(baseline_controllers[i]) == _status_state(current_controllers[i]), label + "_equivalence_%d" % i)
		_check(fighters[i] == before, label + "_input_%d" % i)
		baseline_controllers[i]._process(0.1)
		current_controllers[i]._process(0.1)
		_check(_status_state(baseline_controllers[i]) == _status_state(current_controllers[i]), label + "_phase_%d" % i)
	var details: Dictionary = {
		"input_updates_per_cycle": fighters.size(), "unique_controllers_per_arm": by_uid.size(),
		"actual_replay_status_inputs": actual_status_inputs,
		"missing_field_overlay": missing,
		"overlay_note": "Missing-field case erases statuses and sets shield=0 on copies of real replay fighters" if missing else "Unmodified real replay fighter inputs",
		"automatic_process_disabled_equally": true
	}
	_measure_pair(label, baseline_controllers, current_controllers, fighters, "status", fighters.size(), details)
	for uid: String in by_uid:
		_check(_status_state(by_uid[uid][0]) == _status_state(by_uid[uid][1]), label + "_final_state_" + uid)
	_cases[-1]["passed"] = _failures.size() == failures_before
	for host: Node3D in hosts:
		host.free()


func _status_state(controller) -> Dictionary:
	var sprites: Dictionary = {}
	for kind: String in controller._sprites:
		var sprite: Sprite3D = controller._sprites[kind]
		sprites[kind] = {
			"visible": sprite.visible, "texture": sprite.texture,
			"parent": str(sprite.get_parent().name),
			"pixel_size": sprite.pixel_size, "billboard": sprite.billboard
		}
	return {
		"active": controller._active_kinds.duplicate(), "slots": controller._slot_x.duplicate(),
		"shield": controller._shield_amount, "phase": controller._shield_phase,
		"elapsed": controller._shield_phase_elapsed, "pending": controller._shield_hide_pending,
		"processing": controller.is_processing(), "sprites": sprites
	}


func _execute(receiver, inputs: Array, mode: String, cycles: int) -> int:
	var accumulator: int = 0
	match mode:
		"uid":
			for cycle: int in cycles:
				for fighter: Dictionary in inputs:
					accumulator += receiver._visual_id(fighter).length()
		"collect":
			for cycle: int in cycles:
				for state: Dictionary in inputs:
					receiver._state = state
					accumulator += receiver._collect_vfx_units(state).size()
		"status":
			for cycle: int in cycles:
				for i: int in inputs.size():
					receiver[i].update_from_fighter(inputs[i])
			accumulator = inputs.size() * cycles
	return accumulator


func _measure_pair(label: String, baseline, current, inputs: Array, mode: String, calls_per_cycle: int, details: Dictionary) -> void:
	var failures_before: int = _failures.size()
	var checks_before: int = _checks
	# Explicit per-case output equivalence is outside the timed region.
	match mode:
		"uid":
			for i: int in inputs.size():
				_check(baseline._visual_id(inputs[i]) == current._visual_id(inputs[i]), label + "_exact_uid_%d" % i)
		"collect":
			for i: int in inputs.size():
				_compare_collect(baseline, current, inputs[i], label + "_exact_snapshot_%d" % i)
		"status":
			for i: int in inputs.size():
				baseline[i].update_from_fighter(inputs[i])
				current[i].update_from_fighter(inputs[i])
				_check(_status_state(baseline[i]) == _status_state(current[i]), label + "_exact_status_%d" % i)
	var warm_a: int = _execute(baseline, inputs, mode, _warmup_cycles)
	var warm_b: int = _execute(current, inputs, mode, _warmup_cycles)
	_check(warm_a == warm_b, label + "_warmup_result")
	var original_us: Array = []
	var current_us: Array = []
	var batch_rows: Array = []
	var paired_reductions: Array = []
	var cycles: int = _cycles * (16 if mode == "uid" else 1)
	for batch: int in _batches:
		var order: Array = [0, 1] if batch % 2 == 0 else [1, 0]
		var measured: Array = [0, 0]
		var receipts: Array = [0, 0]
		for arm: int in order:
			var receiver = baseline if arm == 0 else current
			var started: int = Time.get_ticks_usec()
			receipts[arm] = _execute(receiver, inputs, mode, cycles)
			measured[arm] = Time.get_ticks_usec() - started
		_check(receipts[0] == receipts[1], label + "_batch_%d_same_work" % batch)
		_sink += int(receipts[0]) + int(receipts[1])
		original_us.append(measured[0])
		current_us.append(measured[1])
		var reduction: float = 100.0 * (1.0 - float(measured[1]) / maxf(1.0, float(measured[0])))
		paired_reductions.append(reduction)
		batch_rows.append({
			"batch": batch, "order": "AB" if order[0] == 0 else "BA",
			"baseline_us": measured[0], "current_us": measured[1],
			"paired_reduction_percent": reduction, "same_work_checksum": receipts[0]
		})
	var original_median: float = _median(original_us)
	var current_median: float = _median(current_us)
	var calls: int = cycles * calls_per_cycle
	var summary: Dictionary = {
		"name": label, "hotspot": mode, "batches": batch_rows,
		"passed": _failures.size() == failures_before, "case_checks": _checks - checks_before,
		"input_sha256": Digest.sha256_variant(inputs), "timed_calls_per_arm": calls * _batches,
		"calls_per_arm_per_batch": calls,
		"baseline_median_us": original_median, "current_median_us": current_median,
		"baseline_median_us_per_call": original_median / maxf(1.0, float(calls)),
		"current_median_us_per_call": current_median / maxf(1.0, float(calls)),
		"median_time_reduction_percent": 100.0 * (1.0 - current_median / maxf(1.0, original_median)),
		"paired_reduction_median_percent": _median(paired_reductions),
		"baseline_min_us": original_us.min(), "baseline_max_us": original_us.max(),
		"current_min_us": current_us.min(), "current_max_us": current_us.max(),
		"details": details
	}
	_cases.append(summary)
	print("[HOTPATH_CASE] %s original=%.1fus current=%.1fus reduction=%.2f%% calls=%d" % [
		label, original_median, current_median, summary.median_time_reduction_percent, calls])


func _median(values: Array) -> float:
	var sorted_values: Array = values.duplicate()
	sorted_values.sort()
	var center: int = sorted_values.size() / 2
	if sorted_values.size() % 2 == 1:
		return float(sorted_values[center])
	return (float(sorted_values[center - 1]) + float(sorted_values[center])) * 0.5


func _write_results() -> void:
	var absolute: String = ProjectSettings.globalize_path(_out_dir)
	var error: int = DirAccess.make_dir_recursive_absolute(absolute)
	if error != OK:
		printerr("[HOTPATH_BENCH] Cannot create output directory: %d" % error)
		get_tree().quit(2)
		return
	var json: String = JSON.stringify(_result, "\t")
	var file: FileAccess = FileAccess.open(absolute.path_join("results.json"), FileAccess.WRITE)
	if file == null:
		printerr("[HOTPATH_BENCH] Cannot write results.json")
		get_tree().quit(2)
		return
	file.store_string(json)
	file.close()
	if not _run_label.is_empty():
		var run_dir: String = absolute.path_join(_run_label)
		if DirAccess.make_dir_recursive_absolute(run_dir) == OK:
			var archive: FileAccess = FileAccess.open(run_dir.path_join("results.json"), FileAccess.WRITE)
			if archive != null:
				archive.store_string(json)
				archive.close()
