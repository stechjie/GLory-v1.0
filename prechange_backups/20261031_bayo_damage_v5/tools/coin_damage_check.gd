extends Node
const Harness := preload("res://tools/CheckHarness.gd")
const Hud := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")
const Sim := preload("res://scripts/battle/BattleSimulator.gd")
const Burst := preload("res://effects/vfx3d/modules/VFXCoinBurst3D.gd")
const LaneBurst := preload("res://effects/vfx3d/modules/VFXLaneClearBurst3D.gd")
const Ronin := preload("res://effects/vfx3d/frameronin/FrameRoninImpactMeshes.gd")
const Quality := preload("res://effects/vfx3d/core/VFXQualityBudget.gd")
var h: RefCounted

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	h = Harness.new("coin_damage")
	var hud := Hud.new()
	add_child(hud)
	hud.size = Vector2(1600,720)
	for index in range(6):
		var value := int(Hud.DAMAGE_TIERS[index])
		h.expect(Hud.damage_tier(value - 1) == index, "below_%d" % index, "Below threshold must retain prior tier")
		h.expect(Hud.damage_tier(value) == index + 1, "at_%d" % index, "Exact threshold must advance")
		hud.show_damage(value, false)
		h.expect(hud._damage_total == value and hud._damage_title.text == "D A M A G E", "label_%d" % index, "Shows authoritative total")
	for round_number in [1, 10, 11]:
		var thresholds: Array = Hud.EARLY_DAMAGE_TIERS if round_number <= 10 else Hud.DAMAGE_TIERS
		for index in range(thresholds.size()):
			var threshold := int(thresholds[index])
			h.expect(Hud.damage_tier(threshold-1,round_number)==index and Hud.damage_tier(threshold,round_number)==index+1,"round_%d_tier_%d" % [round_number,index],"Round-specific thresholds have exact boundaries")
	hud.show_damage(10000,false,10)
	h.expect(hud._current_tier == 4,"round10_top","Round 10 uses early cap")
	hud.show_damage(10000,false,11)
	h.expect(hud._current_tier == 1,"round11_switch","Same total is restyled at round 11")
	hud.show_damage(640001, false)
	h.expect(Hud.damage_tier(640001) == 6 and hud._damage_total == 640001, "visual_cap", "Only artwork is capped")
	h.expect(hud._damage_label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "input_transparent", "HUD cannot block input")
	hud.show_damage(30, false)
	h.expect(not hud._fire.visible and hud._damage_total == 30, "seek_absolute", "Seek replaces total and removes higher fire")
	var state := {"kind":"pve", "elapsed":1.0, "player":[], "enemy":[], "visual_events":[], "unit_stats":{
		"a":{"owner_slot":0,"team":"player","group":"player","damage_dealt":100},
		"dead":{"owner_slot":0,"team":"player","group":"player","damage_dealt":200},
		"ally":{"owner_slot":1,"team":"player","group":"player","damage_dealt":900},
		"boss":{"owner_slot":0,"team":"enemy","group":"boss","damage_dealt":999}}, "element_damage_by_slot":{0:50}}
	var frames: Array = []
	Sim._replay_capture_frame(state, frames, [])
	h.expect(state._replay_slot_damage == [[350,900,0,0,0,0]], "owner_snapshot", "Snapshot includes dead units/elements, excludes boss and separates teammates")
	h.expect(frames.size() == 1 and frames[0].is_empty(), "frames_unchanged", "Presentation snapshot does not add unit frame columns")
	var fx := Burst.new()
	add_child(fx)
	fx.play_burst(Vector3.ZERO,0.0,Vector3.RIGHT,Color.RED,"normal",true)
	h.expect(fx.get_node_or_null("GoldCoins") is MultiMeshInstance3D, "coin_mesh", "Real flat coin batch exists")
	h.expect(fx.find_children("BurstShards*","MultiMeshInstance3D",true,false).size()==3, "layered_shards", "Three thin fragment batches")
	h.expect(fx.get_node_or_null("GoldShortTrails") is MultiMeshInstance3D,"gold_trails","Short impact trails are batched")
	for preset in [81,85]:
		var poses: Array[ArrayMesh] = Ronin.frames(preset)
		h.expect(poses[0] == Ronin.frames(preset)[0],"ronin_cache_%d" % preset,"Repeated deaths reuse imported geometry")
		h.expect(poses[-1].get_aabb().size.x > poses[0].get_aabb().size.x,"ronin_growth_%d" % preset,"Fatal-hit outline grows rather than staying a static badge")
	var saved_quality := Quality.tier
	Quality.tier = Quality.Tier.LOW
	var low := Burst.new()
	add_child(low)
	low.play_burst(Vector3.ZERO,0.0,Vector3.ZERO,Color.RED,"normal",true)
	h.expect(low.get_node_or_null("GoldImpactCore") == null and low.get_node_or_null("GoldCoins") != null,"low_flash_gate","Low tier retains coins without the bright imported accent")
	Quality.tier = saved_quality
	var wave := LaneBurst.new()
	add_child(wave)
	var bounds := Rect2(-1.5,-3.0,3.0,6.0)
	wave.play_clear(Vector3(1.0,0.0,2.5),bounds)
	var plane := wave.get_node("LaneClippedWave") as MeshInstance3D
	h.expect(plane.mesh.size == bounds.size and plane.position.x == 0.0 and plane.position.z == 0.0,"lane_bounds","Wave geometry remains inside the supplied lane")
	var origin: Vector2 = plane.material_override.get_shader_parameter("origin_uv")
	h.expect(origin.is_equal_approx(Vector2(2.5/3.0,5.5/6.0)),"wave_origin","Wave originates at final enemy rather than lane center")
	await get_tree().create_timer(1.05).timeout
	await get_tree().process_frame
	h.expect(not is_instance_valid(fx), "burst_released", "Transient coin burst releases itself")
	h.expect(not is_instance_valid(wave),"wave_released","Lane clear has no lingering nodes")
	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	h.expect(not source.contains("_record_personal_kill") and not source.contains("show_kills"), "removed_kills", "Old personal Kills counter is removed")
	h.expect(not FileAccess.get_file_as_string("res://ui/services/SfxService.gd").contains("CUE_KILL_STREAK"), "removed_streak_audio", "Old streak cue is unregistered")
	hud.queue_free()
	h.finish(get_tree())
