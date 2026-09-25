extends Node
const Harness := preload("res://tools/CheckHarness.gd")
const Warmup := preload("res://scripts/assets/BattleRenderWarmup.gd")
const Block := preload("res://effects/vfx3d/VFXBlockRoot.gd")

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var h := Harness.new("battle_render_warmup")
	var replay := {"roster": {
		"a": {"id": "human_archer", "def": {"range": 4.0, "skill_id": "every_fourth_combo"}},
		"b": {"id": "god_archangel", "def": {"range": 4.0, "skill_id": "random_ally_damage_reduction"}},
		"c": {"id": "dark_doom", "def": {"range": 1.0, "skill_id": "shared_hp_link"}},
	}}
	var template := SubViewport.new()
	template.transparent_bg = true
	template.msaa_3d = Viewport.MSAA_DISABLED
	add_child(template)
	var warmup := Warmup.new()
	add_child(warmup)
	var blocks_before := Block.active_block_count()
	var round_before := GameState.round_index
	var state_before := NetworkService.state
	var replay_before := var_to_bytes(replay)
	var report: Dictionary = await warmup.prepare_replays([replay], template)
	h.expect(bool(report.get("ok", false)), "renderer_complete", "Current authored projectile, impact, guard and Doom tear preparation completed")
	h.expect(var_to_bytes(replay) == replay_before and GameState.round_index == round_before and NetworkService.state == state_before,
		"isolated_game_state", "Rendering preparation neither mutates replay nor advances game/network state")
	if DisplayServer.get_name() != "headless":
		h.expect(int(report.get("rendered", 0)) == 5, "real_draws", "All five actual routes reached frame_post_draw; Doom's absent basic slash is not invented")
		h.expect(report.get("lighting_variants", []) == ["directional_only", "with_omni"], "both_light_variants", "Group-heal Omni and ordinary no-Omni pipelines are drawn before readiness")
		var retained := 0
		for item in report.get("items", []):
			retained += int(item.get("retained_materials", 0))
		h.expect(retained > 0, "pipeline_resources_retained", "Completed jobs retain actual drawn materials along with their bounded ready marker")
		var fast_count := 0
		for item in report.get("items", []):
			if item.get("mode", "") == "oga_direct":
				fast_count += 1
				h.expect(int(item.draw_frames) == 4 and item.drawn_texture_paths.size() == 2,
					"direct_body_and_impact_%d" % fast_count, "The original projectile body and impact both draw with each Omni state in four frames")
		h.expect(fast_count == 2, "complex_routes_preserved", "Only two standard projectiles are accelerated; combo, guard and blood-link teardown keep full composers")
		var second: Dictionary = await warmup.prepare_replays([replay], template)
		h.expect(int(second.get("rendered", -1)) == 0, "same_renderer_reuse", "Second preparation in the same renderer/quality reuses completed variants")
		var keep_running := {"value": true}
		get_tree().create_timer(0.05).timeout.connect(func(): keep_running.value = false)
		var cancel_replay := {"roster": {"late": {"id": "human_cleric", "def": {"range": 4.0, "skill_id": "every_fifth_group_heal"}}}}
		var cancelled: Dictionary = await warmup.prepare_replays([cancel_replay], template, Callable(), func() -> bool: return keep_running.value)
		h.expect(str(cancelled.get("error", "")) == "render_warmup_cancelled", "cancel_during_draw", "Skip/scene cancellation stops active preparation before the remaining routes render")
		await _compare_standard_routes(h, warmup, template)
		await _compare_short_windows(h, warmup, template)
	else:
		h.expect(bool(report.get("headless", false)), "headless_explicit", "Headless completion explicitly does not claim real renderer evidence")
	var declined: Dictionary = await warmup.prepare_replays([replay], template, Callable(), func() -> bool: return false)
	h.expect(str(declined.get("error", "")) == "render_warmup_cancelled", "cancel_before_start", "A completed/skipped battle cannot begin background rendering")
	warmup.queue_free()
	template.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	h.expect(Block.active_block_count() == blocks_before, "effect_budget_released", "All temporary effects leave the production effect budget")
	h.finish(get_tree())

func _material_signatures(materials: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for material in materials.values():
		if not material is ShaderMaterial:
			continue
		var texture: Variant = material.get_shader_parameter("atlas_texture")
		if not texture is Texture2D:
			continue
		var signature := "%s|%s|%s|%s|%s|%s" % [texture.resource_path,
			material.shader.code.sha256_text(), str(material.get_shader_parameter("atlas_grid")),
			str(material.get_shader_parameter("billboard_enabled")),
			str(material.get_shader_parameter("emission_scale")), str(material.get_shader_parameter("tint"))]
		if signature not in result:
			result.append(signature)
	result.sort()
	return result

func _compare_standard_routes(h: RefCounted, warmup: Node, template: SubViewport) -> void:
	var jobs: Array[Dictionary] = []
	for unit in Warmup.CHESS.PROJECTILES:
		jobs.append({"unit": unit, "effect": "basic_attack_ranged_" + Warmup._visual_race(unit), "element": ""})
	for unit in Warmup.CHESS.MELEE_UNIT_RACE:
		jobs.append({"unit": unit, "effect": "basic_attack_melee_" + Warmup._visual_race(unit), "element": ""})
	for effect in Warmup.DIRECT_PACK_ROUTES:
		jobs.append({"unit": "god_priest", "effect": effect, "element": ""})
	for element in ["fire", "ice", "thunder", "poison"]:
		jobs.append({"unit": "human_mage", "effect": "random_attribute_bolt", "element": element})
	jobs.append({"unit": "dark_mage", "effect": "silence_bolt", "element": ""})
	jobs.append({"unit": "human_swordsman", "effect": "front_cone_stun", "element": ""})
	var viewport: SubViewport = warmup._make_viewport(template)
	var evidence: Array[Dictionary] = []
	for job in jobs:
		# Observe the real composer throughout its complete delayed-layer window,
		# independently of the direct route's list. Missing impacts, group target
		# layers, or a production route changing to another shader fail equality.
		var full: Node3D = warmup._spawn(viewport, job)
		var full_materials := {}
		var started := Time.get_ticks_msec()
		while Time.get_ticks_msec() - started < 900:
			warmup._retain_draw_materials(full, full_materials)
			await get_tree().process_frame
		warmup._retain_draw_materials(full, full_materials)
		var full_signatures := _material_signatures(full_materials)
		full.queue_free()
		await get_tree().process_frame
		var direct: Node3D = warmup._spawn_direct_oga(viewport, Warmup._direct_oga_route(job))
		var direct_materials := {}
		warmup._retain_draw_materials(direct, direct_materials)
		var direct_signatures := _material_signatures(direct_materials)
		var key := "%s|%s|%s" % [job.unit, job.effect, job.element]
		h.expect(not full_signatures.is_empty() and full_signatures == direct_signatures,
			"original_materials_" + key, "Immediate drawing includes every original body/impact/delayed layer texture, shader and material parameter")
		evidence.append({"key": key, "original": full_signatures, "direct": direct_signatures})
		direct.queue_free()
		await get_tree().process_frame
	viewport.queue_free()
	print("[OGA_DIRECT_COVERAGE] %s" % JSON.stringify(evidence))

func _visible_materials(node: Node, materials: Dictionary) -> void:
	if node is Node3D and not node.is_visible_in_tree():
		return
	if node is MeshInstance3D:
		if node.material_override != null:
			materials[node.material_override.get_instance_id()] = node.material_override
		if node.material_overlay != null:
			materials[node.material_overlay.get_instance_id()] = node.material_overlay
		if node.mesh != null:
			for i in node.mesh.get_surface_count():
				var material: Material = node.get_active_material(i)
				if material != null:
					materials[material.get_instance_id()] = material
	for child in node.get_children():
		_visible_materials(child, materials)

func _pipeline_signatures(materials: Dictionary) -> Array[String]:
	var signatures: Array[String] = []
	for material in materials.values():
		var key := str(material.get_class())
		if material is ShaderMaterial:
			key += "|" + material.shader.code.sha256_text()
			for uniform in material.shader.get_shader_uniform_list():
				var value: Variant = material.get_shader_parameter(uniform.name)
				if value is Texture2D:
					key += "|%s=%s" % [uniform.name, value.resource_path]
		elif material is BaseMaterial3D:
			key += "|%d|%d|%d|%s|%s" % [material.transparency, material.shading_mode,
				material.billboard_mode, str(material.vertex_color_use_as_albedo), str(material.no_depth_test)]
		if key not in signatures:
			signatures.append(key)
	signatures.sort()
	return signatures

func _compare_short_windows(h: RefCounted, warmup: Node, template: SubViewport) -> void:
	var jobs := [
		{"unit":"human_militia", "effect":"attack_interrupt", "element":""},
		{"unit":"human_cleric", "effect":"every_fifth_group_heal", "element":""},
		{"unit":"human_king", "effect":"unique_king_growth", "element":""},
		{"unit":"god_aurora", "effect":"true_damage_attack", "element":""},
		{"unit":"human_archer", "effect":"every_fourth_combo", "element":""},
		{"unit":"god_king", "effect":"global_divine_blast", "element":""},
		{"unit":"god_arbiter", "effect":"judgement_strike", "element":""},
	]
	var viewport: SubViewport = warmup._make_viewport(template)
	var omni := OmniLight3D.new()
	omni.omni_range = 64.0
	omni.light_energy = 0.001
	viewport.add_child(omni)
	for job in jobs:
		var observations: Array = []
		for duration in [0.90, Warmup.composer_warmup_duration(job.effect)]:
			var holder: Node3D = warmup._spawn(viewport, job)
			var variants := [{}, {}]
			var elapsed := 0.0
			var frames := 0
			while elapsed < duration or frames < 4:
				await get_tree().process_frame
				elapsed += get_process_delta_time()
				warmup._set_omni_visibility(viewport, frames % 2 == 1)
				await RenderingServer.frame_post_draw
				_visible_materials(holder, variants[frames % 2])
				frames += 1
			observations.append([_pipeline_signatures(variants[0]), _pipeline_signatures(variants[1])])
			holder.queue_free()
			await get_tree().process_frame
		# A sub-frame flash may be observed under an extra lighting state in
		# the short run; extra coverage is safe, missing coverage is not.
		var covered: bool = not observations[0][0].is_empty()
		for variant in 2:
			for signature in observations[0][variant]:
				covered = covered and signature in observations[1][variant]
		h.expect(covered,
			"short_window_" + job.effect, "Short preparation must draw every full-composer shader/texture pipeline with both light states")
		print("[SHORT_WARMUP_COVERAGE] ", JSON.stringify({"effect":job.effect,"full":observations[0],"short":observations[1]}))
	viewport.queue_free()
	await get_tree().process_frame
