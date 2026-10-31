extends Node
const Harness := preload("res://tools/CheckHarness.gd")
const Hud := preload("res://effects/runtime/presentation/BattleCombatFeedback.gd")
const Sim := preload("res://scripts/battle/BattleSimulator.gd")
const Burst := preload("res://effects/vfx3d/modules/VFXCoinBurst3D.gd")
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
		h.expect(hud._damage_label.text == "DAMAGE ×%d" % value, "label_%d" % index, "Shows authoritative total")
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
	await get_tree().create_timer(1.05).timeout
	await get_tree().process_frame
	h.expect(not is_instance_valid(fx), "burst_released", "Transient coin burst releases itself")
	var source := FileAccess.get_file_as_string("res://scenes/battle/BattleVfx.gd")
	h.expect(not source.contains("_record_personal_kill") and not source.contains("show_kills"), "removed_kills", "Old personal Kills counter is removed")
	h.expect(not FileAccess.get_file_as_string("res://ui/services/SfxService.gd").contains("CUE_KILL_STREAK"), "removed_streak_audio", "Old streak cue is unregistered")
	hud.queue_free()
	h.finish(get_tree())
