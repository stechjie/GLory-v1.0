class_name BattleRenderWarmup
extends Node

# Resource ready does not mean a renderer pipeline exists. Render only this
# replay's authored routes, one isolated effect at a time, before its first cue.
# No BattleScreen/Director callbacks, audio dispatch, or simulator state enter
# this world. Never restore the old all-catalog, single-frame warm_draw.
const PROCEDURAL := preload("res://effects/BossProceduralVFX3D.gd")
const CHESS := preload("res://effects/vfx3d/units/OgaChessVFXCatalog.gd")
const SKILLS := preload("res://effects/vfx3d/units/OgaSkillVFXCatalog.gd")
const OGA_PROJECTILE := preload("res://effects/vfx3d/modules/VFXFlipbookProjectile3D.gd")
const OGA_MELEE := preload("res://effects/vfx3d/modules/VFXFlipbookMelee3D.gd")
const OGA_PACK := preload("res://effects/vfx3d/modules/VFXPackSkill3D.gd")
const OGA_CARD := preload("res://effects/vfx3d/modules/VFXSpriteFlipbook3D.gd")
# These are the exclusive standard-card routes in UnitSkillVFXComposer3D.
# A catalogue entry alone is insufficient: e.g. judgement_strike and the angel
# guard now use procedural geometry and must still run their complete composer.
const DIRECT_PACK_ROUTES := ["lowest_ally_heal", "nearest_ally_bless", "nearby_ally_heal_buff",
	"black_hole", "guardian_shield_taunt", "curse_attack", "same_target_damage_stack",
	"poison_attack", "death_poison_explosion", "poison_reflect_armor_stack"]
const MAX_JOBS := 256
const MAX_CACHED_JOBS := 512
const MAX_TOTAL_MSEC := 90000
const BOSS_ROUTES := {
	"mirror_clone": ["mirror_spawn", "mirror_slash"],
	"element_meteor": ["element_meteor"],
	"overload_counter": ["overload_stack", "overload_counter"],
	"holy_purify": ["holy_purify"],
	"rage_stack": ["rage_stack", "rage_milestone"],
	"blood_rage": ["blood_rage", "blood_lifesteal"],
	"soul_devour": ["soul_devour"],
	"twin_revive": ["twin_timer", "twin_revive"],
	"apocalypse_charge": ["apocalypse_charge", "apocalypse_complete", "apocalypse_interrupt"],
}
static var _ready_jobs: Dictionary = {}

static func collect_jobs(replays: Array) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	var seen := {}
	for replay in replays:
		if not replay is Dictionary:
			continue
		for entry in (replay.get("roster", {}) as Dictionary).values():
			var unit := str(entry.get("id", ""))
			if unit.is_empty():
				continue
			var unit_def: Dictionary = entry.get("def", {})
			var skill := str(unit_def.get("skill_id", ""))
			var mode := "ranged" if float(unit_def.get("range", 1.0)) > 1.5 else "melee"
			if unit == "human_king":
				_append(jobs, seen, unit, "unique_king_growth")
			elif skill == "mirror_clone":
				_append(jobs, seen, unit, "mirror_slash")
			else:
				var spec: Dictionary = CHESS.projectile_for(unit) if mode == "ranged" else CHESS.melee_for(unit, _visual_race(unit))
				# Several player melee pieces intentionally only animate the model;
				# their production composer returns without a VFX. Do not wait on it.
				if not CHESS.is_player_chess(unit) or not spec.is_empty():
					_append(jobs, seen, unit, "basic_attack_%s_%s" % [mode, _visual_race(unit)])
			if skill == "random_attribute_bolt":
				for element in ["fire", "ice", "thunder", "poison"]:
					_append(jobs, seen, unit, skill, element)
			elif skill in PROCEDURAL.UNIT_SKILLS:
				_append(jobs, seen, unit, skill)
			elif BOSS_ROUTES.has(skill):
				for route in BOSS_ROUTES[skill]:
					_append(jobs, seen, unit, str(route))
	return jobs

static func _append(jobs: Array[Dictionary], seen: Dictionary, unit: String, effect: String, element := "") -> void:
	var key := "%s|%s|%s" % [unit, effect, element]
	if seen.has(key):
		return
	seen[key] = true
	jobs.append({"key": key, "unit": unit, "effect": effect, "element": element})

static func _visual_race(unit: String) -> String:
	for race in ["god", "human", "dark", "undead"]:
		if unit.begins_with(race + "_"):
			return race
	for word in ["dark", "shadow", "demon"]:
		if unit.contains(word):
			return "dark"
	for word in ["undead", "wisp", "poison", "death"]:
		if unit.contains(word):
			return "undead"
	for word in ["god", "angel", "divine"]:
		if unit.contains(word):
			return "god"
	return "human"

func prepare_replays(replays: Array, template: SubViewport, progress: Callable = Callable(), can_continue: Callable = Callable(), deadline_msec := 0) -> Dictionary:
	var jobs := collect_jobs(replays)
	if _cancelled(can_continue):
		return {"ok": false, "error": "render_warmup_cancelled"}
	if DisplayServer.get_name() == "headless":
		return {"ok": true, "headless": true, "jobs": jobs.size(), "rendered": 0}
	if template == null or jobs.size() > MAX_JOBS:
		return {"ok": false, "error": "render_warmup_invalid_viewport_or_capacity", "jobs": jobs.size()}
	var started := Time.get_ticks_msec()
	var deadline := started + MAX_TOTAL_MSEC
	if deadline_msec > 0:
		deadline = mini(deadline, deadline_msec)
	var viewport := _make_viewport(template)
	var point_light := OmniLight3D.new()
	point_light.name = "CurrentReplayOmniVariant"
	point_light.omni_range = 64.0
	point_light.light_energy = 0.001
	point_light.shadow_enabled = false
	viewport.add_child(point_light)
	var rendered := 0
	var max_draw_frame_ms := 0
	var costs: Array[Dictionary] = []
	var format_key := "oga-direct-omni-v2|%s|%d|%d|%s|" % [RenderingServer.get_current_rendering_method(), template.msaa_3d, VFXManager.get_quality_tier(), str(template.transparent_bg)]
	for index in jobs.size():
		if _cancelled(can_continue) or Time.get_ticks_msec() > deadline:
			viewport.queue_free()
			return {"ok": false, "error": "render_warmup_cancelled" if _cancelled(can_continue) else "render_warmup_timeout", "jobs": jobs.size(), "rendered": rendered}
		var job := jobs[index]
		var cache_key := format_key + str(job.key)
		if _ready_jobs.has(cache_key):
			continue
		if progress.is_valid():
			progress.call(index, jobs.size())
		var item_started := Time.get_ticks_msec()
		point_light.visible = false
		var direct := _direct_oga_route(job)
		var holder := _spawn_direct_oga(viewport, direct) if not direct.is_empty() else _spawn(viewport, job)
		var materials := {}
		_retain_draw_materials(holder, materials)
		# Basic projectile impact appears after >=0.24s. Skill composers also
		# create delayed layers up to 0.68s; two immediate draws would miss them.
		var duration := composer_warmup_duration(str(job.effect))
		if not direct.is_empty():
			duration = 0.0
		var elapsed := 0.0
		var draw_frames := 0
		var link_released := false
		var previous_draw := Time.get_ticks_msec()
		while elapsed < duration or draw_frames < 4:
			await get_tree().process_frame
			if _cancelled(can_continue) or Time.get_ticks_msec() > deadline:
				viewport.queue_free()
				return {"ok": false, "error": "render_warmup_cancelled" if _cancelled(can_continue) else "render_warmup_timeout"}
			elapsed += get_process_delta_time()
			if str(job.effect) == "shared_hp_link" and elapsed > 0.40 and not link_released:
				_release_links(holder)
				link_released = true
			# GLES specializes even unshaded surfaces for paired Omni lights.
			# Group-heal lights can touch any nearby effect; compile both states
			# while this isolated world is still owned by preparation.
			_set_omni_visibility(viewport, draw_frames % 2 == 1)
			_retain_draw_materials(holder, materials)
			await RenderingServer.frame_post_draw
			if _cancelled(can_continue):
				viewport.queue_free()
				return {"ok": false, "error": "render_warmup_cancelled"}
			var now := Time.get_ticks_msec()
			max_draw_frame_ms = maxi(max_draw_frame_ms, now - previous_draw)
			previous_draw = now
			draw_frames += 1
		costs.append({"key": job.key, "ms": Time.get_ticks_msec() - item_started, "draw_frames": draw_frames,
			"mode": "oga_direct" if not direct.is_empty() else "full_composer",
			"retained_materials": materials.size(), "drawn_texture_paths": _material_texture_paths(materials)})
		holder.queue_free()
		# Release every block before the next item so the live effect budget
		# cannot silently suppress preparation. Network processing keeps running.
		await get_tree().process_frame
		# BaseMaterial3D also owns generated shaders. A ready marker without a
		# live material can leave the runtime compiling that variant again after
		# this temporary world is freed. The same bounded LRU owns both.
		_ready_jobs[cache_key] = materials.values()
		while _ready_jobs.size() > MAX_CACHED_JOBS:
			_ready_jobs.erase(_ready_jobs.keys()[0])
		rendered += 1
	viewport.queue_free()
	if progress.is_valid():
		progress.call(jobs.size(), jobs.size())
	var report := {"ok": true, "jobs": jobs.size(), "rendered": rendered,
		"elapsed_ms": Time.get_ticks_msec() - started, "max_draw_frame_ms": max_draw_frame_ms,
		"lighting_variants": ["directional_only", "with_omni"], "items": costs}
	print("[BATTLE_RENDER_READY] %s" % JSON.stringify(report))
	return report

# Keep delayed layers, but do not wait for every already-drawn effect to fade
# out. These windows include the last authored spawn plus multiple real draws
# for both lighting variants. Unknown/new routes retain the conservative 0.85s.
# Coverage is checked against an independent full-duration composer run.
static func composer_warmup_duration(effect: String) -> float:
	match effect:
		"attack_interrupt", "every_fifth_group_heal":
			return 0.20 # All modules/materials are constructed synchronously.
		"unique_king_growth":
			return 0.40 # Let the sword enter the preparation camera's view.
		"true_damage_attack":
			return 0.35 # Fracture appears after 0.16s.
		"every_fourth_combo":
			return 0.60 # Arrow's impact appears after 0.42s.
		"global_divine_blast", "judgement_strike":
			return 0.55 # Lightning's ground residual appears after 0.285s.
	return 0.40 if effect.begins_with("basic_attack_") else 0.85

func _cancelled(can_continue: Callable) -> bool:
	return not is_inside_tree() or (can_continue.is_valid() and not bool(can_continue.call()))

func _make_viewport(template: SubViewport) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = "CurrentReplayRenderWarmup"
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	viewport.transparent_bg = template.transparent_bg
	viewport.msaa_3d = template.msaa_3d
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 5.0
	viewport.add_child(camera)
	camera.look_at_from_position(Vector3(0.0, 4.0, 4.0), Vector3(0.0, 0.5, 0.0), Vector3.UP)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.light_color = Color(1.0, 0.84, 0.62)
	light.light_energy = 1.55
	light.rotation_degrees = Vector3(-55, 35, 0)
	viewport.add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.34, 0.42, 0.34)
	settings.ambient_light_energy = 0.42
	environment.environment = settings
	viewport.add_child(environment)
	return viewport

func _spawn(viewport: SubViewport, job: Dictionary) -> Node3D:
	var holder := Node3D.new()
	viewport.add_child(holder)
	var origin := Node3D.new()
	var target := Node3D.new()
	origin.position = Vector3(-0.4, 0.5, 0.0)
	target.position = Vector3(0.4, 0.5, 0.0)
	holder.add_child(origin)
	holder.add_child(target)
	var visual := PROCEDURAL.new()
	holder.add_child(visual)
	var context := {"origin_node": origin, "target_node": target,
		"source_unit_id": str(job.unit), "target_unit_id": str(job.unit),
		"targets": [target.position], "heal_target": origin.position,
		"origin_height": 0.98, "target_height": 0.98, "status_duration": 0.8,
		"attribute": str(job.element), "stacks": 2, "persistent": true}
	visual.play(str(job.effect), origin.position, target.position, context)
	return holder

# Use the original module factories, including their exact shader and material
# parameters. Only the isolated preparation copy changes timing. No simulation,
# live effect, global clock, or audio route is accelerated.
static func _direct_oga_route(job: Dictionary) -> Dictionary:
	var effect := str(job.effect)
	var spec := {}
	var kind := ""
	if effect.begins_with("basic_attack_ranged_"):
		spec = CHESS.projectile_for(str(job.unit))
		kind = "projectile"
	elif effect.begins_with("basic_attack_melee_"):
		spec = CHESS.melee_for(str(job.unit), _visual_race(str(job.unit)))
		kind = "melee"
	elif effect == "random_attribute_bolt" or effect == "silence_bolt":
		spec = SKILLS.projectile_for_element("silence" if effect == "silence_bolt" else str(job.element))
		kind = "projectile"
	elif effect == "front_cone_stun":
		spec = SKILLS.melee_for(effect)
		kind = "melee"
	elif effect in DIRECT_PACK_ROUTES:
		spec = SKILLS.skill_for(effect)
		kind = "pack"
	return {"kind": kind, "spec": spec} if not spec.is_empty() else {}

func _spawn_direct_oga(viewport: SubViewport, route: Dictionary) -> Node3D:
	var holder := Node3D.new()
	viewport.add_child(holder)
	var spec: Dictionary = route.spec.duplicate(true)
	var origin := Vector3(-0.4, 0.5, 0.0)
	var target := Vector3(0.4, 0.5, 0.0)
	if str(route.kind) == "pack":
		var pack := OGA_PACK.new()
		holder.add_child(pack)
		pack.begin()
		var points := {"origin_body": origin, "origin_ground": Vector3(-0.4, 0.03, 0.0),
			"origin_head": origin, "target_body": target, "target_head": target,
			"target_ground": Vector3(0.4, 0.03, 0.0)}
		# Group casts have a second array; render every layer once, even those
		# delayed beyond the old 0.85s window. Instance count doesn't add a shader.
		var layers: Array = spec.get("layers", []).duplicate(true)
		layers.append_array(spec.get("target_layers", []))
		for original in layers:
			var layer: Dictionary = original.duplicate(true)
			layer["delay"] = 0.0
			pack._spawn_layer_after(points, layer, {})
	else:
		var module: Node3D = OGA_PROJECTILE.new() if str(route.kind) == "projectile" else OGA_MELEE.new()
		holder.add_child(module)
		module.play_spec(origin, target, spec, {})
		# The body/slash exists before play_spec's first await. Cancel only its
		# travel coroutine, then invoke the same production impact factory now.
		module.set("_finished", true)
		module._play_impact(target if str(route.kind) == "projectile" else Vector3(0.4, 0.03, 0.0), spec)
	_freeze_oga_cards(holder)
	return holder

func _freeze_oga_cards(node: Node) -> void:
	if node is OGA_CARD:
		# First cold compilation can take longer than a whole effect lifetime.
		# Keep these temporary cards alive and opaque until both masks are drawn.
		# Their timer checks _loop before freeing; no live card is ever touched.
		node.set("_loop", true)
		node.set_process(false)
		(node.get("_material") as ShaderMaterial).set_shader_parameter("opacity", 1.0)
	for child in node.get_children():
		_freeze_oga_cards(child)

static func _material_texture_paths(materials: Dictionary) -> Array[String]:
	var paths: Array[String] = []
	for material in materials.values():
		if material is ShaderMaterial:
			var texture: Variant = material.get_shader_parameter("atlas_texture")
			if texture is Texture2D and not texture.resource_path.is_empty() and texture.resource_path not in paths:
				paths.append(texture.resource_path)
	paths.sort()
	return paths

func _release_links(node: Node) -> void:
	if node.has_method("release_link"):
		node.call("release_link")
	for child in node.get_children():
		_release_links(child)


func _retain_draw_materials(node: Node, materials: Dictionary) -> void:
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		if mesh_node.material_override != null:
			materials[mesh_node.material_override.get_instance_id()] = mesh_node.material_override
		if mesh_node.material_overlay != null:
			materials[mesh_node.material_overlay.get_instance_id()] = mesh_node.material_overlay
		if mesh_node.mesh != null:
			for index in mesh_node.mesh.get_surface_count():
				var material := mesh_node.get_active_material(index)
				if material != null:
					materials[material.get_instance_id()] = material
	for child in node.get_children():
		_retain_draw_materials(child, materials)


func _set_omni_visibility(node: Node, enabled: bool) -> void:
	if node is OmniLight3D:
		(node as OmniLight3D).visible = enabled
	for child in node.get_children():
		_set_omni_visibility(child, enabled)
