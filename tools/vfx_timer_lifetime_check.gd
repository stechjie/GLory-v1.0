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
	h.finish(get_tree())
