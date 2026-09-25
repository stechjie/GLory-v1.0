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
