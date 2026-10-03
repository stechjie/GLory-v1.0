extends Node

# Offline, isolated-package capture through the unmodified BattleScreen path.
# The builder changes only its staged main scene/project/export configuration.
# Android requests: user://model_battle_request.json; output has a fresh run id.
# This validates real battle presentation integration, not network play or a
# release installation. Do not confuse it with the separate model-only preview.
const MODULE_PATH := "res://effects/vfx3d/modules/VFXGuardianSanctuary3D.gd"
const TIMEOUT_MSEC := 180000
const REQUEST_PATH := "user://model_battle_request.json"
var root: Window
var _run_id := ""
var _build := {}
var _expected_model := ""
var _model_stats_cache := {}
var _playback_completed := false

var _screen: Control
var _out := ""
var _seed := 20260823
var _round := 1
var _tier := "MEDIUM"
var _timeline: Array[Dictionary] = []
var _shots: Array[Dictionary] = []
var _captured := {}
var _report := {}
var _failures: Array[String] = []

func _ready() -> void:
	if not bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false)) or str(ProjectSettings.get_setting("application/config/custom_user_dir_name", "")) != "GLoryModelBattlePilot":
		push_error("MODEL_BATTLE_REQUEST_ERROR this tool requires the isolated staged GLoryModelBattlePilot user directory")
		get_tree().quit(2)
		return
	root = get_tree().root
	call_deferred("_run")

func _run() -> void:
	await get_tree().process_frame
	var metadata_path := "res://" + "model_battle_build_info.json"
	if FileAccess.file_exists(metadata_path):
		var loaded: Variant = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
		if loaded is Dictionary:
			_build = loaded
	if str(_build.get("package", "")) != "com.glory.modelbattlepilot" or str(_build.get("source_fingerprint", "")).is_empty():
		push_error("MODEL_BATTLE_REQUEST_ERROR verified staged build metadata is required")
		get_tree().quit(2)
		return
	_expected_model = str(_build.get("expected_model", ""))
	_run_id = str(Time.get_unix_time_from_system()).replace(".", "-")
	if FileAccess.file_exists(REQUEST_PATH):
		var requested: Variant = JSON.parse_string(FileAccess.get_file_as_string(REQUEST_PATH))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REQUEST_PATH))
		if not requested is Dictionary:
			push_error("MODEL_BATTLE_REQUEST_ERROR request must be an object")
			get_tree().quit(2)
			return
		var requested_id := str(requested.get("run_id", ""))
		if requested_id.is_empty() or requested_id.length() > 128 or not requested_id.is_valid_filename() or requested_id.contains(".."):
			push_error("MODEL_BATTLE_REQUEST_ERROR run_id is not a safe filename")
			get_tree().quit(2)
			return
		_run_id = requested_id
	_out = ProjectSettings.globalize_path("user://model_battle_evidence/" + _run_id)
	if DirAccess.dir_exists_absolute(_out):
		push_error("MODEL_BATTLE_REQUEST_ERROR output already exists; choose a fresh run_id")
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService", "VoiceService", "AccountManager"]:
		var service := root.get_node_or_null(service_name)
		if service != null:
			service.process_mode = Node.PROCESS_MODE_DISABLED
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var data := root.get_node("DataRegistry")
	data.call("load_all")
	var fixture: Script = load("res://scripts/qa/FixedBattleFixture.gd")
	var simulator: Script = load("res://scripts/battle/BattleSimulator.gd")
	var budget: Script = load("res://effects/vfx3d/core/VFXQualityBudget.gd")
	budget.set("tier", 0 if _tier == "LOW" else (2 if _tier == "HIGH" else 1))
	fixture.setup_match_state(_round, _seed)
	var replay: Dictionary = simulator.compute_team_replay(0, "model-battle:%d:%d" % [_seed, _round])
	var network := root.get_node("NetworkService")
	# Fixture uses network-shaped boards to compute its deterministic local replay.
	# Presentation receives the prepared package, so no server or room is needed.
	network.set("team_active", false)
	network.set("team_replay_rival", {})
	var frames: Array = replay.get("frames", [])
	var guardians := {}
	var roster: Dictionary = replay.get("roster", {})
	for uid in roster:
		var fighter: Dictionary = roster[uid]
		if str(fighter.get("id", "")) == "god_guard":
			guardians[uid] = {"unit_id": "god_guard", "name": fighter.get("name", ""),
				"star": fighter.get("star", 1), "lane": fighter.get("lane", 0),
				"team": fighter.get("team", ""), "resolved_def": fighter.get("def", {})}
	_report = {"schema_version":1, "run_id":_run_id, "source_fingerprint":_build.get("source_fingerprint", ""),
		"expected_model":_expected_model, "os":OS.get_name(), "gpu":RenderingServer.get_video_adapter_name(), "viewport":root.size,
		"scope":"isolated offline package using the real BattleScreen replay path; not release or multiplayer validation", "seed": _seed, "round": _round, "tier": _tier, "output_directory": _out,
		"generated_utc": Time.get_datetime_string_from_system(true, false),
		"engine": Engine.get_version_info().get("string", ""),
		"renderer": RenderingServer.get_current_rendering_method(),
		"pipeline": "FixedBattleFixture.setup_match_state -> BattleSimulator.compute_team_replay -> GameState.pending_battle_package -> BattleScreen._ready -> replay playback",
		"network": {"peer": root.multiplayer.multiplayer_peer.get_class(), "processing_disabled": true, "team_active_during_playback": false},
		"replay_frames": frames.size(), "guardians": guardians,
		"source_sha256": _source_hashes(), "samples": [], "screenshots": [],
		"notes": ["Screenshots are unmodified engine viewport output.",
			"Frame samples read production snapshots, actor model resolution, and nodes without directly spawning the candidate model.",
			"Shield depletion/death are reported only if the unchanged fixture naturally produces them.",
			"This capture is functional and visual evidence, not a device performance benchmark."]}
	if frames.is_empty() or guardians.is_empty():
		_failures.append("Fixed fixture produced no replay frames or no god_guard")
		_finish()
		return
	root.get_node("GameState").call("set_pending_battle_package", {"mode": "team_replay", "round_index": _round, "replay": replay})
	var packed: PackedScene = load("res://scenes/battle/BattleScreen.tscn")
	_screen = packed.instantiate()
	root.add_child(_screen)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	var last_frame := -1
	var max_count := 0
	while is_instance_valid(_screen) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		if not bool(_screen.get("_battle_setup_ready")):
			continue
		var sample := _sample(guardians)
		var frame := int(sample.get("replay_frame", 0))
		if not _captured.has("00-actors-ready") and _actors_present(sample):
			_capture("00-actors-ready", sample)
		max_count = maxi(max_count, int(sample.get("sanctuary_node_count", 0)))
		if frame != last_frame:
			_timeline.append(sample)
			last_frame = frame
		for state: Dictionary in sample.get("guardians", []):
			var effect: Dictionary = state.get("effect", {})
			var age := float(effect.get("age", -1.0))
			if age >= 0.30 and not _captured.has("01-opening"):
				_capture("01-opening", sample)
			elif age >= 0.70 and not _captured.has("02-shield-established"):
				_capture("02-shield-established", sample)
			elif age >= 1.60 and not _captured.has("03-persistent-state"):
				_capture("03-persistent-state", sample)
			if not effect.is_empty() and not bool(effect.get("shield_active", true)) and bool(effect.get("taunt_active", false)) and float(effect.get("shield_fade", 1.0)) < 0.001 and not _captured.has("04-shield-depleted-taunt-remains"):
				_capture("04-shield-depleted-taunt-remains", sample)
		if frame >= frames.size():
			_playback_completed = true
			_capture("05-timeline-end", sample)
			break
	if Time.get_ticks_msec() >= deadline:
		_failures.append("Timed out waiting for BattleScreen playback")
	if max_count == 0:
		_failures.append("No VFXGuardianSanctuary3D appeared in the real BattleScreen tree")
	_report["playback_completed"] = _playback_completed
	if not _playback_completed:
		_failures.append("The full prepared replay did not reach its final frame")
	_report["peak_sanctuary_node_count"] = max_count
	_validate_models()
	_report["preparation"] = _screen.get("battle_preparation_report") if is_instance_valid(_screen) else {}
	var guardian_warmup := {}
	for item: Dictionary in (_report.preparation.get("effects", {}) as Dictionary).get("items", []):
		if str(item.get("key", "")) == "god_guard|guardian_shield_taunt|":
			guardian_warmup = item
			break
	_report["guardian_warmup"] = guardian_warmup
	var warmed_shaders: Array = guardian_warmup.get("drawn_shader_paths", [])
	if str(guardian_warmup.get("mode", "")) != "full_composer" or int(guardian_warmup.get("draw_frames", 0)) < 4 or "res://effects/vfx3d/shaders/guardian_sanctuary.gdshader" not in warmed_shaders or "res://effects/vfx3d/shaders/guardian_range.gdshader" not in warmed_shaders:
		_failures.append("Formal preparation did not draw both actual guardian shader routes")
	_report["natural_shield_depletion_captured"] = _captured.has("04-shield-depleted-taunt-remains")
	if is_instance_valid(_screen):
		_screen.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	_report["sanctuary_nodes_after_screen_free"] = _count_sanctuaries(root)
	if int(_report.sanctuary_nodes_after_screen_free) != 0:
		_failures.append("A sanctuary node survived BattleScreen disposal")
	_finish()

func _sample(guardians: Dictionary) -> Dictionary:
	var units: Dictionary = _screen.get("_vfx_prev_units")
	var records: Dictionary = _screen.get("_persistent_unit_vfx")
	var fighters: Dictionary = _screen.get("_replay_by_uid")
	var result := {"replay_frame": int(_screen.get("_replay_frame")), "render_frame": Engine.get_frames_drawn(),
		"sanctuary_node_count": _count_sanctuaries(_screen), "guardians": []}
	for uid in guardians:
		var fighter: Dictionary = fighters.get(uid, {})
		var unit: Dictionary = units.get(uid, {})
		var record: Dictionary = records.get(uid, {})
		var state := {"uid": uid, "unit_id": fighter.get("id", ""), "star": fighter.get("star", 0),
			"alive": fighter.get("alive", false), "hp": fighter.get("hp", 0), "shield": fighter.get("shield", 0),
			"snapshot_taunt_active": unit.get("taunt_active", false), "snapshot_taunt_radius_sim": unit.get("taunt_radius", 0.0),
			"record_kind": record.get("kind", ""), "effect": {}}
		var registry: RefCounted = _screen.get("_unit_actor_registry")
		var actor: Node3D = registry.call("get_actor", str(uid))
		if is_instance_valid(actor):
			var resolved: Dictionary = actor.get_meta("resolved_visual", {})
			var visual: Node3D = actor.get("visual_root")
			var actor_state := {"resolved_model": resolved.get("model", ""),
				"raw_model": (fighter.get("def", {}) as Dictionary).get("model", ""),
				"model_visual_scale": resolved.get("model_visual_scale", 1.0),
				"battle_visual_scale": _screen.get("battle_unit_visual_scale"),
				"actor_position": _v3(actor.position), "actor_rotation_degrees": _v3(actor.rotation_degrees),
				"model_height": actor.get_meta("model_height", 0.0), "anchors": {}}
			if is_instance_valid(visual):
				actor_state["visual_scene_path"] = visual.scene_file_path
				actor_state["visual_root_position"] = _v3(visual.position)
				actor_state["visual_root_scale"] = _v3(visual.scale)
				actor_state["model_structure"] = _model_structure(visual)
				actor_state["animation_players"] = _animation_players(visual)
			for anchor_name in ["ActorRoot", "FootAnchor", "CastAnchor", "HitAnchor"]:
				var anchor := actor.get_node_or_null(anchor_name) as Node3D
				if anchor != null:
					actor_state.anchors[anchor_name] = {"local": _v3(anchor.position), "global": _v3(anchor.global_position)}
			state["actor"] = actor_state
		var effect: Variant = record.get("node")
		if is_instance_valid(effect):
			state["effect_script"] = effect.get_script().resource_path
			state["effect_tree_path"] = str(effect.get_path())
			state["effect_position"] = _v3(effect.global_position)
			if effect.has_method("get_debug_state"):
				var debug: Dictionary = effect.call("get_debug_state").duplicate()
				var radius: Vector2 = debug.get("world_radius", Vector2.ZERO)
				debug["world_radius"] = [radius.x, radius.y]
				state["effect"] = debug
			var meshes: Array[Dictionary] = []
			for child in effect.get_children():
				if child is MeshInstance3D:
					var material: Material = child.material_override
					meshes.append({"name": child.name, "visible": child.visible,
						"global_position": _v3(child.global_position), "global_scale": _v3(child.global_basis.get_scale()),
						"shader": material.shader.resource_path if material is ShaderMaterial else "StandardMaterial3D"})
			state["meshes"] = meshes
		result.guardians.append(state)
	return result

func _capture(label: String, sample: Dictionary) -> void:
	_captured[label] = true
	var path := _out.path_join(label + ".png")
	var error := root.get_texture().get_image().save_png(path)
	var evidence := sample.duplicate(true)
	evidence["file"] = path.get_file()
	evidence["save_error"] = error
	_shots.append(evidence)
	if label == "01-opening":
		print("MODEL_BATTLE_ACTOR_AUDIT %s" % JSON.stringify(sample.get("guardians", [])))
	if error != OK:
		_failures.append("Screenshot failed: " + label)
	print("MODEL_BATTLE_CAPTURE label=%s replay_frame=%d sanctuary=%d" % [label, int(sample.replay_frame), int(sample.sanctuary_node_count)])

func _count_sanctuaries(node: Node) -> int:
	var count := 0
	var script: Variant = node.get_script()
	if script is Script and script.resource_path == MODULE_PATH:
		count += 1
	for child in node.get_children():
		count += _count_sanctuaries(child)
	return count

func _source_hashes() -> Dictionary:
	var result := {}
	for row: Dictionary in _build.get("files", []):
		var path := str(row.get("path", ""))
		if path in ["scenes/battle/BattleScreen.gd", "scripts/qa/FixedBattleFixture.gd", "scripts/battle/BattleSimulator.gd", "data/units/race_units.json"] or path.contains("god_guard") or path.contains("UnitVisualConfig"):
			result["res://" + path] = row.get("sha256", "")
	return result

func _actors_present(sample: Dictionary) -> bool:
	for item: Dictionary in sample.get("guardians", []):
		if not (item.get("actor", {}) as Dictionary).is_empty():
			return true
	return false

func _validate_models() -> void:
	var paths := {}
	var actors_seen := {}
	var animations_seen := {}
	var animation_ranges := {}
	for sample: Dictionary in _timeline:
		for item: Dictionary in sample.get("guardians", []):
			var actor: Dictionary = item.get("actor", {})
			var path := str(actor.get("visual_scene_path", ""))
			if path.is_empty():
				continue
			paths[path] = true
			actors_seen[str(item.uid)] = actor.get("model_structure", {})
			for animation: Dictionary in actor.get("animation_players", []):
				if bool(animation.get("playing", false)):
					var animation_name := str(animation.get("animation", ""))
					animations_seen[animation_name] = true
					var position := float(animation.get("position", 0.0))
					var animation_key := "%s|%s|%s" % [str(item.uid), str(animation.get("path", "")), animation_name]
					var extent: Vector2 = animation_ranges.get(animation_key, Vector2(position, position))
					animation_ranges[animation_key] = Vector2(minf(extent.x, position), maxf(extent.y, position))
	_report["observed_model_paths"] = paths.keys()
	_report["model_actors"] = actors_seen
	_report["playing_animations_seen"] = animations_seen.keys()
	var animation_advanced := false
	var advances := {}
	for animation_name in animation_ranges:
		var extent: Vector2 = animation_ranges[animation_name]
		advances[animation_name] = {"minimum_position":extent.x,"maximum_position":extent.y,"span":extent.y-extent.x}
		animation_advanced = animation_advanced or extent.y - extent.x > 0.02
	_report["animation_positions"] = advances
	_report["animation_advanced"] = animation_advanced
	if animations_seen.is_empty() or not animation_advanced:
		_failures.append("No playing model animation advanced through distinct positions in the actual battle")
	if actors_seen.is_empty():
		_failures.append("No god_guard visual was observed through the real actor registry")
	if _expected_model.is_empty():
		_failures.append("Build metadata lacks expected_model; candidate identity cannot be verified")
	elif paths.keys() != [_expected_model]:
		_failures.append("Actual visual_scene_path differs from the expected production mapping")
	for structure: Dictionary in actors_seen.values():
		if int(structure.get("mesh_count", 0)) <= 0:
			_failures.append("An observed god_guard has no real mesh geometry")

func _model_structure(node: Node) -> Dictionary:
	var cache_key := node.get_instance_id()
	if _model_stats_cache.has(cache_key):
		return _model_stats_cache[cache_key]
	var result := {"mesh_count":0, "surface_count":0, "triangles":0, "skeletons":[], "root_script":""}
	var script: Variant = node.get_script()
	if script is Script:
		result.root_script = script.resource_path
	_collect_structure(node, result)
	_model_stats_cache[cache_key] = result
	return result

func _collect_structure(node: Node, result: Dictionary) -> void:
	if node is MeshInstance3D and node.mesh != null:
		result.mesh_count += 1
		result.surface_count += node.mesh.get_surface_count()
		for index in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(index)
			if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null and arrays[Mesh.ARRAY_INDEX].size() > 0:
				result.triangles += int(arrays[Mesh.ARRAY_INDEX].size() / 3)
			elif arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
				result.triangles += int(arrays[Mesh.ARRAY_VERTEX].size() / 3)
	if node is Skeleton3D:
		result.skeletons.append({"path":str(node.get_path()),"bone_count":node.get_bone_count()})
	for child in node.get_children():
		_collect_structure(child, result)

func _animation_players(node: Node) -> Array[Dictionary]:
	var players: Array[Dictionary] = []
	if node is AnimationPlayer:
		players.append({"path":str(node.get_path()),"animation":node.current_animation,"playing":node.is_playing(),"position":node.current_animation_position if node.is_playing() else 0.0})
	for child in node.get_children():
		players.append_array(_animation_players(child))
	return players

func _v3(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _finish() -> void:
	_report["samples"] = _timeline
	_report["screenshots"] = _shots
	_report["failures"] = _failures
	_report["status"] = "PASS" if _failures.is_empty() else "FAIL"
	var file := FileAccess.open(_out.path_join("evidence.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "  "))
		file.close()
	else:
		_failures.append("Could not write evidence.json")
	print("MODEL_BATTLE_RESULT status=%s samples=%d screenshots=%d failures=%s output=%s" % ["PASS" if _failures.is_empty() else "FAIL", _timeline.size(), _shots.size(), JSON.stringify(_failures), _out])
	get_tree().quit(0 if _failures.is_empty() else 1)
