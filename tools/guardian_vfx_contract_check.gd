extends SceneTree

# Run with: Godot --headless --path . --script res://tools/guardian_vfx_contract_check.gd
# Loads production scripts after autoload setup, then exercises the real opening
# route, replay-shaped snapshots, state updates and owner cleanup. No image test
# can prove these lifecycle/skill semantics; visual acceptance remains separate.
const Harness := preload("res://tools/CheckHarness.gd")
var h := Harness.new("guardian_vfx_contract")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	await process_frame
	var network := root.get_node_or_null("NetworkService")
	if network != null:
		network.set_process(false)
	_check_preview_requests()
	var factory: Script = load("res://scripts/units/UnitFactory.gd")
	var simulator: Script = load("res://scripts/battle/BattleSimulator.gd")
	var shared: Script = load("res://scripts/battle/BattleSimShared.gd")
	var battle_script: Script = load("res://scenes/battle/BattleVfx.gd")
	var route_script: Script = load("res://effects/BossProceduralVFX3D.gd")
	var warmup_script: Script = load("res://scripts/assets/BattleRenderWarmup.gd")
	var guardian_job := {"unit": "god_guard", "effect": "guardian_shield_taunt", "element": ""}
	h.expect((warmup_script._direct_oga_route(guardian_job) as Dictionary).is_empty(), "warmup_real_route", "Guardian preparation must not bypass its composer through the retired OGA plate")
	var warmup: Node = warmup_script.new()
	root.add_child(warmup)
	var viewport := SubViewport.new()
	warmup.add_child(viewport)
	var prepared: Node3D = warmup.call("_spawn", viewport, guardian_job)
	var retained := {}
	warmup.call("_retain_draw_materials", prepared, retained)
	var shader_paths: Array = warmup_script._material_shader_paths(retained)
	h.expect("res://effects/vfx3d/shaders/guardian_sanctuary.gdshader" in shader_paths and "res://effects/vfx3d/shaders/guardian_range.gdshader" in shader_paths, "warmup_guardian_shaders", "Preparation must retain both actual guardian shaders")
	var has_shard_material := false
	for material in retained.values():
		if material is StandardMaterial3D and material.vertex_color_use_as_albedo and material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
			has_shard_material = true
	h.expect(has_shard_material, "warmup_instanced_shards", "The activation MultiMesh material must survive temporary warmup world disposal")
	warmup.queue_free()
	await process_frame
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/race_units.json"))
	var base: Dictionary = {}
	for definition: Dictionary in parsed.get("units", []):
		if str(definition.get("id", "")) == "god_guard":
			base = definition
			break
	if not h.expect(not base.is_empty(), "unit_identity", "god_guard must be the selected unit"):
		h.finish(self)
		return
	h.expect(str(base.get("skill_id", "")) == "guardian_shield_taunt", "skill_identity", "Guard must use its own opening shield/taunt skill")
	var battle: Control = battle_script.new()
	root.add_child(battle)
	var arena := Control.new()
	arena.size = Vector2(1000.0, 520.0)
	battle.add_child(arena)
	battle.set("_arena", arena)
	var route: Node3D = route_script.new()
	battle.add_child(route)
	battle.set("_battle_3d_vfx_root", route)
	var actor := _actor()
	root.add_child(actor)
	var registry: RefCounted = battle.get("_unit_actor_registry")
	h.expect(registry.call("register_actor", "guardian_test", actor), "actor_contract", "Test actor must use the production anchor contract")
	var d: Dictionary = factory.apply_star_stats(base, 1)
	var live := _fighter(d)
	var battle_log: Array[String] = []
	simulator._apply_opening_unit_skills([live], [], battle_log, {"elapsed": 0.0})
	h.expect(int(live.shield) == int(round(float(live.max_hp) * float(d.start_shield_pct))), "opening_self_shield", "Opening shield must match actual resolved unit data")
	h.expect(bool(live.get("taunt_active", false)), "opening_taunt", "Opening skill must activate the guardian taunt")
	# Enter through the production snapshot dispatcher, including opening seeding.
	battle.call("_refresh_battle_vfx", {"player": [live], "enemy": []})
	var snapshots: Dictionary = battle.get("_vfx_prev_units")
	var records: Dictionary = battle.get("_persistent_unit_vfx")
	var effect: Node3D = (records.get("guardian_test", {}) as Dictionary).get("node")
	if not h.expect(is_instance_valid(effect), "formal_route", "Production opening route must create a persistent guardian effect"):
		battle.free()
		actor.free()
		h.finish(self)
		return
	if not h.expect(effect.get_script().resource_path.ends_with("VFXGuardianSanctuary3D.gd") and effect.has_method("get_debug_state"), "exclusive_new_route", "Formal skill must reach the new module, rather than the old OGA plate"):
		battle.free()
		actor.free()
		h.finish(self)
		return
	var initial: Dictionary = effect.call("get_debug_state")
	h.expect(bool(initial.get("persistent", false)) and bool(initial.get("shield_active", false)) and bool(initial.get("taunt_active", false)), "opening_visual_state", "Both independent states must start active")
	var expected_radius: Vector2 = battle.call("_guardian_taunt_world_radius", float(d.taunt_radius))
	h.expect((initial.get("world_radius", Vector2.ZERO) as Vector2).is_equal_approx(expected_radius), "mapped_radius", "Effect radius must come from the battle coordinate conversion")
	h.expect(not is_equal_approx(expected_radius.x, expected_radius.y), "anisotropic_radius", "A simulation circle must retain the arena's nonuniform X/Z scale")
	h.expect(int(initial.get("spark_count", 100000)) <= 48, "bounded_particles", "A persistent guardian must not exceed the low-tier per-effect particle ceiling")
	var range_mesh := effect.get_node("TauntRange_NoDamage") as MeshInstance3D
	var seal_mesh := effect.get_node("ShieldFootSeal") as MeshInstance3D
	var foot := actor.get_node("FootAnchor") as Node3D
	var cast := actor.get_node("CastAnchor") as Node3D
	h.expect(_same_ground_center(range_mesh, foot) and _same_ground_center(seal_mesh, foot), "ground_center_at_opening", "Actual range and seal meshes must center on the production FootAnchor, not the offset CastAnchor")
	await create_timer(1.5).timeout
	h.expect(is_instance_valid(effect) and float(effect.call("get_debug_state").get("range_fade", 0.0)) > 0.99, "persistent_hold", "The formal effect must remain readable after its opening burst ends")
	# Retained nodes must follow their caster, without replaying the opening burst.
	await process_frame
	var before := effect.global_position
	var move := Vector3(0.7, 0.0, -0.4)
	actor.position += move
	await process_frame
	await process_frame
	h.expect((effect.global_position - before).is_equal_approx(move), "caster_follow", "Persistent shell/range must follow the original actor")
	h.expect(_same_ground_center(range_mesh, foot) and _same_ground_center(seal_mesh, foot), "ground_center_after_move", "Both ground meshes must retain their actor's actual foot center after movement")
	actor.rotation.y = PI * 0.5
	await process_frame
	await process_frame
	h.expect(_same_ground_center(range_mesh, foot) and _same_ground_center(seal_mesh, foot), "ground_center_after_turn", "Turning the production actor must not orbit the range/seal around its feet")
	h.expect(effect.global_position.is_equal_approx(cast.global_position), "body_follows_cast_after_turn", "Ground centering must preserve the body's original CastAnchor attachment")
	h.expect(range_mesh.global_basis.x.is_equal_approx(Vector3.RIGHT * expected_radius.x) and range_mesh.global_basis.z.is_equal_approx(Vector3.BACK * expected_radius.y), "world_ellipse_after_turn", "Taunt axes and radii must stay in battle world space when the actor turns")
	battle.call("_play_opening_unit_vfx", snapshots)
	h.expect((battle.get("_persistent_unit_vfx") as Dictionary)["guardian_test"].node == effect, "opening_deduplicated", "Repeated seeding must not stack another guardian")
	# Shield depletion does NOT stop taunt in the actual simulation.
	live.shield = 0
	var attacker := {"uid": "enemy", "team": "enemy", "lane": 0, "pos": live.pos + Vector2(20, 0), "def": {}}
	h.expect(not (shared._nearest_taunter(attacker, [live]) as Dictionary).is_empty(), "taunt_after_shield_sim", "Actual targeting must retain taunt after shield is depleted")
	battle.call("_refresh_battle_vfx", {"player": [live], "enemy": []})
	var depleted: Dictionary = effect.call("get_debug_state")
	h.expect(not bool(depleted.get("shield_active", true)) and bool(depleted.get("taunt_active", false)), "taunt_after_shield_visual", "Shield depletion must remove only the shell, preserving taunt")
	await create_timer(0.3).timeout
	depleted = effect.call("get_debug_state")
	h.expect(float(depleted.get("shield_fade", 1.0)) < 0.001 and float(depleted.get("range_fade", 0.0)) > 0.99, "independent_visual_fades", "The actual shield fade must finish while the taunt range stays visible")
	# Replay fighters omit taunt_active/radius, but retain the four-star resolved
	# definition. Test that path, not a hand-authored context with a hardcoded size.
	var star4: Dictionary = factory.apply_star_stats(base, 4)
	var replay_fighter := _fighter(star4)
	replay_fighter.shield = 0
	battle.call("_refresh_battle_vfx", {"player": [replay_fighter], "enemy": []})
	var replay_state: Dictionary = effect.call("get_debug_state")
	var star4_radius: Vector2 = battle.call("_guardian_taunt_world_radius", float(star4.taunt_radius))
	h.expect(bool(replay_state.get("taunt_active", false)) and not bool(replay_state.get("shield_active", true)), "replay_state_parity", "Replay must retain taunt without inventing a depleted shield")
	h.expect((replay_state.get("world_radius", Vector2.ZERO) as Vector2).is_equal_approx(star4_radius) and star4_radius.x > expected_radius.x, "four_star_radius", "Four-star range must reach the effect through resolved data")
	# Death clears both states and releases the record/node.
	replay_fighter.alive = false
	snapshots = battle.call("_collect_vfx_units", {"player": [replay_fighter], "enemy": []})
	battle.call("_sync_persistent_unit_vfx", snapshots)
	h.expect(not (battle.get("_persistent_unit_vfx") as Dictionary).has("guardian_test"), "death_record_cleanup", "Dead guardian must not remain in the persistent registry")
	await create_timer(0.2).timeout
	h.expect(not is_instance_valid(effect), "death_node_cleanup", "Dead guardian effect must finish after its fade")
	# Restart cleanup is deliberately guardian-only; the existing blood-link
	# lifecycle must retain ownership of its own record.
	replay_fighter.alive = true
	snapshots = battle.call("_collect_vfx_units", {"player": [replay_fighter], "enemy": []})
	battle.call("_play_opening_unit_vfx", snapshots)
	records = battle.get("_persistent_unit_vfx")
	var restarted: Node3D = records["guardian_test"].node
	records["unrelated_link"] = {"kind": "blood_link", "target_uid": "target"}
	battle.call("_clear_guardian_unit_vfx")
	h.expect(records.has("unrelated_link") and not records.has("guardian_test"), "selective_restart_cleanup", "Guardian reset must preserve unrelated blood-link records")
	await process_frame
	h.expect(not is_instance_valid(restarted), "restart_node_cleanup", "Restart must release old guardian before a fresh opening")
	records.erase("unrelated_link")
	# Owner deletion must clean itself even if no next battle snapshot arrives.
	battle.call("_play_opening_unit_vfx", snapshots)
	var orphan: Node3D = (battle.get("_persistent_unit_vfx") as Dictionary)["guardian_test"].node
	actor.queue_free()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout
	h.expect(not is_instance_valid(orphan), "owner_cleanup", "Owner deletion must not leave a floating persistent effect")
	battle.free()
	h.finish(self)

func _fighter(definition: Dictionary) -> Dictionary:
	return {"uid": "guardian_test", "id": "god_guard", "name": "光之卫士", "team": "player", "lane": 0,
		"hp": int(definition.hp), "max_hp": int(definition.hp), "shield": 0, "alive": true,
		"pos": Vector2(500.0, 260.0), "def": definition, "statuses": {}}

func _actor() -> Node3D:
	var actor_script: Script = load("res://effects/runtime/presentation/UnitActor3D.gd")
	var actor: Node3D = actor_script.new()
	actor.name = "GuardianContractActor"
	actor.call("configure_contract", 0.98, "melee")
	return actor

func _same_ground_center(mesh: Node3D, foot: Node3D) -> bool:
	return Vector2(mesh.global_position.x, mesh.global_position.z).is_equal_approx(Vector2(foot.global_position.x, foot.global_position.z))

func _check_preview_requests() -> void:
	var preview: Script = load("res://effects/preview/GuardianVFXPreview.gd")
	# Round-trip the same JSON types used by the device protocol. This tests the
	# public request boundary without starting a preview or touching user files.
	var request: Dictionary = JSON.parse_string(JSON.stringify({
		"run_id": "guardian-contract", "perf": true, "animate": true,
		"star4": true, "close": true, "color": "#7ab8ffff", "mode": "new",
		"count": 6, "tier": 1, "cases": [
			{"mode": "off", "count": 1, "tier": 0, "seconds": 30},
			{"mode": "old", "count": 6, "tier": 1, "seconds": 30},
			{"mode": "new", "count": 12, "tier": 2, "seconds": 180},
		]}))
	h.expect(str(preview.validate_request(request)).is_empty(), "preview_complete_request", "A complete JSON device request must support animated four-star/color previews and the comparative performance cases")
	var invalid_cases := {
		"mode": {"mode": "unknown"},
		"count": {"count": 0},
		"tier": {"tier": -1},
		"case_type": {"cases": ["new"]},
		"color": {"color": "not-a-color"},
	}
	for label: String in invalid_cases:
		var invalid := request.duplicate(true)
		invalid.merge(invalid_cases[label], true)
		h.expect(not str(preview.validate_request(invalid)).is_empty(), "preview_reject_" + label, "Invalid device input must be rejected before scene construction or measurement")
