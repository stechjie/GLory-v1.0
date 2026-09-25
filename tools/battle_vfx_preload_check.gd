extends Node
const H := preload("res://tools/CheckHarness.gd")
const Fixture := preload("res://scripts/qa/FixedBattleFixture.gd")
const Sim := preload("res://scripts/battle/BattleSimulator.gd")
const Manifest := preload("res://scripts/assets/BattleAssetManifest.gd")
const Chess := preload("res://effects/vfx3d/units/OgaChessVFXCatalog.gd")
const RenderWarmup := preload("res://scripts/assets/BattleRenderWarmup.gd")
var h: RefCounted

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	h = H.new("battle_vfx_preload")
	for round_index in [1, 20, 21]:
		Fixture.setup_match_state(round_index, 20260807)
		var replay: Dictionary = Sim.compute_team_replay(0)
		var paths: Array = Manifest.replay_texture_paths(replay)
		var render_jobs: Array[Dictionary] = RenderWarmup.collect_jobs([replay, replay])
		var job_keys := {}
		var has_archer := false
		var has_mirror := false
		for job in render_jobs:
			job_keys[job.key] = true
			has_archer = has_archer or (job.unit == "human_archer" and job.effect == "basic_attack_ranged_human")
			has_mirror = has_mirror or job.effect == "mirror_spawn"
		h.expect(job_keys.size() == render_jobs.size() and render_jobs.size() < RenderWarmup.MAX_JOBS, "renderer_jobs_bounded", "Actual round %d uses %d unique current-roster render routes even when both perspectives repeat" % [round_index, render_jobs.size()])
		h.expect(has_archer and has_mirror == (round_index == 20), "renderer_real_routes", "Authored archer projectile always renders; mirror spawn only renders for its actual Boss round")
		var old_paths: Array = []
		var expected_oga: Array = []
		for entry in (replay.roster as Dictionary).values():
			for cfg in SkillVFXConfig.get_textures(str(entry.id)):
				if not old_paths.has(cfg.path):
					old_paths.append(cfg.path)
			var projectile: Dictionary = Chess.projectile_for(str(entry.id))
			for key in ["path", "impact_path"]:
				var path := str(projectile.get(key, ""))
				if not path.is_empty() and not expected_oga.has(path):
					expected_oga.append(path)
		var omitted_before := 0
		var omitted_after := 0
		var missing: Array = []
		for path in expected_oga:
			if not old_paths.has(path):
				omitted_before += 1
			if not paths.has(path):
				omitted_after += 1
		for path in paths:
			if not ResourceLoader.exists(path):
				missing.append(path)
		var unique := {}
		for path in paths:
			unique[path] = true
		h.expect(omitted_before > 0 and omitted_after == 0, "actual_fixture_coverage", "Round %d previously omitted %d OGA projectile/impact paths; now omits %d" % [round_index, omitted_before, omitted_after])
		h.expect(missing.is_empty(), "resources_exist", "Every requested texture exists: %s" % str(missing))
		h.expect(unique.size() == paths.size(), "deduplicated", "Repeated units, impacts and delayed layers share one preload request")
		print("VFX_PRELOAD_METRICS %s" % JSON.stringify({"round": round_index, "roster_count": replay.roster.size(),
			"legacy_unique_paths": old_paths.size(), "current_unique_paths": paths.size(), "oga_projectile_omitted_before": omitted_before,
			"oga_projectile_omitted_after": omitted_after, "missing_paths": missing}))
	# A unit that spawns only in a later frame must still contribute its model,
	# projectile and impact; two distinct summoned UIDs must not duplicate IO.
	var late := {"roster": {
		"original": {"id": "human_archer", "def": {"model": "res://sentinel/base.tscn"}},
		"summon_lane_0": {"id": "undead_titan", "def": {"model": "res://sentinel/summon.tscn", "skill_id": "poison_reflect_armor_stack"}},
		"summon_lane_1": {"id": "undead_titan", "def": {"model": "res://sentinel/summon.tscn", "skill_id": "poison_reflect_armor_stack"}}},
		"frames": [[["original", 0, 0, 100, true]], [["summon_lane_0", 0, 0, 100, true], ["summon_lane_1", 0, 0, 100, true]]]}
	var late_paths: Array = Manifest.replay_texture_paths(late)
	h.expect(late_paths.has("res://assets/vfx/oga/skill_packs/nature_armor.png") and late_paths.has("res://assets/vfx/oga/skill_packs/special_green.png"), "summoned_nested_layers", "Complete roster includes delayed armor skill layers from later summoned fighters")
	h.expect(Manifest.replay_paths(late) == ["res://sentinel/base.tscn", "res://sentinel/summon.tscn"], "summoned_models_unique", "Full summoned roster models preload once per path, independent of UID")
	var late_jobs: Array[Dictionary] = RenderWarmup.collect_jobs([late])
	var summoned_skill_count := 0
	for job in late_jobs:
		if job.effect == "poison_reflect_armor_stack":
			summoned_skill_count += 1
	h.expect(summoned_skill_count == 1, "summoned_renderer_route", "Two later summoned identities render their actual armor material route exactly once")
	h.expect(RenderWarmup.collect_jobs([{}]).is_empty(), "renderer_empty_roster", "No current fighters means no all-catalog warmup")
	var single: Array = Manifest.fighter_texture_paths("human_archer", {})
	h.expect(single.has("res://assets/vfx/oga/projectiles/human_archer_metal_arrow.png") and single.has("res://assets/vfx/oga/impacts/human_archer_hit.png"), "archer_actual_paths", "The actual authored metal arrow and separate delayed impact are both covered")
	h.expect(not single.has("res://assets/vfx/oga/skill_packs/nature_armor.png"), "current_fighters_only", "An archer does not preload unrelated undead armor or the whole catalog")
	var silence: Array = Manifest.fighter_texture_paths("dark_mage", {"skill_id": "silence_bolt"})
	h.expect(silence.has("res://assets/vfx/oga/skill_packs/cosmic_orb.png") and silence.has("res://assets/vfx/oga/skill_packs/cosmic_seal.png"), "silence_projectile", "Silence launch and delayed impact both preload")
	var doom: Array = Manifest.fighter_texture_paths("dark_doom", {"skill_id": "shared_hp_link"})
	h.expect(doom.has("res://assets/vfx/skills/dark_doom_link/doom_link_chain.png") and doom.has("res://assets/vfx/skills/dark_doom_link/doom_link_knot.png") and doom.has("res://assets/vfx/skills/dark_doom_link/doom_link_tear.png"), "current_doom_route", "Authored Doom rope, knot and tear replace retired generic link preload")
	NetworkService.team_active = false
	GameState.reset_run()
	h.finish(get_tree())
