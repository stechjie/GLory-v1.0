extends Node
## Focused, real-engine preview of the approved monster death presentation.
## Run the scene with a renderer, --fixed-fps 30, and optionally --write-movie.
## --out <fresh absolute directory> saves unedited engine PNGs and a manifest.
## --tier LOW|MEDIUM|HIGH only changes this process's runtime VFX budget.
## It never calls PlayerProfile.mark_seen or changes persistent player options.

const HOST := preload("res://scenes/battle/BattleVfx.gd")
const ACTOR := preload("res://effects/runtime/presentation/UnitActor3D.gd")
const RESOLVER := preload("res://effects/runtime/presentation/UnitVisualResolver.gd")
const QUALITY := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
const DURATION := 9.0
const STAGE_SECONDS := 3.0
const DEATH_AT := 0.80
const SHOTS := {"ready": 0.55, "impact": 0.85, "dust": 1.16, "dust_peak": 1.30, "embers": 1.43, "clean": 2.35}

var _host
var _title: Label
var _status: Label
var _footer: Label
var _out := ""
var _tier := "MEDIUM"
var _extended := false
var _duration := DURATION
var _time := 0.0
var _stage := -1
var _running := false
var _finishing := false
var _dead := false
var _fired_count := 0
var _fighters: Array[Dictionary] = []
var _shots_done := {}
var _samples: Array[Dictionary] = []
var _failures: Array[String] = []
var _defs := {}
var _scenes := {}

func _ready() -> void:
	set_process(false)
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	_extended = "--extended" in args
	_duration = 12.0 if _extended else DURATION
	for i in args.size():
		if i + 1 >= args.size():
			continue
		match args[i]:
			"--out": _out = ProjectSettings.globalize_path(str(args[i + 1]))
			"--tier": _tier = str(args[i + 1]).to_upper()
	if _tier not in ["LOW", "MEDIUM", "HIGH"]:
		push_error("MONSTER_DEATH_PREVIEW invalid --tier")
		get_tree().quit(2)
		return
	if not _out.is_empty():
		if DirAccess.dir_exists_absolute(_out):
			push_error("MONSTER_DEATH_PREVIEW --out must be a fresh directory")
			get_tree().quit(2)
			return
		if DirAccess.make_dir_recursive_absolute(_out) != OK:
			push_error("MONSTER_DEATH_PREVIEW cannot create output directory")
			get_tree().quit(2)
			return
	# Prevent online services from doing unrelated work in this isolated preview.
	for service_name in ["NetworkService", "RealtimeService", "AnalyticsService", "ChatService", "AnnouncementService", "MailService", "VoiceService", "AccountManager"]:
		var service := get_tree().root.get_node_or_null(service_name)
		if service != null:
			service.process_mode = Node.PROCESS_MODE_DISABLED
	get_tree().root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	QUALITY.tier = QUALITY.Tier.LOW if _tier == "LOW" else (QUALITY.Tier.HIGH if _tier == "HIGH" else QUALITY.Tier.MEDIUM)
	DataRegistry.ensure_loaded()
	for spec in [{"table": "pve_monsters", "key": "monsters"}, {"table": "bosses", "key": "bosses"}, {"table": "race_units", "key": "units"}, {"table": "mercenaries", "key": "mercenaries"}]:
		for definition in DataRegistry.get_table(spec.table).get(spec.key, []):
			_defs[str(definition.get("id", ""))] = definition
	var model_ids := ["pve_land_rock_beast", "pve_sky_wind_falcon", "boss_rage_beast"]
	if _extended:
		model_ids.append_array(["undead_small", "merc_libra_judge"])
	for unit_id in model_ids:
		var visual := RESOLVER.resolve_definition(unit_id, _defs.get(unit_id, {}))
		var scene := load(str(visual.get("model", ""))) as PackedScene
		if scene == null:
			_failures.append("missing real model: " + unit_id)
		else:
			_scenes[unit_id] = scene
	if not _failures.is_empty():
		_finish()
		return
	_build_stage()
	await get_tree().process_frame
	_begin_stage(0)
	# Give materials and model scripts a few rendered frames before the timeline.
	for _i in range(8):
		await get_tree().process_frame
	_running = true
	set_process(true)
	print("MONSTER_DEATH_PREVIEW ready tier=%s duration=%.0fs actual_route=BattleVfx.cue_play_death" % [_tier, _duration])

func _build_stage() -> void:
	_host = HOST.new()
	_host.name = "MonsterDeathProductionHost"
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_host)
	var arena := Control.new()
	arena.name = "PreviewArena"
	arena.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arena.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_host.add_child(arena)
	_host._arena = arena
	var background := TextureRect.new()
	background.texture = load(HOST.BATTLE_2_5D_BASE_PATH) as Texture2D
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arena.add_child(background)
	_host._setup_battle_3d_view(arena)
	# Closer framing for assessment; production model scale, anchors and light stay.
	_host._battle_3d_camera.size = 4.0
	_title = _label(30, Color("ffe9b5"), 24.0)
	_title.text = "MONSTER DEATH  /  " + _tier
	_status = _label(23, Color("f4f1e9"), 68.0)
	_footer = _label(18, Color("d2ddda"), -64.0)
	_footer.text = "Real game models + production death cue  |  Focused preview, no gameplay changes"

func _label(font_size: int, color: Color, top: float) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.025, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	label.z_index = 200
	label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE if top < 0 else Control.PRESET_TOP_WIDE)
	label.offset_top = top
	label.offset_bottom = top + 40.0
	_host.add_child(label)
	return label

func _process(delta: float) -> void:
	if not _running or _finishing:
		return
	_time += delta
	if _time >= _duration:
		_finishing = true
		set_process(false)
		call_deferred("_finish")
		return
	var next_stage := mini(3 if _extended else 2, int(_time / STAGE_SECONDS))
	if next_stage != _stage:
		_begin_stage(next_stage)
	var age := _time - float(_stage) * STAGE_SECONDS
	if _stage == 3:
		while _fired_count < _fighters.size() and age >= DEATH_AT + float(_fired_count) * 0.13:
			_fire_fighter(_fired_count)
			_fired_count += 1
	else:
		if not _dead and age >= DEATH_AT:
			_trigger_deaths()
	for key in SHOTS:
		var shot_key := "%02d_%s" % [_stage + 1, str(key)]
		var target_time := float(SHOTS[key])
		if _stage == 2 and str(key) == "dust_peak":
			target_time = 1.40
		if _stage == 3:
			target_time = 2.85 if str(key) == "clean" else (1.80 if str(key) == "embers" else target_time)
		if age >= target_time and not _shots_done.has(shot_key):
			_shots_done[shot_key] = true
			_capture.call_deferred(shot_key, age)
	_host._update_vfx_camera_shake()

func _begin_stage(index: int) -> void:
	_host.cue_release_corpses()
	for node in _host._battle_3d_models.values():
		if is_instance_valid(node):
			node.queue_free()
	_host._battle_3d_models.clear()
	_host._unit_actor_registry.clear()
	_fighters.clear()
	_stage = index
	_dead = false
	_fired_count = 0
	var specs: Array = []
	match index:
		0:
			_status.text = "01  /  ROCKPLATE BEAST  /  SINGLE DEATH"
			specs = [{"id": "pve_land_rock_beast", "at": Vector3.ZERO}]
		1:
			_status.text = "02  /  ROCKPLATE + FALCONS  /  GROUP DEATH"
			specs = [{"id": "pve_land_rock_beast", "at": Vector3(-1.0, 0, 0.0)}, {"id": "pve_sky_wind_falcon", "at": Vector3(0.1, 0, -0.25)}, {"id": "pve_sky_wind_falcon", "at": Vector3(1.05, 0, 0.25)}]
		2:
			_status.text = "03  /  RAMPAGE BEAST  /  BOSS DEATH"
			specs = [{"id": "boss_rage_beast", "at": Vector3(0, 0, -0.15)}]
		3:
			_status.text = "04  /  PIECE + MERCENARY  /  KILLS x5 + LANE CLEAR"
			specs = [{"id": "undead_small", "at": Vector3(-1.35, 0, -0.20)}, {"id": "merc_libra_judge", "at": Vector3(-0.65, 0, 0.35)}, {"id": "pve_sky_wind_falcon", "at": Vector3(0.15, 0, -0.3)}, {"id": "pve_land_rock_beast", "at": Vector3(0.75, 0, 0.35)}, {"id": "pve_sky_wind_falcon", "at": Vector3(1.35, 0, -0.20)}]
	var killer := Node3D.new()
	killer.name = "OffscreenKiller"
	killer.position = Vector3(-2.5, 0, 0.2)
	_host._battle_3d_root.add_child(killer)
	_host._battle_3d_models["preview_killer"] = killer
	_host._state = {"kind": "pve", "elapsed": 1.0, "player": [{"uid": "preview_killer", "id": "human_militia", "owner_slot": 0 if index == 3 else 1, "team": "player", "lane": 0, "alive": true}, {"uid": "preview_local_lane_owner", "id": "human_militia", "owner_slot": 0, "team": "player", "lane": 0, "alive": true}], "enemy": []}
	for i in specs.size():
		var fighter := _fighter(str(specs[i].id), "preview_%d_%d" % [index, i])
		_fighters.append(fighter)
		_host._state.enemy.append(fighter)
		_make_actor(fighter, specs[i].at)
	# Alive state-only sentinel prevents an unrelated lane-clear celebration.
	if index != 3:
		_host._state.enemy.append({"uid": "preview_far_sentinel", "id": "pve_land_rock_beast", "team": "enemy", "owner_slot": 3, "lane": 0, "alive": true, "hp": 100, "def": _defs.pve_land_rock_beast})

func _fighter(unit_id: String, uid: String) -> Dictionary:
	var definition: Dictionary = _defs.get(unit_id, {}).duplicate(true)
	return {"uid": uid, "id": unit_id, "def": definition, "team": "enemy", "owner_slot": 3, "lane": 0, "star": 1, "alive": true, "hp": int(definition.get("hp", 100)), "pos": Vector2(500, 260), "footprint_cells": int(definition.get("footprint_cells", 1)), "is_mercenary": unit_id.begins_with("merc_"), "killer_uid": "preview_killer"}

func _make_actor(fighter: Dictionary, at: Vector3) -> void:
	var visual := RESOLVER.resolve_for_fighter(fighter)
	var actor = ACTOR.new()
	actor.name = str(fighter.uid)
	actor.configure_contract(_host.anchor_height_for(visual), RESOLVER.archetype_for(visual))
	actor.set_meta("unit_id", str(fighter.id))
	actor.set_meta("resolved_visual", visual)
	actor.set_meta("base_yaw", float(visual.get("model_base_yaw", 180.0)))
	actor.position = at
	actor.rotation_degrees.y = 180.0
	_host._battle_3d_root.add_child(actor)
	var scene: PackedScene = _scenes[str(fighter.id)]
	var model := scene.instantiate() as Node3D
	model.scale = Vector3.ONE * float(visual.get("model_visual_scale", 1.0)) * float(_host.battle_unit_visual_scale)
	actor.attach_model(model)
	_host._center_model_for_full_body_view(model)
	_host._setup_model_animation_state(actor, model, visual, fighter)
	_host._battle_3d_models[str(fighter.uid)] = actor
	if not _host._unit_actor_registry.register_actor(str(fighter.uid), actor):
		_failures.append("actor registration failed: " + str(fighter.uid))

func _trigger_deaths() -> void:
	_dead = true
	var events: Array = []
	for fighter in _fighters:
		fighter.alive = false
		fighter.hp = 0
		events.append({"type": "death", "source_uid": str(fighter.uid), "killer_uid": "preview_killer"})
	_host.cue_claim_corpses(events)
	for fighter in _fighters:
		if not _host.cue_play_death(str(fighter.uid), 0.35, "preview_killer", "preview:%d:%s" % [_stage, str(fighter.uid)], _time):
			_failures.append("production death cue rejected: " + str(fighter.uid))
	print("MONSTER_DEATH_PREVIEW fired stage=%d count=%d time=%.3f" % [_stage + 1, _fighters.size(), _time])

func _fire_fighter(index: int) -> void:
	var fighter: Dictionary = _fighters[index]
	fighter.alive = false
	fighter.hp = 0
	_host._state.elapsed = _time
	_host.cue_claim_corpses([{"type": "death", "source_uid": str(fighter.uid), "killer_uid": "preview_killer"}])
	if not _host.cue_play_death(str(fighter.uid), 0.35, "preview_killer", "preview:extended:%d" % index, _time):
		_failures.append("extended production death cue rejected: " + str(fighter.uid))

func _capture(shot_key: String, age: float) -> void:
	await RenderingServer.frame_post_draw
	if not is_instance_valid(_host):
		return
	var effects: Array[Dictionary] = []
	for node in _host._battle_3d_vfx_root.find_children("*", "GPUParticles3D", true, false):
		var particles := node as GPUParticles3D
		effects.append({"name": str(particles.name), "amount": particles.amount, "lifetime": particles.lifetime, "emitting": particles.emitting})
	var sample := {"shot": shot_key, "time": _time, "stage_age": age, "active_corpses": _host._active_death_actors.size(), "pending_corpses": _host._cue_corpses.size(), "particles": effects}
	if not _out.is_empty():
		var png := _out.path_join(shot_key + ".png")
		var result := get_viewport().get_texture().get_image().save_png(png)
		if result != OK:
			_failures.append("cannot save " + png)
		sample["png"] = png
	if shot_key.ends_with("clean") and (int(sample.active_corpses) != 0 or not effects.is_empty()):
		_failures.append("death presentation did not clean itself: " + shot_key)
	_samples.append(sample)

func _finish() -> void:
	if is_instance_valid(_host):
		_host.cue_release_corpses()
	var manifest := {"scope": "Focused real-model presentation preview using production BattleVfx.cue_play_death; not a full match or a phone benchmark", "tier": _tier, "extended": _extended, "engine": Engine.get_version_info(), "renderer": RenderingServer.get_current_rendering_method(), "camera_size": 4.0, "production_camera_size": 7.2, "model_creation": "UnitActor3D + UnitVisualResolver + production centering/animation helpers; excludes persistent mark_seen", "duration_seconds": _duration, "cue_offset_seconds": DEATH_AT, "samples": _samples, "failures": _failures}
	if not _out.is_empty():
		var file := FileAccess.open(_out.path_join("preview_manifest.json"), FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(manifest, "\t"))
	print("MONSTER_DEATH_PREVIEW %s samples=%d failures=%s" % ["PASS" if _failures.is_empty() else "FAIL", _samples.size(), str(_failures)])
	get_tree().quit(0 if _failures.is_empty() else 1)
