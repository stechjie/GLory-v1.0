extends SceneTree
func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		var holder := Node3D.new()
		holder.scale = Vector3.ONE * 1.26
		get_root().add_child(holder)
		var w := (load(path) as PackedScene).instantiate() as Node3D
		holder.add_child(w)
		await process_frame
		await process_frame
		var em: Dictionary = w.get("_flame_emitters")
		for a in em.keys():
			for p in em[a]:
				var cp := p as CPUParticles3D
				var anchor := cp.get_parent() as BoneAttachment3D
				print("FL %s %s bone=%s emitting=%s p_global_scale=%s anchor_scale=%s pos=%s" % [path.get_file(), a, anchor.bone_name, cp.emitting, cp.global_transform.basis.get_scale(), anchor.global_transform.basis.get_scale(), w.global_transform.affine_inverse() * cp.global_position])
		holder.queue_free()
	quit(0)
