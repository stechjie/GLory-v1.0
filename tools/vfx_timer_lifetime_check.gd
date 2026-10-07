extends Node

const H := preload("res://tools/CheckHarness.gd")

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	var h := H.new("vfx_timer_lifetime")
	var path := "res://effects/vfx3d/VFXLightningArc.gd"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--effect-script="):
			path = arg.trim_prefix("--effect-script=")
	var script: Script = load(path)
	# Keep the node alive but remove it from the scene, exactly as a cancelled
	# battle/scene transition can do while a SceneTreeTimer still holds a signal.
	for delay in [0.01, 0.06, 0.10, 0.18, 0.24, 0.35]:
		var effect: Node3D = script.new()
		add_child(effect)
		effect.play_arc(Vector3(0, 2, 0), Vector3.ZERO)
		await get_tree().create_timer(delay).timeout
		remove_child(effect)
		var children := effect.get_child_count()
		await get_tree().create_timer(0.12).timeout
		h.expect(is_instance_valid(effect) and effect.get_child_count() == children,
			"detached_%.2f" % delay, "Cancelled effect must not create later stages or dereference a null SceneTree")
		effect.free()
	var normal: Node3D = script.new()
	add_child(normal)
	normal.play_arc(Vector3(0, 2, 0), Vector3.ZERO)
	await get_tree().create_timer(1.0).timeout
	h.expect(not is_instance_valid(normal), "normal_completion", "An attached effect still finishes and releases itself")
	# Check the actual composer too: it extends Node3D, not VFXBlockRoot.
	var boss_script: Script = load("res://effects/vfx3d/boss/BossSkillVFXComposer3D.gd")
	h.expect(boss_script != null and boss_script.can_instantiate(), "boss_compiles", "Boss composer must resolve all helper calls")
	var hit_script: Script = load("res://effects/vfx3d/modules/VFXHitStopController.gd")
	var hit: Node = hit_script.new()
	add_child(hit)
	var original_scale := Engine.time_scale
	hit.play_hit_stop(0.075, 0.08)
	await get_tree().create_timer(0.25, true, false, true).timeout
	h.expect(is_equal_approx(Engine.time_scale, original_scale), "hit_stop_real_time", "Hit stop must restore time scale in real time, not slowed game time")
	if is_instance_valid(hit):
		hit.free()
	Engine.time_scale = original_scale
	h.finish(get_tree())
