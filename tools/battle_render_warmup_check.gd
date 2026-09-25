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
		var second: Dictionary = await warmup.prepare_replays([replay], template)
		h.expect(int(second.get("rendered", -1)) == 0, "same_renderer_reuse", "Second preparation in the same renderer/quality reuses completed variants")
		var keep_running := {"value": true}
		get_tree().create_timer(0.05).timeout.connect(func(): keep_running.value = false)
		var cancel_replay := {"roster": {"late": {"id": "human_cleric", "def": {"range": 4.0, "skill_id": "every_fifth_group_heal"}}}}
		var cancelled: Dictionary = await warmup.prepare_replays([cancel_replay], template, Callable(), func() -> bool: return keep_running.value)
		h.expect(str(cancelled.get("error", "")) == "render_warmup_cancelled", "cancel_during_draw", "Skip/scene cancellation stops active preparation before the remaining routes render")
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
